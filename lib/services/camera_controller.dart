import 'dart:async';

import 'package:flutter/services.dart';

/// 美颜参数,取值 0~1
class BeautyParams {
  const BeautyParams({
    this.smooth = 0.5,
    this.whiten = 0.3,
    this.ruddy = 0.25,
    this.brightness = 0.1,
    this.saturation = 0.5,
    this.slim = 0.0,
  });

  final double smooth; // 磨皮
  final double whiten; // 美白
  final double ruddy; // 红润
  final double brightness; // 亮度
  final double saturation; // 饱和度
  final double slim; // 瘦脸

  Map<String, double> toMap() => {
        'smooth': smooth,
        'whiten': whiten,
        'ruddy': ruddy,
        'brightness': brightness,
        'saturation': saturation,
        'slim': slim,
      };
}

/// 原生美颜相机(Android: Camera2 + OpenGL ES;iOS: AVFoundation + Core Image)。
///
/// 预览画面以 Flutter Texture 形式给出,提词字幕等 UI 直接叠加在上面。
/// 麦克风由原生层采集:EventChannel 推送 16kHz 单声道 int16 PCM 供语音识别,
/// 录制时原生层自己把 48kHz 音轨编码进 mp4。
class HinterCamera {
  HinterCamera._();
  static final HinterCamera instance = HinterCamera._();

  static const _ch = MethodChannel('hinter/camera');
  static const _micCh = EventChannel('hinter/mic');
  static const _evtCh = EventChannel('hinter/camera_events');

  Future<Map<Object?, Object?>?> start({required bool front}) async {
    return await _ch.invokeMethod<Map<Object?, Object?>>(
        'start', {'front': front});
  }

  Future<void> stop() => _ch.invokeMethod('stop');

  Future<void> setBeauty(BeautyParams p) =>
      _ch.invokeMethod('setBeauty', p.toMap());

  /// 返回 {'modes':[720,1080,...], 'current':1080}
  Future<Map<Object?, Object?>?> switchCamera({required bool front}) =>
      _ch.invokeMethod<Map<Object?, Object?>>(
          'switchCamera', {'front': front});

  /// {'modes': [...], 'current': n}
  Future<Map<Object?, Object?>?> getSupportedModes() =>
      _ch.invokeMethod<Map<Object?, Object?>>('getSupportedModes');

  /// 切换画质档(竖屏短边);返回最新档位状态
  Future<Map<Object?, Object?>?> setQualityMode(int shortEdge) =>
      _ch.invokeMethod<Map<Object?, Object?>>(
          'setQualityMode', {'short': shortEdge});

  Future<void> startRecording(String path) =>
      _ch.invokeMethod('startRecording', {'path': path});

  /// 返回录制完成的文件路径
  Future<String?> stopRecording() =>
      _ch.invokeMethod<String?>('stopRecording');

  /// 把录好的视频保存进系统相册(成功返回 true)
  Future<bool> saveToGallery(String path) async {
    return await _ch.invokeMethod<bool>('saveToGallery', {'path': path}) ??
        false;
  }

  /// 16kHz 单声道 int16 小端 PCM
  Stream<Uint8List> micStream() =>
      _micCh.receiveBroadcastStream().cast<Uint8List>();

  /// 原生事件:{'event': 'recordError', 'message': ...} 等
  Stream<Map<Object?, Object?>> events() =>
      _evtCh.receiveBroadcastStream().cast<Map<Object?, Object?>>();
}
