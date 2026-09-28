package com.hinter.hinter.camera

import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Matrix
import android.os.Handler
import com.google.mlkit.vision.common.InputImage
import com.google.mlkit.vision.face.Face
import com.google.mlkit.vision.face.FaceDetection
import com.google.mlkit.vision.face.FaceDetector
import com.google.mlkit.vision.face.FaceDetectorOptions

/**
 * 人脸跟踪:使用普通人脸检测(比 FaceMesh 更稳定)。
 * 直接消费"合成后的显示画面"回读的小探针图。
 * 检测坐标系与显示坐标系天然一致(只隔一次上下翻转)。
 * 输出 (cx, cy, rx, ry) 为显示空间归一化坐标,v 轴与 GL 一致(自下向上)。
 */
class FaceTracker(
    private val handler: Handler,
    private val onResult: (cx: Float, cy: Float, rx: Float, ry: Float, present: Boolean, jawWidths: FloatArray) -> Unit,
) : FaceTrackerBase {
    private val detector: FaceDetector = FaceDetection.getClient(
        FaceDetectorOptions.Builder()
            .setPerformanceMode(FaceDetectorOptions.PERFORMANCE_MODE_FAST)
            .setLandmarkMode(FaceDetectorOptions.LANDMARK_MODE_NONE)
            .setClassificationMode(FaceDetectorOptions.CLASSIFICATION_MODE_NONE)
            .build()
    )

    @Volatile private var busy = false
    @Volatile private var closed = false
    @Volatile private var lastDetect = 0L

    private var flipMat: Matrix? = null
    private var flipBmp: Bitmap? = null

    // 平滑后的椭圆(显示空间)
    private var sx = 0.5f
    private var sy = 0.5f
    private var srx = 0f
    private var sry = 0f
    private var present = false
    private var lastFaceAt = 0L

    // 速度外推状态(归一化坐标/16ms)
    private var lastAt = 0L
    private var lcx = 0.5f
    private var lcy = 0.5f
    private var vxE = 0f
    private var vyE = 0f

    private var missLogAt = 0L
    private var hitLogAt = 0L

    // 下颌线宽度轮廓(从边界框估算):索引 0=下巴, 1=下颌, 2=脸颊, 3=颧骨
    private val jawWidths = FloatArray(4) { 0.15f }

    /** 从 @param src(GL 回读,底边朝上)发起一次检测;内部限流并防重入 */
    override fun process(src: Bitmap) {
        if (closed || busy) return
        val now = System.currentTimeMillis()
        if (now - lastDetect < 55) return
        lastDetect = now
        busy = true
        handler.post {
            if (closed) { busy = false; return@post }
            try {
                val w = src.width
                val h = src.height
                var fb = flipBmp
                if (fb == null || fb.width != w || fb.height != h) {
                    fb = Bitmap.createBitmap(w, h, Bitmap.Config.ARGB_8888)
                    flipBmp = fb
                    flipMat = null // 翻转平移量与高度绑定,尺寸变了要重建
                }
                val mat = flipMat ?: Matrix().apply {
                    preScale(1f, -1f, 0f, 0f)
                    postTranslate(0f, h.toFloat())
                }.also { flipMat = it }
                Canvas(fb).apply {
                    drawColor(0xFF000000.toInt())
                    drawBitmap(src, mat, null)
                }
                detector.process(InputImage.fromBitmap(fb, 0))
                    .addOnSuccessListener { faces ->
                        if (closed) return@addOnSuccessListener
                        val best = faces?.maxByOrNull {
                            it.boundingBox.width().toLong() *
                                it.boundingBox.height().toLong()
                        }
                        if (best == null) {
                            if (now - missLogAt > 2000) {
                                missLogAt = now
                                android.util.Log.i("HinterFace", "no face rot=0")
                            }
                            decay()
                        } else {
                            applyMesh(best, w, h, now)
                        }
                    }
                    .addOnCompleteListener { busy = false }
            } catch (e: Exception) {
                busy = false
                android.util.Log.e("HinterFace", "process failed", e)
            }
        }
    }

    private fun applyMesh(face: Face, w: Int, h: Int, now: Long) {
        val box = face.boundingBox
        if (box.width() <= 0 || box.height() <= 0) { decay(); return }
        val minx = box.left.toFloat() / w
        val maxx = box.right.toFloat() / w
        val miny = box.top.toFloat() / h
        val maxy = box.bottom.toFloat() / h
        val cx = (minx + maxx) / 2f
        // 翻转图 y 顶向下 → 显示 v 底向上
        val cy = 1f - (miny + maxy) / 2f
        val rx = (maxx - minx) / 2f * 0.96f
        val ry = (maxy - miny) / 2f * 1.02f

        // 从边界框估算下颌线宽度轮廓(全宽,shader 里会除 2)
        val faceWidth = (maxx - minx).coerceIn(0.15f, 0.50f)
        val chinWidth = faceWidth * 0.55f
        val jawWidth = faceWidth * 0.75f
        val cheekWidth = faceWidth * 0.90f
        val smooth = 0.5f
        jawWidths[0] += (chinWidth - jawWidths[0]) * smooth
        jawWidths[1] += (jawWidth - jawWidths[1]) * smooth
        jawWidths[2] += (cheekWidth - jawWidths[2]) * smooth
        jawWidths[3] += (faceWidth - jawWidths[3]) * smooth

        if (now - hitLogAt > 1000) {
            hitLogAt = now
            android.util.Log.i(
                "HinterFace",
                "box=${box.width()}x${box.height()} " +
                    "-> cx=${"%.2f".format(cx)} cy=${"%.2f".format(cy)} " +
                    "rx=${"%.2f".format(rx)} ry=${"%.2f".format(ry)}")
        }
        lastFaceAt = now
        // 速度外推:掩码朝运动方向提前 ~1.2 个检测周期,抵消管线滞后(减少过冲闪烁)
        val dt = (now - lastAt).coerceIn(1L, 300L).toFloat()
        lastAt = now
        val ivx = (cx - lcx) / dt * 16f
        val ivy = (cy - lcy) / dt * 16f
        vxE += (ivx - vxE) * 0.30f
        vyE += (ivy - vyE) * 0.30f
        lcx = cx; lcy = cy
        val pcx = (cx + vxE * 1.2f).coerceIn(0.05f, 0.95f)
        val pcy = (cy + vyE * 1.2f).coerceIn(0.05f, 0.95f)

        val k = 0.60f
        sx += (pcx - sx) * k
        sy += (pcy - sy) * k
        srx += (rx - srx) * 0.35f
        sry += (ry - sry) * 0.35f
        present = true
        onResult(sx, sy, srx, sry, true, jawWidths.copyOf())
    }

    /** 短时间检不到:收缩椭圆并淡出(显示空间与检测一致,不会再"遗留在背景上") */
    private fun decay() {
        vxE *= 0.5f
        vyE *= 0.5f
        if (System.currentTimeMillis() - lastFaceAt > 400) {
            srx *= 0.6f
            sry *= 0.6f
            present = srx > 0.02f
        }
        onResult(sx, sy, srx, sry, present, jawWidths.copyOf())
    }

    override fun close() {
        closed = true
        try { detector.close() } catch (_: Exception) {}
        try { flipBmp?.recycle() } catch (_: Exception) {}
        flipBmp = null
    }
}
