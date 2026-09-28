import 'package:shared_preferences/shared_preferences.dart';

/// 全局设置(SharedPreferences 持久化)。
class AppSettings {
  AppSettings._();
  static final AppSettings instance = AppSettings._();

  late SharedPreferences _sp;

  Future<void> init() async {
    _sp = await SharedPreferences.getInstance();
  }

  // ---- 相机 / 提词 ----
  bool get frontCamera => _sp.getBool('frontCamera') ?? true;
  set frontCamera(bool v) => _sp.setBool('frontCamera', v);

  /// 前摄预览镜像(自拍视角,不影响录制成片)
  bool get mirrorPreview => _sp.getBool('mirrorPreview') ?? true;
  set mirrorPreview(bool v) => _sp.setBool('mirrorPreview', v);

  double get fontSize => _sp.getDouble('fontSize') ?? 22;
  set fontSize(double v) => _sp.setDouble('fontSize', v);

  /// 提词区占屏幕高度比例
  double get overlayRatio => _sp.getDouble('overlayRatio') ?? 0.42;
  set overlayRatio(double v) => _sp.setDouble('overlayRatio', v);

  /// 提词浮窗顶边位置(占屏幕高度比例,可拖动)
  double get overlayTopRatio => _sp.getDouble('overlayTopRatio') ?? 0.46;
  set overlayTopRatio(double v) => _sp.setDouble('overlayTopRatio', v);

  /// 提词浮窗水平偏移(-0.5~0.5,相对屏宽;0=居中)
  double get overlayLeftRatio => _sp.getDouble('overlayLeftRatio') ?? 0.0;
  set overlayLeftRatio(double v) => _sp.setDouble('overlayLeftRatio', v);

  /// 提词浮窗背景不透明度
  double get overlayOpacity => _sp.getDouble('overlayOpacity') ?? 0.025;
  set overlayOpacity(double v) => _sp.setDouble('overlayOpacity', v);

  /// 录制画质档(竖屏短边:720/1080/1440/2160),默认 1080p
  int get qualityShort => _sp.getInt('qualityShort') ?? 1080;
  set qualityShort(int v) => _sp.setInt('qualityShort', v);

  /// 语音跟随灵敏度(0~1):越高越宽容(念个大概就跟随),默认 0.5
  double get followSens => _sp.getDouble('followSens') ?? 0.26;
  set followSens(double v) => _sp.setDouble('followSens', v);

  // ---- 美颜 (0~1) ----
  double get smooth => _sp.getDouble('smooth') ?? 0.5;
  set smooth(double v) => _sp.setDouble('smooth', v);

  double get whiten => _sp.getDouble('whiten') ?? 0.3;
  set whiten(double v) => _sp.setDouble('whiten', v);

  double get ruddy => _sp.getDouble('ruddy') ?? 0.25;
  set ruddy(double v) => _sp.setDouble('ruddy', v);

  double get brightness => _sp.getDouble('brightness') ?? 0.1;
  set brightness(double v) => _sp.setDouble('brightness', v);

  double get saturation => _sp.getDouble('saturation') ?? 0.5;
  set saturation(double v) => _sp.setDouble('saturation', v);

  double get slim => _sp.getDouble('slim') ?? 0.0;
  set slim(double v) => _sp.setDouble('slim', v);

  /// 提词浮窗高度(占屏幕比例,可拖角调整)
  double get boxHeightRatio => _sp.getDouble('boxHeightRatio') ?? 0.42;
  set boxHeightRatio(double v) => _sp.setDouble('boxHeightRatio', v);

  /// 提词浮窗整体缩放系数(两指捏合;宽/高/字号等比,0.6~1.5)
  double get pinchScale => _sp.getDouble('pinchScale') ?? 1.0;
  set pinchScale(double v) => _sp.setDouble('pinchScale', v);

  // ---- 模型 ----
  String get lastScriptId => _sp.getString('lastScriptId') ?? '';
  set lastScriptId(String v) => _sp.setString('lastScriptId', v);
}
