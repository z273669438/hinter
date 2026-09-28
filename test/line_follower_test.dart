import 'package:flutter_test/flutter_test.dart';
import 'dart:math' as math;

import 'package:hinter/services/line_follower.dart';

void main() {
  const script =
      '大家好,我是小 hinter。今天给大家介绍一款口播提词器,它能在你录制视频的时候,'
      '自动识别你说出的每一句话,然后让字幕跟着你的朗读一起平滑滚动。';

  String norm(String s) => LineFollower.normalize(s);

  /// 以 ~50ms/帧的节奏喂流式转写,模拟真实识别到达过程
  Future<void> feedStreamed(LineFollower f, String spoken,
      {int step = 3, int frameMs = 50}) async {
    for (var i = step; i <= spoken.length; i += step) {
      f.feed(spoken.substring(0, i));
      await Future<void>.delayed(Duration(milliseconds: frameMs));
    }
    f.feed(spoken);
  }

  /// 排空阶段:转写持续增长(模拟说话继续),触发重锚定/预算等机制
  Future<void> drain(LineFollower f, String finalText, int ms) async {
    final end = DateTime.now().add(Duration(milliseconds: ms));
    var k = 3;
    while (DateTime.now().isBefore(end)) {
      k = math.min(k + 3, finalText.length);
      f.feed(finalText.substring(0, k));
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
  }

  /// 模拟 whisper 窗口:窗口 = 最近 ~12 秒转写(约 40 字),尾部 = 刚念的字
  Future<void> readTo(LineFollower f, String spoken, int from, int to,
      {int step = 4, int frameMs = 60}) async {
    for (var i = from + step; i <= to; i += step) {
      f.feedWindow(spoken.substring(math.max(0, i - 40), i));
      await Future<void>.delayed(Duration(milliseconds: frameMs));
    }
    if (to > from) f.feedWindow(spoken.substring(math.max(0, to - 40), to));
  }

  group('LineFollower whisper 窗口模式', () {
    test('中途换气停顿后继续读,高亮仍跟随到结尾', () async {
      final f = LineFollower(rawText: script, threshold: 0.9)
        ..offlineMode = true;
      final spoken = norm(script);
      await readTo(f, spoken, 0, 45);
      // 换气停顿:窗口连续多次不变(不再前进)
      for (var k = 0; k < 3; k++) {
        await Future<void>.delayed(const Duration(milliseconds: 300));
        f.feedWindow(spoken.substring(math.max(0, 45 - 40), 45));
      }
      final atPause = f.rawOffsetPlus(1);
      // 恢复朗读直到结尾
      await readTo(f, spoken, 45, spoken.length);
      final end = DateTime.now().add(const Duration(milliseconds: 4500));
      while (DateTime.now().isBefore(end)) {
        f.feedWindow(spoken.substring(math.max(0, spoken.length - 40)));
        await Future<void>.delayed(const Duration(milliseconds: 120));
      }
      expect(f.finished, isTrue);
      // 停顿不冻结:恢复朗读后高亮一路跟到结尾
      expect(f.rawOffsetPlus(1), greaterThan(atPause + 15));
    });

    test('识别误差大的坏段落:模糊重锚定能跳出并继续跟随', () async {
      final f = LineFollower(rawText: script, threshold: 0.9);
      final spoken = norm(script);
      // 先精确读到第 30 字(排空让显示指针追上对齐位置)
      await feedStreamed(f, spoken.substring(0, 30), frameMs: 25);
      await drain(f, spoken.substring(0, 30), 2500);
      final at = f.charOffset;
      expect(at, greaterThan(15));
      // 中间一段识别完全跑偏(书面词常见),之后每 10 字错 2 字地恢复
      final garbage = '殿中妃嫔窃窃私语皇后娘娘凤座巍然沈玉垂首不语';
      final tail = spoken.substring(42);
      final buf = StringBuffer(garbage);
      for (var i = 0; i < tail.length; i += 10) {
        buf.write(tail.substring(i, math.min(i + 8, tail.length)));
      }
      await drain(f, buf.toString(), 6500);
      // 修复前:坏段落把 mpos 钉死在 ~30;修复后:模糊重锚定跳过去继续跟
      expect(f.charOffset, greaterThan(at + 10));
    });

    test('窗口模式下读无关内容不前进,回到脚本继续跟', () async {
      final f = LineFollower(rawText: script, threshold: 0.9)
        ..offlineMode = true;
      final spoken = norm(script);
      await readTo(f, spoken, 0, 30);
      final at = f.rawOffsetPlus(1);
      for (var k = 0; k < 4; k++) {
        f.feedWindow('今天天气真不错我们出去玩吧哈哈');
        await Future<void>.delayed(const Duration(milliseconds: 80));
      }
      expect(f.rawOffsetPlus(1), lessThanOrEqualTo(at + 3));
      await readTo(f, spoken, 30, spoken.length);
      expect(f.finished, isTrue);
    });
  });

  group('LineFollower 增量对齐', () {
    test('流式逐字识别能一路跟到结尾', () async {
      final f = LineFollower(rawText: script, threshold: 0.9);
      final spoken = norm(script);
      await feedStreamed(f, spoken);
      await drain(f, spoken, 4200);
      expect(f.finished, isTrue);
    });

    test('带同音错字的转写仍能跟完', () async {
      final f = LineFollower(rawText: script, threshold: 0.9);
      final spoken = norm(script);
      final buf = StringBuffer();
      for (var i = 0; i < spoken.length; i++) {
        buf.write(i % 7 == 3 ? '的' : spoken[i]);
      }
      await feedStreamed(f, buf.toString(), frameMs: 30);
      await drain(f, buf.toString(), 4200);
      expect(f.finished, isTrue);
    });

    test('漏念/跳读也能继续跟随', () async {
      final f = LineFollower(rawText: script, threshold: 0.9);
      final spoken = norm(script);
      final jumpy = spoken.substring(0, 10) + spoken.substring(20);
      await feedStreamed(f, jumpy, frameMs: 30);
      await drain(f, jumpy, 7000);
      expect(f.charOffset, greaterThan(spoken.length * 0.85));
    });

    test('显示指针有速度闸门:不会瞬间抢跑到结尾', () async {
      final f = LineFollower(rawText: script, threshold: 0.9);
      final spoken = norm(script);
      // 一次性喂 30 字(gap<=40 不触发快照对齐)
      f.feed(spoken.substring(0, 30));
      await Future<void>.delayed(const Duration(milliseconds: 300));
      f.feed(spoken.substring(0, 30));
      // 外推设计:显示可达 识别位置(27)+14 余量 + 0.3s 追赶 ≈ 44,
      // 但绝不能一口气跑到结尾(~68)
      expect(f.charOffset, lessThan(45));
      expect(f.charOffset, greaterThan(0));
    });

    test('点字幕跳转后从新位置继续对齐', () async {
      final f = LineFollower(rawText: script, threshold: 0.9);
      final spoken = norm(script);
      await feedStreamed(f, spoken.substring(0, 20), frameMs: 30);
      // 恒速闸门:20 字需 ~3s 放行完
      await drain(f, spoken.substring(0, 20), 6000);
      expect(f.charOffset, greaterThanOrEqualTo(15));

      f.seekRaw(0);
      expect(f.charOffset, 0);
      await feedStreamed(f, spoken.substring(0, 10), frameMs: 30);
      await drain(f, spoken.substring(0, 10), 5200);
      expect(f.charOffset, greaterThanOrEqualTo(8));
    });

    test('念完之后不再移动', () async {
      final f = LineFollower(rawText: script, threshold: 0.9);
      final spoken = norm(script);
      f.feed(spoken); // gap>40 → 快照对齐到结尾
      expect(f.finished, isTrue);
      f.feed(spoken + spoken);
      expect(f.charOffset, spoken.length);
    });

    test('读与脚本无关的内容时高亮不前进', () async {
      final f = LineFollower(rawText: script, threshold: 0.9);
      final spoken = norm(script);
      // 先正常念 10 字建立进度
      await feedStreamed(f, spoken.substring(0, 10), frameMs: 30);
      await drain(f, spoken.substring(0, 10), 1500);
      final at = f.charOffset;
      expect(at, greaterThan(0));
      // 然后念完全无关的内容 2.5 秒
      const other = '今天天气真好我们一起去公园散步看风景聊天喝咖啡逛街';
      final otherN = norm(other);
      var k = 2;
      final end = DateTime.now().add(const Duration(milliseconds: 2500));
      while (DateTime.now().isBefore(end)) {
        k = (k + 2).clamp(2, otherN.length);
        f.feed(otherN.substring(0, k));
        await Future<void>.delayed(const Duration(milliseconds: 40));
      }
      // 外推余量:最多再走 14 字(有界,停止朗读后即停)
      expect(f.charOffset, lessThanOrEqualTo(at + 15));
      // 回到脚本继续念 → 恢复跟随
      await feedStreamed(f, spoken.substring(at, at + 20), frameMs: 30);
      await drain(f, spoken.substring(at, at + 20), 2000);
      expect(f.charOffset, greaterThan(at));
    });

    test('录制中途调整灵敏度立即生效', () async {
      final f = LineFollower(rawText: script, threshold: 0.9, sensitivity: 0.0);
      final spoken = norm(script);
      // 低灵敏(0):带错字的转写几乎不推进
      await feedStreamed(f, spoken.substring(0, 30), frameMs: 25);
      await drain(f, spoken.substring(0, 30), 800);
      final lowPos = f.charOffset;
      // 录制中把灵敏度调到 1.0
      f.sensitivity = 1.0;
      await drain(f, spoken.substring(0, 30), 2500);
      final highPos = f.charOffset;
      expect(highPos, greaterThan(lowPos + 3),
          reason: '调高灵敏度后应立即恢复跟随');
    });

    test('rawOffset 与原文位置对应', () {
      final f = LineFollower(rawText: script, threshold: 0.9);
      // 初始起点在文首(高亮含第一、二行,由 highlightLead 控制)
      expect(f.rawOffset, 0);
      expect(f.rawOffsetPlus(LineFollower.highlightLead),
          lessThan(script.length));
    });
  });
}
