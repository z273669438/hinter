package com.hinter.hinter.camera

import android.graphics.Bitmap

/**
 * 轻量人脸定位:在探针图上做肤色聚类 + 中心加权,估算人脸椭圆。
 * 不依赖任何外部库,纯 Kotlin + Bitmap.getPixel()。
 * 256px 探针图上约 1ms/帧,作为 ML Kit 失败时的降级方案。
 *
 * 注意:探针图来自 glReadPixels,行序是 GL 约定(底边朝上):
 *   bitmap y=0 → 显示空间 v=0(画面底部)
 *   bitmap y=h → 显示空间 v=1(画面顶部)
 * 所有输出坐标都转换到显示空间(v 轴向上,与 shader 一致)。
 */
class SkinFaceEstimator(
    private val onResult: (cx: Float, cy: Float, rx: Float, ry: Float, present: Boolean) -> Unit,
) {
    companion object {
        private const val GRID = 10
        private const val STEP = 4
    }

    private var sx = 0.5f
    private var sy = 0.55f
    private var srx = 0.25f
    private var sry = 0.32f
    private var present = false
    private var lastLogAt = 0L

    fun process(src: Bitmap) {
        val w = src.width
        val h = src.height
        val cellW = w / GRID
        val cellH = h / GRID

        // 每个网格单元的肤色像素统计(坐标存显示空间)
        val counts = IntArray(GRID * GRID)
        val sumX = FloatArray(GRID * GRID)
        val sumY = FloatArray(GRID * GRID)

        var totalSkin = 0
        var weightedCx = 0f
        var weightedCy = 0f
        var totalWeight = 0f
        // 肤色像素的水平边界(检测脸是否贴边)
        var minU = 1f
        var maxU = 0f

        var by = 0
        while (by < h) {
            // glReadPixels 底边朝上:bitmap 行 by → 显示空间 v = 1 - by/h
            val v = 1f - by.toFloat() / h
            var bx = 0
            while (bx < w) {
                val p = src.getPixel(bx, by)
                val r = ((p shr 16) and 0xFF) / 255f
                val g = ((p shr 8) and 0xFF) / 255f
                val b = (p and 0xFF) / 255f

                val cb = -0.168736f * r - 0.331264f * g + 0.5f * b
                val cr = 0.5f * r - 0.418688f * g - 0.081312f * b

                val isSkin = cb in -0.20f..-0.03f && cr in 0.05f..0.27f
                if (isSkin) {
                    val u = bx.toFloat() / w
                    // 更新肤色水平边界
                    if (u < minU) minU = u
                    if (u > maxU) maxU = u
                    val gx = (bx / cellW).coerceAtMost(GRID - 1)
                    // 网格 y:bitmap 行 by 对应的显示 v 行
                    val gy = ((1f - v) * GRID).toInt().coerceIn(0, GRID - 1)
                    val idx = gy * GRID + gx
                    counts[idx]++
                    sumX[idx] += u
                    sumY[idx] += v

                    // 中心加权:自拍/提词场景脸在画面中上部
                    val dx = u - 0.5f
                    val dy = v - 0.58f
                    val dist = kotlin.math.sqrt(dx * dx + dy * dy)
                    val weight = 1f / (1f + dist * 4f)

                    weightedCx += u * weight
                    weightedCy += v * weight
                    totalWeight += weight
                    totalSkin++
                }
                bx += STEP
            }
            by += STEP
        }

        if (totalSkin < 50) {
            if (System.currentTimeMillis() - lastLogAt > 2000) {
                lastLogAt = System.currentTimeMillis()
                android.util.Log.i("HinterSkin", "totalSkin=$totalSkin < 50, no face")
            }
            decay()
            return
        }

        // 找肤色最密集的网格簇(带中心加权)
        var bestIdx = -1
        var bestScore = 0f
        for (i in 0 until GRID * GRID) {
            if (counts[i] < 3) continue
            val cx = sumX[i] / counts[i]
            val cy = sumY[i] / counts[i]
            val dx = cx - 0.5f
            val dy = cy - 0.58f
            val dist = kotlin.math.sqrt(dx * dx + dy * dy)
            val centerBias = 1f / (1f + dist * 3f)
            val score = counts[i] * centerBias
            if (score > bestScore) {
                bestScore = score
                bestIdx = i
            }
        }

        val faceCx: Float
        val faceCy: Float
        if (bestIdx < 0) {
            faceCx = weightedCx / totalWeight
            faceCy = weightedCy / totalWeight
        } else {
            faceCx = sumX[bestIdx] / counts[bestIdx]
            faceCy = sumY[bestIdx] / counts[bestIdx]
        }

        // 估算人脸半径:基于肤色像素的分布范围
        // 肤色主要集中在脸颊/鼻子,额头肤色少,所以垂直半径要放大(2.8)才能覆盖全脸
        var varX = 0f
        var varY = 0f
        var n = 0
        for (i in 0 until GRID * GRID) {
            if (counts[i] < 2) continue
            val cx = sumX[i] / counts[i]
            val cy = sumY[i] / counts[i]
            val dx = cx - faceCx
            val dy = cy - faceCy
            varX += dx * dx * counts[i]
            varY += dy * dy * counts[i]
            n += counts[i]
        }
        var rx = if (n > 0) kotlin.math.sqrt(varX / n) * 2.4f else 0.25f
        var ry = if (n > 0) kotlin.math.sqrt(varY / n) * 2.8f else 0.35f
        rx = rx.coerceIn(0.18f, 0.42f)
        ry = ry.coerceIn(0.25f, 0.55f)

        // 边缘补偿:肤色到达屏幕左右边缘时,说明脸的一部分在屏幕外
        // 需要把脸椭圆向边缘方向延伸,并增大水平半径
        // 但补偿要克制,避免把背景包进来导致变形
        var edgeOffsetX = 0f
        val edgeThreshold = 0.10f  // 只有肤色到达 10% 以内才补偿
        val maxEdgeCompensation = 0.08f  // 最大补偿量限制

        if (minU < edgeThreshold && totalSkin > 200) {
            // 左边缘贴边且有足够肤色:脸中心左移,半径增大
            val compensation = ((edgeThreshold - minU) * 1.5f).coerceAtMost(maxEdgeCompensation)
            edgeOffsetX = -compensation
            rx += compensation * 0.8f
        }
        if (maxU > (1f - edgeThreshold) && totalSkin > 200) {
            // 右边缘贴边且有足够肤色:脸中心右移,半径增大
            val compensation = ((maxU - (1f - edgeThreshold)) * 1.5f).coerceAtMost(maxEdgeCompensation)
            edgeOffsetX += compensation
            rx += compensation * 0.8f
        }
        rx = rx.coerceAtMost(0.50f) // 限制最大半径,避免覆盖太多背景

        val adjustedCx = (faceCx + edgeOffsetX).coerceIn(0.05f, 0.95f)
        // 中心稍微上移:肤色中心在脸颊,但脸椭圆中心应该在额头和下巴中间
        val adjustedCy = (faceCy + 0.03f).coerceAtMost(0.85f)

        // 平滑:降低系数让跟踪更平滑(避免光圈摊开效果)
        sx += (adjustedCx - sx) * 0.40f
        sy += (adjustedCy - sy) * 0.40f
        // 半径渐入:刚检测到脸时用更慢的系数,避免光圈摊开
        val radiusSmooth = if (!present) 0.15f else 0.35f
        srx += (rx - srx) * radiusSmooth
        sry += (ry - sry) * radiusSmooth
        present = true
        if (System.currentTimeMillis() - lastLogAt > 2000) {
            lastLogAt = System.currentTimeMillis()
            android.util.Log.i("HinterSkin",
                "raw=(${ "%.2f".format(faceCx)},${"%.2f".format(faceCy)}) " +
                    "adj=(${ "%.2f".format(adjustedCx)},${"%.2f".format(adjustedCy)}) " +
                    "smooth=(${ "%.2f".format(sx)},${"%.2f".format(sy)}) " +
                    "r=(${ "%.2f".format(srx)},${"%.2f".format(sry)}) " +
                    "uRange=[${"%.2f".format(minU)},${"%.2f".format(maxU)}] " +
                    "skin=$totalSkin")
        }
        onResult(sx, sy, srx, sry, true)
    }

    private fun decay() {
        if (present) {
            srx *= 0.7f
            sry *= 0.7f
            present = srx > 0.05f
            onResult(sx, sy, srx, sry, present)
        }
    }
}
