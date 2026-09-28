package com.hinter.hinter.camera

import android.graphics.Bitmap

/**
 * 人脸追踪器通用接口。
 * FaceTracker 和 FaceMeshTracker 都实现此接口,方便切换和降级。
 */
interface FaceTrackerBase {
    fun process(src: Bitmap)
    fun close()
}
