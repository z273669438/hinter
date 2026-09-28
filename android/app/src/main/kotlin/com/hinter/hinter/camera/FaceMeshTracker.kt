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
 * 提取下颌线轮廓点,输出精确的脸部形状。
 * 输出 (cx, cy, rx, ry) 为显示空间归一化坐标,v 轴与 GL 一致(自下向上)。
 * 额外输出下颌线宽度轮廓(jawWidths)用于精确瘦脸。
 */
class FaceMeshTracker(
    private val handler: Handler,
    private val onResult: (cx: Float, cy: Float, rx: Float, ry: Float, present: Boolean, jawWidths: FloatArray) -> Unit,
) : FaceTrackerBase {
    private val detector: FaceMeshDetector? = try {
        // 尝试初始化 FaceMesh,失败则回退到普通人脸检测
        FaceMeshDetection.getClient(
            FaceMeshDetectorOptions.Builder().build()
        ).also { android.util.Log.i("HinterFaceMesh", "Detector initialized OK") }
    } catch (e: Exception) {
        android.util.Log.e("HinterFaceMesh", "Detector init failed: ${e.message}")
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

    // 下颌线轮廓:左脸颊和右脸颊在不同高度的宽度
    // 索引 0=下巴, 1=下颌, 2=脸颊, 3=颧骨
    private val jawWidths = FloatArray(4) { 0.15f }  // 默认宽度

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

        // 从 468 个点中提取下颌线轮廓
        val points = faceMesh.allPoints
        if (points.isEmpty()) { decay(); return }

        // ML Kit FaceMesh 点索引(TRIANGLES 常量):
        // 下颌线左侧: 0, 1, 2, ..., 16 (下巴到左耳)
        // 下颌线右侧: 16, 17, ..., 32 (下巴到右耳)
        // 脸部轮廓: 200-232 区域
        
        // 提取关键点(归一化坐标,v 轴翻转)
        val getPoint = { idx: Int ->
            if (idx < points.size) {
                val p = points[idx]
                val px = p.position.x / w
                val py = 1f - p.position.y / h  // 翻转 v 轴
                Pair(px, py)
            } else null
        }

        // 用边界框作为基础
        val minx = box.left.toFloat() / w
        val maxx = box.right.toFloat() / w
        val miny = box.top.toFloat() / h
        val maxy = box.bottom.toFloat() / h
        val cx = (minx + maxx) / 2f
        val cy = 1f - (miny + maxy) / 2f
        // 椭圆贴合真实脸部轮廓
        val rx = (maxx - minx) / 2f * 0.96f
        val ry = (maxy - miny) / 2f * 1.02f

        // ---- 脸宽纵向轮廓:FaceMesh 标准轮廓点 ----
        // (此前用 2/5/8/24/27 是眉眼区域索引,宽度全错 → 形变带落在太阳穴成竖条)
        // 152=下巴底,172/397=左右下颌角,234/454=左右脸颊最宽点,66/296=左右额角
        val bw = maxx - minx
        fun span(a: Pair<Float, Float>?, b: Pair<Float, Float>?, def: Float): Float =
            if (a != null && b != null) {
                kotlin.math.abs(a.first - b.first).coerceIn(bw * 0.2f, bw * 1.15f)
            } else def
        val chinW = bw * 0.34f
        val jawW = span(getPoint(397), getPoint(172), bw * 0.62f)
        val cheekW = span(getPoint(234), getPoint(454), bw * 0.96f)
        val templeW = span(getPoint(296), getPoint(66), cheekW * 0.92f)

        run {
            // 更新脸宽轮廓(平滑) - 全部存全宽,shader 里统一除 2
            // 索引对应 shader 的 h:0=下巴 → 0.33=下颌 → 0.66=脸颊 → 1.0=额角
            val smooth = 0.5f
            jawWidths[0] += (chinW - jawWidths[0]) * smooth
            jawWidths[1] += (jawW - jawWidths[1]) * smooth
            jawWidths[2] += (cheekW - jawWidths[2]) * smooth
            jawWidths[3] += (templeW - jawWidths[3]) * smooth
        }

        if (now - hitLogAt > 1000) {
            hitLogAt = now
            android.util.Log.i(
                "HinterFaceMesh",
                "mesh points=${points.size} box=${box.width()}x${box.height()} " +
                    "-> cx=${"%.2f".format(cx)} cy=${"%.2f".format(cy)} " +
                    "jaw=[${jawWidths.joinToString { "%.3f".format(it) }}]")
        }
        lastFaceAt = now
        // 速度外推(1.2 帧超前)已移除:识别抖动被放大成超前冲刺,
        // 表现为高亮"越读越快往前蹿"。改为纯平滑跟随。
        val k = 0.60f
        sx += (cx - sx) * k
        sy += (cy - sy) * k
        val radiusSmooth = if (!present) 0.15f else 0.35f
        srx += (rx - srx) * radiusSmooth
        sry += (ry - sry) * radiusSmooth
        present = true
        onResult(sx, sy, srx, sry, true, jawWidths.copyOf())
    }

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
        try { detector?.close() } catch (_: Exception) {}
        try { flipBmp?.recycle() } catch (_: Exception) {}
        flipBmp = null
    }
}
