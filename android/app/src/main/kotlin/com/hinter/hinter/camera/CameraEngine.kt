package com.hinter.hinter.camera

import android.annotation.SuppressLint
import android.content.Context
import android.graphics.ImageFormat
import android.graphics.SurfaceTexture
import android.hardware.camera2.CameraCaptureSession
import android.hardware.camera2.CameraCharacteristics
import android.hardware.camera2.CameraDevice
import android.hardware.camera2.CameraManager
import android.hardware.camera2.CameraMetadata
import android.hardware.camera2.CaptureRequest
import android.os.Handler
import android.os.HandlerThread
import android.util.Size
import android.view.Surface

/**
 * Camera2 封装:打开前/后摄,把预览帧写入 native 自己的 SurfaceTexture
 * (交给 GL 线程做美颜处理),与 Flutter 预览纹理解耦。
 */
class CameraEngine(private val context: Context) {

    /** 相机探测结果:支持的输出尺寸列表 + 传感器旋转角 */
    data class CameraProbe(
        val sizes: List<Size>,      // SurfaceTexture 预览尺寸,降序
        val yuvSizes: List<Size>,   // YUV_420_888 分析流尺寸,降序
        val sensorOrientation: Int,
    )

    private val camThread = HandlerThread("hinter-cam").apply { start() }
    private val camHandler = Handler(camThread.looper)

    private var camera: CameraDevice? = null
    private var session: CameraCaptureSession? = null

    companion object {
        private const val ASPECT_16_9 = 16f / 9f

        private fun isWide(s: Size): Boolean {
            val long = maxOf(s.width, s.height)
            val short = minOf(s.width, s.height)
            return kotlin.math.abs(long.toFloat() / short - ASPECT_16_9) < 0.25f
        }

        /** 为输出短边(竖屏,如 1080)挑选传感器横屏 buffer:
         *  优先 16:9 模式(无变形),其次任意比例,面积取"够用的最小值" */
        fun selectSize(sizes: List<Size>, targetShort: Int): Size {
            val wide = sizes.filter { isWide(it) }
            wide.filter { minOf(it.width, it.height) >= targetShort }
                .minByOrNull { it.width.toLong() * it.height }
                ?.let { return it }
            wide.filter { maxOf(it.width, it.height) >= targetShort }
                .minByOrNull { it.width.toLong() * it.height }
                ?.let { return it }
            sizes.filter { minOf(it.width, it.height) >= targetShort }
                .minByOrNull { it.width.toLong() * it.height }
                ?.let { return it }
            sizes.filter { maxOf(it.width, it.height) >= targetShort }
                .minByOrNull { it.width.toLong() * it.height }
                ?.let { return it }
            sizes.maxByOrNull { it.width.toLong() * it.height }?.let { return it }
            return Size(1280, 720)
        }

        private fun findCameraId(context: Context, front: Boolean): String? {
            val mgr = context.getSystemService(Context.CAMERA_SERVICE) as CameraManager
            val want = if (front) CameraCharacteristics.LENS_FACING_FRONT
            else CameraCharacteristics.LENS_FACING_BACK
            for (id in mgr.cameraIdList) {
                val facing = mgr.getCameraCharacteristics(id)
                    .get(CameraCharacteristics.LENS_FACING)
                if (facing == want) return id
            }
            return mgr.cameraIdList.firstOrNull()
        }

        /**
         * 不打开相机即可拿到的探测信息:
         * 支持的 SurfaceTexture 输出尺寸(降序)+ 传感器旋转角。
         */
        fun probe(context: Context, front: Boolean): CameraProbe {
            val fallback = CameraProbe(
                listOf(Size(1280, 720)), listOf(Size(640, 480)), 90)
            return try {
                val mgr = context.getSystemService(Context.CAMERA_SERVICE) as CameraManager
                val id = findCameraId(context, front) ?: return fallback
                val chars = mgr.getCameraCharacteristics(id)
                val map = chars.get(CameraCharacteristics.SCALER_STREAM_CONFIGURATION_MAP)
                val sizes = (map?.getOutputSizes(SurfaceTexture::class.java)
                    ?: arrayOf(Size(1280, 720))).toList()
                    .sortedByDescending { it.width.toLong() * it.height }
                val yuvSizes = (map?.getOutputSizes(ImageFormat.YUV_420_888)
                    ?: arrayOf(Size(640, 480))).toList()
                    .sortedByDescending { it.width.toLong() * it.height }
                val orientation = chars.get(CameraCharacteristics.SENSOR_ORIENTATION) ?: 90
                CameraProbe(sizes, yuvSizes, orientation)
            } catch (_: Exception) {
                fallback
            }
        }
    }

    @SuppressLint("MissingPermission")
    fun open(front: Boolean, surface: Surface, size: Size,
             extraSurface: Surface? = null,
             onError: ((String) -> Unit)? = null) {
        val targets = listOfNotNull(surface, extraSurface)
        camHandler.post {
            try {
                closeLocked()
                val mgr = context.getSystemService(Context.CAMERA_SERVICE) as CameraManager
                val id = findCameraId(context, front)
                    ?: throw IllegalStateException("没有可用摄像头")
                mgr.openCamera(id, object : CameraDevice.StateCallback() {
                    override fun onOpened(cam: CameraDevice) {
                        camera = cam
                        try {
                            cam.createCaptureSession(
                                targets,
                                object : CameraCaptureSession.StateCallback() {
                                    override fun onConfigured(s: CameraCaptureSession) {
                                        session = s
                                        startRepeatingLocked(targets)
                                    }

                                    override fun onConfigureFailed(s: CameraCaptureSession) {
                                        onError?.invoke("相机会话配置失败")
                                    }
                                },
                                camHandler
                            )
                        } catch (e: Exception) {
                            onError?.invoke("创建相机会话失败: ${e.message}")
                        }
                    }

                    override fun onDisconnected(cam: CameraDevice) {
                        cam.close()
                    }

                    override fun onError(cam: CameraDevice, error: Int) {
                        cam.close()
                        onError?.invoke("相机打开失败 (code=$error)")
                    }
                }, camHandler)
            } catch (e: Exception) {
                onError?.invoke("相机启动失败: ${e.message}")
            }
        }
    }

    private fun startRepeatingLocked(targets: List<Surface>) {
        val cam = camera ?: return
        val builder = cam.createCaptureRequest(CameraDevice.TEMPLATE_PREVIEW)
        for (t in targets) builder.addTarget(t)
        builder.set(CaptureRequest.CONTROL_MODE, CameraMetadata.CONTROL_MODE_AUTO)
        builder.set(
            CaptureRequest.CONTROL_AF_MODE,
            CaptureRequest.CONTROL_AF_MODE_CONTINUOUS_VIDEO
        )
        session?.setRepeatingRequest(builder.build(), null, camHandler)
        android.util.Log.i("HinterCamera", "repeating request started, ${targets.size} targets")
    }

    fun switchCamera(front: Boolean, surface: Surface, size: Size,
                     extraSurface: Surface? = null,
                     onError: ((String) -> Unit)? = null) {
        open(front, surface, size, extraSurface, onError)
    }

    private fun closeLocked() {
        try { session?.close() } catch (_: Exception) {}
        try { camera?.close() } catch (_: Exception) {}
        session = null
        camera = null
    }

    fun close() {
        camHandler.post { closeLocked() }
        camThread.quitSafely()
    }
}
