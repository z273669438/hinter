import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// Dart 侧落盘诊断:写进与 iOS 原生插件同一个 Documents/hinter_diag.log。
/// 侧载 app 的 os_log 不可读,沙盒文件是唯一可靠的诊断通道(adb-free,
/// pymobiledevice3 house_arrest 可拉)。正式版移除。
class Ddiag {
  static File? _f;

  static Future<void> init() async {
    try {
      final docs = await getApplicationDocumentsDirectory();
      _f = File(p.join(docs.path, 'hinter_diag.log'));
    } catch (_) {}
  }

  static void w(String msg) {
    try {
      _f?.writeAsStringSync('${DateTime.now()} dart: $msg\n',
          mode: FileMode.append, flush: true);
    } catch (_) {}
  }
}
