import 'package:flutter/services.dart';

/// 读取原生层记录的未捕获崩溃堆栈(Android)。
class CrashReporter {
  CrashReporter._();
  static final CrashReporter instance = CrashReporter._();

  static const _ch = MethodChannel('hinter/diag');

  /// 上次闪退的堆栈;没有则返回 null(iOS 未实现时同样返回 null)
  Future<String?> lastCrash() async {
    try {
      return await _ch.invokeMethod<String?>('getLastCrash');
    } on PlatformException {
      return null;
    } on MissingPluginException {
      return null;
    }
  }

  Future<void> clear() async {
    try {
      await _ch.invokeMethod<void>('clearCrash');
    } catch (_) {}
  }
}
