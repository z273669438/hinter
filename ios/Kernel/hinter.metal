// hinter.metal — 美颜合成核(移植自安卓 GLSL beautyCombine)
// 单次 pass:瘦脸位移采样 + 肤色/椭圆掩码磨皮 + 定向美白红润 + 全局亮度/饱和度
// 编译:workflow 中 xcrun metal 编成 default.metallib 注入 Runner.app,
// Swift 经 CIColorKernel(functionName:fromMetalLibraryData:) 加载。

#include <metal_stdlib>
using namespace metal;
#include <CoreImage/CoreImage.h>

// 半宽轮廓插值(jaw 存全宽,h:0=下巴 → 1=颧骨/额角)。
// C1 连续跨段 mix,消除折角(安卓 v43 同源逻辑)
static inline float jawHalf(float4 jaw, float hh) {
    float a0 = jaw.x * 0.5;
    float a1 = jaw.y * 0.5;
    float a2 = jaw.z * 0.5;
    float a3 = jaw.w * 0.5;
    float sA = mix(a0, a1, smoothstep(0.00, 0.33, hh));
    float sB = mix(a1, a2, smoothstep(0.33, 0.66, hh));
    float sC = mix(a2, a3, smoothstep(0.66, 1.00, hh));
    float m = mix(sA, sB, smoothstep(0.16, 0.50, hh));
    return mix(m, sC, smoothstep(0.50, 0.84, hh));
}

extern "C" { namespace coreimage {

// 参数:s=原图, blur=高斯模糊图(同尺寸同坐标系),
// smoothA/whitenA/ruddyA/brightA/satMul/slimA=强度,
// face=(cx, cyTop, rx, ry) 显示坐标(y 顶基),faceOn=0/1,
// jaw=4 级全宽轮廓(无 FaceMesh 时传默认近似)
float4 hinterBeauty(sampler2d s, sampler2d blur,
                    float smoothA, float whitenA, float ruddyA,
                    float brightA, float satMul, float slimA,
                    float4 face, float faceOn, float4 jaw) {
    float2 uv = s.coord();                 // 左下原点
    float2 disp = float2(uv.x, 1.0 - uv.y); // 左上原点(与 face 参数同基)
    float faceActive = faceOn;
    float2 fc = mix(float2(0.5, 0.5), face.xy, faceOn);
    float2 fr = max(mix(float2(0.3, 0.4), face.zw, faceOn), float2(0.06));

    // ---- 瘦脸:沿轮廓法线的绝对位移(与安卓一致)----
    if (slimA > 0.001 && faceActive > 0.5) {
        float chinY = fc.y - fr.y * 0.85;
        float topY = fc.y + fr.y * 1.05;
        float hh = clamp((disp.y - chinY) / (topY - chinY), 0.0, 1.0);
        float hw = max(jawHalf(jaw, hh), 0.04);
        float dx = disp.x - fc.x;
        float t = fabs(dx) / hw;
        float rr = length((disp - fc) / fr);
        float band = smoothstep(0.25, 1.00, rr) * (1.0 - smoothstep(1.00, 1.45, rr));
        float vBand = smoothstep(0.00, 0.16, hh) * (1.0 - smoothstep(0.26, 0.50, hh));
        float lat = smoothstep(0.25, 0.95, t);
        float e2 = 0.09;
        float slope = (jawHalf(jaw, min(hh + e2, 1.0)) -
                       jawHalf(jaw, max(hh - e2, 0.0))) / (2.0 * e2);
        float inv = rsqrt(1.0 + slope * slope);
        float sh = slimA * hw * 0.10 * band * vBand * lat;
        if (dx < 0.0) sh = -sh;
        disp.x += sh * inv;
        disp.y -= fabs(sh) * slope * inv * 1.5;
        uv = float2(disp.x, 1.0 - disp.y);
    }

    float4 src = s.sample(s, uv);
    float4 blr = blur.sample(blur, uv);
    float lum = dot(src.rgb, float3(0.299, 0.587, 0.114));

    // ---- 肤色掩码(YCbCr 窗口,同安卓)----
    float cb = -0.168736 * src.r - 0.331264 * src.g + 0.5 * src.b;
    float cr = 0.5 * src.r - 0.418688 * src.g - 0.081312 * src.b;
    float skinCol = smoothstep(-0.20, -0.12, cb) *
                    (1.0 - smoothstep(-0.03, 0.01, cb)) *
                    smoothstep(0.05, 0.11, cr) *
                    (1.0 - smoothstep(0.20, 0.27, cr));

    // ---- 空间掩码:2.5 倍脸半径柔和衰减 + 下巴以下颈部退出 ----
    float2 norm = (disp - fc) / (fr * 2.5);
    float dist = length(norm);
    float spatialMask = 1.0 - smoothstep(0.3, 1.2, dist);
    float chinYn = fc.y - fr.y * 0.75;
    spatialMask *= smoothstep(chinYn - 0.06, chinYn + 0.02, disp.y);

    float skinMask = mix(skinCol, skinCol * spatialMask, faceActive);
    float m = skinMask;
    m *= 1.0 - smoothstep(0.80, 0.96, lum); // 高光不处理
    m *= smoothstep(0.05, 0.15, lum);       // 死暗不处理
    float mFace = skinMask * (1.0 - smoothstep(0.75, 0.95, lum));

    // ---- 磨皮:边缘保留混合,强度曲线收敛(smooth=1 时约 65%)----
    float3 detail = src.rgb - blr.rgb;
    float dy = fabs(dot(detail, float3(0.299, 0.587, 0.114)));
    float edge = smoothstep(0.015, 0.09, dy);
    float3 smoothed = mix(blr.rgb, src.rgb, edge);
    float st = clamp((0.12 + 0.53 * smoothA) * m, 0.0, 0.72);
    float3 c = mix(src.rgb, smoothed, st);
    c += detail * (st * 0.20);

    // ---- 美白:gamma 提亮中间调,仅作用肤色区 ----
    float wh = whitenA * mFace;
    float midKnee = 1.0 - smoothstep(0.55, 0.90, lum);
    c = pow(max(c, float3(0.001)), float3(1.0 - wh * midKnee * 0.26));
    c += float3(0.014, 0.003, 0.0) * wh * midKnee;
    c.r += ruddyA * 0.05 * mFace;

    // ---- 全局亮度/饱和度 ----
    c += brightA * 0.10;
    float l2 = dot(c, float3(0.299, 0.587, 0.114));
    c = mix(float3(l2), c, satMul);
    return float4(clamp(c, 0.0, 1.0), 1.0);
}

}}
