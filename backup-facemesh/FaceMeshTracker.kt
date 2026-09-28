package com.hinter.hinter.camera

import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Matrix
import android.os.Handler
import com.google.mlkit.vision.common.InputImage
import com.google.mlkit.vision.facemesh.FaceMesh
import com.google.mlkit.vision.facemesh.FaceMeshDetection
import com.google.mlkit.vision.facemesh.FaceMeshDetector
import com.google.mlkit.vision.facemesh.FaceMeshDetectorOptions

/**
 * 人脸跟踪:使用 ML Kit FaceMesh(468 关键点)做精确面部追踪。
 * 输出 (cx, cy, rx, ry) 为显示空间归一化坐标,v 轴与 GL 一致(自下向上)。
 * 带完善的错误处理和降级逻辑,避免崩溃。
 */
class FaceMeshTracker(
    private val handler: Handler,
    private val onResult: (cx: Float, cy: Float, rx: Float, ry: Float, present: Boolean) -> Unit,
) : FaceTrackerBase {
    private val detector: FaceMeshDetector? = try {
        FaceMeshDetection.getClient(
            FaceMeshDetectorOptions.Builder()
                .build()
        )
    } catch (e: Exception) {
        android.util.Log.e("HinterFaceMesh", "Detector init failed", e)
        null
    }

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

    // 速度外推状态
    private var lastAt = 0L
    private var lcx = 0.5f
    private var lcy = 0.5f
    private var vxE = 0f
    private var vyE = 0f

    private var missLogAt = 0L
    private var hitLogAt = 0L
    private var errorCount = 0

    override fun process(src: Bitmap) {
        if (closed || busy || detector == null) return
        val now = System.currentTimeMillis()
        if (now - lastDetect < 90) return  // FaceMesh 较慢,降低检测频率
        lastDetect = now
        busy = true
        handler.post {
            if (closed || detector == null) { busy = false; return@post }
            try {
                val w = src.width
                val h = src.height
                var fb = flipBmp
                if (fb == null || fb.width != w || fb.height != h) {
                    fb = Bitmap.createBitmap(w, h, Bitmap.Config.ARGB_8888)
                    flipBmp = fb
                    flipMat = null
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
                    .addOnSuccessListener { faceMeshes ->
                        if (closed) return@addOnSuccessListener
                        errorCount = 0
                        val best = faceMeshes?.maxByOrNull {
                            it.boundingBox.width().toLong() *
                                it.boundingBox.height().toLong()
                        }
                        if (best == null) {
                            if (now - missLogAt > 2000) {
                                missLogAt = now
                                android.util.Log.i("HinterFaceMesh", "no face")
                            }
                            decay()
                        } else {
                            applyFaceMesh(best, w, h, now)
                        }
                    }
                    .addOnFailureListener { e ->
                        errorCount++
                        android.util.Log.e("HinterFaceMesh", "Detection failed (count=$errorCount)", e)
                        if (errorCount > 5) {
                            android.util.Log.e("HinterFaceMesh", "Too many errors, disabling")
                            detector.close()
                        }
                    }
                    .addOnCompleteListener { busy = false }
            } catch (e: Exception) {
                busy = false
                errorCount++
                android.util.Log.e("HinterFaceMesh", "process failed (count=$errorCount)", e)
                if (errorCount > 5) {
                    android.util.Log.e("HinterFaceMesh", "Too many errors, disabling")
                    try { detector.close() } catch (_: Exception) {}
                }
            }
        }
    }

    private fun applyFaceMesh(faceMesh: FaceMesh, w: Int, h: Int, now: Long) {
        val box = faceMesh.boundingBox
        if (box.width() <= 0 || box.height() <= 0) { decay(); return }

        // 从 468 个点中提取下颌线轮廓(更精确的脸部形状)
        // ML Kit FaceMesh 的点索引:下颌线大约是 0-32 和 200-232
        val points = faceMesh.allPoints
        if (points.isEmpty()) { decay(); return }

        // 用边界框作为基础(简单可靠)
        val minx = box.left.toFloat() / w
        val maxx = box.right.toFloat() / w
        val miny = box.top.toFloat() / h
        val maxy = box.bottom.toFloat() / h
        val cx = (minx + maxx) / 2f
        val cy = 1f - (miny + maxy) / 2f
        val rx = (maxx - minx) / 2f * 1.10f
        val ry = (maxy - miny) / 2f * 1.18f

        if (now - hitLogAt > 1000) {
            hitLogAt = now
            android.util.Log.i(
                "HinterFaceMesh",
                "mesh points=${points.size} box=${box.width()}x${box.height()} " +
                    "-> cx=${"%.2f".format(cx)} cy=${"%.2f".format(cy)} " +
                    "rx=${"%.2f".format(rx)} ry=${"%.2f".format(ry)}")
        }
        lastFaceAt = now
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
        // 半径渐入:刚检测到脸时用更慢的系数,避免光圈摊开
        val radiusSmooth = if (!present) 0.15f else 0.35f
        srx += (rx - srx) * radiusSmooth
        sry += (ry - sry) * radiusSmooth
        present = true
        onResult(sx, sy, srx, sry, true)
    }

    private fun decay() {
        vxE *= 0.5f
        vyE *= 0.5f
        if (System.currentTimeMillis() - lastFaceAt > 400) {
            srx *= 0.6f
            sry *= 0.6f
            present = srx > 0.02f
        }
        onResult(sx, sy, srx, sry, present)
    }

    override fun close() {
        closed = true
        try { detector?.close() } catch (_: Exception) {}
        try { flipBmp?.recycle() } catch (_: Exception) {}
        flipBmp = null
    }
}
