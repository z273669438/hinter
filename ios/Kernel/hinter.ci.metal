// hinter.ci.metal — 美颜合成核(移植自安卓 GLSL beautyCombine)
// 单 pass:瘦脸位移采样 + 核内环形模糊磨皮 + 肤色×椭圆双掩码 + 定向美白红润
//
// 关键约束:CIColorKernel 只接受 **1 个** 输入图像!所以模糊在核内做
// (两圈 8 点环均值近似高斯),不引入第二个 sampler —— v31 装机实测
// "BUILD FAILED" 就是多图像签名被拒。
//
// 编译(必须两步,缺一即空库/链接失败):
//   xcrun metal -fcikernel -c -target air64-apple-ios15.0.0 hinter.ci.metal -o k.air
//   xcrun metallib -cikernel k.air -o default.metallib

#include <metal_stdlib>
#include <CoreImage/CoreImage.h>

using namespace metal;

// 半宽轮廓插值(jaw 存全宽,h:0=下巴 → 1=颧骨/额角)。C1 连续跨段 mix,消除折角
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

namespace coreimage {

// 8 点环均值(uv 归一化,左下原点;r 为像素半径)
static inline float3 ringAvg(sampler s, float2 uv, float2 texel, float r) {
    float2 o = texel * r;
    float3 a = s.sample(uv + float2( 0.92388,  0.38268) * o).rgb;
    a += s.sample(uv + float2( 0.38268,  0.92388) * o).rgb;
    a += s.sample(uv + float2(-0.38268,  0.92388) * o).rgb;
    a += s.sample(uv + float2(-0.92388,  0.38268) * o).rgb;
    a += s.sample(uv + float2(-0.92388, -0.38268) * o).rgb;
    a += s.sample(uv + float2(-0.38268, -0.92388) * o).rgb;
    a += s.sample(uv + float2( 0.38268, -0.92388) * o).rgb;
    a += s.sample(uv + float2( 0.92388, -0.38268) * o).rgb;
    return a * 0.125;
}

}

extern "C" { namespace coreimage {

// 参数:s=原图(唯一输入图像),强度 6 个,
// face=(cx, cyTop, rx, ry) 左上原点归一化,faceOn=0/1,
// jaw=4 级全宽轮廓,texel=1/像素尺寸
float4 hinterBeauty(sampler s, float smoothA, float whitenA, float ruddyA,
                    float brightA, float satMul, float slimA,
                    float4 face, float faceOn, float4 jaw, float2 texel) {
    float2 uv = s.coord();                   // 归一化,左下原点
    float2 disp = float2(uv.x, 1.0 - uv.y);  // 左上原点(与 face 同基)
    float2 fc = face.xy;
    float2 fr = max(face.zw, float2(0.045)); // 无脸时椭圆≈0 → 几乎不处理

    // ---- 瘦脸:沿轮廓法线的绝对位移 ----
    if (slimA > 0.001 && faceOn > 0.5) {
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

    float4 src = s.sample(uv);
    float3 sc = src.rgb;

    // ---- 核内双环模糊(替代 CIGaussianBlur,避免第二个输入图像)----
    float r1 = 2.5 + 6.0 * smoothA;          // 像素半径
    float3 b1 = ringAvg(s, uv, texel, r1);
    float3 b2 = ringAvg(s, uv, texel, r1 * 2.3);
    float3 blr = sc * 0.22 + b1 * 0.52 + b2 * 0.26;

    float lum = dot(sc, float3(0.299, 0.587, 0.114));

    // ---- 肤色掩码(YCbCr 窗口,同安卓)----
    float cb = -0.168736 * sc.r - 0.331264 * sc.g + 0.5 * sc.b;
    float cr = 0.5 * sc.r - 0.418688 * sc.g - 0.081312 * sc.b;
    float skinCol = smoothstep(-0.20, -0.12, cb) *
                    (1.0 - smoothstep(-0.03, 0.01, cb)) *
                    smoothstep(0.05, 0.11, cr) *
                    (1.0 - smoothstep(0.20, 0.27, cr));

    // ---- 空间掩码:必须始终生效(脸部定向,绝不全局)----
    // 2.5 倍脸半径柔和衰减 + 下巴以下颈部退出
    float2 norm = (disp - fc) / (fr * 2.5);
    float dist = length(norm);
    float spatialMask = 1.0 - smoothstep(0.3, 1.2, dist);
    float chinYn = fc.y + fr.y * 0.75;                 // 左上原点:y 增大 = 向下
    spatialMask *= 1.0 - smoothstep(chinYn - 0.02, chinYn + 0.06, disp.y);

    // 无脸时椭圆收缩,强度随之淡出(不再退化成全屏)
    float skinMask = skinCol * spatialMask * mix(0.45, 1.0, faceOn);
    float m = skinMask;
    m *= 1.0 - smoothstep(0.80, 0.96, lum); // 高光不处理
    m *= smoothstep(0.05, 0.15, lum);       // 死暗不处理

    // ---- 磨皮:边缘保留混合,强度曲线收敛 ----
    float3 detail = sc - blr;
    float dy = fabs(dot(detail, float3(0.299, 0.587, 0.114)));
    float edge = smoothstep(0.015, 0.09, dy);
    float3 smoothed = mix(blr, sc, edge);
    float st = clamp((0.12 + 0.55 * smoothA) * m, 0.0, 0.75);
    float3 c = mix(sc, smoothed, st);
    c += detail * (st * 0.20);

    // ---- 美白:gamma 提亮中间调,仅作用肤色区 ----
    float wh = whitenA * m;
    float midKnee = 1.0 - smoothstep(0.55, 0.90, lum);
    c = pow(max(c, float3(0.001)), float3(1.0 - wh * midKnee * 0.26));
    c += float3(0.014, 0.003, 0.0) * wh * midKnee;
    c.r += ruddyA * 0.05 * m;

    // ---- 全局亮度/饱和度 ----
    c += brightA * 0.10;
    float l2 = dot(c, float3(0.299, 0.587, 0.114));
    c = mix(float3(l2), c, satMul);
    return float4(clamp(c, 0.0, 1.0), src.a);
}

}}
