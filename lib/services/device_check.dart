import 'dart:async';

import 'package:flutter/services.dart';

/// 设备能力探测与"配置不足以运行"判定。
///
/// 阈值依据（真机实测，1440×3168 / SD845 级 / 4GB 机器全功能可跑，
/// 偶有卡顿）：
/// - 内存 ≥4GB 才吃得下「468 点面部网格 + 三趟美颜着色器 + zipformer
///   int8 双线程」同帧竞争；<3.5GB 提示偏小，<2.5GB 提示不建议
/// - CPU ≥8 核（4 大核 + 4 小核）；<8 核提示
/// - Android 8.0（API 26）以下提示（安装下限随 Flutter SDK 更低）
/// - 可用存储 ≥1.5GB 流畅；<1.2GB 时模型解包（约 1.3GB）+ 录制会失败
class DeviceCheck {
  static const _ch = MethodChannel('hinter/diag');

  /// 0 = 达标；1 = 偏低（可能卡顿）；2 = 不建议（大概率不可用）
  static int lastLevel = 0;
  static String lastSummary = '';

  static Future<Map<Object?, Object?>?> _info() async {
    try {
      return await _ch.invokeMethod('deviceInfo');
    } catch (_) {
      return null;
    }
  }

  /// 返回null = 达标不提示；否则返回要展示的提示文案
  static Future<String?> check() async {
    final info = await _info();
    if (info == null) return null; // 通道失败不拦着用户
    final sdk = (info['sdkInt'] as num?)?.toInt() ?? 0;
    final memMb = (info['totalMemMb'] as num?)?.toDouble() ?? 0;
    final cores = (info['cores'] as num?)?.toInt() ?? 0;
    final diskMb = (info['freeDiskMb'] as num?)?.toDouble() ?? 0;
    final model = (info['model'] as String?) ?? '';

    final reasons = <String>[];
    var level = 0;
    if (sdk < 26) {
      reasons.add('Android 版本偏低（建议 8.0+）');
      level = level < 2 ? 2 : level;
    }
    if (memMb > 0 && memMb < 2500) {
      reasons.add('内存 ${(memMb / 1024).toStringAsFixed(1)}GB 不足（建议 ≥4GB）');
      level = 2;
    } else if (memMb > 0 && memMb < 3500) {
      reasons.add('内存 ${(memMb / 1024).toStringAsFixed(1)}GB 偏小（建议 ≥4GB）');
      level = level < 1 ? 1 : level;
    }
    if (cores > 0 && cores < 8) {
      reasons.add('CPU 核心数 $cores 偏少（建议 8 核）');
      level = level < 1 ? 1 : level;
    }
    if (diskMb < 1200) {
      reasons.add('可用存储 ${(diskMb / 1024).toStringAsFixed(1)}GB 不足'
          '（解包模型约需 1.3GB）');
      level = 2;
    } else if (diskMb < 1500) {
      reasons.add('可用存储 ${(diskMb / 1024).toStringAsFixed(1)}GB 偏紧');
      level = level < 1 ? 1 : level;
    }

    lastLevel = level;
    lastSummary = '内存${(memMb / 1024).toStringAsFixed(1)}GB / ${cores}核 / '
        'Android$sdk';
    if (reasons.isEmpty) return null;
    final head = level >= 2 ? '设备配置不足' : '设备配置偏低';
    return '$head（$lastSummary）：${reasons.join('；')}。'
        '本应用建议使用 2018 年及以后生产的旗舰/中高端手机。'
        '仍可尝试使用，若卡顿严重建议关闭美颜或降低画质。';
  }
}
