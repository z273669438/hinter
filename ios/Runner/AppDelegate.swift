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
    float edge = smoothstep(0.010, 0.06, dy);
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

    float st = min(smoothAmt * m, 0.85);
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
    private var currentTier = 1080

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
    /// 最近一次成功检出人脸的媒体时间(用于漏检保持)
    private var lastFaceOkAt: CFTimeInterval = 0
    private var faceTick: Int = 0
    /// 上一帧检出的人脸椭圆 + 速度,用于按检测延迟做位置外推
    private var lastMeasured = SIMD4<Float>(0.5, 0.5, 0, 0)
    private var faceVel = SIMD4<Float>(0, 0, 0, 0)
    private var slimCapture = 0
    private var jawHist: [SIMD4<Float>] = []
    /// 下颌锚点(左上原点归一化): chinX, chinY, jawHalfW, jawTopY
    /// 来自 Vision faceContour 轮廓点,而不是脸框比例推算
    private var jawAnchor = SIMD4<Float>(0.5, 0.74, 0.14, 0.62)
    /// 下颌四级全宽:下巴/下颌角/脸颊/额角(安卓同款,来自 faceContour)
    private var jawW = SIMD4<Float>(0.30, 0.55, 0.85, 0.82)
    /// 人脸翻滚角(弧度),来自 VNFaceObservation.roll,用于把形变坐标系转正
    private var faceRoll: Float = 0
    private var lastDetLog: CFTimeInterval = 0
    private var lastFaceDetect: CFTimeInterval = 0
    private var renderCount: Int64 = 0

    /// 美颜合成核(Metal,workflow 编译 default.metallib 注入 app 根目录)
    /// 注意:核内做任意坐标采样(瘦脸位移/模糊),CI 判定为**通用核**,
    /// 必须用 CIKernel 加载;CIColorKernel 会抛 "appears to be a CIKernel"。
    private lazy var beautyKernel: CIKernel? = {
        guard let url = Bundle.main.url(forResource: "default",
                                        withExtension: "metallib"),
              let data = try? Data(contentsOf: url) else {
            diag("metallib NOT FOUND -> fallback chain")
            return nil
        }
        do {
            let k = try CIKernel(functionName: "hinterBeauty",
                                 fromMetalLibraryData: data)
            diag("beautyKernel LOADED")
            return k
        } catch {
            diag("beautyKernel BUILD FAILED: \(error)")
            return nil
        }
    }()
    private var audioDbg: Int64 = 0
    /// 瘦脸液化中心的平滑值(每帧 EMA;Swift 禁止 extension 存储属性)
    private var slimCx: Double = -1
    private var slimCy: Double = -1
    private var slimRx: Double = 0
    private var micSent: Int64 = 0
    private var micConvFail: Int64 = 0
    private var micEmpty: Int64 = 0
    private var slimLostAt: CFTimeInterval = 0
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
        // 节流与状态全部放在串行队列内访问。
        // 旧实现用跨线程 faceBusy 布尔量做互斥:faceQueue 写 false、视频线程读,
        // 没有同步保证,视频线程会一直读到旧的 true → 检测静默停摆几十秒,
        // 表现为美颜"不跟脸/位置固定"。改为队列内自节流后该隐患消失。
        faceQueue.async { [weak self] in
            guard let self = self else { return }
            let now = CACurrentMediaTime()
            if now - self.lastFaceDetect < 0.07 { return }
            self.lastFaceDetect = now
            self.faceTick &+= 1
            // 只跑矩形检测:关键点请求贵一倍以上,而内核瘦脸已改用 fc/fr,
            // 不再需要轮廓点。去掉后检测帧率明显提高 → 转头时掩码不滞后
            let req = VNDetectFaceRectanglesRequest()
            let lmReq = VNDetectFaceLandmarksRequest()
            let handler = VNImageRequestHandler(cvPixelBuffer: pb, options: [:])
            do {
                try handler.perform([req, lmReq])
            } catch {
                diag("det THROW \(error.localizedDescription)")
                return
            }
            let tNow = CACurrentMediaTime()
            if tNow - self.lastDetLog > 1.0 {
                self.lastDetLog = tNow
                if let fs = req.results, let f = fs.max(by: {
                    $0.boundingBox.width * $0.boundingBox.height <
                        $1.boundingBox.width * $1.boundingBox.height }) {
                    let b = f.boundingBox
                    diag(String(format: "det n=%d bb=(%.3f,%.3f,%.3f,%.3f)",
                                     fs.count, b.minX, b.minY, b.width, b.height))
                } else {
                    diag("det NONE")
                }
            }
            guard let faces = req.results, !faces.isEmpty else {
                self.onFaceMiss()
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
            // 合理性校验:误检(下巴/反光/肩部)会把瘦脸位移推到头发和画面边缘
            let ratio = ry / max(rx, 0.001)
            let sane = cx > 0.08 && cx < 0.92 && cy > 0.05 && cy < 0.92
                && rx > 0.085 && rx < 0.56 && ry > 0.065 && ry < 0.50
                && ratio > 0.38 && ratio < 1.05
            guard sane else {
                self.onFaceMiss()
                return
            }
            // ---- 下颌四级宽度(移植安卓 FaceMesh 方案)----
            // 安卓用 ML Kit 关键点:152=下巴底, 172/397=下颌角, 234/454=脸颊,
            // 66/296=额角;iOS 用 Vision faceContour 按同样"高度分档"取宽度。
            // 宽度必须来自真实轮廓——用脸框推算会让形变带整体偏移(安卓同样踩过)。
            let bw = rx / 0.55                       // 脸框宽(归一化)
            var w0 = bw * 0.34, w1 = bw * 0.62, w2 = bw * 0.96, w3 = bw * 0.92
            var lmObs: VNFaceObservation?
            if let lms = lmReq.results, !lms.isEmpty {
                lmObs = lms.min { a, b in
                    hypot(a.boundingBox.midX - bb.midX, a.boundingBox.midY - bb.midY) <
                        hypot(b.boundingBox.midX - bb.midX, b.boundingBox.midY - bb.midY)
                }
            }
            if let c = lmObs?.landmarks?.faceContour, c.pointCount > 6 {
                let sz = CGSize(width: CVPixelBufferGetWidth(pb),
                                height: CVPixelBufferGetHeight(pb))
                var pts: [(Float, Float)] = []
                pts.reserveCapacity(c.pointCount)
                for pt in c.pointsInImage(imageSize: sz) {
                    pts.append((Float(pt.x / sz.width),
                                1.0 - Float(pt.y / sz.height)))   // 左上原点
                }
                let topY = pts.map { $0.1 }.min() ?? 0
                let botY = pts.map { $0.1 }.max() ?? 1
                let chinX = (pts.max { $0.1 < $1.1 }?.0) ?? cx
                let hgt = max(botY - topY, 0.02)
                // h:0=下巴 → 1=额角
                func widthAt(_ h: Float, _ tol: Float) -> Float? {
                    let yTarget = botY - h * hgt
                    var halfMax: Float = 0
                    for (px, py) in pts where abs(py - yTarget) <= tol * hgt {
                        halfMax = max(halfMax, abs(px - chinX))
                    }
                    return halfMax > 0.005 ? halfMax * 2 : nil
                }
                func clampW(_ v: Float, _ lo: Float) -> Float {
                    min(max(v, bw * lo), bw * 1.15)
                }
                if let v = widthAt(0.06, 0.10) { w0 = clampW(v, 0.20) }
                if let v = widthAt(0.30, 0.10) { w1 = clampW(v, 0.40) }
                if let v = widthAt(0.62, 0.10) { w2 = clampW(v, 0.70) }
                if let v = widthAt(0.92, 0.10) { w3 = clampW(v, 0.65) }
            }
            // EMA 平滑(宽度变化比位置慢,直接 0.25)
            self.jawW.x += (w0 - self.jawW.x) * 0.25
            self.jawW.y += (w1 - self.jawW.y) * 0.25
            self.jawW.z += (w2 - self.jawW.z) * 0.25
            self.jawW.w += (w3 - self.jawW.w) * 0.25

            // 位置/尺寸突变都要阻尼:Vision 偶发把框检成一半大小(rx 0.37→0.17),
            // 单帧采纳会让美颜区突然缩到脸中间,观感就是"不跟脸"
            let jump = abs(cx - self.faceEllipse.x) + abs(cy - self.faceEllipse.y)
            let sizeRatio = rx / max(self.faceEllipse.z, 0.001)
            let sizeWild = sizeRatio < 0.72 || sizeRatio > 1.40
            // 椭圆已经塌陷(被误检拖小)时直接吸附恢复,否则美颜掩码等于关闭,
            // 表现就是"滑块怎么拉都没反应"
            let collapsed = self.faceEllipse.z < 0.085
            // 快速转头本身就是"大跳变",旧逻辑在此时反而把跟随压到 0.12,
            // 等于最需要跟上时故意变慢 → 只要跳变不荒谬就快速跟随
            let k: Float = collapsed ? 1.0
                : (sizeWild ? 0.15 : (jump > 0.45 ? 0.25 : 0.55))
            self.faceEllipse.x += (cx - self.faceEllipse.x) * k
            self.faceEllipse.y += (cy - self.faceEllipse.y) * k
            self.faceEllipse.z += (rx - self.faceEllipse.z) * k
            self.faceEllipse.w += (ry - self.faceEllipse.w) * k
            // 人脸翻滚角:设备倾斜/歪头时,形变坐标系必须跟着转
            if let r = best.roll?.floatValue {
                self.faceRoll += (r - self.faceRoll) * 0.35
            }
            self.faceOn = true
            let tNow2 = CACurrentMediaTime()
            // 速度必须用**实测框**算,不能用平滑后的椭圆:
            // EMA 每步只走 35%,用它的差值当速度会把真实速度低估约 3 倍,
            // 外推补偿自然不够 → "跟得慢"
            if self.lastFaceOkAt > 0 {
                let dt2 = Float(max(tNow2 - self.lastFaceOkAt, 0.001))
                if dt2 < 0.5 {
                    func capv(_ v: Float, _ lim: Float) -> Float {
                        min(max(v, -lim), lim)
                    }
                    let mvx = capv((cx - self.lastMeasured.x) / dt2, 3.0)
                    let mvy = capv((cy - self.lastMeasured.y) / dt2, 3.0)
                    let mvz = capv((rx - self.lastMeasured.z) / dt2, 2.0)
                    let mvw = capv((ry - self.lastMeasured.w) / dt2, 2.0)
                    let vk: Float = 0.35        // 速度再做轻平滑,抑制误检毛刺
                    self.faceVel.x += (mvx - self.faceVel.x) * vk
                    self.faceVel.y += (mvy - self.faceVel.y) * vk
                    self.faceVel.z += (mvz - self.faceVel.z) * vk
                    self.faceVel.w += (mvw - self.faceVel.w) * vk
                }
            }
            self.lastMeasured = SIMD4<Float>(cx, cy, rx, ry)
            self.lastFaceOkAt = tNow2
        }
    }

    /// 漏检处理:近拍时 Vision 常间歇性丢脸,立刻收缩会让美颜区闪烁/跑偏。
    /// 1.2s 内保持上次椭圆不动,之后才开始收缩淡出。
    private func onFaceMiss() {
        let age = CACurrentMediaTime() - lastFaceOkAt
        if age < 1.2 { return }          // 短暂漏检:原位置保持,不闪
        if age < 3.0 {                    // 中期:沿用上次位置
            faceOn = faceEllipse.z > 0.085
            return
        }
        // 长时间检不到脸(日志里出现过 20~40s):**淡出**美颜。
        // 曾试过套用居中默认椭圆,结果是把挤压/磨皮落到与脸无关的位置,
        // 用户感受是"位置乱跑、不跟脸"。宁可暂时不处理,也不能压错地方。
        faceEllipse = SIMD4<Float>(0.5, 0.54, 0.06, 0.04)
        faceOn = false
    }

    /// 在图上画出内核实际使用的椭圆(红)与瘦脸带上界(青),用于把
    /// "坐标"和"画面"钉在同一帧上,排除时间差导致的误判
    private func debugMark(_ img: CIImage, e: SIMD4<Float>,
                           extent: CGRect) -> CIImage {
        let W = extent.width, H = extent.height
        let cx = CGFloat(e.x) * W
        let cyCI = H - CGFloat(e.y) * H          // 转 CI 的左下原点
        let rx = CGFloat(e.z) * W, ry = CGFloat(e.w) * H
        let rect = CGRect(x: cx - rx, y: cyCI - ry,
                          width: rx * 2, height: ry * 2)
        let bw: CGFloat = 6
        let red = CIColor(red: 1, green: 0, blue: 0, alpha: 1)
        var out = img
        for b in [CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: bw),
                  CGRect(x: rect.minX, y: rect.maxY - bw, width: rect.width, height: bw),
                  CGRect(x: rect.minX, y: rect.minY, width: bw, height: rect.height),
                  CGRect(x: rect.maxX - bw, y: rect.minY, width: bw, height: rect.height)] {
            out = CIImage(color: red).cropped(to: b).composited(over: out)
        }
        // 青色横线 = 瘦脸带上界(vy=0.45);黄线 = 下界(vy=1.22)
        for (vy, col) in [(Float(0.45), CIColor(red: 0, green: 1, blue: 1, alpha: 1)),
                          (Float(1.22), CIColor(red: 1, green: 1, blue: 0, alpha: 1))] {
            let y = cyCI - CGFloat(vy) * ry
            if y > extent.minY && y < extent.maxY {
                let r = CGRect(x: extent.minX, y: y - 3,
                               width: extent.width, height: 6)
                out = CIImage(color: col).cropped(to: r).composited(over: out)
            }
        }
        return out.cropped(to: extent)
    }

    private func handleVideo(_ sampleBuffer: CMSampleBuffer) {
        guard let pb = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        lastVideoW = CVPixelBufferGetWidth(pb)
        lastVideoH = CVPixelBufferGetHeight(pb)
        detectFace(pb)

        var ci = CIImage(cvPixelBuffer: pb)
        let extent = ci.extent

        // 按检测延迟外推人脸位置:检测只有几帧/秒,转头时椭圆会滞后,
        // 表现为"磨皮/瘦脸跟着头漂、漏到背景"。用速度×延迟补偿即可贴合
        let ageS = Float(min(max(CACurrentMediaTime() - lastFaceOkAt, 0), 0.35))
        let ex = min(max(faceEllipse.x + faceVel.x * ageS, 0.0), 1.0)
        let ey = min(max(faceEllipse.y + faceVel.y * ageS, 0.0), 1.0)
        let ez = min(max(faceEllipse.z + faceVel.z * ageS, 0.02), 0.60)
        let ew = min(max(faceEllipse.w + faceVel.w * ageS, 0.02), 0.45)

        // 模糊半径(像素):按人脸框像素宽取比例 → 手机/平板、近/远观感一致
        let faceWpx = ez > 0.02
            ? CGFloat(ez) / 0.55 * extent.width
            : extent.width * 0.25
        let blurR = min(max(faceWpx * (0.004 + 0.012 * beauty.smooth), 1.5), 16.0)

        // 美颜:单输入 Metal 通用核(模糊在核内做,避免第二输入图坐标错位)
        if let kernel = beautyKernel {
            // jaw = (chinX, chinY, jawHalfW, jawTopY) 左上原点归一化
            let jaw = CIVector(x: CGFloat(jawW.x), y: CGFloat(jawW.y),
                               z: CGFloat(jawW.z), w: CGFloat(jawW.w))
            let out = kernel.apply(
                extent: extent,
                roiCallback: { _, r in r.insetBy(dx: -48, dy: -48) },
                arguments: [
                    ci,
                    NSNumber(value: beauty.smooth),
                    NSNumber(value: beauty.whiten),
                    NSNumber(value: beauty.ruddy),
                    NSNumber(value: beauty.brightness),
                    NSNumber(value: 0.78 + beauty.saturation * 0.5),
                    NSNumber(value: faceOn ? beauty.slim : 0.0),
                    CIVector(x: CGFloat(ex), y: CGFloat(ey),
                             z: CGFloat(ez), w: CGFloat(ew)),
                    NSNumber(value: faceOn ? 1.0 : 0.0),
                    jaw,
                    CIVector(x: 1.0 / max(extent.width, 1),
                             y: 1.0 / max(extent.height, 1)),
                    NSNumber(value: Double(blurR)),
                    NSNumber(value: Double(faceRoll)),
                ])
            if let o = out { ci = o }
        } else {
            // 回退链:全屏高斯磨皮 + 提亮(仅在核不可用时生效)
            if beauty.smooth > 0.01 {
                blurFilter?.setValue(ci.clampedToExtent(), forKey: kCIInputImageKey)
                blurFilter?.setValue(2.5 + beauty.smooth * 5.0, forKey: kCIInputRadiusKey)
                if let b = blurFilter?.outputImage?.cropped(to: extent) {
                    ci = ci.applyingFilter("CIDissolveTransition", parameters: [
                        "inputTargetImage": b,
                        "inputTime": NSNumber(value: 0.05 + 0.30 * beauty.smooth),
                    ])
                }
            }
            if beauty.whiten > 0.01 {
                ci = ci.applyingFilter("CIGammaAdjust", parameters: [
                    "inputPower": NSNumber(value: 1.0 - 0.12 * beauty.whiten)])
            }
            ci = ci.applyingFilter("CIColorControls", parameters: [
                kCIInputBrightnessKey: NSNumber(value: beauty.brightness * 0.25),
                kCIInputSaturationKey: NSNumber(value: 0.78 + beauty.saturation * 0.5)])
        }
        // 3) 渲染到输出缓冲,交给 Flutter 预览
        renderCount += 1
        if renderCount == 1 || renderCount % 150 == 0 {
            diag("render #\(renderCount) tex=\(textureId) faceOn=\(faceOn ? 1 : 0) "
                 + "age=\(Int((CACurrentMediaTime() - lastFaceOkAt) * 1000))ms "
                 + "c=(\(String(format: "%.3f", faceEllipse.x)),\(String(format: "%.3f", faceEllipse.y))) "
                 + "r=(\(String(format: "%.3f", faceEllipse.z)),\(String(format: "%.3f", faceEllipse.w))) "
                 + "sl=\(String(format: "%.2f", beauty.smooth))/\(String(format: "%.2f", beauty.whiten))"
                 + "/\(String(format: "%.2f", beauty.slim))"
                 + " jaw=(\(String(format: "%.2f", jawAnchor.x)),\(String(format: "%.2f", jawAnchor.y))"
                 + ",\(String(format: "%.2f", jawAnchor.z)),\(String(format: "%.2f", jawAnchor.w)))")
        }
        if let sink = sink, let ctx = ciContext, textureId >= 0,
           let outBuf = makeBuffer() {
            ctx.render(ci, to: outBuf)
            if renderCount == 70 {
                ciWrite(ci, ctx: ctx, name: "frame70.png")
            }
            // 900 帧≈15s:此时用户通常已在调滑块,留一张带美颜参数的实拍帧做对照
            if renderCount == 900 {
                ciWrite(ci, ctx: ctx, name: "frame900.png")
            }
            // 瘦脸生效且有脸时抓前 3 帧,用于人工核对形变落点
            if slimCapture < 3, beauty.slim > 0.5, faceOn {
                let marked = debugMark(ci, e: SIMD4<Float>(ex, ey, ez, ew),
                                       extent: extent)
                ciWrite(marked, ctx: ctx, name: "slim\(slimCapture).png")
                diag("slimCapture #\(slimCapture) jaw=(\(String(format: "%.2f", jawAnchor.x)),"
                     + "\(String(format: "%.2f", jawAnchor.y)),\(String(format: "%.2f", jawAnchor.z)),"
                     + "\(String(format: "%.2f", jawAnchor.w))) sl=\(String(format: "%.2f", beauty.slim))")
                slimCapture += 1
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
        audioDbg += 1
        if audioDbg == 1 || audioDbg % 200 == 0 {
            diag("audio #\(audioDbg) micSink=\(micSink == nil ? "nil" : "on") sent=\(micSent) fail=\(micConvFail) empty=\(micEmpty)")
        }
        // 1) 录制音轨(直接透传给 AVAssetWriter 由其编码 AAC)
        if recording, let w = writer, w.status == .writing,
           let aIn = writerAudio, aIn.isReadyForMoreMediaData,
           sessionStartTs != nil {
            aIn.append(sampleBuffer)
        }

        // 2) 本地语音识别:转 16kHz 单声道 int16
        if micSink == nil, audioDbg % 100 == 5 {
            diag("audio but micSink=nil (dart 未订阅?)")
        }
        guard let micSink = micSink,
              let desc = CMSampleBufferGetFormatDescription(sampleBuffer) else { return }
        do {
            if audioConverter == nil {
                let inFormat = AVAudioFormat(cmAudioFormatDescription: desc)
                // non-interleaved:int16ChannelData 属性仅对
                // 非交错格式提供指针,交错格式固定返回 nil(黑屏同款静默坑)
                let outFormat = AVAudioFormat(commonFormat: .pcmFormatInt16,
                                              sampleRate: 16000,
                                              channels: 1,
                                              interleaved: false)!
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
            // 不信任 status 枚举返回值(iOS 26 桥接层实测 status=1 时
            // Swift 的 == .haveData 仍判 false):只看缓冲区有没有数据
            let statusRaw = status.rawValue
            _ = status
            if out.frameLength > 0 {
                let abl = out.audioBufferList.pointee
                if abl.mNumberBuffers >= 1, let p = abl.mBuffers.mData,
                   abl.mBuffers.mDataByteSize > 0 {
                    let bytes = Data(bytes: p,
                                     count: Int(abl.mBuffers.mDataByteSize))
                    micSent += 1
                    if micSent == 1 || micSent % 200 == 0 {
                        diag("SENT #\(micSent) bytes=\(bytes.count)")
                    }
                    DispatchQueue.main.async {
                        micSink(bytes)
                    }
                } else {
                    micEmpty += 1
                    if micEmpty == 1 || micEmpty % 100 == 0 {
                        diag("NILBUF st=\(statusRaw) fl=\(out.frameLength) nb=\(abl.mNumberBuffers) #\(micEmpty)")
                    }
                }
            } else {
                micEmpty += 1
                if micEmpty == 1 || micEmpty % 100 == 0 {
                    diag("ZERO st=\(statusRaw) fl=\(out.frameLength) #\(micEmpty)")
                }
            }
        } catch {
            micConvFail += 1
            if micConvFail == 1 || micConvFail % 50 == 0 {
                diag("CONV FAIL #\(micConvFail): \(error)")
            }
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
