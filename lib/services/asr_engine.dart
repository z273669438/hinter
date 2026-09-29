import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:path/path.dart' as p;

import 'package:sherpa_onnx/sherpa_onnx.dart' as sherpa_onnx;

import 'ddiag.dart';
import 'package:whisper_flutter_new/whisper_flutter_new.dart';


/// 端上流式语音识别:sherpa-onnx 流式 Zipformer(transducer,int8)。
///
/// 麦克风 PCM(16kHz 单声道 int16)由原生相机插件统一采集并通过
/// `hinter/mic` EventChannel 推送过来(原生层同时负责录制音轨,
/// 避免两端同时占用麦克风产生冲突)。
class AsrEngine {
  AsrEngine._();
  static final AsrEngine instance = AsrEngine._();

  sherpa_onnx.OnlineRecognizer? _recognizer;
  sherpa_onnx.OnlineStream? _stream;
  bool _loaded = false;
  bool _loading = false;

  // ---- whisper.cpp 离线切块模式(FFI,包内 Isolate.run 后台解码)----
  // 已实现并验证可跑通,但实测窗口转写 + 尾部锚定的跟随体验不如
  // 流式 zipformer(tiny 模型对部分句子识别质量差,锚定呈周期性
  // 跳动),按用户反馈切回流式。要重试 whisper.cpp 改回 true。
  static const bool preferWhisper = false;
  static const int _cppWindowSecs = 8;
  bool _whisperMode = false; // 决定用 whisper 后立即置真(PCM 提前开始缓存)
  bool _whisperReady = false;
  bool _wcppBusy = false;
  String _cppModelDir = '';
  String _rootDir = '';
  Timer? _chunkTimer;
  final List<Float32List> _pcmChunks = <Float32List>[];
  int _pcmLen = 0;
  String _whisperTail = ''; // 上一次窗口转写(供显示)
  int _lastDbgMs = 0;
  int _pcmRecvAcc = 0;

  /// 诊断日志(正式版移除):节流 3s
  void _dbgLog(String msg) {
    final now = DateTime.now().millisecondsSinceEpoch;
    if (now - _lastDbgMs < 3000) return;
    _lastDbgMs = now;
    debugPrint('HinterDbg $msg');
  }

  bool get isWhisper => _whisperReady;

  /// 通知跟随器切换到窗口对齐模式(whisper 装载成功时由页面调用)
  void Function()? markOffline;

  String _committed = '';
  String _partial = '';

  final _textCtrl = StreamController<String>.broadcast();
  Stream<String> get onText => _textCtrl.stream;
  bool get loaded => _loaded;
  bool get loading => _loading;

  /// committed + 当前 partial,即最近识别到的全文(截尾)
  String get text {
    final t = _committed + _partial;
    return t.length > 200 ? t.substring(t.length - 200) : t;
  }

  /// 供跟随对齐用的转写:partial 尾部 3 字是"正在说的词",识别结果
  /// 天然比话音提前,对齐时截掉可消除高亮抢跑
  String get alignText {
    // whisper 模式:整段窗口转写交给跟随器做尾部锚定。
    // 此前该分支丢失 → 跟随器永远收到空串,高亮完全不动(80字卡死根因)
    if (_whisperReady) return _whisperTail;
    var p = _partial;
    // 固定截尾 3 字:流式尾部词是"话音未落已出字";比例截尾在长句下
    // 会让领先量随句长增长("越读越快"的来源),固定字数更稳
    const cut = 3;
    if (p.length > cut) p = p.substring(0, p.length - cut);
    // 不在这里截断 200 字:截断会让转写变成"滑动窗口",feed() 里的
    // _tx 对齐基准错位 → 匹配率崩塌 → 重锚定钉死 → 高亮永久冻结。
    // 窗口裁剪统一交给 LineFollower.feed 的 _maxSpoken(带 _tx 平移)
    return _committed + p;
  }

  Future<void> load(String modelDir) async {
    if (_loaded || _loading) return;
    _loading = true;
    try {
      final whisperDir = p.join(modelDir, 'whisper');
      final ggmlModel = p.join(whisperDir, 'ggml-tiny.bin');
      if (preferWhisper && File(ggmlModel).existsSync()) {
        // whisper 模式:主 isolate 不初始化 sherpa(双 isolate 各持一套
        // ORT 运行时实例会在解码时死锁),worker 内自行 initBindings
        _whisperMode = true;
        await _loadWhisper(whisperDir, modelDir);
        return;
      }
      sherpa_onnx.initBindings();
      await _buildStreamingRecognizer(modelDir);
      _loaded = true;
      Ddiag.w('streaming zipformer loaded ok');
    } catch (e) {
      Ddiag.w('engine load ERR $e');
      rethrow;
    } finally {
      _loading = false;
    }
  }

  /// 送入一帧 16kHz 单声道 int16 小端 PCM
  int _pcmDbg = 0;

  void acceptPcm(Uint8List bytes) {
    _pcmDbg++;
    if (_pcmDbg == 1 || _pcmDbg % 200 == 0) {
      Ddiag.w('pcm chunk #$_pcmDbg bytes=${bytes.length} loaded=$_loaded');
    }
    if (_whisperMode) {
      // whisper 模式:缓存 PCM,周期切块识别
      if (bytes.length < 2) return;
      final n = bytes.length ~/ 2;
      final chunk = Float32List(n);
      final bd = ByteData.sublistView(bytes);
      for (var i = 0; i < n; i++) {
        chunk[i] = bd.getInt16(i * 2, Endian.little) / 32768.0;
      }
      _pcmChunks.add(chunk);
      _pcmLen += n;
      _pcmRecvAcc += n;
      // 上限 30 秒(whisper 上限),超出丢弃最旧
      final maxLen = _whisperSampleRate * 30;
      while (_pcmLen > maxLen && _pcmChunks.isNotEmpty) {
        _pcmLen -= _pcmChunks.first.length;
        _pcmChunks.removeAt(0);
      }
      return;
    }
    if (!_loaded || _stream == null || bytes.length < 2) return;
    final n = bytes.length ~/ 2;
    final samples = Float32List(n);
    final bd = ByteData.sublistView(bytes);
    for (var i = 0; i < n; i++) {
      samples[i] = bd.getInt16(i * 2, Endian.little) / 32768.0;
    }
    final rec = _recognizer!;
    final st = _stream!;
    st.acceptWaveform(samples: samples, sampleRate: 16000);
    while (rec.isReady(st)) {
      rec.decode(st);
    }
    _partial = rec.getResult(st).text;
    if (rec.isEndpoint(st)) {
      if (_partial.isNotEmpty) _committed += _partial;
      _partial = '';
      rec.reset(st);
    }
    _textCtrl.add(text);
  }

  /// whisper.cpp 初始化:模型文件已随 App 内置并解包,这里只需就位
  Future<void> _loadWhisper(String whisperDir, String rootDir) async {
    _rootDir = rootDir;
    try {
      final modelFile = File(p.join(whisperDir, 'ggml-tiny.bin'));
      if (!modelFile.existsSync()) throw 'ggml-tiny.bin missing';
      _cppModelDir = whisperDir;
      _whisperReady = true;
      _loaded = true;
      markOffline?.call();
      // 每 2s 对最近 ≤7s 音频解码一次;Whisper.transcribe 内部用
      // Isolate.run 执行 FFI,不阻塞 UI。busy 标志防重叠
      _chunkTimer = Timer.periodic(const Duration(milliseconds: 2000), (_) {
        _recognizeChunk();
      });
    } catch (e) {
      debugPrint('HinterDbg whisper.cpp: $e');
      await _giveUpWhisper();
    }
  }

  /// 彻底放弃 whisper.cpp:切回流式 zipformer(识别质量略低但不卡 UI)
  Future<void> _giveUpWhisper() async {
    _whisperReady = false;
    _whisperMode = false;
    _pcmChunks.clear();
    _pcmLen = 0;
    if (_recognizer == null) {
      try {
        sherpa_onnx.initBindings();
        await _buildStreamingRecognizer(_rootDir);
      } catch (e) {
        return;
      }
    }
    _loaded = true;
  }

  /// 流式 zipformer 识别器构造(whisper 回退用;文件已在盘上)
  Future<void> _buildStreamingRecognizer(String modelDir) async {
    final config = sherpa_onnx.OnlineRecognizerConfig(
      model: sherpa_onnx.OnlineModelConfig(
        transducer: sherpa_onnx.OnlineTransducerModelConfig(
          encoder: p.join(modelDir, 'encoder-epoch-99-avg-1.int8.onnx'),
          decoder: p.join(modelDir, 'decoder-epoch-99-avg-1.int8.onnx'),
          joiner: p.join(modelDir, 'joiner-epoch-99-avg-1.int8.onnx'),
        ),
        tokens: p.join(modelDir, 'tokens.txt'),
        numThreads: 2,
        debug: false,
      ),
      enableEndpoint: true,
      rule1MinTrailingSilence: 1.0,
      rule2MinTrailingSilence: 0.5,
      rule3MinUtteranceLength: 15,
    );
    _recognizer = sherpa_onnx.OnlineRecognizer(config);
    _stream = _recognizer!.createStream();
  }



  static const int _whisperSampleRate = 16000;
  static const int _whisperWindowSecs = 6;

  /// 拼接最近 ≤secs 秒 PCM(从最新往前取)
  Float32List _mergeWindow(int secs) {
    final maxSamples = _whisperSampleRate * secs;
    final merged = Float32List(math.min(_pcmLen, maxSamples));
    var need = merged.length;
    var out = merged.length;
    for (var i = _pcmChunks.length - 1; i >= 0 && out > 0; i--) {
      final c = _pcmChunks[i];
      final take = math.min(c.length, out);
      out -= take;
      merged.setRange(out, out + take, c, c.length - take);
    }
    if (out > 0) {
      // 不足:前移填充(短音频)
      merged.setRange(0, need - out, merged.sublist(need - out));
    }
    return merged;
  }

  /// whisper.cpp 切块解码:PCM → 临时 WAV → FFI(内部 Isolate.run)
  Future<void> _recognizeChunk() async {
    if (_wcppBusy || !_whisperReady || _pcmLen == 0) return;
    _wcppBusy = true;
    File? wav;
    try {
      final merged = _mergeWindow(_cppWindowSecs);
      if (merged.length < _whisperSampleRate) return; // <1s 不解码
      wav = await _writeTempWav(merged);
      final w = Whisper(model: WhisperModel.tiny, modelDir: _cppModelDir);
      final resp = await w.transcribe(
        transcribeRequest: TranscribeRequest(
          audio: wav.path,
          language: 'zh',
          threads: 4,
          isNoTimestamps: true,
        ),
      );
      final text = resp.text.trim();
      final tail12 = text.length > 12 ? text.substring(text.length - 12) : text;
      _dbgLog('asr buf=${(_pcmLen / _whisperSampleRate).toStringAsFixed(1)}s'
          ' recv=${(_pcmRecvAcc / _whisperSampleRate).toStringAsFixed(1)}s'
          ' tail="$tail12"');
      _pcmRecvAcc = 0;
      if (text.isNotEmpty && text != _whisperTail) {
        _whisperTail = text;
        _committed = '';
        _partial = '';
        _textCtrl.add(text);
      }
    } catch (e) {
    } finally {
      try {
        wav?.deleteSync();
      } catch (_) {}
      _wcppBusy = false;
    }
  }

  /// Float32 PCM → 16k 单声道 16bit WAV 临时文件
  Future<File> _writeTempWav(Float32List pcm) async {
    final n = pcm.length;
    final out = BytesBuilder();
    final hdr = ByteData(44);
    void putStr(int off, String s) {
      for (var i = 0; i < s.length; i++) {
        hdr.setUint8(off + i, s.codeUnitAt(i));
      }
    }

    putStr(0, 'RIFF');
    hdr.setUint32(4, 36 + n * 2, Endian.little);
    putStr(8, 'WAVE');
    putStr(12, 'fmt ');
    hdr.setUint32(16, 16, Endian.little);
    hdr.setUint16(20, 1, Endian.little); // PCM
    hdr.setUint16(22, 1, Endian.little); // mono
    hdr.setUint32(24, _whisperSampleRate, Endian.little);
    hdr.setUint32(28, _whisperSampleRate * 2, Endian.little);
    hdr.setUint16(32, 2, Endian.little);
    hdr.setUint16(34, 16, Endian.little);
    putStr(36, 'data');
    hdr.setUint32(40, n * 2, Endian.little);
    out.add(hdr.buffer.asUint8List());
    final body = ByteData(n * 2);
    for (var i = 0; i < n; i++) {
      var v = (pcm[i] * 32767).round().clamp(-32768, 32767);
      body.setInt16(i * 2, v, Endian.little);
    }
    out.add(body.buffer.asUint8List());
    final f = File(p.join(Directory.systemTemp.path, 'hinter_wcpp.wav'));
    await f.writeAsBytes(out.takeBytes(), flush: true);
    return f;
  }

  /// 清空识别上下文(重新开始跟读时调用)
  void resetText() {
    _committed = '';
    _partial = '';
    _whisperTail = '';
    _pcmChunks.clear();
    _pcmLen = 0;
    if (_recognizer != null && _stream != null) {
      _recognizer!.reset(_stream!);
    }
    _textCtrl.add(text);
  }

  void dispose() {
    _chunkTimer?.cancel();
    _chunkTimer = null;
    _whisperReady = false;
    _whisperMode = false;
    _stream?.free();
    _stream = null;
    _recognizer?.free();
    _recognizer = null;
    _loaded = false;
  }
}
