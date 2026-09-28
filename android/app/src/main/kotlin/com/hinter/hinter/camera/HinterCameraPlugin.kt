package com.hinter.hinter.camera

import android.content.ContentValues
import android.content.Context
import android.media.MediaScannerConnection
import android.os.Build
import android.os.Environment
import android.os.Handler
import android.os.Looper
import android.provider.MediaStore
import android.view.Surface
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.view.TextureRegistry
import java.io.File

/**
 * 美颜相机插件(方法通道 hinter/camera):
 * - start/stop/switchCamera:Camera2 + GL 美颜,预览走 Flutter Texture;
 * - setBeauty:磨皮/美白/红润/亮度/饱和度;
 * - startRecording/stopRecording:美颜画面 + 麦克风音轨合流为 MP4;
 * - EventChannel hinter/mic:16kHz 单声道 int16 PCM(供本地语音识别);
 * - EventChannel hinter/camera_events:异步错误事件。
 */
class HinterCameraPlugin : FlutterPlugin, MethodChannel.MethodCallHandler {

    companion object {
        /** 调试用:>=0 时强制预览旋转角(adb am start --ei debug_rot N) */
        @Volatile var debugRot: Int = -1
    }

    private var appContext: Context? = null
    private var textureRegistry: TextureRegistry? = null

    private val mainHandler = Handler(Looper.getMainLooper())
    private var renderer: BeautyRenderer? = null
    private var cameraEngine: CameraEngine? = null
    private var audio: AudioEngine? = null
    private var recorder: Recorder? = null

    private var micSink: EventChannel.EventSink? = null
    private var evtSink: EventChannel.EventSink? = null

    // 人脸跟踪(ML Kit FaceMesh):渲染器按 ~11fps 回读显示画布小探针图喂给检测
    private var faceTracker: FaceTrackerBase? = null
    private var faceRetryGen = 0L // 每次 stopAll 递增,使挂起的重试失效

    // ---- 画质档位状态 ----
    private var currentProbe: CameraEngine.CameraProbe? = null
    private var currentFront = true
    @Volatile private var currentShort = BeautyRenderer.QUALITY_TIERS[1] // 默认 1080

    /** 根据输出短边算竖屏输出尺寸(传感器比例决定,避免裁剪) */
    private fun pickOutput(probe: CameraEngine.CameraProbe, short: Int): Pair<Int, Int> {
        val size = CameraEngine.selectSize(probe.sizes, short)
        val longSide = maxOf(size.width, size.height)
        val ratio = longSide.toFloat() / minOf(size.width, size.height)
        var w = short
        var h = (short * ratio).toInt()
        if (h > BeautyRenderer.OUT_SHORT_CAP) {
            val k = h.toFloat() / BeautyRenderer.OUT_SHORT_CAP
            w = (short / k).toInt()
            h = BeautyRenderer.OUT_SHORT_CAP
        }
        w = w - w % 2
        h = h - h % 2
        return Pair(w.coerceAtLeast(2), h.coerceAtLeast(2))
    }

    /** 当前摄像头支持(长边够用)的档位列表 */
    private fun supportedTiers(probe: CameraEngine.CameraProbe): List<Int> =
        BeautyRenderer.QUALITY_TIERS.filter { t ->
            probe.sizes.any { maxOf(it.width, it.height) >= t }
        }

    /** 归一到该摄像头支持的最接近档位 */
    private fun normalizeShort(probe: CameraEngine.CameraProbe, short: Int): Int {
        val tiers = supportedTiers(probe)
        if (tiers.isEmpty()) return 720
        return tiers.minByOrNull { kotlin.math.abs(it - short) } ?: short
    }

    private fun modesResult(): Map<String, Any> {
        val probe = currentProbe
            ?: return mapOf(
                "modes" to listOf<Int>(),
                "current" to currentShort,
                "width" to (renderer?.renderWidth ?: 0).toLong(),
                "height" to (renderer?.renderHeight ?: 0).toLong(),
            )
        return mapOf(
            "modes" to supportedTiers(probe),
            "current" to currentShort,
            "width" to (renderer?.renderWidth ?: 0).toLong(),
            "height" to (renderer?.renderHeight ?: 0).toLong(),
        )
    }

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        appContext = binding.applicationContext
        textureRegistry = binding.textureRegistry

        MethodChannel(binding.binaryMessenger, "hinter/camera").setMethodCallHandler(this)

        EventChannel(binding.binaryMessenger, "hinter/mic").setStreamHandler(
            object : EventChannel.StreamHandler {
                override fun onListen(args: Any?, events: EventChannel.EventSink?) {
                    micSink = events
                }

                override fun onCancel(args: Any?) {
                    micSink = null
                }
            })

        EventChannel(binding.binaryMessenger, "hinter/camera_events").setStreamHandler(
            object : EventChannel.StreamHandler {
                override fun onListen(args: Any?, events: EventChannel.EventSink?) {
                    evtSink = events
                }

                override fun onCancel(args: Any?) {
                    evtSink = null
                }
            })
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        stopAll()
        appContext = null
        textureRegistry = null
    }

    private fun emitError(message: String) {
        mainHandler.post {
            evtSink?.success(mapOf("event" to "error", "message" to message))
        }
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "start" -> startCamera(call.argument<Boolean>("front") ?: true, result)
            "stop" -> {
                stopAll()
                result.success(null)
            }
            "setBeauty" -> {
                renderer?.setBeauty(
                    (call.argument<Number>("smooth")?.toDouble()) ?: 0.5,
                    (call.argument<Number>("whiten")?.toDouble()) ?: 0.3,
                    (call.argument<Number>("ruddy")?.toDouble()) ?: 0.25,
                    (call.argument<Number>("brightness")?.toDouble()) ?: 0.1,
                    (call.argument<Number>("saturation")?.toDouble()) ?: 0.5,
                    (call.argument<Number>("slim"))?.toDouble() ?: -1.0,
                )
                result.success(null)
            }
            "switchCamera" -> switchCamera(
                call.argument<Boolean>("front") ?: false, result)
            "getSupportedModes" -> result.success(modesResult())
            "setQualityMode" -> setQualityMode(
                call.argument<Number>("short")?.toInt() ?: currentShort, result)
            "startRecording" -> startRecording(
                call.argument<String>("path"), result)
            "stopRecording" -> stopRecording(result)
            "saveToGallery" -> saveToGallery(
                call.argument<String>("path"), result)
            else -> result.notImplemented()
        }
    }

    /**
     * 预览旋转角(shader 用,显示=顺时针 rotDeg)。
     * 这台设备(vivo/高通 HAL)的相机 buffer 已预旋转 90°:
     * 后摄 sensorRot=90 → 0 正确(实测);
     * 前摄镜像翻转使旋转方向相反 → sensorRot+90(270→0,实测修正 180°)。
     */
    private fun rotationFor(front: Boolean, sensorRot: Int): Int =
        if (front) (sensorRot + 90) % 360 else sensorRot - 90

    /**
     * 创建人脸跟踪器并挂到渲染器:优先用 FaceMeshTracker,失败时降级到 FaceTracker。
     * 检测输入是"合成后的显示画面"回读,坐标与屏幕一致。
     * 初始化失败时延迟重试(ML Kit 模型可能需要 unpack 时间)。
     */
    private fun attachFaceTracker(attempt: Int = 0, gen: Long = faceRetryGen) {
        val r = renderer ?: return
        if (gen != faceRetryGen) return
        stopFaceTracker()
        try {
            // 优先尝试 FaceMeshTracker
            faceTracker = FaceMeshTracker(mainHandler) { cx, cy, rx, ry, present, jawWidths ->
                r.setFace(cx, cy, rx, ry, present)
                r.setFaceFromTracker(present)
                r.setJawWidths(jawWidths)
            }
            r.faceTracker = faceTracker
            r.setFaceFallback(false)
            android.util.Log.i("HinterFace", "FaceMeshTracker attached (attempt=$attempt)")
        } catch (e: Exception) {
            android.util.Log.e("HinterFace", "FaceMeshTracker init failed (attempt=$attempt)", e)
            faceTracker = null
            r.faceTracker = null
            // FaceMeshTracker 失败,尝试 FaceTracker
            try {
                faceTracker = FaceTracker(mainHandler) { cx, cy, rx, ry, present, jawWidths ->
                    r.setFace(cx, cy, rx, ry, present)
                    r.setFaceFromTracker(present)
                    r.setJawWidths(jawWidths)
                }
                r.faceTracker = faceTracker
                r.setFaceFallback(false)
                android.util.Log.i("HinterFace", "FaceTracker fallback attached (attempt=$attempt)")
            } catch (e2: Exception) {
                android.util.Log.e("HinterFace", "FaceTracker init failed (attempt=$attempt)", e2)
                faceTracker = null
                r.faceTracker = null
                if (attempt < 5) {
                    val delayMs = 1000L * (attempt + 1)
                    android.util.Log.i("HinterFace", "retry in ${delayMs}ms")
                    mainHandler.postDelayed({ attachFaceTracker(attempt + 1, gen) }, delayMs)
                } else {
                    android.util.Log.w("HinterFace", "All retries failed, enabling fallback mode")
                    r.setFaceFallback(true)
                }
            }
        }
    }

    private fun stopFaceTracker() {
        try { faceTracker?.close() } catch (_: Exception) {}
        faceTracker = null
        renderer?.faceTracker = null
        renderer?.skinFaceEstimator = null
    }

    private fun startCamera(front: Boolean, result: MethodChannel.Result) {
        val ctx = appContext
        val registry = textureRegistry
        if (ctx == null || registry == null) {
            result.error("STATE", "引擎未就绪", null)
            return
        }
        try {
            stopAll()
            currentFront = front
            val entry = registry.createSurfaceTexture()
            val probe = CameraEngine.probe(ctx, front)
            currentProbe = probe
            currentShort = normalizeShort(probe, currentShort)
            val camSize = CameraEngine.selectSize(probe.sizes, currentShort)
            val (outW, outH) = pickOutput(probe, currentShort)
            val rot = if (debugRot >= 0) debugRot else rotationFor(front, probe.sensorOrientation)
            android.util.Log.i(
                "HinterCamera",
                "start front=$front camSize=$camSize out=${outW}x$outH " +
                    "sensorRot=${probe.sensorOrientation} rotDeg=$rot tiers=${supportedTiers(probe)}")

            val r = BeautyRenderer(entry)
            renderer = r
            r.onFail = { msg -> emitError(msg) }
            r.start(camSize.width, camSize.height, outW, outH, rot)
            r.onReady { st ->
                st.setDefaultBufferSize(camSize.width, camSize.height)
                val engine = CameraEngine(ctx)
                cameraEngine = engine
                engine.open(front, Surface(st), camSize,
                    extraSurface = null) { msg ->
                    emitError(msg)
                }
            }
            attachFaceTracker()

            val a = AudioEngine { bytes ->
                mainHandler.post { micSink?.success(bytes) }
            }
            audio = a
            try {
                a.start()
            } catch (e: Exception) {
                emitError("麦克风不可用: ${e.message}")
            }

            result.success(mapOf(
                "textureId" to r.textureId,
                "width" to outW.toLong(),
                "height" to outH.toLong(),
                "modes" to supportedTiers(probe),
                "current" to currentShort,
            ))
        } catch (e: Exception) {
            result.error("START", e.message, null)
        }
    }

    /** 切换画质档:重开相机到新的传感器尺寸 + 调整输出尺寸 */
    private fun setQualityMode(short: Int, result: MethodChannel.Result) {
        val ctx = appContext
        val r = renderer
        val probe = currentProbe
        if (ctx == null || r == null || probe == null) {
            result.error("STATE", "相机未启动", null)
            return
        }
        val tier = normalizeShort(probe, short)
        if (tier == currentShort) {
            result.success(modesResult())
            return
        }
        currentShort = tier
        val camSize = CameraEngine.selectSize(probe.sizes, tier)
        val (outW, outH) = pickOutput(probe, tier)
        r.setOutputSize(outW, outH)
        r.onReady { st ->
            st.setDefaultBufferSize(camSize.width, camSize.height)
            cameraEngine?.open(currentFront, Surface(st), camSize,
                extraSurface = null
            ) { msg -> emitError(msg) }
        }
        result.success(modesResult())
    }

    private fun switchCamera(front: Boolean, result: MethodChannel.Result) {
        val ctx = appContext
        val r = renderer
        if (ctx == null || r == null) {
            result.error("STATE", "相机未启动", null)
            return
        }
        currentFront = front
        val probe = CameraEngine.probe(ctx, front)
        currentProbe = probe
        // 新摄像头可能不支持当前档位,归一并同步输出尺寸
        currentShort = normalizeShort(probe, currentShort)
        val camSize = CameraEngine.selectSize(probe.sizes, currentShort)
        val (outW, outH) = pickOutput(probe, currentShort)
        val rot = if (debugRot >= 0) debugRot else rotationFor(front, probe.sensorOrientation)
        android.util.Log.i(
            "HinterCamera",
            "switch front=$front camSize=$camSize out=${outW}x$outH rotDeg=$rot")
        r.setOutputSize(outW, outH)
        r.setRotation(rot)
        r.onReady { st ->
            st.setDefaultBufferSize(camSize.width, camSize.height)
            cameraEngine?.switchCamera(front, Surface(st), camSize,
                extraSurface = null
            ) { msg -> emitError(msg) }
        }
        result.success(modesResult())
    }

    private fun startRecording(path: String?, result: MethodChannel.Result) {
        val r = renderer
        if (path == null || r == null) {
            result.error("STATE", "相机未启动", null)
            return
        }
        // 编码器初始化放后台线程,避免阻塞主线程
        Thread({
            val bitRate = when (currentShort) {
                720 -> 5_000_000
                1440 -> 16_000_000
                2160 -> 28_000_000
                else -> 10_000_000
            }
            val rec = Recorder(r.renderWidth, r.renderHeight, bitRate)
            try {
                rec.start(path)
            } catch (e: Exception) {
                mainHandler.post {
                    result.error("REC", "编码器启动失败: ${e.message}", null)
                }
                return@Thread
            }
            recorder = rec
            audio?.audioTap = { s, n -> rec.feedAudio(s, n) }
            r.attachRecordSurface(rec.recordSurface)
            mainHandler.post { result.success(null) }
        }, "hinter-rec-start").start()
    }

    private fun stopRecording(result: MethodChannel.Result) {
        val rec = recorder
        if (rec == null) {
            result.success(null)
            return
        }
        recorder = null
        audio?.audioTap = null
        renderer?.detachRecordSurface() // 同步等 GL 线程画完最后一帧并摘掉编码器
        Thread({
            try {
                val p = rec.stop()
                mainHandler.post { result.success(p) }
            } catch (e: Exception) {
                mainHandler.post { result.error("REC", e.message, null) }
            }
        }, "hinter-rec-stop").start()
    }

    /** 把录制好的视频写入系统相册(Movies/Hinter),图库App即可看到 */
    private fun saveToGallery(path: String?, result: MethodChannel.Result) {
        val ctx = appContext
        if (path == null || ctx == null) {
            result.error("SAVE", "参数缺失", null)
            return
        }
        Thread({
            try {
                val src = File(path)
                if (!src.exists()) throw IllegalStateException("视频文件不存在")
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                    val resolver = ctx.contentResolver
                    val values = ContentValues().apply {
                        put(MediaStore.Video.Media.DISPLAY_NAME, src.name)
                        put(MediaStore.Video.Media.MIME_TYPE, "video/mp4")
                        put(MediaStore.Video.Media.RELATIVE_PATH,
                            Environment.DIRECTORY_MOVIES + "/Hinter")
                        put(MediaStore.Video.Media.IS_PENDING, 1)
                    }
                    val uri = resolver.insert(
                        MediaStore.Video.Media.EXTERNAL_CONTENT_URI, values)
                        ?: throw IllegalStateException("无法写入系统媒体库")
                    resolver.openOutputStream(uri)?.use { out ->
                        src.inputStream().use { it.copyTo(out) }
                    } ?: throw IllegalStateException("写入媒体库失败")
                    values.clear()
                    values.put(MediaStore.Video.Media.IS_PENDING, 0)
                    resolver.update(uri, values, null, null)
                } else {
                    // Android 9 及以下:复制到公共 Movies 目录并触发媒体扫描
                    @Suppress("DEPRECATION")
                    val dir = File(
                        Environment.getExternalStoragePublicDirectory(
                            Environment.DIRECTORY_MOVIES), "Hinter")
                    dir.mkdirs()
                    val dest = File(dir, src.name)
                    src.copyTo(dest, overwrite = true)
                    MediaScannerConnection.scanFile(
                        ctx, arrayOf(dest.absolutePath),
                        arrayOf("video/mp4"), null)
                }
                mainHandler.post { result.success(true) }
            } catch (e: Exception) {
                mainHandler.post { result.error("SAVE", e.message, null) }
            }
        }, "hinter-gallery").start()
    }

    private fun stopAll() {
        faceRetryGen++ // 使挂起的 FaceTracker 重试失效
        val rec = recorder
        recorder = null
        audio?.audioTap = null
        // 先摘跟踪器(渲染器回读探针依赖它),再走原有停相机/释放顺序
        stopFaceTracker()
        val r = renderer
        if (rec != null) {
            // 先让 GL 线程摘掉编码器 Surface(同步等待),再停录制器,
            // 避免编码器释放 Surface 后 GL 仍往上面画导致 native 崩溃
            r?.detachRecordSurface()
            Thread({ rec.stop() }, "hinter-rec-stop").start()
        }
        try { audio?.stop() } catch (_: Exception) {}
        audio = null
        try { cameraEngine?.close() } catch (_: Exception) {}
        cameraEngine = null
        renderer = null
        try { r?.release() } catch (_: Exception) {}
    }
}
