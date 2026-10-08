import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show kDebugMode;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import '../models/script.dart';
import '../services/asr_engine.dart';
import '../services/camera_controller.dart';
import '../services/ddiag.dart';
import '../services/device_check.dart';
import '../services/line_follower.dart';
import '../services/model_manager.dart';
import '../services/settings.dart';
import '../widgets/teleprompter_overlay.dart';

class TeleprompterPage extends StatefulWidget {
  const TeleprompterPage({super.key, required this.script});

  final Script script;

  @override
  State<TeleprompterPage> createState() => _TeleprompterPageState();
}

class _TeleprompterPageState extends State<TeleprompterPage>
    with WidgetsBindingObserver {
  final _camera = HinterCamera.instance;

  LineFollower? _follower;

  int _textureId = -1;
  String? _camError;
  String? _deviceWarn; // 设备配置偏低提示(用户可关闭)
  bool _starting = true;

  bool _recording = false;
  int _recSecs = 0;
  Timer? _recTimer;
  int _countdown = 0;
  Timer? _cdTimer;

  String? _modelNote;

  // 画质档位
  List<int> _modes = const [];
  int _currentMode = 1080;

  // 输出尺寸(预览按此等比 cover,避免拉伸畸变)
  double _texW = 0;
  double _texH = 0;

  // 浮窗面板开合
  bool _topOpen = false; // 顶部下拉(镜像+画质)
  double _pinchScale = 1.0; // 浮窗整体缩放系数(捏合)
  double _followSens = 0.5; // 识别跟随灵敏度
  double _pinchStartScale = 1.0; // 本次捏合起始系数
  int _activePointers = 0; // 当前按下的指针数
  bool _pinching = false; // 双指中:临时禁用浮窗内滚动

  // 抖音式美颜:当前选中调节项(null=未选中)
  String? _beautySel;

  late bool _front;
  late bool _mirror;
  late double _fontSize;
  late double _overlayTopRatio; // 浮窗顶边(可拖)
  late double _overlayLeftRatio; // 浮窗水平偏移(斜向拖拽)
  late double _boxHRatio; // 浮窗高度(可拖角缩放)
  late double _overlayOpacity;
  late BeautyParams _beauty;

  @override
  void initState() {
    super.initState();
    Ddiag.init();
    WidgetsBinding.instance.addObserver(this);
    final s = AppSettings.instance;
    _front = s.frontCamera;
    _mirror = s.mirrorPreview;
    _fontSize = s.fontSize;
    _overlayTopRatio = s.overlayTopRatio;
    _overlayLeftRatio = s.overlayLeftRatio;
    _boxHRatio = s.boxHeightRatio;
    _pinchScale = s.pinchScale;
    _overlayOpacity = s.overlayOpacity;
    _beauty = BeautyParams(
      smooth: s.smooth,
      whiten: s.whiten,
      ruddy: s.ruddy,
      brightness: s.brightness,
      saturation: s.saturation,
      slim: s.slim,
    );
    _currentMode = s.qualityShort;
    _followSens = s.followSens;
    _follower = LineFollower(
      rawText: widget.script.text,
      threshold: widget.script.followThreshold,
      sensitivity: AppSettings.instance.followSens,
      onAdvance: () {
        if (mounted) setState(() {});
      },
    );
    _init();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && mounted) {
      // 从其他页面/应用回来:相机可能已被系统回收,预览不可用则重启
      if (!_recording && !_starting &&
          (_textureId < 0 || _camError != null)) {
        setState(() {
          _camError = null;
          _starting = true;
        });
        _init();
      }
    }
  }

  Future<void> _init() async {
    // 1. 权限
    final states = await [
      Permission.camera,
      Permission.microphone,
    ].request();
    if (states[Permission.camera]!.isGranted == false ||
        states[Permission.microphone]!.isGranted == false) {
      setState(() {
        _starting = false;
        _camError = '需要相机和麦克风权限才能口播录制';
      });
      return;
    }

    // 2. 先启动相机 —— 预览与语音模型完全解耦,模型没就绪也能看到画面。
    //    快速退出再进入时,原生层 stop(Camera2 异步释放)与 start 竞态,
    //    立即重开常报"相机启动失败" → 自动重试
    Object? lastErr;
    for (var attempt = 0; attempt < 3; attempt++) {
      try {
        AppSettings.instance.qualityShort = _currentMode;
        final info = await _camera.start(front: _front);
        setState(() {
          _textureId = (info?['textureId'] as num?)?.toInt() ?? -1;
          _modes = ((info?['modes'] as List?) ?? const [])
              .map((e) => (e as num).toInt())
              .toList();
          _currentMode =
              (info?['current'] as num?)?.toInt() ?? _currentMode;
          _texW = (info?['width'] as num?)?.toDouble() ?? 0;
          _texH = (info?['height'] as num?)?.toDouble() ?? 0;
          _starting = false;
        });
        Ddiag.w('camera start ok tex=$_textureId');
        _dispatchBeauty();
        final warn = await DeviceCheck.check();
        if (mounted) setState(() => _deviceWarn = warn);
        lastErr = null;
        break;
      } catch (e) {
        lastErr = e;
        await Future<void>.delayed(const Duration(milliseconds: 800));
      }
    }
    if (lastErr != null) {
      setState(() {
        _starting = false;
        _camError = '相机启动失败: $lastErr';
      });
      return;
    }

    // 3. 数据流:原生 PCM → ASR → 对齐跟随(重试场景先清旧订阅)
    _micSub?.cancel();
    _textSub?.cancel();
    _evtSub?.cancel();
    _micSub = _camera.micStream().listen((pcm) {
      // 录制即跟随(点红钮自动开启)
      if (_following) AsrEngine.instance.acceptPcm(pcm);
    }, onError: (e) {
      debugPrint('mic stream error: $e');
    });
    _textSub = AsrEngine.instance.onText.listen((text) {
      if (!mounted) return;
        // 对齐用"去抢跑"文本(截掉 partial 尾部),显示用全文
      // 引擎可能在 whisper→流式 间回退,每次同步对齐模式
      _follower?.offlineMode = AsrEngine.instance.isWhisper;
      if (_following) _follower?.feed(AsrEngine.instance.alignText);
      if (_asrDbg % 20 == 1) Ddiag.w('asrText: $text');
      _asrDbg++;
    });
    _evtSub = _camera.events().listen((ev) {
      if (!mounted) return;
      final msg = '${ev['message']}';
      if (ev['event'] == 'recordError') {
        setState(() => _recording = false);
        _recTimer?.cancel();
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('录制出错: $msg')));
      } else if (ev['event'] == 'error') {
        setState(() => _camError = msg);
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(msg)));
      }
    });

    // 4. 语音模型:后台加载,失败不影响预览
    await _ensureModel();
    WakelockPlus.enable();
  }

  bool get _following => AsrEngine.instance.loaded && _asrOn;
  bool _asrOn = false; // 录制开始后打开
  int _asrDbg = 0;

  Future<void> _ensureModel() async {
    if (AsrEngine.instance.loaded) {
      if (mounted) setState(() => _modelNote = null);
      return;
    }
    try {
      final dir = await ModelManager.instance.modelDir();
      // 模型随 App 打包:首次使用自动解包(秒级),进度实时显示
      await ModelManager.instance.ensureReady(onProgress: (v) {
        if (mounted && v < 1) {
          setState(
              () => _modelNote = '正在启用内置语音模型 ${(v * 100).round()}%…');
        }
      });
      if (mounted) setState(() => _modelNote = '正在加载语音模型…');
      await AsrEngine.instance.load(dir.path);
      _follower?.offlineMode = AsrEngine.instance.isWhisper;
      if (mounted) setState(() => _modelNote = null);
    } catch (e) {
      Ddiag.w('ASR load failed: $e');
      debugPrint('ASR load failed: $e');
      if (mounted) setState(() => _modelNote = '语音模型不可用,跟读功能关闭');
    }
  }

  // ---- 录制控制(入口在顶部下拉面板) ----

  Future<void> _startRecording() async {
    setState(() => _countdown = 3);
    _cdTimer = Timer.periodic(const Duration(seconds: 1), (t) {
      if (!mounted) return;
      setState(() => _countdown--);
      if (_countdown <= 0) {
        t.cancel();
        _beginRecording();
      }
    });
  }

  Future<void> _beginRecording() async {
    try {
      final docs = await getApplicationDocumentsDirectory();
      final dir = Directory(p.join(docs.path, 'hinter', 'videos'));
      await dir.create(recursive: true);
      final now = DateTime.now();
      final ts = '${now.year}${_two(now.month)}${_two(now.day)}'
          '_${_two(now.hour)}${_two(now.minute)}${_two(now.second)}';
      final path = p.join(dir.path, 'koubo_$ts.mp4');
      await _camera.startRecording(path);
      if (!mounted) return;
      setState(() {
        _recording = true;
        _recSecs = 0;
        _asrOn = true; // 录制即自动跟读
      });
      AsrEngine.instance.resetText();
      _follower?.resync();
      _recTimer = Timer.periodic(const Duration(seconds: 1), (t) {
        if (mounted) setState(() => _recSecs++);
      });
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('无法开始录制: $e')));
      }
    }
  }

  static String _two(int v) => v.toString().padLeft(2, '0');

  Future<void> _stopRecording() async {
    _recTimer?.cancel();
    String? path;
    try {
      path = await _camera.stopRecording();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('停止录制出错: $e')));
      }
    }
    if (mounted) {
      setState(() {
        _recording = false;
        _asrOn = false;
      });
    }
    if (path != null) {
      // 写入系统相册;失败时如实提示(不再谎报成功)
      try {
        final saved = await _camera.saveToGallery(path);
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text(saved
                ? '已保存到系统相册(影片/Hinter)'
                : '视频已保存在应用目录(hinter/videos/${p.basename(path)}),'
                    '但写入相册未成功'),
            duration: const Duration(seconds: 5),
          ));
        }
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text('视频已保存在应用目录,但写入相册失败: $e'),
            duration: const Duration(seconds: 5),
          ));
        }
      }
    }
  }

  Future<void> _switchCamera() async {
    _front = !_front;
    AppSettings.instance.frontCamera = _front;
    try {
      final info = await _camera.switchCamera(front: _front);
      setState(() {
        if (info != null) {
          _modes = ((info['modes'] as List?) ?? const [])
              .map((e) => (e as num).toInt())
              .toList();
          _currentMode =
              (info['current'] as num?)?.toInt() ?? _currentMode;
          _texW = (info['width'] as num?)?.toDouble() ?? _texW;
          _texH = (info['height'] as num?)?.toDouble() ?? _texH;
        }
      });
    } catch (e) {
      _front = !_front;
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('切换摄像头失败: $e')));
      }
    }
  }

  /// 切换录制画质档(原生会重开相机到新的传感器尺寸)
  Future<void> _applyQuality(int shortEdge) async {
    if (shortEdge == _currentMode) return;
    setState(() => _currentMode = shortEdge);
    AppSettings.instance.qualityShort = shortEdge;
    try {
      final res = await _camera.setQualityMode(shortEdge);
      if (res != null && mounted) {
        setState(() {
          _currentMode =
              (res['current'] as num?)?.toInt() ?? shortEdge;
          _texW = (res['width'] as num?)?.toDouble() ?? _texW;
          _texH = (res['height'] as num?)?.toDouble() ?? _texH;
        });
        AppSettings.instance.qualityShort = _currentMode;
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('切换画质失败: $e')));
      }
    }
  }

  // ---- 美颜(实时下发,原生异步处理,不阻塞滑杆拖动) ----

  void _dispatchBeauty() {
    _camera.setBeauty(_beauty); // 不 await:拖动保持跟手
  }

  void _setBeautyParam({double? smooth, double? whiten, double? slim}) {
    setState(() {
      _beauty = BeautyParams(
        smooth: smooth ?? _beauty.smooth,
        whiten: whiten ?? _beauty.whiten,
        ruddy: _beauty.ruddy,
        brightness: _beauty.brightness,
        saturation: _beauty.saturation,
        slim: slim ?? _beauty.slim,
      );
    });
    final s = AppSettings.instance;
    s.smooth = _beauty.smooth;
    s.whiten = _beauty.whiten;
    s.slim = _beauty.slim;
    _dispatchBeauty();
  }

  /// 画质档位:每行两个等宽按钮,平均铺满面板(2 行放 4 档)
  List<Widget> _qualityChipRows() {
    Widget cell(int? m) {
      if (m == null) {
        return const SizedBox(height: 40); // 占位,保持行数对齐
      }
      final selected = m == _currentMode;
      return GestureDetector(
        onTap: () => _applyQuality(m),
        child: Container(
          height: 40,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: selected ? const Color(0xFFFFB300) : Colors.white12,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(
                color: selected ? const Color(0xFFFFB300) : Colors.white24),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              if (selected)
                const Padding(
                  padding: EdgeInsets.only(right: 4),
                  child: Icon(Icons.check,
                      size: 15, color: Colors.black87),
                ),
              Text(_tierLabel(m),
                  style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: selected ? Colors.black : Colors.white70)),
            ],
          ),
        ),
      );
    }

    Widget rowOf(List<int> items) {
      final cols = _modes.length <= 4 ? _modes.length : 2;
      return Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: Row(
          children: [
            for (var i = 0; i < cols; i++) ...[
              if (i > 0) const SizedBox(width: 8),
              Expanded(child: cell(i < items.length ? items[i] : null)),
            ],
          ],
        ),
      );
    }

    if (_modes.length <= 4) {
      return [rowOf(_modes.toList())];
    }
    final half = (_modes.length / 2).ceil();
    return [
      rowOf(_modes.take(half).toList()),
      if (_modes.length > half) rowOf(_modes.skip(half).toList()),
    ];
  }

  static const _tierLabels = {
    720: '720p',
    1080: '1080p',
    1440: '2.5K',
    2160: '4K',
  };

  String _tierLabel(int m) => _tierLabels[m] ?? '$m';

  String _fmtSecs(int s) =>
      '${(s ~/ 60).toString().padLeft(2, '0')}:${(s % 60).toString().padLeft(2, '0')}';

  @override
  void dispose() {
    _micSub?.cancel();
    _textSub?.cancel();
    _evtSub?.cancel();
    _recTimer?.cancel();
    _cdTimer?.cancel();
    if (_recording) {
      _camera.stopRecording().catchError((_) => null);
    }
    _camera.stop().catchError((_) {});
    WidgetsBinding.instance.removeObserver(this);
    WakelockPlus.disable();
    super.dispose();
  }

  StreamSubscription<Uint8List>? _micSub;
  StreamSubscription<String>? _textSub;
  StreamSubscription<Map<Object?, Object?>>? _evtSub;

  @override
  Widget build(BuildContext context) {
    final mq = MediaQuery.of(context);
    final screenH = mq.size.height;
    final flipPreview = _mirror && _front;
    Widget preview = _textureId >= 0
        ? (_texW > 0 && _texH > 0
            // 等比裁剪填满(cover):任何档位下预览都不拉伸
            ? SizedBox.expand(
                child: FittedBox(
                  fit: BoxFit.cover,
                  child: SizedBox(
                    width: _texW,
                    height: _texH,
                    child: Texture(textureId: _textureId),
                  ),
                ),
              )
            : Texture(textureId: _textureId))
        : Container(
            color: Colors.black,
            alignment: Alignment.center,
            child: _camError != null
                ? Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(_camError!, textAlign: TextAlign.center),
                      const SizedBox(height: 12),
                      OutlinedButton(
                        onPressed: () {
                          setState(() {
                            _camError = null;
                            _starting = true;
                          });
                          _init();
                        },
                        child: const Text('重试'),
                      ),
                    ],
                  )
                : const CircularProgressIndicator(),
          );
    if (flipPreview) {
      preview = Transform(
        alignment: Alignment.center,
        transform: Matrix4.diagonal3Values(-1, 1, 1),
        child: preview,
      );
    }

    // ---- 浮窗几何:两指捏合缩放整体比例(宽/高/字号等比),
    //      顶部小横条拖动移窗,右下角拖高(粗调) ----
    final screenW = mq.size.width;
    const edgeL = 12.0, edgeR = 12.0;
    final minTopRatio = 0.12;
    final pinch = _pinchScale.clamp(0.6, 1.5);
    final fullBoxW = screenW - edgeL - edgeR;
    final boxW = (fullBoxW * pinch).clamp(fullBoxW * 0.4, fullBoxW);
    // 居中 + 用户斜向拖拽偏移(限制不超出屏幕)
    final maxOffX = (screenW - boxW) / 2 / screenW;
    final boxLeft = (screenW - boxW) / 2 +
        _overlayLeftRatio.clamp(-maxOffX, maxOffX) * screenW;
    final boxH = (_boxHRatio.clamp(0.18, 0.78) * pinch) * screenH;
    final maxTopRatio = (1 - boxH / screenH - 0.12).clamp(0.12, 0.85);
    final top = _overlayTopRatio.clamp(minTopRatio, maxTopRatio) * screenH;
    // 有效字号:设置滑杆的基准字号 × 捏合系数
    final effFont = (_fontSize * pinch).clamp(12.0, 64.0);

    // 两指捏合:Listener 计数指针,双指时临时禁掉浮窗内滚动,
    // 否则 SingleChildScrollView 会在手势竞技场里抢走捏合事件
    Widget pinchable(Widget child) {
      return Listener(
        behavior: HitTestBehavior.translucent,
        onPointerDown: (_) {
          _activePointers++;
          if (_activePointers == 2 && !_pinching) {
            setState(() => _pinching = true);
          }
        },
        onPointerUp: (_) {
          _activePointers = (_activePointers - 1).clamp(0, 8);
          if (_activePointers < 2 && _pinching) {
            setState(() => _pinching = false);
            _pinchStartScale = 0;
          }
        },
        onPointerCancel: (_) {
          _activePointers = (_activePointers - 1).clamp(0, 8);
          if (_activePointers < 2 && _pinching) {
            setState(() => _pinching = false);
            _pinchStartScale = 0;
          }
        },
        child: GestureDetector(
          behavior: HitTestBehavior.translucent,
          onScaleStart: (d) =>
              _pinchStartScale = _pinchScale,
          onScaleUpdate: (d) {
            if (_pinchStartScale <= 0) return;
            setState(() {
              _pinchScale = (_pinchStartScale * d.scale)
                  .clamp(0.6, 1.5)
                  .toDouble();
              // 双指拖动:直接移动浮窗(单指仍滚动文本)
              if (_pinching) {
                _overlayTopRatio = (_overlayTopRatio + d.focalPointDelta.dy / screenH)
                    .clamp(minTopRatio, maxTopRatio);
                _overlayLeftRatio = (_overlayLeftRatio + d.focalPointDelta.dx / screenW)
                    .clamp(-maxOffX, maxOffX);
              }
            });
          },
          onScaleEnd: (d) {
            AppSettings.instance.pinchScale = _pinchScale;
            AppSettings.instance.overlayTopRatio = _overlayTopRatio;
            AppSettings.instance.overlayLeftRatio = _overlayLeftRatio;
          },
          child: child,
        ),
      );
    }

    final teleprompter = pinchable(ClipRRect(
      borderRadius: BorderRadius.circular(16),
      child: ColoredBox(
        color: Colors.black.withValues(alpha: _overlayOpacity),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOutCubic,
          height: boxH,
          child: Stack(
            children: [
              Positioned.fill(
                child: TeleprompterOverlay(
                  cursorRate: 12,
                  text: widget.script.text,
                  currentRawOffset: _follower?.rawOffset ?? 0,
                  highlightRawEnd:
                      _follower?.rawOffsetPlus(LineFollower.highlightLead) ??
                          0,
                  fontSize: effFont,
                  scrollEnabled: !_pinching,
                  onSeek: (pos) {
                    _follower?.seekRaw(pos);
                    // 同步清空识别上下文,跟随器等待新转写重新对齐
                    AsrEngine.instance.resetText();
                    setState(() {});
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    ));


    return PopScope(
      canPop: true,
      child: GestureDetector(
        // 点空白收起弹出层
        behavior: HitTestBehavior.translucent,
        onTap: () {
          if (_topOpen) {
            setState(() => _topOpen = false);
          }
        },
        child: Scaffold(
          backgroundColor: Colors.black,
          body: Stack(
            fit: StackFit.expand,
            children: [
              preview,
              // 浮空提词窗
              Positioned(
                  left: boxLeft, width: boxW, top: top,
                  child: teleprompter),
              // 设备配置提示(可关闭)
              if (_deviceWarn != null)
                Positioned(
                  left: 12,
                  right: 12,
                  top: mq.padding.top + 52,
                  child: Container(
                    padding: const EdgeInsets.fromLTRB(10, 6, 4, 6),
                    decoration: BoxDecoration(
                      color: const Color(0xCC5D4037),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Row(
                      children: [
                        const Icon(Icons.warning_amber_rounded,
                            color: Color(0xFFFFD54F), size: 18),
                        const SizedBox(width: 6),
                        Expanded(
                          child: Text(
                            _deviceWarn!,
                            maxLines: 3,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                                fontSize: 11, color: Colors.white),
                          ),
                        ),
                        IconButton(
                          visualDensity: VisualDensity.compact,
                          icon: const Icon(Icons.close,
                              size: 16, color: Colors.white54),
                          onPressed: () => setState(() => _deviceWarn = null),
                        ),
                      ],
                    ),
                  ),
                ),
              // 模型加载进度提示(仅首次解包/加载时短暂显示)
              if (_modelNote != null)
                Positioned(
                  left: 16,
                  right: 16,
                  bottom: mq.padding.bottom + 92,
                  child: Text(
                    _modelNote!,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                        fontSize: 11,
                        color: Colors.white38,
                        shadows: [
                          Shadow(blurRadius: 4, color: Colors.black54)
                        ]),
                  ),
                ),
              // 顶栏
              Positioned(
                top: mq.padding.top + 4,
                left: 8,
                right: 8,
                child: Row(
                  children: [
                    // (返回用系统手势/返回箭头,不放页内按钮)
                    Expanded(
                      child: Text(
                        widget.script.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                            color: Color(0xCC1A1A1A), // 深色:亮背景易找
                            fontSize: 15,
                            fontWeight: FontWeight.w600),
                      ),
                    ),
                    if (_starting)
                      const SizedBox(
                          width: 18,
                          height: 18,
                          child:
                              CircularProgressIndicator(strokeWidth: 2)),
                  ],
                ),
              ),
              // 顶部下拉面板(仅:镜像开关 + 画质档位,整齐两行)
              AnimatedPositioned(
                duration: const Duration(milliseconds: 200),
                curve: Curves.easeOut,
                top: _topOpen ? mq.padding.top + 56 : -360,
                left: 0,
                right: 0,
                child: Container(
                  margin: const EdgeInsets.symmetric(horizontal: 40),
                  padding: const EdgeInsets.symmetric(
                      horizontal: 16, vertical: 10),
                  decoration: BoxDecoration(
                    color: const Color(0xE6181818),
                    borderRadius: BorderRadius.circular(14),
                  ),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Row(
                        children: [
                          const Text('镜像',
                              style: TextStyle(
                                  fontSize: 13, color: Colors.white70)),
                          const Spacer(),
                          Switch(
                              value: _mirror,
                              onChanged: (v) {
                                setState(() => _mirror = v);
                                AppSettings.instance.mirrorPreview = v;
                              }),
                        ],
                      ),
                      const Divider(height: 8, color: Colors.white12),
                      // 识别灵敏度:低 = 念得准才跟随;高 = 念个大概就跟随
                      Row(
                        children: [
                          const Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text('识别',
                                  style: TextStyle(
                                      fontSize: 13, color: Colors.white70)),
                              SizedBox(width: 2),
                              Tooltip(
                                triggerMode: TooltipTriggerMode.tap,
                                showDuration: Duration(seconds: 4),
                                message: '向左滑：念得准才跟随（识别严格）。'
                                    '向右滑：念个大概就跟随（更宽容）',
                                child: Icon(Icons.error_outline,
                                    size: 14, color: Colors.white38),
                              ),
                            ],
                          ),
                          Expanded(
                            child: Slider(
                              value: _followSens.clamp(0.0, 1.0),
                              onChanged: (v) {
                                setState(() => _followSens = v);
                                AppSettings.instance.followSens = v;
                                _follower?.sensitivity = v;
                              },
                            ),
                          ),
                          Text('${(_followSens * 100).toStringAsFixed(1)}%',
                              style: const TextStyle(
                                  fontSize: 11, color: Colors.white54)),
                        ],
                      ),
                      const Divider(height: 8, color: Colors.white12),
                      // 字号 / 透明度(原设置气泡迁入)
                      Row(
                        children: [
                          const Text('字号',
                              style: TextStyle(
                                  fontSize: 13, color: Colors.white70)),
                          Expanded(
                            child: Slider(
                              value: _fontSize.clamp(16, 48),
                              min: 16,
                              max: 48,
                              onChanged: (v) {
                                setState(() => _fontSize = v);
                                AppSettings.instance.fontSize = v;
                              },
                            ),
                          ),
                          Text('${_fontSize.toStringAsFixed(0)}',
                              style: const TextStyle(
                                  fontSize: 11, color: Colors.white54)),
                        ],
                      ),
                      Row(
                        children: [
                          const Text('透明',
                              style: TextStyle(
                                  fontSize: 13, color: Colors.white70)),
                          Expanded(
                            child: Slider(
                              value: _overlayOpacity.clamp(0.0, 0.85),
                              min: 0.0,
                              max: 0.85,
                              onChanged: (v) {
                                setState(() => _overlayOpacity = v);
                                AppSettings.instance.overlayOpacity = v;
                              },
                            ),
                          ),
                          Text('${(_overlayOpacity * 100).toStringAsFixed(1)}%',
                              style: const TextStyle(
                                  fontSize: 11, color: Colors.white54)),
                        ],
                      ),
                      const Divider(height: 8, color: Colors.white12),
                      // 画质:标题一行 + 选项均分两行(如 720p/1080p | 2.5K/4K)
                      const Align(
                        alignment: Alignment.centerLeft,
                        child: Text('画质',
                            style: TextStyle(
                                fontSize: 13, color: Colors.white70)),
                      ),
                      const SizedBox(height: 6),
                      if (_modes.isNotEmpty)
                        ..._qualityChipRows(),
                    ],
                  ),
                ),
              ),
              // 底部居中:录制按钮 + 右侧翻转(透明,无底色)
              Positioned(
                left: 0,
                right: 0,
                bottom: mq.padding.bottom + 6,
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    _recButton(),
                    const SizedBox(width: 14),
                    _roundBtn(Icons.cameraswitch, '翻转', _switchCamera),
                  ],
                ),
              ),
              // 右上角:顶部下拉按钮(与美颜列同右边距对齐)
              Positioned(
                top: mq.padding.top + 2,
                right: 2,
                child: IconButton(
                  icon: Icon(
                    _topOpen ? Icons.expand_less : Icons.expand_more,
                    color: const Color(0xCC1A1A1A),
                    size: 30,
                  ),
                  onPressed: () => setState(() => _topOpen = !_topOpen),
                ),
              ),
              // 右上角:抖音式美颜竖排文字按钮(磨皮/美白/瘦脸),
              // 点中某项在其下方展开纵向滑杆;整块透明不遮挡画面
              Positioned(
                top: mq.padding.top + 52,
                right: 2,
                child: _beautyColumn(),
              ),
              // 倒计时
              if (_countdown > 0)
                Center(
                  child: Text('$_countdown',
                      style: TextStyle(
                          fontSize: 120,
                          color: Colors.white.withValues(alpha: 0.9),
                          fontWeight: FontWeight.w900)),
                ),
            ],
          ),
        ),
      ),
    );
  }

  /// 抖音式:右侧竖排美颜入口。每项 = 图标 + 竖排文字 + 半透明底片
  /// (拍摄画面上更醒目),点中某项在其下方展开纵向滑杆。
  Widget _beautyColumn() {
    final icons = {
      'smooth': Icons.face_retouching_natural,
      'whiten': Icons.wb_sunny_outlined,
      'slim': Icons.face,
    };
    Widget vLabel(String s, Color c) => Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final ch in s.split(''))
              Text(ch,
                  style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                      color: c)),
          ],
        );

    Widget item(String label, String key) {
      final on = _beautySel == key; // 正在调节
      final active = switch (key) {
        'whiten' => _beauty.whiten,
        'slim' => _beauty.slim,
        _ => _beauty.smooth,
      } >
          0.02; // 值非 0 = 功能生效中
      final fg = (on || active) ? const Color(0xFFFFB300) : Colors.white;
      return Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () => setState(() => _beautySel = on ? null : key),
            child: Container(
              padding: const EdgeInsets.symmetric(
                  horizontal: 5, vertical: 7),
              decoration: BoxDecoration(
                color: Colors.black.withValues(
                    alpha: on ? 0.45 : (active ? 0.36 : 0.28)),
                borderRadius: BorderRadius.circular(13),
                border: Border.all(
                    color: on
                        ? const Color(0xFFFFB300)
                        : (active
                            ? const Color(0x99FFB300)
                            : Colors.white24),
                    width: 1),
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(icons[key], size: 16, color: fg),
                  const SizedBox(height: 2),
                  vLabel(label, fg),
                ],
              ),
            ),
          ),
          if (on) _verticalBeautySlider(key),
        ],
      );
    }

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        item('磨皮', 'smooth'),
        const SizedBox(height: 8),
        item('美白', 'whiten'),
        const SizedBox(height: 8),
        item('瘦脸', 'slim'),
      ],
    );
  }

  /// 选中项的纵向调节杆(透明底,显示在按钮下方)
  Widget _verticalBeautySlider(String key) {
    final label =
        {'smooth': '磨皮', 'whiten': '美白', 'slim': '瘦脸'}[key]!;
    double value;
    switch (key) {
      case 'whiten':
        value = _beauty.whiten;
        break;
      case 'slim':
        value = _beauty.slim;
        break;
      default:
        value = _beauty.smooth;
    }
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text('${(value * 100).round()}',
            style: const TextStyle(
                fontSize: 12,
                color: Colors.white,
                shadows: [Shadow(blurRadius: 4, color: Colors.black87)])),
        SizedBox(
          width: 34,
          height: 132,
          child: RotatedBox(
            quarterTurns: 3,
            child: SliderTheme(
              data: SliderTheme.of(context).copyWith(
                trackHeight: 3,
                thumbShape:
                    const RoundSliderThumbShape(enabledThumbRadius: 9),
                activeTrackColor: Colors.white70,
                inactiveTrackColor: Colors.white24,
                thumbColor: Colors.white,
                overlayColor: Colors.white24,
              ),
              child: Slider(
                value: value.clamp(0.0, 1.0),
                onChanged: (v) {
                  switch (key) {
                    case 'whiten':
                      _setBeautyParam(whiten: v);
                      break;
                    case 'slim':
                      _setBeautyParam(slim: v);
                      break;
                    default:
                      _setBeautyParam(smooth: v);
                  }
                },
              ),
            ),
          ),
        ),
        Text(label,
            style: TextStyle(
                fontSize: 10,
                color: Colors.white.withValues(alpha: 0.7),
                shadows: const [
                  Shadow(blurRadius: 4, color: Colors.black87)
                ])),
      ],
    );
  }

  /// 录制按钮(底部居中)
  Widget _recButton() {
    return GestureDetector(
      onTap: _recording ? _stopRecording : _startRecording,
      child: Container(
        width: 72,
        height: 72,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          border: Border.all(color: Colors.red, width: 4),
        ),
        child: _recording
            ? Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Container(
                    width: 26,
                    height: 26,
                    decoration: BoxDecoration(
                      color: Colors.red,
                      borderRadius: BorderRadius.circular(6),
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(_fmtSecs(_recSecs),
                      style: const TextStyle(
                          fontSize: 11,
                          color: Colors.red,
                          fontWeight: FontWeight.w600)),
                ],
              )
            : Center(
                child: Container(
                  width: 54,
                  height: 54,
                  decoration: const BoxDecoration(
                      color: Colors.red, shape: BoxShape.circle),
                ),
              ),
      ),
    );
  }

  Widget _roundBtn(IconData icon, String label, VoidCallback onTap,
      {Color? color}) {
    return InkWell(
      borderRadius: BorderRadius.circular(40),
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.all(6),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, color: color ?? Colors.white, size: 26),
            const SizedBox(height: 2),
            Text(label,
                style:
                    TextStyle(fontSize: 10, color: color ?? Colors.white70)),
          ],
        ),
      ),
    );
  }
}
