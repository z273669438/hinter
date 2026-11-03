// hinter.ci.metal — 美颜合成核(移植自安卓 GLSL beautyCombine)
// 单 pass:瘦脸位移采样 + 肤色×椭圆双掩码磨皮 + 定向美白红润
//
// 关键约束:本核在**任意坐标**采样(瘦脸位移),Core Image 会把它判定为
// **通用核 CIKernel**(不是 CIColorKernel)。Swift 端必须用
// CIKernel(functionName:fromMetalLibraryData:) 加载,否则报
// "Cannot initialize CIColorKernel because the kernel appears to be a CIKernel"。
// 通用核支持多个输入图像 → 模糊直接用上游 CIGaussianBlur 的结果。
//
// 编译(必须两步,缺一即空库/链接失败):
//   xcrun metal -fcikernel -c -target air64-apple-ios15.0.0 hinter.ci.metal -o k.air
//   xcrun metallib -cikernel k.air -o default.metallib
//
// 坐标系:sampler.coord() 返回归一化坐标,原点左下;face/jaw 是左上原点
// (Vision 检测后已翻转),核内用 disp = (x, 1-y) 统一到左上原点到 0..1。

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

extern "C" { namespace coreimage {

float4 hinterBeauty(sampler s, sampler blur,
                    float smoothA, float whitenA, float ruddyA,
                    float brightA, float satMul, float slimA,
                    float4 face, float faceOn, float4 jaw) {
    float2 uv = s.coord();                   // 归一化,左下原点
    float2 disp = float2(uv.x, 1.0 - uv.y);  // 左上原点(与 face 同基)
    float2 fc = face.xy;
    float2 fr = max(face.zw, float2(0.045)); // 无脸时椭圆≈0 → 几乎不处理

    // ---- 瘦脸:下颌段沿轮廓法线向内收 ----
    // hh:0=下巴(下方, y 大) → 1=额角(上方, y 小)
    if (slimA > 0.001 && faceOn > 0.5) {
        float chinY = fc.y + fr.y * 0.80;
        float topY = fc.y - fr.y * 1.00;
        float hh = clamp((disp.y - chinY) / (topY - chinY), 0.0, 1.0);
        float hw = max(jawHalf(jaw, hh), 0.04);   // 该高度半宽(归一化)
        float dx = disp.x - fc.x;
        float rr = length((disp - fc) / fr);      // 椭圆归一距离
        // 纵向只在下颌段生效;hh>0.5(眼/太阳穴以上)完全不碰
        float vBand = smoothstep(0.00, 0.14, hh) *
                      (1.0 - smoothstep(0.28, 0.50, hh));
        // 横向沿脸缘窄带,带内向外取样 → 脸被压窄
        float band = smoothstep(0.40, 0.88, rr) * (1.0 - smoothstep(1.02, 1.32, rr));
        float lat = smoothstep(0.15, 0.75, fabs(dx) / max(fr.x, 0.05));
        float sh = slimA * hw * 0.20 * band * vBand * lat;
        // 沿轮廓切线方向跟随(位移主要横向,纵向只做轻微跟随)
        float slope = (jawHalf(jaw, min(hh + 0.10, 1.0)) -
                       jawHalf(jaw, max(hh - 0.10, 0.0))) / 0.20;
        float inv = rsqrt(1.0 + slope * slope);
        disp.x += (dx < 0.0 ? -sh : sh) * inv;
        disp.y += fabs(sh) * slope * inv * 0.6;
        uv = float2(disp.x, 1.0 - disp.y);
    }

    float4 src = s.sample(uv);
    float3 sc = src.rgb;
    float3 blr = blur.sample(uv).rgb;
    float lum = dot(sc, float3(0.299, 0.587, 0.114));

    // ---- 肤色掩码(YCbCr 窗口;边界给足过渡,避免硬线)----
    float cb = -0.168736 * sc.r - 0.331264 * sc.g + 0.5 * sc.b;
    float cr = 0.5 * sc.r - 0.418688 * sc.g - 0.081312 * sc.b;
    float skinCol = smoothstep(-0.22, -0.09, cb) *
                    (1.0 - smoothstep(-0.05, 0.03, cb)) *
                    smoothstep(0.02, 0.10, cr) *
                    (1.0 - smoothstep(0.17, 0.32, cr));

    // ---- 空间掩码:恒脸部定向(2.6 倍脸半径柔和衰减 + 颈部退出)----
    float2 norm = (disp - fc) / (fr * 2.6);
    float spatialMask = 1.0 - smoothstep(0.35, 1.25, length(norm));
    float chinLine = fc.y + fr.y * 0.95;                  // 左上原点:y 大 = 下
    spatialMask *= 1.0 - smoothstep(chinLine - 0.04, chinLine + 0.10, disp.y);

    float m = skinCol * spatialMask * mix(0.45, 1.0, faceOn);
    // 高光/死暗保护:窗口拉宽,避免亮度临界处切出轮廓
    m *= 1.0 - smoothstep(0.74, 1.00, lum);
    m *= smoothstep(0.04, 0.22, lum);

    // ---- 磨皮:低频混合。边缘保留权重用**宽过渡**,避免纹理区斑块 ----
    float3 hp = sc - blr;
    float hpMag = length(hp);
    float keep = smoothstep(0.035, 0.20, hpMag);   // 大结构完全保留
    float3 smoothed = mix(blr, sc, keep);
    float st = clamp((0.14 + 0.66 * smoothA) * m, 0.0, 0.88);
    float3 c = mix(sc, smoothed, st);
    c += hp * (st * 0.08);                          // 极少量纹理回加,防塑料

    // ---- 美白:亮度域提亮(保色相,不再逐通道 gamma → 不假白)----
    float wh = whitenA * m;
    float knee = 1.0 - smoothstep(0.60, 0.98, lum); // 宽膝高光保护
    c += (1.0 - c) * (wh * knee * 0.24);
    c += float3(0.012, 0.004, 0.0) * wh * knee;     // 微暖
    c.r += ruddyA * 0.04 * m;
    // 美白后略补饱和,抵消提亮带来的"发白"
    float l2 = dot(c, float3(0.299, 0.587, 0.114));
    c = mix(float3(l2), c, 1.0 + wh * knee * 0.14);

    // ---- 全局亮度/饱和度 ----
    c += brightA * 0.10;
    float l3 = dot(c, float3(0.299, 0.587, 0.114));
    c = mix(float3(l3), c, satMul);
    return float4(clamp(c, 0.0, 1.0), src.a);
}

}}
