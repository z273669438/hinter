package com.hinter.hinter.camera

import android.graphics.SurfaceTexture
import android.opengl.EGL14
import android.opengl.EGLConfig
import android.opengl.EGLContext
import android.opengl.EGLDisplay
import android.opengl.EGLExt
import android.opengl.EGLSurface
import android.opengl.GLES11Ext
import android.opengl.GLES20
import android.os.Handler
import android.os.HandlerThread
import android.os.Looper
import android.view.Surface
import io.flutter.view.TextureRegistry
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit

/**
 * 美颜渲染器(GL 线程,三趟着色器):
 *   1) 相机 OES 纹理(旋转到竖屏)→ 半分辨率 FBO,横向高斯模糊;
 *   2) 纵向高斯模糊;
 *   3) 全分辨率合成:边缘保留磨皮(模糊与原图差异小的地方用模糊值)、
 *      肤色掩码美白/红润、亮度/饱和度。
 * 结果同时画到 Flutter 预览纹理和(录制时的)编码器输入 Surface。
 */
class BeautyRenderer(private val entry: TextureRegistry.SurfaceTextureEntry) {

    companion object {
        /** 目标档位在传感器 buffer 中可保 16:9 裁剪的最小边长 */
        const val WIDE_MIN = 1900
        /** 竖屏输出短边上限(4K 传感器只取到 2160 竖屏) */
        const val OUT_SHORT_CAP = 2160

        /** 画质档位(以竖屏短边命名:1080=1080x1920) */
        val QUALITY_TIERS = listOf(720, 1080, 1440, 2160)
        val TIER_LABELS = mapOf(
            720 to "720p",
            1080 to "1080p",
            1440 to "2.5K",
            2160 to "4K",
        )

        /**
         * 顶点着色器:只传屏幕坐标。
         * 注意:瘦脸形变/旋转采样必须放在**片元**里逐像素计算 ——
         * 画面只有一个四边形,顶点级计算会在四角插值,等于完全无形变。
         */
        private const val VERT_PLAIN_MAIN = """
            attribute vec2 aPos;
            varying vec2 vUV;
            void main() {
                vUV = aPos * 0.5 + 0.5;
                gl_Position = vec4(aPos, 0.0, 1.0);
            }
        """

        /** 显示坐标 → 纹理采样坐标(含瘦脸形变 + 纹理矩阵 + 传感器旋转) */
        private const val FUNC_TO_TEX = """
            uniform mat4 uTexMat;
            uniform float uRotDeg;
            uniform float uSlim;
            uniform vec4 uFace;
            uniform float uFaceOn;
            uniform float uFaceFallback;
            vec2 toTex(vec2 disp) {
                // 瘦脸:有人脸数据时用脸位置,否则用屏幕中心作为默认
                float faceActive = max(uFaceOn, uFaceFallback);
                if (uSlim > 0.001) {
                    // 瘦脸:形变集中在"脸颊轮廓带"(u≈0.9),且垂直方向
                    // 从下巴向上衰减,颧骨以上归零 —— 额头/眼鼻完全不动
                    vec2 fc = mix(vec2(0.5, 0.5), uFace.xy, uFaceOn);
                    vec2 fr = max(mix(vec2(0.3, 0.4), uFace.zw, uFaceOn), vec2(0.06));
                    vec2 d = disp - fc;
                    vec2 e = d / fr;
                    float u = length(e);            // 0 脸心 → 1 轮廓
                    // 轮廓带超宽软过渡:0.60~0.95(避免畸变边界)
                    float band = smoothstep(0.60, 0.95, u)
                               * (1.0 - smoothstep(0.95, 1.10, u));
                    float topV = fc.y + fr.y;       // 显示 v 向上,头顶值大
                    float tt = (topV - disp.y) / (2.0 * fr.y);
                    // 垂直衰减超软:避免下巴附近畸变
                    float ramp = smoothstep(0.45, 0.80, clamp(tt, 0.0, 1.0))
                               * (1.0 - smoothstep(0.80, 0.95, tt));
                    // 形变强度降低(0.35),避免畸变
                    d.x *= 1.0 + uSlim * 0.35 * band * ramp;
                    disp = fc + d;
                }
                vec2 base = (uTexMat * vec4(disp, 0.0, 1.0)).xy;
                float rad = radians(uRotDeg);
                float cs = cos(rad);
                float sn = sin(rad);
                vec2 q = base - 0.5;
                return vec2(q.x * cs - q.y * sn, q.x * sn + q.y * cs) + 0.5;
            }
        """

        private const val FRAG_OES_BLUR = """
            #extension GL_OES_EGL_image_external : require
            precision mediump float;
            varying vec2 vUV;
            uniform samplerExternalOES uTex;
            uniform vec2 uStep;
            $FUNC_TO_TEX
            void main() {
                // 在显示空间做横向模糊(taps 直接偏移屏幕坐标),
                // 形变/旋转在采样时统一处理,方向与半径都准确
                vec3 col = texture2D(uTex, toTex(vUV)).rgb * 0.227027;
                col += texture2D(uTex, toTex(vUV + vec2(uStep.x * 1.3846154, 0.0))).rgb * 0.3162162;
                col += texture2D(uTex, toTex(vUV - vec2(uStep.x * 1.3846154, 0.0))).rgb * 0.3162162;
                col += texture2D(uTex, toTex(vUV + vec2(uStep.x * 3.2307692, 0.0))).rgb * 0.0702703;
                col += texture2D(uTex, toTex(vUV - vec2(uStep.x * 3.2307692, 0.0))).rgb * 0.0702703;
                gl_FragColor = vec4(col, 1.0);
            }
        """

        private const val FRAG_BLUR2D = """
            precision mediump float;
            varying vec2 vUV;
            uniform sampler2D uTex;
            uniform vec2 uStep;
            void main() {
                vec3 c = texture2D(uTex, vUV).rgb * 0.227027;
                c += texture2D(uTex, vUV + uStep * 1.3846154).rgb * 0.3162162;
                c += texture2D(uTex, vUV - uStep * 1.3846154).rgb * 0.3162162;
                c += texture2D(uTex, vUV + uStep * 3.2307692).rgb * 0.0702703;
                c += texture2D(uTex, vUV - uStep * 3.2307692).rgb * 0.0702703;
                gl_FragColor = vec4(c, 1.0);
            }
        """

        /** 合成:人脸区域内的边缘保留磨皮 + 美白红润 + 全局亮度/饱和度 */
        private const val FRAG_COMBINE = """
            #extension GL_OES_EGL_image_external : require
            precision mediump float;
            varying vec2 vUV;
            uniform samplerExternalOES uSrc;
            uniform sampler2D uBlur;
            uniform float uSmooth;
            uniform float uWhiten;
            uniform float uRuddy;
            uniform float uBright;
            uniform float uSatMul;
            $FUNC_TO_TEX
            void main() {
                vec3 src = texture2D(uSrc, toTex(vUV)).rgb;
                vec3 blur = texture2D(uBlur, vUV).rgb;
                float lum = dot(src, vec3(0.299, 0.587, 0.114));

                // ---- 肤色掩码(YCbCr 色度,窗口收紧:纯白/浅灰墙 cr≈0 直接排除)----
                float cb = -0.168736 * src.r - 0.331264 * src.g + 0.5 * src.b;
                float cr = 0.5 * src.r - 0.418688 * src.g - 0.081312 * src.b;
                float skinCol = smoothstep(-0.20, -0.12, cb) * (1.0 - smoothstep(-0.03, 0.01, cb))
                              * smoothstep(0.05, 0.11, cr) * (1.0 - smoothstep(0.20, 0.27, cr));

                // 空间衰减掩码:以脸为中心的超柔和大范围衰减,避免身体皮肤被美颜
                // 使用 2.5 倍脸半径,从脸心到边缘渐变,消除可见边界
                float faceActive = max(uFaceOn, uFaceFallback);
                vec2 fc = mix(vec2(0.5, 0.5), uFace.xy, uFaceOn);
                vec2 fr = max(mix(vec2(0.3, 0.4), uFace.zw, uFaceOn), vec2(0.06));
                vec2 delta = vUV - fc;
                vec2 norm = delta / (fr * 2.5);  // 2.5 倍脸半径范围
                float dist = length(norm);
                // 超柔和衰减:0.3 开始渐变,1.2 完全归零(无可见边界)
                float spatialMask = 1.0 - smoothstep(0.3, 1.2, dist);
                // 垂直约束:排除脖子(下巴以下快速衰减)
                // fc.y - fr.y * 0.8 是下巴位置,向下 0.15 归零
                float chinY = fc.y - fr.y * 0.8;
                float neckFade = 1.0 - smoothstep(chinY - 0.15, chinY, vUV.y);
                spatialMask *= neckFade;
                // 混合:有人脸时用空间掩码,无人脸时用纯肤色
                float skinMask = mix(skinCol, skinCol * spatialMask, faceActive);

                // 最终掩码
                float m = skinMask;
                // 高光/极暗处不处理:避免死白与噪点放大
                m *= 1.0 - smoothstep(0.80, 0.96, lum);
                m *= smoothstep(0.05, 0.15, lum);
                // 美白/红润专用掩码
                float mFace = skinMask;
                mFace *= 1.0 - smoothstep(0.75, 0.95, lum); // 高光处少加,防过曝

                // 磨皮:中半径模糊 + 边缘保留 + 细节回加(避免塑料感/看不清)
                vec3 detail = src - blur;
                float dy = abs(dot(detail, vec3(0.299, 0.587, 0.114)));
                float edge = smoothstep(0.015, 0.09, dy);
                vec3 smoothed = mix(blur, src, edge);
                // 磨皮强度提高 1.5 倍,让效果更明显
                float st = clamp(uSmooth * 1.5 * m, 0.0, 1.0);
                vec3 c = mix(src, smoothed, st);
                // 细节回加减少(25%→15%),磨皮效果更强
                c += detail * (st * 0.15);

                // 美白:提亮+降饱和(不直接加色,保留纹理)
                float wh = uWhiten * mFace * (1.0 - smoothstep(0.40, 0.85, lum));
                // 提亮:0.4
                c *= 1.0 + wh * 0.40;
                // 降饱和:大幅降低到 0.15
                float lumW = dot(c, vec3(0.299, 0.587, 0.114));
                c = mix(c, vec3(lumW), wh * 0.15);
                c.r += uRuddy * 0.05 * mFace;
                // 亮度/饱和度属"画面调节",全局生效
                c += uBright * 0.10;
                float l2 = dot(c, vec3(0.299, 0.587, 0.114));
                c = mix(vec3(l2), c, uSatMul);
                gl_FragColor = vec4(clamp(c, 0.0, 1.0), 1.0);
            }
        """
    }

    private val glThread = HandlerThread("hinter-gl").apply { start() }
    private val glHandler = Handler(glThread.looper)
    private val mainHandler = Handler(Looper.getMainLooper())

    private var display: EGLDisplay = EGL14.EGL_NO_DISPLAY
    private var context: EGLContext = EGL14.EGL_NO_CONTEXT
    private var config: EGLConfig? = null
    private var windowSurface: EGLSurface = EGL14.EGL_NO_SURFACE

    private var oesTex = 0
    private var texA = 0
    private var texB = 0
    private var fboA = 0
    private var fboB = 0
    private var progOes = 0
    private var progBlur = 0
    private var progCombine = 0

    /** 相机帧专用的 SurfaceTexture(OES 纹理载体),与 Flutter 预览纹理解耦 */
    var cameraTexture: SurfaceTexture? = null
        private set

    private val texMatrix = FloatArray(16)
    /** 输出尺寸(用户画质档,竖屏;预览与录制共用) */
    @Volatile private var outW = 1080
    @Volatile private var outH = 1920
    /** 传感器 buffer 尺寸(横屏,跟随相机档位,预览渲染尺寸=竖屏化的它) */
    private var sensorW = 1920
    private var sensorH = 1080
    /** 半分辨率模糊缓冲(跟随输出比例) */
    private var halfW = 540
    private var halfH = 960
    @Volatile private var rotDeg = -90f

    @Volatile private var smooth = 0.5f
    @Volatile private var whiten = 0.3f
    @Volatile private var ruddy = 0.25f
    @Volatile private var bright = 0.1f
    @Volatile private var satMul = 1.0f
    @Volatile private var slim = 0.0f
    // 人脸椭圆(显示空间归一化:cx,cy,rx,ry + 有无脸),由 FaceTracker 驱动
    @Volatile private var faceCx = 0.5f
    @Volatile private var faceCy = 0.5f
    @Volatile private var faceRx = 0f
    @Volatile private var faceRy = 0f
    @Volatile private var faceOn = 0f
    // 人脸检测不可用时降级标志(由插件在 FaceTracker 初始化失败后设置)
    @Volatile private var faceFallback = 0f
    // 肤色分析人脸估算器(ML Kit 不可用时的降级方案)
    var skinFaceEstimator: SkinFaceEstimator? = null
    // ML Kit 是否正在跟踪人脸(用于协调估算器:跟踪中不覆盖)
    @Volatile private var faceFromTracker = false
    fun setFaceFromTracker(active: Boolean) { faceFromTracker = active }

    /** 供 FaceTracker 回调设置人脸区域(线程安全:字段 volatile) */
    fun setFace(cx: Float, cy: Float, rx: Float, ry: Float, present: Boolean) {
        faceCx = cx; faceCy = cy; faceRx = rx; faceRy = ry
        faceOn = if (present) 1f else 0f
        // 诊断:确认 FaceTracker 回调真的在调用
        if (present && System.currentTimeMillis() - faceLogAt > 2000) {
            faceLogAt = System.currentTimeMillis()
            android.util.Log.i("HinterBeauty",
                "setFace called: cx=$cx cy=$cy rx=$rx ry=$ry present=$present")
        }
    }

    /** 调试:强制脸效果开启(绕过人脸跟踪,测试渲染管线) */
    fun setForceFaceOn(force: Boolean) {
        if (force) {
            faceCx = 0.5f; faceCy = 0.5f; faceRx = 0.3f; faceRy = 0.4f
            faceOn = 1f
        }
    }

    /** 人脸检测不可用时启用降级模式(纯肤色掩码) */
    fun setFaceFallback(enabled: Boolean) {
        faceFallback = if (enabled) 1f else 0f
        android.util.Log.i("HinterBeauty", "faceFallback=$faceFallback")
    }

    /** 接收肤色分析估算器的人脸位置(降级模式,主线程回调) */
    fun setEstimatedFace(cx: Float, cy: Float, rx: Float, ry: Float, present: Boolean) {
        faceCx = cx; faceCy = cy; faceRx = rx; faceRy = ry
        faceOn = if (present) 1f else 0f
        if (present && System.currentTimeMillis() - faceLogAt > 2000) {
            faceLogAt = System.currentTimeMillis()
            android.util.Log.i("HinterBeauty",
                "setEstimatedFace: cx=$cx cy=$cy rx=$rx ry=$ry")
        }
    }

    private var recordSurface: EGLSurface = EGL14.EGL_NO_SURFACE
    private var recordTarget: Surface? = null

    // ---- FaceMesh 探针:周期性把合成结果回读成小图供人脸跟踪 ----
    /** 由插件注入;每 ~11fps 采一帧 256px 探针图 */
    @field:Volatile var faceTracker: FaceTrackerBase? = null
    private var probeTex = 0
    private var probeFbo = 0
    private var probeW = 256
    private var probeH = 456
    private var probePix: java.nio.ByteBuffer? = null
    private val probeBmp = arrayOfNulls<android.graphics.Bitmap>(2)
    private var probeFlip = 0
    private var lastProbeAt = 0L

    private var released = false

    // 初始化状态机:start()/initGl() 与 onReady() 的 post 顺序无关紧要,
    // 用 pending 队列消除竞态;initGl 失败时如实上报(不再静默黑屏)。
    @Volatile private var state = 0 // 0 未就绪 / 1 成功 / -1 失败
    private val pending = mutableListOf<(SurfaceTexture) -> Unit>()
    var onFail: ((String) -> Unit)? = null

    val textureId: Long get() = entry.id()
    val renderWidth: Int get() = outW
    val renderHeight: Int get() = outH

    /**
     * @param camW/camH 传感器 buffer 尺寸(横屏)
     * @param outW/outH 输出尺寸(竖屏,用户画质档;预览与录制共用)
     */
    fun start(camW: Int, camH: Int, outW: Int, outH: Int, rotationDeg: Int) {
        sensorW = camW; sensorH = camH
        this.outW = outW; this.outH = outH
        halfW = (outW / 2).coerceAtLeast(2); halfH = (outH / 2).coerceAtLeast(2)
        rotDeg = rotationDeg.toFloat()
        computeProbeSize()
        // 渲染目标(Flutter 纹理)为竖屏输出尺寸
        entry.surfaceTexture().setDefaultBufferSize(outW, outH)
        glHandler.post { initGl() }
    }

    /** 运行时切换画质档(重建模糊缓冲 + 调整输出尺寸) */
    fun setOutputSize(outW: Int, outH: Int) {
        this.outW = outW; this.outH = outH
        halfW = (outW / 2).coerceAtLeast(2); halfH = (outH / 2).coerceAtLeast(2)
        computeProbeSize()
        glHandler.post { recreateHalfTextures() }
    }

    private fun computeProbeSize() {
        probeW = 256.coerceAtMost(outW)
        probeH = (probeW * outH.toFloat() / outW).toInt().coerceAtLeast(2)
        probeH -= probeH % 2
    }

    private fun recreateHalfTextures() {
        if (display == EGL14.EGL_NO_DISPLAY || released) return
        EGL14.eglMakeCurrent(display, windowSurface, windowSurface, context)
        if (texA != 0) {
            GLES20.glDeleteTextures(1, intArrayOf(texA), 0)
            GLES20.glDeleteFramebuffers(1, intArrayOf(fboA), 0)
        }
        if (texB != 0) {
            GLES20.glDeleteTextures(1, intArrayOf(texB), 0)
            GLES20.glDeleteFramebuffers(1, intArrayOf(fboB), 0)
        }
        texA = genTex(GLES20.GL_TEXTURE_2D, halfW, halfH)
        texB = genTex(GLES20.GL_TEXTURE_2D, halfW, halfH)
        fboA = genFbo(texA)
        fboB = genFbo(texB)
        recreateProbeLocked()
    }

    private fun recreateProbeLocked() {
        if (probeTex != 0) {
            GLES20.glDeleteTextures(1, intArrayOf(probeTex), 0)
            GLES20.glDeleteFramebuffers(1, intArrayOf(probeFbo), 0)
        }
        probeTex = genTex(GLES20.GL_TEXTURE_2D, probeW, probeH)
        probeFbo = genFbo(probeTex)
        probePix = java.nio.ByteBuffer
            .allocateDirect(probeW * probeH * 4)
            .order(java.nio.ByteOrder.nativeOrder())
        probeBmp[0]?.recycle(); probeBmp[1]?.recycle()
        probeBmp[0] = android.graphics.Bitmap.createBitmap(probeW, probeH, android.graphics.Bitmap.Config.ARGB_8888)
        probeBmp[1] = android.graphics.Bitmap.createBitmap(probeW, probeH, android.graphics.Bitmap.Config.ARGB_8888)
    }

    fun setBeauty(smooth: Double, whiten: Double, ruddy: Double,
                  bright: Double, sat: Double, slim: Double = -1.0) {
        this.smooth = smooth.toFloat()
        this.whiten = whiten.toFloat()
        this.ruddy = ruddy.toFloat()
        this.bright = bright.toFloat()
        this.satMul = (0.6 + sat * 0.8).toFloat()
        if (slim >= 0) this.slim = slim.toFloat()
        android.util.Log.i("HinterBeauty",
            "setBeauty: smooth=$smooth whiten=$whiten ruddy=$ruddy bright=$bright sat=$sat slim=$slim " +
                "-> smoothF=${this.smooth} whitenF=${this.whiten} slimF=${this.slim}")
    }

    /** 切换前后摄时更新旋转角度(传感器方向不同) */
    fun setRotation(deg: Int) {
        rotDeg = deg.toFloat()
    }

    /** GL 初始化完成后回调(用于创建相机 SurfaceTexture 并打开相机) */
    fun onReady(block: (SurfaceTexture) -> Unit) {
        synchronized(pending) {
            when (state) {
                1 -> cameraTexture?.let { block(it) }
                0 -> pending.add(block)
                else -> return // 失败:不消费
            }
        }
    }

    fun attachRecordSurface(surface: Surface) {
        glHandler.post {
            if (!released) {
                try {
                    detachRecordLocked()
                    recordTarget = surface
                    recordSurface = createSurface(surface)
                } catch (e: Exception) {
                    // 编码器 Surface 创建失败不能带崩整个 App,回退为仅预览
                    android.util.Log.e("HinterRenderer", "attach record surface failed", e)
                    recordSurface = EGL14.EGL_NO_SURFACE
                    try { recordTarget?.release() } catch (_: Exception) {}
                    recordTarget = null
                }
            }
        }
    }

    fun detachRecordSurface() {
        runSync { detachRecordLocked() }
    }

    fun release() {
        runSync {
            released = true
            detachRecordLocked()
            try {
                if (windowSurface != EGL14.EGL_NO_SURFACE) {
                    EGL14.eglDestroySurface(display, windowSurface)
                }
                EGL14.eglMakeCurrent(
                    display, EGL14.EGL_NO_SURFACE, EGL14.EGL_NO_SURFACE, EGL14.EGL_NO_CONTEXT)
                EGL14.eglDestroyContext(display, context)
                EGL14.eglTerminate(display)
            } catch (_: Exception) {}
            windowSurface = EGL14.EGL_NO_SURFACE
            display = EGL14.EGL_NO_DISPLAY
            context = EGL14.EGL_NO_CONTEXT
        }
        glThread.quitSafely()
        // Flutter 纹理注销必须在主线程(@UiThread);在 GL 线程调用会抛
        // RuntimeException 并闪退 —— 用 entry 所属的 handler 切回主线程。
        mainHandler.post {
            try { entry.release() } catch (_: Exception) {}
        }
    }

    /** 在 GL 线程同步执行 */
    private fun runSync(block: () -> Unit) {
        if (Thread.currentThread() === glThread) {
            block()
            return
        }
        val latch = CountDownLatch(1)
        glHandler.post {
            try { block() } finally { latch.countDown() }
        }
        latch.await(1, TimeUnit.SECONDS)
    }

    private fun detachRecordLocked() {
        if (recordSurface != EGL14.EGL_NO_SURFACE) {
            try { EGL14.eglDestroySurface(display, recordSurface) } catch (_: Exception) {}
            recordSurface = EGL14.EGL_NO_SURFACE
        }
        try { recordTarget?.release() } catch (_: Exception) {}
        recordTarget = null
    }

    // ---- GL 内部 ----

    private fun initGl() {
        try {
            display = EGL14.eglGetDisplay(EGL14.EGL_DEFAULT_DISPLAY)
            val ver = IntArray(2)
            EGL14.eglInitialize(display, ver, 0, ver, 1)
            val attribs = intArrayOf(
                EGL14.EGL_RED_SIZE, 8,
                EGL14.EGL_GREEN_SIZE, 8,
                EGL14.EGL_BLUE_SIZE, 8,
                EGL14.EGL_ALPHA_SIZE, 8,
                EGL14.EGL_RENDERABLE_TYPE, EGL14.EGL_OPENGL_ES2_BIT,
                EGLExt.EGL_RECORDABLE_ANDROID, 1,
                EGL14.EGL_NONE
            )
            val configs = arrayOfNulls<EGLConfig>(1)
            val num = IntArray(1)
            var chosen = EGL14.eglChooseConfig(display, attribs, 0, configs, 0, 1, num, 0)
            // 个别机型不支持 EGL_RECORDABLE_ANDROID,去掉该要求重试
            if (!chosen || num[0] == 0) {
                val attribsFallback = intArrayOf(
                    EGL14.EGL_RED_SIZE, 8,
                    EGL14.EGL_GREEN_SIZE, 8,
                    EGL14.EGL_BLUE_SIZE, 8,
                    EGL14.EGL_ALPHA_SIZE, 8,
                    EGL14.EGL_RENDERABLE_TYPE, EGL14.EGL_OPENGL_ES2_BIT,
                    EGL14.EGL_NONE
                )
                chosen = EGL14.eglChooseConfig(display, attribsFallback, 0, configs, 0, 1, num, 0)
            }
            if (!chosen || num[0] == 0) {
                throw IllegalStateException("没有可用的 EGL 配置")
            }
            config = configs[0]
            val ctxAttribs = intArrayOf(EGL14.EGL_CONTEXT_CLIENT_VERSION, 2, EGL14.EGL_NONE)
            context = EGL14.eglCreateContext(
                display, config, EGL14.EGL_NO_CONTEXT, ctxAttribs, 0)
            windowSurface = createSurface(Surface(entry.surfaceTexture()))
            EGL14.eglMakeCurrent(display, windowSurface, windowSurface, context)

            oesTex = genTex(GLES11Ext.GL_TEXTURE_EXTERNAL_OES)
            texA = genTex(GLES20.GL_TEXTURE_2D, halfW, halfH)
            texB = genTex(GLES20.GL_TEXTURE_2D, halfW, halfH)
            fboA = genFbo(texA)
            fboB = genFbo(texB)
            recreateProbeLocked()
            progOes = buildProgram(VERT_PLAIN_MAIN, FRAG_OES_BLUR)
            progBlur = buildProgram(VERT_PLAIN_MAIN, FRAG_BLUR2D)
            progCombine = buildProgram(VERT_PLAIN_MAIN, FRAG_COMBINE)
            android.util.Log.i(
                "HinterRenderer",
                "uRotDeg loc: combine=${GLES20.glGetUniformLocation(progCombine, "uRotDeg")} " +
                    "oes=${GLES20.glGetUniformLocation(progOes, "uRotDeg")} " +
                    "texMat=${GLES20.glGetUniformLocation(progCombine, "uTexMat")}")

            // 首帧清屏:未收到相机帧前给 Flutter 一个干净的黑帧,
            // 避免 undefined buffer 内容(部分驱动为白色/花屏)
            GLES20.glViewport(0, 0, outW, outH)
            GLES20.glClearColor(0f, 0f, 0f, 1f)
            GLES20.glClear(GLES20.GL_COLOR_BUFFER_BIT)
            EGL14.eglSwapBuffers(display, windowSurface)

            // 相机帧载体:在 GL 线程上创建并绑定 OES 纹理
            val st = SurfaceTexture(oesTex)
            var frameCount = 0L
            st.setOnFrameAvailableListener({
                frameCount++
                if (frameCount % 30L == 1L) {
                    android.util.Log.i("HinterRenderer", "camera frame #${frameCount}")
                }
                glHandler.post { renderFrame() }
            }, glHandler)
            cameraTexture = st
            skinFaceEstimator = SkinFaceEstimator { cx, cy, rx, ry, present ->
                mainHandler.post { setEstimatedFace(cx, cy, rx, ry, present) }
            }
            synchronized(pending) {
                state = 1
                val blocks = pending.toList()
                pending.clear()
                blocks.forEach { it(st) }
            }
        } catch (e: Exception) {
            android.util.Log.e("HinterRenderer", "initGl failed", e)
            synchronized(pending) { state = -1; pending.clear() }
            onFail?.invoke("GL 渲染管线初始化失败: ${e.message}")
        }
    }

    private fun renderFrame() {
        val st = cameraTexture ?: return
        if (display == EGL14.EGL_NO_DISPLAY || released) return
        // GL 资源不完整时跳过渲染,避免在非法 GL 状态上触发驱动崩溃
        if (oesTex == 0 || texA == 0 || texB == 0 ||
            progOes == 0 || progBlur == 0 || progCombine == 0
        ) return
        try {
            st.updateTexImage()
            st.getTransformMatrix(texMatrix)

            val radius = 0.8f + smooth * 2.0f // 半分辨率像素(全分辨率约 1.6~5.6px)
            // pass1: OES(传感器朝向)→ fboA(显示朝向,半分辨率,显示横轴模糊)
            drawHalf(progOes, oesTex, fboA, radius / halfW, 0f, useTexMat = true)
            // pass2: fboA → fboB(显示纵轴模糊;缓冲已是显示朝向,直接按轴偏移)
            drawHalf(progBlur, texA, fboB, 0f, radius / halfH, useTexMat = false)
            // pass3: 合成输出(源图按显示朝向采样,模糊图直接按显示坐标叠加)
            drawTo(windowSurface, outW, outH, -1L)
            if (recordSurface != EGL14.EGL_NO_SURFACE) {
                drawTo(recordSurface, outW, outH, st.timestamp)
            }
            maybeProbe()
        } catch (e: Exception) {
            android.util.Log.e("HinterRenderer", "renderFrame failed", e)
        }
    }

    private fun drawHalf(prog: Int, tex: Int, fbo: Int, stepX: Float, stepY: Float, useTexMat: Boolean) {
        GLES20.glBindFramebuffer(GLES20.GL_FRAMEBUFFER, fbo)
        GLES20.glViewport(0, 0, halfW, halfH)
        GLES20.glUseProgram(prog)
        GLES20.glActiveTexture(GLES20.GL_TEXTURE0)
        GLES20.glBindTexture(GLES11Ext.GL_TEXTURE_EXTERNAL_OES.takeIf { useTexMat } ?: GLES20.GL_TEXTURE_2D, tex)
        GLES20.glUniform1i(GLES20.glGetUniformLocation(prog, "uTex"), 0)
        GLES20.glUniform2f(GLES20.glGetUniformLocation(prog, "uStep"), stepX, stepY)
        if (useTexMat) {
            GLES20.glUniform1f(GLES20.glGetUniformLocation(prog, "uRotDeg"), rotDeg)
            GLES20.glUniformMatrix4fv(GLES20.glGetUniformLocation(prog, "uTexMat"), 1, false, texMatrix, 0)
            GLES20.glUniform1f(GLES20.glGetUniformLocation(prog, "uSlim"), slim)
            GLES20.glUniform4f(GLES20.glGetUniformLocation(prog, "uFace"),
                faceCx, faceCy, faceRx, faceRy)
            GLES20.glUniform1f(GLES20.glGetUniformLocation(prog, "uFaceOn"), faceOn)
        }
        drawQuad()
        // 必须解绑 FBO:否则后续往窗口/编码器表面的绘制会落进残留 FBO
        // (GL 绑定跨 eglSwapBuffers 持久,这是预览与录制全黑的根因)
        GLES20.glBindFramebuffer(GLES20.GL_FRAMEBUFFER, 0)
        GLES20.glBindTexture(GLES20.GL_TEXTURE_2D, 0)
    }

    private fun drawTo(surface: EGLSurface, w: Int, h: Int, timestampNs: Long) {
        if (!EGL14.eglMakeCurrent(display, surface, surface, context)) return
        GLES20.glBindFramebuffer(GLES20.GL_FRAMEBUFFER, 0)
        GLES20.glViewport(0, 0, w, h)
        setupCombine()
        drawQuad()
        if (timestampNs >= 0) {
            EGLExt.eglPresentationTimeANDROID(display, surface, timestampNs)
        }
        EGL14.eglSwapBuffers(display, surface)
        teardownCombine()
    }

    /** 绑定合成 pass 的纹理与全部 uniform(窗口/编码器/探针共用同一份) */
    private fun setupCombine() {
        GLES20.glUseProgram(progCombine)
        GLES20.glActiveTexture(GLES20.GL_TEXTURE0)
        GLES20.glBindTexture(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, oesTex)
        GLES20.glUniform1i(GLES20.glGetUniformLocation(progCombine, "uSrc"), 0)
        GLES20.glActiveTexture(GLES20.GL_TEXTURE1)
        GLES20.glBindTexture(GLES20.GL_TEXTURE_2D, texB)
        GLES20.glUniform1i(GLES20.glGetUniformLocation(progCombine, "uBlur"), 1)
        GLES20.glUniform1f(GLES20.glGetUniformLocation(progCombine, "uRotDeg"), rotDeg)
        GLES20.glUniformMatrix4fv(
            GLES20.glGetUniformLocation(progCombine, "uTexMat"), 1, false, texMatrix, 0)
        GLES20.glUniform1f(GLES20.glGetUniformLocation(progCombine, "uSlim"), slim)
        GLES20.glUniform4f(GLES20.glGetUniformLocation(progCombine, "uFace"),
            faceCx, faceCy, faceRx, faceRy)
        GLES20.glUniform1f(GLES20.glGetUniformLocation(progCombine, "uFaceOn"), faceOn)
        GLES20.glUniform1f(GLES20.glGetUniformLocation(progCombine, "uSmooth"), smooth)
        GLES20.glUniform1f(GLES20.glGetUniformLocation(progCombine, "uWhiten"), whiten)
        GLES20.glUniform1f(GLES20.glGetUniformLocation(progCombine, "uRuddy"), ruddy)
        GLES20.glUniform1f(GLES20.glGetUniformLocation(progCombine, "uBright"), bright)
        GLES20.glUniform1f(GLES20.glGetUniformLocation(progCombine, "uSatMul"), satMul)
        // 诊断:确认人脸数据真的进了 shader(每秒一条)
        val nowMs = System.currentTimeMillis()
        if (nowMs - faceLogAt > 1000) {
            faceLogAt = nowMs
            android.util.Log.i(
                "HinterBeauty",
                "uFaceOn=$faceOn face=(${"%.2f".format(faceCx)}," +
                    "${"%.2f".format(faceCy)},${"%.2f".format(faceRx)}," +
                    "${"%.2f".format(faceRy)}) " +
                    "loc=${GLES20.glGetUniformLocation(progCombine, "uFace")}/" +
                    "${GLES20.glGetUniformLocation(progCombine, "uFaceOn")}")
        }
    }

    private fun teardownCombine() {
        GLES20.glBindTexture(GLES20.GL_TEXTURE_2D, 0)
        GLES20.glActiveTexture(GLES20.GL_TEXTURE0)
        GLES20.glBindTexture(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, 0)
    }

    /**
     * 以约 11fps 把合成结果重画进 256px 探针 FBO 并回读,喂给 FaceTracker。
     * 探针与"实际显示的画面"逐像素一致(仅缩放),从根上消除检测坐标偏移。
     */
    private var probeLogAt = 0L
    private var probeCount = 0L
    private fun maybeProbe() {
        if (probeTex == 0 || probeFbo == 0) return
        val now = System.currentTimeMillis()
        if (now - lastProbeAt < 60) return
        lastProbeAt = now
        probeCount++
        if (probeCount - probeLogAt < 2L || now - probeLogAt > 2000) {
            probeLogAt = now
            android.util.Log.i("HinterProbe", "probe #$probeCount size=${probeW}x$probeH tracker=ok")
        }
        GLES20.glBindFramebuffer(GLES20.GL_FRAMEBUFFER, probeFbo)
        GLES20.glViewport(0, 0, probeW, probeH)
        setupCombine()
        drawQuad()
        teardownCombine()
        val pix = probePix ?: return
        pix.clear()
        GLES20.glReadPixels(
            0, 0, probeW, probeH,
            GLES20.GL_RGBA, GLES20.GL_UNSIGNED_BYTE, pix)
        GLES20.glBindFramebuffer(GLES20.GL_FRAMEBUFFER, 0)
        if (GLES20.glGetError() != GLES20.GL_NO_ERROR) {
            android.util.Log.e("HinterProbe", "glReadPixels error: ${GLES20.glGetError()}")
            return
        }
        // GL 不保证推进 Buffer position,统一 rewind 到 0
        pix.position(0)
        val idx = probeFlip
        probeFlip = 1 - probeFlip
        val bmp = probeBmp[idx] ?: return
        bmp.copyPixelsFromBuffer(pix)
        val tracker = faceTracker
        if (tracker != null) {
            tracker.process(bmp)
        } else if (!faceFromTracker) {
            // ML Kit 不可用或丢失跟踪:用肤色分析估算人脸位置
            val est = skinFaceEstimator
            if (est != null) {
                mainHandler.post {
                    try { est.process(bmp) } catch (_: Exception) {}
                }
            }
        }
    }

    private var quadBuf: java.nio.FloatBuffer? = null
    private var faceLogAt = 0L

    private fun drawQuad() {
        val buf = quadBuf ?: java.nio.ByteBuffer.allocateDirect(8 * 4)
            .order(java.nio.ByteOrder.nativeOrder())
            .asFloatBuffer()
            .also { fb ->
                fb.put(floatArrayOf(-1f, -1f, 1f, -1f, -1f, 1f, 1f, 1f))
                fb.flip()
                quadBuf = fb
            }
        val posLoc = GLES20.glGetAttribLocation(currentProgram(), "aPos")
        GLES20.glEnableVertexAttribArray(posLoc)
        GLES20.glVertexAttribPointer(posLoc, 2, GLES20.GL_FLOAT, false, 0, buf)
        GLES20.glDrawArrays(GLES20.GL_TRIANGLE_STRIP, 0, 4)
        GLES20.glDisableVertexAttribArray(posLoc)
    }

    private fun currentProgram(): Int {
        val b = IntArray(1)
        GLES20.glGetIntegerv(GLES20.GL_CURRENT_PROGRAM, b, 0)
        return b[0]
    }

    private fun genTex(target: Int): Int {
        val ids = IntArray(1)
        GLES20.glGenTextures(1, ids, 0)
        GLES20.glBindTexture(target, ids[0])
        GLES20.glTexParameteri(target, GLES20.GL_TEXTURE_MIN_FILTER, GLES20.GL_LINEAR)
        GLES20.glTexParameteri(target, GLES20.GL_TEXTURE_MAG_FILTER, GLES20.GL_LINEAR)
        GLES20.glTexParameteri(target, GLES20.GL_TEXTURE_WRAP_S, GLES20.GL_CLAMP_TO_EDGE)
        GLES20.glTexParameteri(target, GLES20.GL_TEXTURE_WRAP_T, GLES20.GL_CLAMP_TO_EDGE)
        return ids[0]
    }

    private fun genTex(target: Int, w: Int, h: Int): Int {
        val id = genTex(target)
        GLES20.glTexImage2D(
            GLES20.GL_TEXTURE_2D, 0, GLES20.GL_RGBA, w, h, 0,
            GLES20.GL_RGBA, GLES20.GL_UNSIGNED_BYTE, null
        )
        return id
    }

    private fun genFbo(tex: Int): Int {
        val ids = IntArray(1)
        GLES20.glGenFramebuffers(1, ids, 0)
        GLES20.glBindFramebuffer(GLES20.GL_FRAMEBUFFER, ids[0])
        GLES20.glFramebufferTexture2D(
            GLES20.GL_FRAMEBUFFER, GLES20.GL_COLOR_ATTACHMENT0,
            GLES20.GL_TEXTURE_2D, tex, 0)
        GLES20.glBindFramebuffer(GLES20.GL_FRAMEBUFFER, 0)
        return ids[0]
    }

    private fun buildProgram(vert: String, frag: String): Int {
        val vs = compile(GLES20.GL_VERTEX_SHADER, vert)
        val fs = compile(GLES20.GL_FRAGMENT_SHADER, frag)
        val prog = GLES20.glCreateProgram()
        GLES20.glAttachShader(prog, vs)
        GLES20.glAttachShader(prog, fs)
        GLES20.glLinkProgram(prog)
        val status = IntArray(1)
        GLES20.glGetProgramiv(prog, GLES20.GL_LINK_STATUS, status, 0)
        if (status[0] == 0) {
            val log = GLES20.glGetProgramInfoLog(prog)
            throw IllegalStateException("着色器链接失败: $log")
        }
        return prog
    }

    private fun compile(type: Int, src: String): Int {
        val sh = GLES20.glCreateShader(type)
        GLES20.glShaderSource(sh, src.trimIndent())
        GLES20.glCompileShader(sh)
        val status = IntArray(1)
        GLES20.glGetShaderiv(sh, GLES20.GL_COMPILE_STATUS, status, 0)
        if (status[0] == 0) {
            val log = GLES20.glGetShaderInfoLog(sh)
            throw IllegalStateException("着色器编译失败: $log")
        }
        return sh
    }

    private fun createSurface(surface: Surface): EGLSurface {
        val attribs = intArrayOf(EGL14.EGL_NONE)
        val s = EGL14.eglCreateWindowSurface(display, config, surface, attribs, 0)
        if (s == null || s == EGL14.EGL_NO_SURFACE) {
            throw IllegalStateException("创建 EGL Surface 失败")
        }
        return s
    }
}
