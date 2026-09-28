import 'dart:io';

import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// 语音模型:中英双语流式 Zipformer(2023-02-20)的 int8 量化版。
/// **已随 App 打包**(assets/models,共约 190MB),首次启动自动解包到
/// 应用私有目录,全程无需用户下载、不依赖网络权限。
class ModelSpec {
  static const name = 'streaming-zipformer-bilingual-zh-en-2023-02-20 (int8)';

  static const encoderFile = 'encoder-epoch-99-avg-1.int8.onnx';
  static const decoderFile = 'decoder-epoch-99-avg-1.int8.onnx';
  static const joinerFile = 'joiner-epoch-99-avg-1.int8.onnx';
  static const tokensFile = 'tokens.txt';

  static const files = [encoderFile, decoderFile, joinerFile, tokensFile];

  /// 每个文件的期望大小(字节),用于校验解包完整性。
  /// 真实大小:encoder ≈ 173MB,decoder ≈ 13MB,joiner ≈ 3.2MB,tokens = 56KB
  static const sizes = [
    181895032, // encoder
    13091040,  // decoder
    3228404,   // joiner
    56317,     // tokens
  ];

  static const assetPrefix = 'assets/models/';

  // ---- whisper.cpp(ggml 模型,资产存在时优先使用)----
  static const whisperDir = 'whisper';
  static const whisperFiles = [
    'ggml-tiny.bin',
  ];
  /// 真实大小:ggerganov/whisper.cpp 官方 ggml-tiny(多语种,约 74MB)
  static const whisperSizes = [77691713];
}

class ModelManager {
  ModelManager._();
  static final ModelManager instance = ModelManager._();

  Directory? _dir;

  /// 模型存放目录:应用私有外部存储(必可读写;覆盖安装不丢)。
  Future<Directory> modelDir() async {
    if (_dir != null) return _dir!;
    Directory target;
    try {
      final ext = await getExternalStorageDirectory();
      if (ext != null) {
        target = Directory(p.join(ext.path, 'hinter_models'));
      } else {
        throw Exception('no external dir');
      }
    } catch (_) {
      final docs = await getApplicationDocumentsDirectory();
      target = Directory(p.join(docs.path, 'hinter', 'models'));
    }
    await target.create(recursive: true);
    _dir = target;
    return target;
  }

  bool _completeIn(Directory dir) {
    for (var i = 0; i < ModelSpec.files.length; i++) {
      try {
        final f = File(p.join(dir.path, ModelSpec.files[i]));
        if (!f.existsSync()) return false;
        if (f.lengthSync() != ModelSpec.sizes[i]) return false;
      } catch (_) {
        return false;
      }
    }
    return true;
  }

  /// 旧版本经「下载」存放的目录;存在且完整就直接搬用,不浪费。
  List<Directory> _legacyDirs(Directory docs) => [
        Directory(
            p.join(docs.path, 'hinter', 'models', 'zipformer-zh-en-2023-02-20')),
        Directory(p.join(docs.path, 'hinter', 'models')),
      ];

  /// 是否已就绪(无需解包)
  Future<bool> isReady() async {
    if (_completeIn(await modelDir())) return true;
    final docs = await getApplicationDocumentsDirectory();
    for (final legacy in _legacyDirs(docs)) {
      if (_completeIn(legacy)) {
        if (await _adoptLegacy(legacy)) return true;
      }
    }
    return false;
  }

  /// 保证模型可用:优先搬旧下载,其次从 App 内置资源解包。
  /// onProgress 回调 0~1。
  ///
  /// 注意:whisper 资产解包**不能**被 isReady() 短路 —— 旧版本装过的手机
  /// 已有完整 zipformer,若在此 return,whisper 永远不会落盘,引擎会一直
  /// 静默回退到流式 zipformer(“高亮走到一半永久冻结”的根源)。
  Future<void> ensureReady({void Function(double)? onProgress}) async {
    final target = await modelDir();
    if (await isReady()) {
      onProgress?.call(1);
    } else {
      final total = ModelSpec.sizes.fold<int>(0, (a, b) => a + b);
      var done = 0;
      for (var i = 0; i < ModelSpec.files.length; i++) {
        final name = ModelSpec.files[i];
        final dst = File(p.join(target.path, name));
        if (await dst.exists() && await dst.length() == ModelSpec.sizes[i]) {
          done += ModelSpec.sizes[i];
          onProgress?.call(done / total);
          continue;
        }
        // 从打包进 APK 的 asset 解包
        final bytes = await rootBundle.load('${ModelSpec.assetPrefix}$name');
        await dst.writeAsBytes(
            bytes.buffer.asUint8List(bytes.offsetInBytes, bytes.lengthInBytes),
            flush: true);
        if (await dst.length() != ModelSpec.sizes[i]) {
          throw '解包校验失败: $name';
        }
        done += ModelSpec.sizes[i];
        onProgress?.call(done / total);
      }
    }
    await _ensureWhisper(target);
  }

  /// whisper 资产缺失/大小不符 → 逐个补齐(覆盖安装升级场景的关键路径)
  Future<void> _ensureWhisper(Directory target) async {
    for (var i = 0; i < ModelSpec.whisperFiles.length; i++) {
      final name = ModelSpec.whisperFiles[i];
      final dst = File(p.join(target.path, ModelSpec.whisperDir, name));
      try {
        if (await dst.exists() &&
            await dst.length() == ModelSpec.whisperSizes[i]) {
          continue;
        }
      } catch (_) {}
      final bytes = await rootBundle
          .load('${ModelSpec.assetPrefix}${ModelSpec.whisperDir}/$name');
      await dst.create(recursive: true);
      await dst.writeAsBytes(
          bytes.buffer.asUint8List(bytes.offsetInBytes, bytes.lengthInBytes),
          flush: true);
    }
  }

  Future<bool> _adoptLegacy(Directory legacy) async {
    final target = await modelDir();
    if (p.equals(legacy.path, target.path)) return true;
    try {
      for (var i = 0; i < ModelSpec.files.length; i++) {
        final name = ModelSpec.files[i];
        final dst = File(p.join(target.path, name));
        if (await dst.exists() && await dst.length() == ModelSpec.sizes[i]) {
          continue;
        }
        final src = File(p.join(legacy.path, name));
        // 流式复制,避免大文件占内存
        await src.openRead().pipe(dst.openWrite());
      }
      return _completeIn(target);
    } catch (_) {
      return false;
    }
  }
}
