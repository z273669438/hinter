import Flutter
import UIKit
import AVFoundation
import CoreImage
import CoreVideo
import Metal
import Photos
import Vision

// ============================================================================
// HinterCameraPlugin
//
// 美颜相机插件(方法通道 hinter/camera):
// - start / stop / switchCamera:AVCaptureSession + Core Image 美颜,
//   预览走 FlutterTexture;
// - setBeauty:磨皮 / 美白 / 红润 / 亮度 / 饱和度;
// - startRecording / stopRecording:美颜画面 + 麦克风音轨合流为 MP4;
// - EventChannel hinter/mic:16kHz 单声道 int16 PCM(供本地语音识别);
// - EventChannel hinter/camera_events:异步错误事件。
//
// 美颜算法与 Android(GLSL)保持一致:
//   高斯模糊 → 边缘保留合成(磨皮)→ 肤色掩码(YCbCr)美白/红润 → 亮度/饱和度。
// ============================================================================

/// 把最新渲染帧交给 Flutter 引擎
/// 文件通道保证可读;Documents/hinter_diag.log)
func diag(_ msg: String) {
    NSLog("[HinterCam] %@", msg)
    let line = "\(Date()): \(msg)" + "\n"
    let dir = NSSearchPathForDirectoriesInDomains(.documentDirectory,
        .userDomainMask, true).first
    if let dir = dir {
        let f = URL(fileURLWithPath: dir).appendingPathComponent("hinter_diag.log")
        if let h = try? FileHandle(forWritingTo: f) {
            h.seekToEndOfFile()
            h.write(line.data(using: .utf8)!)
            try? h.close()
        } else {
            try? line.write(to: f, atomically: true, encoding: .utf8)
        }
    }
}


final class PixelBufferSink: NSObject, FlutterTexture {
    private let lock = NSLock()
    private var buffer: CVPixelBuffer?

    func present(_ pb: CVPixelBuffer) {
        lock.lock()
        buffer = pb
        lock.unlock()
    }

    var copyCount: Int64 = 0
    func copyPixelBuffer() -> Unmanaged<CVPixelBuffer>? {
        lock.lock()
        copyCount += 1
        if copyCount == 1 || copyCount % 150 == 0 {
            diag("copyPixelBuffer #\(copyCount) hasBuf=\(buffer == nil ? 0 : 1)")
        }
        let b = buffer
        lock.unlock()
        guard let b else { return nil }
        return Unmanaged<CVPixelBuffer>.passRetained(b)
    }
}

/// 通用事件通道转发
final class PassthroughStreamHandler: NSObject, FlutterStreamHandler {
    var onListen: ((@escaping FlutterEventSink) -> Void)?
    var onCancel: (() -> Void)?

    func onListen(withArguments arguments: Any?,
                  eventSink events: @escaping FlutterEventSink) -> FlutterError? {
        onListen?(events)
        return nil
    }

    func onCancel(withArguments arguments: Any?) -> FlutterError? {
        onCancel?()
        return nil
    }
}

/// v7 诊断:把 CI 图像落盘为 PNG(Documents)
func ciWrite(_ image: CIImage, ctx: CIContext, name: String) {
    let raw = image.extent
    let ext = raw.isInfinite
        ? CGRect(x: 0, y: 0, width: 720, height: 1280)
        : CGRect(x: max(raw.minX, 0), y: max(raw.minY, 0),
                 width: max(raw.width, 1), height: max(raw.height, 1))
    guard let cg = ctx.createCGImage(image, from: ext) else {
        diag("createCGImage FAILED extent=\(image.extent)")
        return
    }
    let dir = NSSearchPathForDirectoriesInDomains(.documentDirectory,
        .userDomainMask, true).first!
    let url = URL(fileURLWithPath: dir).appendingPathComponent(name)
    if let data = PNGRep.repr(cg) {
        try? data.write(to: url)
        diag("saved \(name) \(data.count)b extent=\(image.extent)")
    } else {
        diag("PNG encode failed extent=\(image.extent)")
    }
}

enum PNGRep {
    static func repr(_ cg: CGImage) -> Data? {
        let acc = NSMutableData()
        guard let ds = CGImageDestinationCreateWithData(
            acc, "public.png" as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(ds, cg, nil)
        guard CGImageDestinationFinalize(ds) else { return nil }
        return acc as Data
    }
}

/// 填纯红(BGRA)
func fillRed(_ b: CVPixelBuffer) {
    CVPixelBufferLockBaseAddress(b, [])
    defer { CVPixelBufferUnlockBaseAddress(b, []) }
    guard let base = CVPixelBufferGetBaseAddress(b) else { return }
    let stride = CVPixelBufferGetBytesPerRow(b)
    let w = CVPixelBufferGetWidth(b), h = CVPixelBufferGetHeight(b)
    base.withMemoryRebound(to: UInt8.self, capacity: stride * h) { p in
        for y in 0..<h {
            let row = p + y * stride
            for x in 0..<w {
                row[x * 4] = 0; row[x * 4 + 1] = 0
                row[x * 4 + 2] = 255; row[x * 4 + 3] = 255
            }
        }
    }
}

struct BeautyParams {
    var smooth = 0.5
    var whiten = 0.3
    var ruddy = 0.25
    var brightness = 0.1
    var saturation = 0.5
    var slim = 0.0
}

/// 美颜合成核(逐像素;模糊图由上游 CIGaussianBlur 提供)
private let beautyKernelSource = """
#include <CoreImage/CoreImage.h>
using namespace metal;

extern "C" float4 beautyCombine(coreimage::sampler srcSampler,
                                coreimage::sampler blurSampler,
                                float smoothAmt,
                                float whiten,
                                float ruddy,
                                float bright,
                                float satMul,
                                float slim,
                                float2 extent,
                                float4 face,
                                float faceOn) {
    // 瘦脸:以人脸框中心/半径为准(无脸时退回画面中心)
    float2 disp = srcSampler.coord() / extent;
    float2 srcCoord = srcSampler.coord();
    if (slim > 0.001 && faceOn > 0.5) {
        float2 fc = face.xy;
        float2 fr = max(face.zw * 1.15, float2(0.10));
        float2 d = disp - fc;
        float2 e = d / fr;
        float w = clamp(1.0 - dot(e, e), 0.0, 1.0);
        w = w * w * (3.0 - 2.0 * w);
        d.x *= 1.0 + slim * 0.22 * w; // 向外取样 = 压窄(方向修正)
        srcCoord = (fc + d) * extent;
    }
    float4 s4 = srcSampler.sample(srcCoord);
    float4 b4 = blurSampler.sample(srcCoord);
    float3 s = s4.rgb / max(s4.a, 0.0001);
    float3 b = b4.rgb / max(b4.a, 0.0001);

    // 磨皮:小半径模糊 + 边缘保留 + 细节回加(避免塑料感)
    float3 detail = s - b;
    float dy = abs(dot(detail, float3(0.299, 0.587, 0.114)));
    float edge = smoothstep(0.015, 0.09, dy);
    float3 smoothed = mix(b, s, edge);

    float lum = dot(s, float3(0.299, 0.587, 0.114));
    // 肤色掩码(YCbCr 色度;纯白/灰天然落在窗口外)
    float cb = -0.168736 * s.r - 0.331264 * s.g + 0.5 * s.b;
    float cr = 0.5 * s.r - 0.418688 * s.g - 0.081312 * s.b;
    float skinCol = smoothstep(-0.25, -0.18, cb) * (1.0 - smoothstep(-0.04, 0.03, cb))
                  * smoothstep(-0.02, 0.06, cr) * (1.0 - smoothstep(0.17, 0.24, cr));
    // 人脸软掩码
    float fe = length((disp - face.xy) / max(face.zw, float2(0.05)));
    float faceSoft = 1.0 - smoothstep(0.62, 1.0, fe);
    float m = skinCol * faceSoft * faceOn; // 未检到脸则完全不处理
    // 高光/极暗不处理
    m *= 1.0 - smoothstep(0.80, 0.96, lum);
    m *= smoothstep(0.05, 0.15, lum);

    float st = clamp(smoothAmt * m, 0.0, 1.0);
    float3 c = mix(s, smoothed, st);
    c += detail * (st * 0.25); // 细节回加
    // 美白:gamma 提亮中间调(保色相纹理)+ 高光保护 + 微暖调(与 Android 一致)
    float wh = whiten * m;
    float midKnee = 1.0 - smoothstep(0.55, 0.90, lum);
    c = pow(max(c, float3(0.001)), float3(1.0 - wh * midKnee * 0.26));
    c += float3(0.014, 0.003, 0.0) * wh * midKnee;
    c.r += ruddy * 0.05 * m;
    c += bright * 0.10;
    float l2 = dot(c, float3(0.299, 0.587, 0.114));
    c = mix(float3(l2), c, satMul);
    return float4(c * s4.a, s4.a);
}
"""

class HinterCameraPlugin: NSObject, FlutterPlugin {

    private var registrar: FlutterPluginRegistrar?
    private let session = AVCaptureSession()
    private let sessionQueue = DispatchQueue(label: "hinter.session")
    private let videoQueue = DispatchQueue(label: "hinter.video")
    private let audioQueue = DispatchQueue(label: "hinter.audio")

    private var videoOutput: AVCaptureVideoDataOutput?
    private var audioOutput: AVCaptureAudioDataOutput?
    private var currentInput: AVCaptureDeviceInput?
    private var front = true
    @Volatile private var currentTier = 1080

    private func presetFor(_ tier: Int) -> AVCaptureSession.Preset {
        switch tier {
        case 720: return .hd1280x720
        case 2160: return .hd4K3840x2160
        default: return .high
        }
    }

    /// 当前镜头支持的档位(短边像素)
    private func supportedTiers(front: Bool) -> [Int] {
        var tiers = [720, 1080]
        if !front && session.canSetSessionPreset(.hd4K3840x2160) {
            tiers.append(2160)
        }
        return tiers
    }

    private var sink: PixelBufferSink?
    private var textureId: Int64 = -1

    private var ciContext: CIContext?
    private var combineKernel: CIColorKernel?
    private var blurFilter = CIFilter(name: "CIGaussianBlur")

    private var pool: CVPixelBufferPool?
    private var poolW = 0
    private var poolH = 0

    private var beauty = BeautyParams()

    private var micSink: FlutterEventSink?
    private var evtSink: FlutterEventSink?
    private var audioConverter: AVAudioConverter?
    private var pcmOut: AVAudioPCMBuffer?

    // 录制
    private var writer: AVAssetWriter?
    private var writerVideo: AVAssetWriterInput?
    private var writerAdaptor: AVAssetWriterInputPixelBufferAdaptor?
    private var writerAudio: AVAssetWriterInput?
    private var sessionStartTs: CMTime?
    @objc dynamic private var recording = false
    private var lastVideoW = 0
    private var lastVideoH = 0

    // ---- 人脸检测(Vision):显示空间归一化椭圆,供美颜掩码使用 ----
    private let faceQueue = DispatchQueue(label: "hinter.face")
    private var faceEllipse = SIMD4<Float>(0.5, 0.5, 0, 0) // cx, cy, rx, ry
    private var faceOn = false
    private var lastFaceDetect: CFTimeInterval = 0
    private var faceBusy = false
    private var renderCount: Int64 = 0
    /// 双通道诊断:NSLog + 沙盒文件(iOS26 上 os_log 经侧载签名可能不可见,

    static func register(with registrar: FlutterPluginRegistrar) {
        let inst = HinterCameraPlugin()
        inst.registrar = registrar

        let ch = FlutterMethodChannel(name: "hinter/camera",
                                      binaryMessenger: registrar.messenger())
        ch.setMethodCallHandler(inst.handle)

        let mic = PassthroughStreamHandler()
        mic.onListen = { sink in inst.micSink = sink }
        mic.onCancel = { inst.micSink = nil }
        FlutterEventChannel(name: "hinter/mic",
                            binaryMessenger: registrar.messenger())
            .setStreamHandler(mic)

        let evt = PassthroughStreamHandler()
        evt.onListen = { sink in inst.evtSink = sink }
        evt.onCancel = { inst.evtSink = nil }
        FlutterEventChannel(name: "hinter/camera_events",
                            binaryMessenger: registrar.messenger())
            .setStreamHandler(evt)
    }

    private func emitError(_ message: String) {
        DispatchQueue.main.async {
            self.evtSink?(["event": "error", "message": message])
        }
    }

    func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        switch call.method {
        case "start":
            let front = (call.arguments as? [String: Any])?["front"] as? Bool ?? true
            start(front: front, result: result)
        case "stop":
            stopAll(result: result)
        case "setBeauty":
            let args = call.arguments as? [String: Any] ?? [:]
            beauty.smooth = args["smooth"] as? Double ?? beauty.smooth
            beauty.whiten = args["whiten"] as? Double ?? beauty.whiten
            beauty.ruddy = args["ruddy"] as? Double ?? beauty.ruddy
            beauty.brightness = args["brightness"] as? Double ?? beauty.brightness
            beauty.saturation = args["saturation"] as? Double ?? beauty.saturation
            beauty.slim = args["slim"] as? Double ?? beauty.slim
            diag("setBeauty s=\(beauty.smooth) w=\(beauty.whiten) slim=\(beauty.slim)")
            result(nil)
        case "setQualityMode":
            let short = ((call.arguments as? [String: Any])?["short"]
                as? NSNumber)?.intValue ?? 1080
            setQualityMode(short: short, result: result)
        case "switchCamera":
            let front = (call.arguments as? [String: Any])?["front"] as? Bool ?? false
            switchCamera(front: front, result: result)
        case "startRecording":
            let path = (call.arguments as? [String: Any])?["path"] as? String
            startRecording(path: path, result: result)
        case "stopRecording":
            stopRecording(result: result)
        case "saveToGallery":
            let path = (call.arguments as? [String: Any])?["path"] as? String
            saveToGallery(path: path, result: result)
        default:
            result(FlutterMethodNotImplemented)
        }
    }

    // ---- 会话 ----

    private func setQualityMode(short: Int, result: @escaping FlutterResult) {
        sessionQueue.async { [weak self] in
            guard let self = self else { return }
            let tiers = self.supportedTiers(front: self.front)
            let tier = tiers.min(by: {
                abs($0 - short) < abs($1 - short)
            }) ?? 1080
            self.currentTier = tier
            self.session.beginConfiguration()
            if self.session.canSetSessionPreset(self.presetFor(tier)) {
                self.session.sessionPreset = self.presetFor(tier)
            }
            self.session.commitConfiguration()
            DispatchQueue.main.async {
                result(["modes": tiers.map { NSNumber(value: $0) },
                        "current": NSNumber(value: tier),
                        "width": 1080,
                        "height": 1920])
            }
        }
    }

    private func configureAudioSession() {
        let s = AVAudioSession.sharedInstance()
        try? s.setCategory(.playAndRecord, mode: .videoRecording,
                           options: [.defaultToSpeaker, .allowBluetooth])
        try? s.setActive(true)
    }

    private func start(front: Bool, result: @escaping FlutterResult) {
        self.front = front
        sessionQueue.async { [weak self] in
            guard let self = self, let registrar = self.registrar else { return }
            self.teardownSession()

            self.configureAudioSession()

            if self.sink == nil {
                self.sink = PixelBufferSink()
                // FlutterTextureRegistry 必须在主线程调用:
                // 后台线程 register 会静默失败 → Dart 拿到黑纹理(无报错)
                let sem = DispatchSemaphore(value: 0)
                var tid: Int64 = -1
                DispatchQueue.main.async {
                    tid = registrar.textures().register(self.sink!)
                    sem.signal()
                }
                sem.wait()
                self.textureId = tid
                diag("registerTexture tid=\(tid)")
            }
            if self.ciContext == nil {
                self.ciContext = CIContext(options: [.cacheIntermediates: false])
            }

            do {
                try self.buildSession(front: front)
            } catch {
                DispatchQueue.main.async {
                    result(FlutterError(code: "START",
                                        message: "相机启动失败: \(error.localizedDescription)",
                                        details: nil))
                }
                return
            }

            DispatchQueue.global().async { self.session.startRunning() }
            let texId = self.textureId
            NSLog("[HinterCam] start done texId=%lld running=%d",
                  texId, session.isRunning ? 1 : 0)
            let tiers = self.supportedTiers(front: front)
            let ct = self.currentTier
            DispatchQueue.main.async {
                result(["textureId": NSNumber(value: texId),
                        "width": 1080,
                        "height": 1920,
                        "modes": tiers.map { NSNumber(value: $0) },
                        "current": NSNumber(value: ct)])
            }
        }
    }

    private func buildSession(front: Bool) throws {
        session.beginConfiguration()
        session.sessionPreset = presetFor(currentTier)
        defer { session.commitConfiguration() }

        let position: AVCaptureDevice.Position = front ? .front : .back
        let device = AVCaptureDevice.default(.builtInWideAngleCamera,
                                             for: .video, position: position)
            ?? AVCaptureDevice.default(for: .video)
        guard let cam = device else {
            throw NSError(domain: "hinter", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "没有可用摄像头"])
        }
        let input = try AVCaptureDeviceInput(device: cam)
        if session.canAddInput(input) {
            session.addInput(input)
            currentInput = input
        }

        let mic = AVCaptureDevice.default(for: .audio)
        if let mic = mic, let micInput = try? AVCaptureDeviceInput(device: mic) {
            if session.canAddInput(micInput) {
                session.addInput(micInput)
            }
        }

        let vOut = AVCaptureVideoDataOutput()
        vOut.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ]
        vOut.alwaysDiscardsLateVideoFrames = true
        vOut.setSampleBufferDelegate(self, queue: videoQueue)
        if session.canAddOutput(vOut) { session.addOutput(vOut) }
        videoOutput = vOut
        vOut.connection(with: .video)?.videoOrientation = .portrait

        let aOut = AVCaptureAudioDataOutput()
        aOut.setSampleBufferDelegate(self, queue: audioQueue)
        if session.canAddOutput(aOut) { session.addOutput(aOut) }
        audioOutput = aOut
    }

    private func teardownSession() {
        recording = false
        for input in session.inputs {
            session.removeInput(input)
        }
        for output in session.outputs {
            session.removeOutput(output)
        }
        currentInput = nil
        videoOutput = nil
        audioOutput = nil
        if session.isRunning {
            session.stopRunning()
        }
    }

    private func switchCamera(front: Bool, result: @escaping FlutterResult) {
        self.front = front
        sessionQueue.async { [weak self] in
            guard let self = self else { return }
            do {
                self.session.beginConfiguration()
                if let old = self.currentInput {
                    self.session.removeInput(old)
                }
                let position: AVCaptureDevice.Position = front ? .front : .back
                guard let cam = AVCaptureDevice.default(.builtInWideAngleCamera,
                                                        for: .video,
                                                        position: position)
                        ?? AVCaptureDevice.default(for: .video) else {
                    throw NSError(domain: "hinter", code: -2,
                                  userInfo: [NSLocalizedDescriptionKey: "没有可用摄像头"])
                }
                let input = try AVCaptureDeviceInput(device: cam)
                if self.session.canAddInput(input) {
                    self.session.addInput(input)
                    self.currentInput = input
                }
                self.session.commitConfiguration()
                DispatchQueue.main.async { result(nil) }
            } catch {
                self.session.commitConfiguration()
                DispatchQueue.main.async {
                    result(FlutterError(code: "SWITCH",
                                        message: "切换摄像头失败: \(error.localizedDescription)",
                                        details: nil))
                }
            }
        }
    }

    private func stopAll(result: @escaping FlutterResult) {
        sessionQueue.async { [weak self] in
            guard let self = self else { return }
            self.finishWriter()
            self.teardownSession()
            if let id = self.sink.map({ _ in self.textureId }), id >= 0 {
                let reg = self.registrar
                DispatchQueue.main.async {
                    reg?.textures().unregisterTexture(id)
                }
            }
            self.sink = nil
            self.textureId = -1
            DispatchQueue.main.async { result(nil) }
        }
    }

    // ---- 录制 ----

    private func startRecording(path: String?, result: @escaping FlutterResult) {
        sessionQueue.async { [weak self] in
            guard let self = self else { return }
            guard let path = path else {
                DispatchQueue.main.async {
                    result(FlutterError(code: "REC", message: "路径为空", details: nil))
                }
                return
            }
            do {
                try self.buildWriter(path: path)
                self.recording = true
                DispatchQueue.main.async { result(nil) }
            } catch {
                DispatchQueue.main.async {
                    result(FlutterError(code: "REC",
                                        message: "编码器启动失败: \(error.localizedDescription)",
                                        details: nil))
                }
            }
        }
    }

    private func buildWriter(path: String) throws {
        let url = URL(fileURLWithPath: path)
        try? FileManager.default.removeItem(at: url)
        let w = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let width = max(lastVideoW, 720)
        let height = max(lastVideoH, 1280)

        let videoSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: 9_000_000,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel
            ]
        ]
        let vIn = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        vIn.expectsMediaDataInRealTime = true
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: vIn,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height
            ])
        if w.canAdd(vIn) { w.add(vIn) }

        let audioSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 48000,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 128_000
        ]
        let aIn = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
        aIn.expectsMediaDataInRealTime = true
        if w.canAdd(aIn) { w.add(aIn) }

        w.startWriting()
        writer = w
        writerVideo = vIn
        writerAdaptor = adaptor
        writerAudio = aIn
        sessionStartTs = nil
    }

    private func finishWriter() {
        recording = false
        guard let w = writer else { return }
        writerVideo?.markAsFinished()
        writerAudio?.markAsFinished()
        writerVideo = nil
        writerAdaptor = nil
        writerAudio = nil
        sessionStartTs = nil
        let group = DispatchGroup()
        group.enter()
        w.finishWriting { group.leave() }
        group.wait(timeout: .now() + 5)
        writer = nil
    }

    private func stopRecording(result: @escaping FlutterResult) {
        sessionQueue.async { [weak self] in
            guard let self = self else { return }
            let hadWriter = self.writer != nil
            let path = (self.writer?.outputURL.path)
            self.finishWriter()
            DispatchQueue.main.async {
                result(hadWriter ? path : nil)
            }
        }
    }

    /// 把录制好的视频保存进系统相册「相簿 Hinter」
    private func saveToGallery(path: String?, result: @escaping FlutterResult) {
        guard let path = path else {
            result(FlutterError(code: "SAVE", message: "路径为空", details: nil))
            return
        }
        let url = URL(fileURLWithPath: path)
        PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
            guard status == .authorized || status == .limited else {
                DispatchQueue.main.async {
                    result(FlutterError(code: "SAVE",
                                        message: "没有相册写入权限",
                                        details: nil))
                }
                return
            }
            PHPhotoLibrary.shared().performChanges({
                PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: url)
            }) { ok, err in
                DispatchQueue.main.async {
                    if ok {
                        result(true)
                    } else {
                        result(FlutterError(code: "SAVE",
                                            message: err?.localizedDescription ?? "保存失败",
                                            details: nil))
                    }
                }
            }
        }
    }

    // ---- 视频帧处理(Core Image 美颜) ----

    private func ensurePool(width: Int, height: Int) {
        guard pool == nil || poolW != width || poolH != height else { return }
        poolW = width
        poolH = height
        var pixelAttrs: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey: width,
            kCVPixelBufferHeightKey: height,
            // ★ Impeller(Metal)要求 buffer 可转 MTLTexture,
            //   缺此属性时纹理转换静默失败 → 全黑无报错
            kCVPixelBufferMetalCompatibilityKey: kCFBooleanTrue!,
            kCVPixelBufferOpenGLESCompatibilityKey: kCFBooleanTrue!,
        ]
        pool = nil
        CVPixelBufferPoolCreate(kCFAllocatorDefault, nil, pixelAttrs as CFDictionary, &pool)
        pixelAttrs.removeAll()
    }

    private func makeBuffer() -> CVPixelBuffer? {
        ensurePool(width: lastVideoW, height: lastVideoH)
        var out: CVPixelBuffer?
        if let pool = pool {
            CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &out)
        }
        if out == nil {
            var createAttrs: [CFString: Any] = [
                kCVPixelBufferMetalCompatibilityKey: kCFBooleanTrue!,
                kCVPixelBufferOpenGLESCompatibilityKey: kCFBooleanTrue!,
            ]
            CVPixelBufferCreate(kCFAllocatorDefault, lastVideoW, lastVideoH,
                                kCVPixelFormatType_32BGRA,
                                createAttrs as CFDictionary, &out)
        }
        return out
    }
}

extension HinterCameraPlugin: AVCaptureVideoDataOutputSampleBufferDelegate,
                              AVCaptureAudioDataOutputSampleBufferDelegate {

    func captureOutput(_ output: AVCaptureOutput,
                       didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        if output is AVCaptureAudioDataOutput {
            handleAudio(sampleBuffer)
        } else {
            handleVideo(sampleBuffer)
        }
    }

    /// Vision 人脸检测(限流 ~10fps,后台队列),结果写入 faceEllipse/faceOn
    private func detectFace(_ pb: CVPixelBuffer) {
        let now = CACurrentMediaTime()
        if faceBusy || now - lastFaceDetect < 0.1 { return }
        faceBusy = true
        lastFaceDetect = now
        faceQueue.async { [weak self] in
            guard let self = self else { return }
            defer { self.faceBusy = false }
            let req = VNDetectFaceRectanglesRequest()
            let handler = VNImageRequestHandler(cvPixelBuffer: pb, options: [:])
            do {
                try handler.perform([req])
            } catch {
                return
            }
            guard let faces = req.results, !faces.isEmpty else {
                // 无脸:椭圆收缩淡出
                self.faceEllipse.z *= 0.6
                self.faceEllipse.w *= 0.6
                self.faceOn = self.faceEllipse.z > 0.02
                return
            }
            // 取最大人脸;Vision 坐标原点在左下 → 转成左上显示坐标
            let best = faces.max { a, b in
                a.boundingBox.width * a.boundingBox.height <
                    b.boundingBox.width * b.boundingBox.height
            }!
            let bb = best.boundingBox
            let cx = Float(bb.midX)
            let cy = Float(1.0 - bb.midY)
            let rx = Float(bb.width) * 0.55
            let ry = Float(bb.height) * 0.62
            let k: Float = 0.35
            self.faceEllipse.x += (cx - self.faceEllipse.x) * k
            self.faceEllipse.y += (cy - self.faceEllipse.y) * k
            self.faceEllipse.z += (rx - self.faceEllipse.z) * k
            self.faceEllipse.w += (ry - self.faceEllipse.w) * k
            self.faceOn = true
        }
    }

    private func handleVideo(_ sampleBuffer: CMSampleBuffer) {
        guard let pb = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        lastVideoW = CVPixelBufferGetWidth(pb)
        lastVideoH = CVPixelBufferGetHeight(pb)
        detectFace(pb)

        var ci = CIImage(cvPixelBuffer: pb)
        let extent = ci.extent

        // 1) 高斯模糊(磨皮基础)
        blurFilter?.setValue(ci.clampedToExtent(), forKey: kCIInputImageKey)
        // 磨皮模糊半径:全分辨率像素,过大必然糊崩
        let sigma = 2.2 + beauty.smooth * 5.0
        blurFilter?.setValue(sigma, forKey: kCIInputRadiusKey)
        var blurred = blurFilter?.outputImage
        if let b = blurred {
            blurred = b.cropped(to: extent)
        }

        // 2) 磨皮:边缘保留合成(经典 max/min 组合,去暗斑提亮瑕疵,
        //    保留轮廓细节);随后 gamma 美白、CITemperatureAndTint 红润、
        //    CIColorControls 亮度/饱和度。iOS 端瘦脸暂未启用(slim 忽略)
        if let b = blurred, beauty.smooth > 0.01 {
            // applyingFilter 的接收者自动占 inputImage,
            // 合成协议的第二张图键名是 inputBackgroundImage
            // (inputImage2 不存在会抛 forUndefinedKey 崩溃;
            //  全用 inputImage 则背景缺省 extent 归零 → 黑屏)
            let maxed = ci.applyingFilter("CIMaximumCompositing",
                                          parameters: ["inputBackgroundImage": b])
            let minned = maxed.applyingFilter("CIMinimumCompositing",
                                              parameters: ["inputBackgroundImage": ci])
            ci = minned.cropped(to: extent)
        }
        if beauty.whiten > 0.01 {
            ci = ci.applyingFilter("CIGammaAdjust", parameters: [
                "inputPower": NSNumber(value: 1.0 - 0.28 * beauty.whiten)])
        }
        if beauty.ruddy > 0.01 {
            ci = ci.applyingFilter("CITemperatureAndTint", parameters: [
                "inputNeutral": CIVector(x: 6500 - 400 * CGFloat(beauty.ruddy),
                                         y: 100),
                "inputTargetNeutral": CIVector(x: 6500, y: 100)])
        }
        ci = ci.applyingFilter("CIColorControls", parameters: [
            kCIInputBrightnessKey: NSNumber(value: beauty.brightness * 0.25),
            kCIInputSaturationKey: NSNumber(value: 0.78 + beauty.saturation * 0.5)])
        // 瘦脸:双侧液化内收(近似安卓 GL 版)
        if beauty.slim > 0.02, faceOn {
            let fw = Double(extent.width), fh = Double(extent.height)
            let cx = Double(faceEllipse.x) * fw
            let cyTop = Double(faceEllipse.y) * fh
            let rx = Double(faceEllipse.z) * fw
            let ry = Double(faceEllipse.w) * fh
            let cyCI = fh - cyTop + ry * 0.12
            for side in [-1.0, 1.0] {
                let center = CIVector(x: CGFloat(cx + side * rx * 0.92),
                                      y: CGFloat(cyCI))
                ci = ci.applyingFilter("CILiquifyEffect", parameters: [
                    "inputCenter": center,
                    "inputRadius": CGFloat(rx * 1.15),
                    "inputAngle": 0.0,
                    "inputScale": 1.0,
                    "inputDisplacement": CGFloat(-26.0 * beauty.slim),
                ])
            }
        }

        // 3) 渲染到输出缓冲,交给 Flutter 预览
        renderCount += 1
        if renderCount == 1 || renderCount % 150 == 0 {
            diag("render #\(renderCount) tex=\(textureId) ciExt=\(ci.extent)")
        }
        if let sink = sink, let ctx = ciContext, textureId >= 0,
           let outBuf = makeBuffer() {
            ctx.render(ci, to: outBuf)
            if renderCount == 70 {
                ciWrite(ci, ctx: ctx, name: "frame70.png")
            }
            sink.present(outBuf)
            let tid = textureId
            let reg = registrar
            DispatchQueue.main.async {
                reg?.textures().textureFrameAvailable(tid)
            }

            // 4) 录制
            if recording, recording_wantsVideo(),
               let adaptor = writerAdaptor, let w = writer, w.status == .writing {
                let ts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
                if sessionStartTs == nil {
                    sessionStartTs = ts
                    w.startSession(atSourceTime: ts)
                }
                adaptor.append(outBuf, withPresentationTime: ts)
            }
        }
    }

    /// 视频流是否该往编码器送(编码器就绪时)
    private func recording_wantsVideo() -> Bool {
        return writerVideo?.isReadyForMoreMediaData ?? false
    }

    private func handleAudio(_ sampleBuffer: CMSampleBuffer) {
        // 1) 录制音轨(直接透传给 AVAssetWriter 由其编码 AAC)
        if recording, let w = writer, w.status == .writing,
           let aIn = writerAudio, aIn.isReadyForMoreMediaData,
           sessionStartTs != nil {
            aIn.append(sampleBuffer)
        }

        // 2) 本地语音识别:转 16kHz 单声道 int16
        guard let micSink = micSink,
              let desc = CMSampleBufferGetFormatDescription(sampleBuffer) else { return }
        do {
            if audioConverter == nil {
                let inFormat = AVAudioFormat(cmAudioFormatDescription: desc)
                let outFormat = AVAudioFormat(commonFormat: .pcmFormatInt16,
                                              sampleRate: 16000,
                                              channels: 1,
                                              interleaved: true)!
                audioConverter = AVAudioConverter(from: inFormat, to: outFormat)
                pcmOut = AVAudioPCMBuffer(pcmFormat: outFormat,
                                          frameCapacity: 48000)
            }
            guard let converter = audioConverter, let out = pcmOut else { return }

            var blockBuffer: CMBlockBuffer?
            var bufferList = AudioBufferList(
                mNumberBuffers: 1,
                mBuffers: AudioBuffer(mNumberChannels: 1,
                                      mDataByteSize: 0,
                                      mData: nil))
            CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
                sampleBuffer,
                bufferListSizeNeededOut: nil,
                bufferListOut: &bufferList,
                bufferListSize: MemoryLayout<AudioBufferList>.size,
                blockBufferAllocator: kCFAllocatorDefault,
                blockBufferMemoryAllocator: kCFAllocatorDefault,
                flags: 0,
                blockBufferOut: &blockBuffer)

            let inFormat = AVAudioFormat(cmAudioFormatDescription: desc)
            guard let inBuf = AVAudioPCMBuffer(
                pcmFormat: inFormat,
                bufferListNoCopy: &bufferList,
                deallocator: nil), inBuf.frameLength > 0 else { return }

            out.frameLength = 0
            var consumed = false
            var convErr: NSError?
            let status = converter.convert(to: out, error: &convErr) { _, outStatus in
                if consumed {
                    outStatus.pointee = .noDataNow
                    return nil
                }
                consumed = true
                outStatus.pointee = .haveData
                return inBuf
            }
            if status == .haveData, out.frameLength > 0,
               let ch = out.int16ChannelData?[0] {
                let bytes = Data(bytes: ch,
                                 count: Int(out.frameLength) * 2)
                DispatchQueue.main.async {
                    micSink(bytes)
                }
            }
        } catch {
            // 转换失败时静默跳过该帧,不影响预览/录制
        }
    }
}

// ============================================================================
// App 入口
// ============================================================================

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "HinterCameraPlugin") {
      HinterCameraPlugin.register(with: registrar)
    }
  }
}
