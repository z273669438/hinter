import 'dart:math' as math;


/// 语音跟随算法(增量对齐器)。
///
/// 维护两个指针,把「识别转写」和「脚本」做增量对齐:
/// - [_tx]   :已对齐消费到的转写位置(归一化后);
/// - [_offset]:已对齐到的脚本位置(归一化后)。
///
/// 每帧把最新转写全文(定稿 + 实时 partial)归一化后整体替换进来(不是累加!
/// 转写本身是全文,累加会产生大量重复导致永远对不上),然后从 [_tx] 继续
/// 向后对齐:两边字符相同则双指针前进;不一致时做有界容错——
/// - 转写多字/错字 → 跳过转写字;
/// - 用户漏念/跳读 → 在脚本前向小窗里找该转写字,跳过脚本字;
/// - 连续容错超过预算(由 threshold 决定)就停下,等下一帧。
///
/// [_offset] 同时记录了对应原文位置([rawIndex]),UI 由此决定高亮与滚动,
/// 与字号、换行方式无关。
class LineFollower {
  LineFollower({
    required String rawText,
    this.threshold = 0.8,
    this.sensitivity = 0.5,
    this.onAdvance,
  }) : rawLength = rawText.length {
    final sb = StringBuffer();
    final idx = <int>[];
    for (var i = 0; i < rawText.length; i++) {
      final ch = rawText[i].toLowerCase();
      if (_noise.hasMatch(ch)) continue;
      sb.write(ch);
      idx.add(i);
    }
    norm = sb.toString();
    rawIndex = idx;
  }

  /// 高亮窗口长度(字符数)
  static const int chunkSize = 16;

  /// 高亮窗口:高亮内容始终领先"用户念到的位置"约 6 字(5~6 个)
  static const int highlightLead = 8;

  final double threshold;
  final void Function()? onAdvance;

  /// 原文总长(UTF-16 码元)
  final int rawLength;

  /// 归一化后的全文
  late final String norm;

  /// norm[i] 对应的原文下标
  late final List<int> rawIndex;

  int _offset = 0;      // 显示指针(限速推进,决定高亮位置)
  int _mpos = 0;        // 对齐指针(跟随语音实时前进,可以超前显示)
  double _debt = 0;     // 已匹配但还没"放出来"的字符
  int _lastFeedMs = 0;
  int _farWindows = 0;
  int _lastTranscriptMs = 0; // 最近一次新转写到达时刻(判断转写流是否活跃)
  int _lastAnchorMs = 0;     // 上次锚定时刻(用真实间隔标定语速)
  int _lastAnchorMpos = 0;

  /// 用锚定间的真实间隔标定语速 EMA(feedWindow 的 dt 被夹到 0.5s,
  /// 不能直接用;语速不准会让外推段速度失配 → 又出现台阶)
  void _updateUserRate(int newMpos) {
    final now = DateTime.now().millisecondsSinceEpoch;
    if (_lastAnchorMs > 0) {
      final rd = ((now - _lastAnchorMs) / 1000.0).clamp(1.0, 8.0);
      final moved = (newMpos - _lastAnchorMpos) / rd;
      if (moved >= 0 && moved <= 12) {
        _userRate += (moved - _userRate) * 0.25;
      }
    }
    _lastAnchorMs = now;
    _lastAnchorMpos = newMpos;
  }
  double _userRate = 4.0; // 对齐指针推进速度的 EMA(≈用户真实语速)

  /// 识别跟随灵敏度(0~1,用户可调):映射到
  /// 冻结阈值 [0.03,0.33] 与容错预算 [4,22] —— 越高越宽容
  double sensitivity = 0.5;
  double _mExact = 0; // 近期精确匹配数的 EMA
  double _mCons = 0; // 近期转写消耗数的 EMA
  bool _frozen = false; // 宽容起步;持续脱节(EMA 低)才转严格
  double _stuckMs = 0; // 脱节(严格模式)持续时长
  int _tx = 0;
  String _spoken = '';
  bool _awaitFresh = false;
  bool _offlineMode = false; // 离线引擎(whisper)窗口对齐模式

  /// 显示推进速度(归一化字符/秒)。取慢于中文口播语速,宁可略滞后也不抢跑;
  /// 深滞后时另有温和纠偏(见 _release),整体封顶 ~4.8 字/秒
  static const double _displayRate = 5.5;

  /// 转写缓存上限(只需覆盖最近若干句 + 容错余量)
  static const int _maxSpoken = 400;

  static final RegExp _noise = RegExp(r'[\p{P}\p{S}\s]', unicode: true);

  int get charOffset => _offset;

  /// 离线引擎(whisper)窗口对齐模式开关
  set offlineMode(bool v) => _offlineMode = v;
  // ignore: unused_element
  bool get dbgFrozen => _frozen;
  // ignore: unused_element
  int get dbgTx => _tx;
  bool get finished => _mpos >= norm.length;

  /// 当前阅读位置对应的原文下标(高亮起点)
  int get rawOffset {
    final o = _offset;
    if (rawIndex.isEmpty) return 0;
    if (o >= rawIndex.length) return rawIndex.last + 1;
    return rawIndex[o];
  }

  /// 从阅读位置往后数 [chars] 个归一化字符的原文下标(高亮终点)
  int rawOffsetPlus(int chars) {
    final i = _offset + chars;
    if (i >= rawIndex.length) return rawLength;
    if (i < 0) return 0;
    return rawIndex[i];
  }

  /// 每收到一帧识别结果调用一次(传入全文)。
  /// 离线引擎(whisper)的窗口转写走 [feedWindow]。
  void feed(String asrText) {
    if (_offlineMode) {
      feedWindow(asrText);
      return;
    }
    final now = DateTime.now().millisecondsSinceEpoch;
    if (_lastFeedMs == 0) _lastFeedMs = now;
    final dt = ((now - _lastFeedMs) / 1000.0).clamp(0.0, 0.5);
    _lastFeedMs = now;
    var n = normalize(asrText);
    if (n.isEmpty) return;
    if (n.length > _maxSpoken) {
      final cut = n.length - _maxSpoken;
      n = n.substring(cut);
      // 砍头后转写指针同步平移,否则对齐基准漂移(长脚本跳变 bug)
      _tx = (_tx - cut).clamp(0, n.length);
    }
    if (_awaitFresh) {
      // 跳转/重置后等的是全新转写,从零开始对齐
      _tx = 0;
      _awaitFresh = false;
    } else if (n.length < _tx) {
      _tx = n.length; // 转写尾部被修订缩短
    }
    // 转写消费量(近似):长度增长即视为有新语音内容到达
    final consumedTx = math.max(0, n.length - _spoken.length);
    if (n != _spoken) _lastTranscriptMs = DateTime.now().millisecondsSinceEpoch;
    _spoken = n;
    final mposBefore = _mpos;
    if (!finished) _align();
    if (dt > 0.001) {
      final moved = (_mpos - mposBefore) / dt; // 字/秒
      // 只接受 0~12 字/秒的样本(超出多为跳读/快照,不代表语速)
      final sample = moved.clamp(0.0, 12.0);
      _userRate += (sample - _userRate) * 0.20;
    }
    final before = _offset;
    _release(dt);
    // ---- 失联重锚定:脱节持续 >1.2s → 用转写末尾(刚念的字)到全文
    // 搜索,命中即跳转 —— 支持用户从脚本任意位置直接开始朗读 ----
    // 失联判定:匹配率极低,或已处于冻结态(误差大的段落同样会卡死)
    final lostNow = consumedTx > 0 &&
        (_frozen || (_mCons > 1.2 && (_mExact / _mCons) < 0.06));
    if (lostNow) {
      _stuckMs += dt * 1000;
      if (_stuckMs > 1200) {
        _stuckMs = 0;
        final newMpos = _tryReanchor(n);
        if (newMpos >= 0) {
          _mpos = newMpos;
          _tx = n.length;
          _offset = math.min(_mpos, _offset + 10); // 高亮就近跳转
          _debt = 0;
          onAdvance?.call();
        }
      }
    } else {
      _stuckMs = 0;
    }
    if (_offset != before) onAdvance?.call();
  }

  /// 重锚定:取转写末尾 10~5 个归一化字,在全文做**模糊**搜索
  /// (容忍少量错字:书面词/人名识别误差大时精确匹配会永远失败);
  /// 取得分最高、距 _mpos 最近的命中,返回匹配终点
  int _tryReanchor(String n) {
    for (final L in const [10, 8, 6, 5]) {
      if (L > n.length || L > norm.length) continue;
      final probe = n.substring(n.length - L);
      var bestIdx = -1;
      var bestScore = 0;
      for (var i = 0; i + L <= norm.length; i++) {
        var m = 0;
        for (var j = 0; j < L; j++) {
          if (norm[i + j] == probe[j]) m++;
        }
        final need = L >= 6 ? L - 2 : L - 1; // 容忍 ≤2 错字(5 字时 ≤1)
        if (m < need) continue;
        if (m > bestScore ||
            (m == bestScore &&
                bestIdx >= 0 &&
                (i - _mpos).abs() < (bestIdx - _mpos).abs())) {
          bestScore = m;
          bestIdx = i;
        }
      }
      if (bestIdx >= 0) return bestIdx + L;
    }
    return -1;
  }

  /// 离线引擎(whisper)窗口对齐:windowText = 最近 ~12 秒音频的转写。
  /// 每次都对齐整个窗口(无 _tx 历史状态)——窗口滑动不影响正确性。
  /// 真实性门控/停读预算照常生效。
  void feedWindow(String windowText) {
    final now = DateTime.now().millisecondsSinceEpoch;
    if (_lastFeedMs == 0) _lastFeedMs = now;
    final dt = ((now - _lastFeedMs) / 1000.0).clamp(0.0, 0.5);
    _lastFeedMs = now;
    var n = normalize(windowText);
    if (n.length > _maxSpoken) n = n.substring(n.length - _maxSpoken);
    final changed = n != _spoken;
    _spoken = n;
    if (n.isEmpty) return;
    if (changed) _lastTranscriptMs = DateTime.now().millisecondsSinceEpoch;
    if (!changed) {
      // 用户主动停读:转写没有新内容 → 不重新锚定,高亮原地保持
      // (不消失、不乱跳;恢复朗读后转写变化,立刻继续跟随)
      final before = _offset;
      _release(dt);
      if (_offset != before) onAdvance?.call();
      return;
    }
    // ---- 尾部锚定(whisper.cpp 窗口模式,稳定性优先)----
    // 窗口每 2s 重解码一次,转写尾部的微小波动不应变成可见的乱跳:
    // 1) 锚点必须落在 _mpos ±25 字的邻近带内才立即采纳;
    // 2) 带内无命中 → 保持原位不动;
    // 3) 连续 3 窗都只有远处命中 → 认定为真实跳读/回读,采纳远处
    //    最近命中(此时才允许大幅移动)
    var anchored = false;
    var bandLen = 0;
    int? bandHit;
    int? farHit;
    var farLen = 0;
    // 模糊匹配:探针在脚本滑窗内逐位比对,允许 1-2 个错字。
    // 精确匹配太脆——一个错字(实时→实实)就整条失败,跟随冻死
    for (var L = math.min(10, n.length); L >= 4; L--) {
      final probe = n.substring(n.length - L);
      final allow = L >= 6 ? 2 : 1;
      int? closest;
      var closestMatch = 0;
      final limit = norm.length - L;
      for (var i = 0; i <= limit; i++) {
        var m = 0;
        for (var j = 0; j < L; j++) {
          if (norm[i + j] == probe[j]) m++;
        }
        if (m < L - allow) continue;
        if (closest == null) {
          closest = i;
          closestMatch = m;
          continue;
        }
        final dNew = (i - _mpos).abs();
        final dOld = (closest - _mpos).abs();
        if (dNew < dOld || (dNew == dOld && m > closestMatch)) {
          closest = i;
          closestMatch = m;
        }
      }
      if (closest == null) continue;
      if ((closest - _mpos).abs() <= 25) {
        bandHit = closest;
        bandLen = L;
        break;
      }
      if (farHit == null) {
        farHit = closest;
        farLen = L;
      }
    }
    if (bandHit != null) {
      final newPos = math.min(bandHit + bandLen, norm.length);
      if (newPos != _mpos) onAdvance?.call();
      _mpos = newPos;
      _updateUserRate(_mpos);
      // 显示指针被大幅超前(真实大跳后):回拉
      if (_offset - _mpos > 30) {
        _offset = _mpos;
        _debt = 0;
      }
      _farWindows = 0;
      anchored = true;
    } else if (farHit != null) {
      _farWindows++;
      if (_farWindows >= 3) {
        final newPos = math.min(farHit + farLen, norm.length);
        if (newPos != _mpos) onAdvance?.call();
        _mpos = newPos;
        _updateUserRate(_mpos);
        if (_offset - _mpos > 30) {
          _offset = _mpos;
          _debt = 0;
        }
        _farWindows = 0;
      }
      anchored = true; // 保持原位等待(非失联)
    }
    // 全未命中(识别噪声/说别的内容):保持 _mpos,等待下一窗。
    if (!anchored) {
      final before = _offset;
      _release(dt);
      if (_offset != before) onAdvance?.call();
      return;
    }
    final before = _offset;
    _release(dt);
    if (_offset != before) onAdvance?.call();
  }

  /// 重新开始跟读:等待新转写(配合 AsrEngine.resetText 使用),保留阅读位置
  void resync() {
    _awaitFresh = true;
    _tx = 0;
  }

  /// 手动跳到原文某个位置(点字幕),同时把转写消费指针推到末尾,
  /// 避免旧转写立刻把进度又推回去
  void seekRaw(int rawPos) {
    if (rawIndex.isEmpty) {
      _offset = 0;
    } else {
      var lo = 0;
      var hi = rawIndex.length;
      while (lo < hi) {
        final mid = (lo + hi) >> 1;
        if (rawIndex[mid] < rawPos) {
          lo = mid + 1;
        } else {
          hi = mid;
        }
      }
      _offset = math.min(lo, rawIndex.length);
    }
    _mpos = _offset;
    _debt = 0;
    // 等待新转写再对齐(页面会同时清空识别文本)
    _awaitFresh = true;
    _tx = 0;
    onAdvance?.call();
  }

  /// 从头开始
  void reset() {
    _offset = 0;
    _mpos = 0;
    _debt = 0;
    _awaitFresh = true;
    _tx = 0;
    onAdvance?.call();
  }

  /// 归一化:去标点/符号/空白,转小写(英文)
  /// 常用繁体→简体映射(whisper tiny 常输出繁体,不转换则锚定失败)
  static const Map<String, String> _t2s = {
    '愛': '爱', '礙': '碍', '罷': '罢', '備': '备', '筆': '笔', '邊': '边', '變': '变', '標': '标',
    '聽': '听', '補': '补', '參': '参', '慘': '惨', '層': '层', '嘗': '尝', '長': '长', '廠': '厂',
    '車': '车', '徹': '彻', '塵': '尘', '稱': '称', '遲': '迟', '衝': '冲', '醜': '丑', '處': '处',
    '觸': '触', '傳': '传', '創': '创', '純': '纯', '詞': '词', '辭': '辞', '錯': '错', '達': '达',
    '帶': '带', '單': '单', '擔': '担', '膽': '胆', '彈': '弹', '當': '当', '黨': '党', '燈': '灯',
    '敵': '敌', '點': '点', '電': '电', '動': '动', '獨': '独', '讀': '读', '隊': '队', '對': '对',
    '奪': '夺', '額': '额', '惡': '恶', '兒': '儿', '發': '发', '罰': '罚', '範': '范', '飛': '飞',
    '廢': '废', '費': '费', '奮': '奋', '豐': '丰', '風': '风', '婦': '妇', '復': '复', '蓋': '盖',
    '乾': '干', '剛': '刚', '個': '个', '給': '给', '構': '构', '夠': '够', '顧': '顾', '關': '关',
    '觀': '观', '廣': '广', '歸': '归', '規': '规', '國': '国', '過': '过', '漢': '汉', '號': '号',
    '鏡': '镜', '臉': '脸', '幾': '几', '錶': '表', '鬍': '胡', '灣': '湾', '齣': '出',
    '後': '后', '護': '护', '劃': '划', '壞': '坏', '歡': '欢', '環': '环', '換': '换', '黃': '黄',
    '揮': '挥', '會': '会', '貨': '货', '機': '机', '積': '积', '極': '极', '際': '际', '價': '价',
    '駕': '驾', '間': '间', '見': '见', '薦': '荐', '將': '将', '講': '讲', '節': '节', '潔': '洁',
    '結': '结', '緊': '紧', '謹': '谨', '進': '进', '經': '经', '驚': '惊', '競': '竞', '靜': '静',
    '舊': '旧', '劇': '剧', '據': '据', '懼': '惧', '覺': '觉', '決': '决', '軍': '军', '開': '开',
    '殼': '壳', '課': '课', '懇': '恳', '誇': '夸', '塊': '块', '虧': '亏', '擴': '扩', '闊': '阔',
    '來': '来', '蘭': '兰', '攔': '拦', '藍': '蓝', '撈': '捞', '勞': '劳', '樂': '乐', '類': '类',
    '淚': '泪', '離': '离', '裡': '里', '禮': '礼', '歷': '历', '聯': '联', '煉': '炼', '練': '练',
    '兩': '两', '糧': '粮', '遼': '辽', '獵': '猎', '靈': '灵', '領': '领', '龍': '龙', '樓': '楼',
    '錄': '录', '慮': '虑', '論': '论', '羅': '罗', '馬': '马', '買': '买', '賣': '卖', '滿': '满',
    '貓': '猫', '門': '门', '們': '们', '夢': '梦', '廟': '庙', '滅': '灭', '難': '难', '腦': '脑',
    '內': '内', '擬': '拟', '釀': '酿', '鳥': '鸟', '寧': '宁', '農': '农', '濃': '浓', '惱': '恼',
    '歐': '欧', '盤': '盘', '拋': '抛', '賠': '赔', '評': '评', '鋪': '铺', '樸': '朴', '齊': '齐',
    '騎': '骑', '氣': '气', '遷': '迁', '錢': '钱', '潛': '潜', '淺': '浅', '搶': '抢', '親': '亲',
    '輕': '轻', '請': '请', '慶': '庆', '區': '区', '權': '权', '讓': '让', '熱': '热', '認': '认',
    '榮': '荣', '軟': '软', '賽': '赛', '喪': '丧', '殺': '杀', '傷': '伤', '設': '设', '審': '审',
    '腎': '肾', '聲': '声', '勝': '胜', '師': '师', '實': '实', '時': '时', '識': '识', '適': '适',
    '勢': '势', '釋': '释', '壽': '寿', '書': '书', '術': '术', '樹': '树', '雙': '双', '誰': '谁',
    '順': '顺', '說': '说', '絲': '丝', '鬆': '松', '蘇': '苏', '訴': '诉', '雖': '虽', '隨': '随',
    '歲': '岁', '損': '损', '縮': '缩', '態': '态', '談': '谈', '湯': '汤', '條': '条', '鐵': '铁',
    '統': '统', '頭': '头', '圖': '图', '團': '团', '脫': '脱', '萬': '万', '網': '网', '為': '为',
    '衛': '卫', '穩': '稳', '問': '问', '無': '无', '務': '务', '霧': '雾', '習': '习', '戲': '戏',
    '細': '细', '蝦': '虾', '險': '险', '現': '现', '獻': '献', '鄉': '乡', '響': '响', '嚮': '向',
    '脅': '胁', '寫': '写', '興': '兴', '選': '选', '學': '学', '壓': '压', '鴨': '鸭', '嚴': '严',
    '鹽': '盐', '陽': '阳', '養': '养', '樣': '样', '藥': '药', '爺': '爷', '業': '业', '醫': '医',
    '義': '义', '億': '亿', '陰': '阴', '銀': '银', '應': '应', '優': '优', '郵': '邮', '與': '与',
    '語': '语', '預': '预', '員': '员', '園': '园', '遠': '远', '願': '愿', '約': '约', '躍': '跃',
    '運': '运', '雜': '杂', '災': '灾', '載': '载', '贊': '赞', '髒': '脏', '棗': '枣', '責': '责',
    '戰': '战', '張': '张', '帳': '账', '這': '这', '針': '针', '陣': '阵', '爭': '争', '證': '证',
    '織': '织', '執': '执', '質': '质', '製': '制', '鐘': '钟', '種': '种', '眾': '众', '專': '专',
    '轉': '转', '準': '准', '資': '资', '蹤': '踪', '總': '总', '組': '组', '鑽': '钻', '視': '视',
    '頻': '频', '題': '题', '顏': '颜', '頓': '顿', '頌': '颂', '飯': '饭', '飲': '饮', '館': '馆',
    '飾': '饰', '飽': '饱', '餘': '余', '於': '于', '麼': '么', '沒': '没', '顆': '颗', '廳': '厅',
    '憶': '忆', '營': '营', '麗': '丽', '蘋': '苹', '檔': '档', '誌': '志', '訊': '讯', '財': '财',
    '職': '职', '儲': '储', '賬': '账', '滙': '汇',
  };

  static String normalize(String s) {
    final lower = s.toLowerCase();
    final sb = StringBuffer();
    for (var i = 0; i < lower.length; i++) {
      final ch = lower[i];
      if (_noise.hasMatch(ch)) continue;
      sb.write(_t2s[ch] ?? ch); // 繁→简(whisper.cpp 常输出繁体)
    }
    return sb.toString();
  }

  void _align() {
    // 容错预算随灵敏度伸缩(灵敏度高 = 允许更多跳字硬凑)
    final maxSkips = 4 + (sensitivity * 18).round();
    var skips = 0;
    // 最近一次可靠锚定(匹配或双字跳)的位置,容错超限时回滚到这里等待
    var snapOffset = _mpos;
    var snapTx = _tx;
    var exact = 0;
    var anchorHits = 0; // 双字锚定命中(强证据)

    void exceed() {
      _mpos = snapOffset;
      _tx = snapTx;
    }

    /// 在 s 的 (from, limit] 范围内找连续两字 [c0,c1] 的位置(双字锚定)
    int findPair(String s, int from, int limit, String c0, String c1) {
      var i = from + 1;
      final end = math.min(limit, s.length - 1);
      while (i < end) {
        if (s[i] == c0 && s[i + 1] == c1) return i;
        i++;
      }
      return -1;
    }

    // _frozen(上一帧判定)= 严格模式:只允许逐字精确匹配推进。
    // 读别的内容/纯噪声 → 无强证据 → 保持冻结,高亮不动;
    // 回到脚本 → 锚定/连 3 字强证据积累 → 解冻恢复正常容错
    while (_tx < _spoken.length && _mpos < norm.length) {
      final sc = norm[_mpos];
      final tc = _spoken[_tx];
      if (tc == sc) {
        _tx++;
        _mpos++;
        exact++;
        skips = 0;
        snapOffset = _mpos;
        snapTx = _tx;
        continue;
      }

      // ---- 双字锚定(两种模式都启用)----
      // 连续两字按序命中就是"在跟脚本"的强证据;此前冻结态禁用锚定,
      // 识别误差大的段落(书面词/人名)会让 mpos 被回滚钉死不动。
      // 1) 用户漏念/跳读:脚本前向 16 字内找「转写字 + 下一转写字」
      if (_tx + 1 < _spoken.length) {
        final si = findPair(norm, _mpos,
            math.min(_mpos + 16, norm.length), tc, _spoken[_tx + 1]);
        if (si > 0) {
          skips += si - _mpos;
          anchorHits++;
          _mpos = si;
          _tx++;
          snapOffset = _mpos; // 双字锚定是可靠位置,回滚快照同步推进
          snapTx = _tx;
          if (skips > maxSkips) {
            exceed();
            break;
          }
          continue;
        }
      }
      // 2) 误识别:转写前向 12 字内找「脚本字 + 下一脚本字」
      if (_mpos + 1 < norm.length) {
        final ti = findPair(_spoken, _tx,
            math.min(_tx + 12, _spoken.length), sc, norm[_mpos + 1]);
        if (ti > 0) {
          skips += ti - _tx;
          anchorHits++;
          _tx = ti;
          snapOffset = _mpos;
          snapTx = _tx;
          if (skips > maxSkips) {
            exceed();
            break;
          }
          continue;
        }
      }
      // 3) 单字微调容错(两种模式都启用):转写字在脚本前向 4 字内
      //    出现 → 跳过中间脚本字。轻微读不准不至于卡死
      final si1 = norm.indexOf(tc, _mpos + 1);
      if (si1 > 0 && si1 < _mpos + 4) {
        skips += si1 - _mpos;
        _mpos = si1;
        _tx++;
        if (skips > maxSkips) {
          exceed();
          break;
        }
        continue;
      }
      // 4) 双向都对不上
      if (!_frozen) _mpos++;
      _tx++;
      skips++;
      if (skips > maxSkips) {
        exceed();
        break;
      }
    }

    // 强证据:双字锚定命中,或本帧 ≥3 字全部精确(高频单字巧合在
    // 无关内容里也常见,不作为"在跟脚本"的证据)
    final strong = ((anchorHits >= 1) || (exact >= 2)) ? 1.0 : 0.0;
    _mExact = _mExact * 0.6 + strong * 0.4;
    _mCons = math.min(_mCons * 0.6 + 1.0, 6.0);
    // 帧末更新冻结状态(下一帧生效);统计不足时保持严格
        // 冻结阈值随灵敏度:低灵敏(0)=0.03 念得准才动;高灵敏(1)=0.33 念个大概就动
    final frozenAt = 0.03 + 0.30 * sensitivity;
    _frozen = _mCons > 1.2 ? _mExact / _mCons < frozenAt : true;
  }

  /// 显示指针匀速放行:滞后 ≤8 字时恒速 [_displayRate];更深滞后温和
  /// 加速(封顶 ~6.5 字/秒)。此前 rate=5.5+gap*2 是比例控制器,ASR 的固有
  /// 领先使 gap 永不归零,速度被持续抬高且越念越大 —— "越来越快"的根源
  void _release(double dt) {
    // 消除"走走停停":窗口转写每 2-5s 才更新一次位置,若显示追平
    // 识别位置就停下,画面必然一顿一顿。只要转写流仍活跃(用户持续
    // 在说),显示就以显示速度持续外推,上限 _mpos+14 —— 该上限恰好
    // 补偿解码延迟期间用户多念的字数,不会越过正在念的位置;
    // 转写流静默(停读 6s)后回落到 _mpos+6,随即自然停住
    final active = _lastTranscriptMs > 0 &&
        DateTime.now().millisecondsSinceEpoch - _lastTranscriptMs < 5000;
    final caughtUp = _offset >= _mpos; // 已追平识别位置(处于外推段)
    final target = _mpos + (active ? 10 : 6);
    final gap = target - _offset;
    if (gap <= 0) {
      _debt = 0;
      return;
    }
    if (gap > 40) {
      // 落后太多(长停顿/大段跳读):快照对齐
      _offset = _mpos;
      _debt = 0;
      return;
    }
    double rate;
    if (caughtUp && active) {
      // 外推段:严格按实测语速恒速前进。转写每 2-5s 落一帧 mpos,
      // 期间显示恰好走完同样的距离 → 运动连续,不再走走停停。
      // 用固定高速反而会冲到上限然后干等 → 又变成台阶
      rate = _userRate.clamp(1.5, 9.0);
    } else {
      // 追赶段:显示速度 = 语速 110% + 温和的欠账加速
      final excess = math.max(0.0, gap - 4.0);
      rate = math.max(_displayRate, _userRate * 1.10) +
          math.min(excess * 0.35, 3.0);
    }
    _debt += dt * rate;
    var step = _debt.floor();
    if (step > gap) step = gap;
    if (step > 0) {
      _offset += step;
      _debt -= step;
    }
    if (_debt > 8) _debt = 8;
  }
}
