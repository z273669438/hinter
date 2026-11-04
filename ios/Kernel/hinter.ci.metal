// hinter.ci.metal — 美颜合成核(移植自安卓 GLSL beautyCombine)
// 单 pass:瘦脸位移采样 + 核内环形模糊磨皮 + 肤色×椭圆双掩码 + 定向美白红润
//
// 【为什么只有 1 个输入图像】
// 之前用"原图 + CIGaussianBlur 结果"两个 sampler,通用核里第二张图的
// 坐标空间与源图不一致(边缘/瓦片边界上取到别处内容),表现为墙面上
// 涂抹状灰黑影、"不开美颜也有影子"。现在模糊在核内用环形采样完成,
// 只有 s 一个输入,坐标一定正确。
//
// 加载方式:CIKernel(任意坐标采样 → 通用核),不是 CIColorKernel。
// 编译:
//   xcrun metal -fcikernel -c -target air64-apple-ios15.0.0 hinter.ci.metal -o k.air
//   xcrun metallib -cikernel k.air -o default.metallib
//
// 坐标:sampler.coord() 归一化、原点左下;face/jaw 左上原点(Vision 已翻转)。

#include <metal_stdlib>
#include <CoreImage/CoreImage.h>

using namespace metal;

// 半宽轮廓插值(jaw 存全宽,h:0=下巴 → 1=颧骨/额角)。C1 连续跨段 mix
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

// 肤色掩码(YCbCr)。过渡带放宽:窄阈值会把视频噪点放大成彩色斑块
static inline float skinMaskOf(float3 c) {
    float cb = -0.168736 * c.r - 0.331264 * c.g + 0.5 * c.b;
    float cr = 0.5 * c.r - 0.418688 * c.g - 0.081312 * c.b;
    return smoothstep(-0.26, -0.06, cb) *
           (1.0 - smoothstep(-0.02, 0.06, cb)) *
           smoothstep(0.00, 0.14, cr) *
           (1.0 - smoothstep(0.16, 0.34, cr));
}

extern "C" { namespace coreimage {

// 8 点环均值(r 为像素半径,texel=1/尺寸)。核内模糊:坐标恒定正确
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

// 参数:s=原图(唯一输入),六个强度,face=(cx,cyTop,rx,ry),faceOn,jaw,
//       texel=1/像素尺寸,blurR=模糊半径(像素,按脸宽比例由 Swift 算好)
float4 hinterBeauty(sampler s, float smoothA, float whitenA, float ruddyA,
                    float brightA, float satMul, float slimA,
                    float4 face, float faceOn, float4 jaw,
                    float2 texel, float blurR) {
    float2 uv = s.coord();                   // 归一化,左下原点
    float2 disp = float2(uv.x, 1.0 - uv.y);  // 左上原点(与 face 同基)
    float2 fc = face.xy;
    float2 fr = max(face.zw, float2(0.045)); // 无脸时椭圆≈0 → 几乎不处理

    float3 sc0 = s.sample(uv).rgb;           // 位移前源色(瘦脸的肤色门控)
    float skinHere = skinMaskOf(sc0);

    // ---- 瘦脸:下颌段整体向中线压缩(比例缩放,视觉上是"脸变窄")----
    // 旧实现是沿脸缘一条窄环做局部位移:位移量不小(实测 40px),但只在环
    // 带内"捏"一下,肉眼几乎看不出轮廓变化 → 改成整段比例压缩
    if (slimA > 0.001 && faceOn > 0.5 && skinHere > 0.05) {
        float chinY = fc.y + fr.y * 0.80;
        float topY = fc.y - fr.y * 1.00;
        float hh = clamp((disp.y - chinY) / (topY - chinY), 0.0, 1.0);
        // 纵向门控:0=下巴(下) → 1=额角(上);到嘴边淡出,太阳穴以上完全不碰
        float vBand = smoothstep(0.00, 0.18, hh) *
                      (1.0 - smoothstep(0.42, 0.68, hh));
        float2 dd = disp - fc;
        float tt = length(dd / fr);
        float inside = 1.0 - smoothstep(1.00, 1.35, tt);   // 脸外不加力
        float k = slimA * 0.13 * vBand * inside *
                  smoothstep(0.15, 0.75, skinHere);        // 非皮肤零位移
        disp.x = fc.x + dd.x * (1.0 + k);   // 向外取样 = 脸缘向内收
        uv = clamp(float2(disp.x, 1.0 - disp.y), 0.003, 0.997);
    }

    float4 src = s.sample(uv);
    float3 sc = src.rgb;
    float lum = dot(sc, float3(0.299, 0.587, 0.114));
    float skinCol = skinMaskOf(sc);

    // ---- 空间掩码:超椭圆(n=3),而不是正椭圆 ----
    // 正椭圆下脸颊/下颌落在椭圆外,权重只剩 0.5~0.6,观感是"只有上半张脸有效"
    float2 q = fabs((disp - fc) / (fr * 1.22));
    float q3 = q.x * q.x * q.x + q.y * q.y * q.y;
    float dMask = pow(max(q3, 0.0), 1.0 / 3.0);
    float spatialMask = 1.0 - smoothstep(0.92, 1.22, dMask);
    // 下巴线≈脸框下沿(fr.y = 0.62×框高,故 0.82 即框底),再往下排除颈部
    float chinLine = fc.y + fr.y * 0.88;
    spatialMask *= 1.0 - smoothstep(chinLine - 0.02, chinLine + 0.08, disp.y);

    float m = skinCol * spatialMask * mix(0.45, 1.0, faceOn);
    m *= 1.0 - smoothstep(0.94, 1.00, lum);   // 只让开接近纯白的高光
    m *= smoothstep(0.02, 0.10, lum);

    // ---- 核内模糊(双环近似高斯,坐标与 s 完全相同,不存在错位)----
    float r1 = clamp(blurR, 1.0, 18.0);
    float3 b1 = ringAvg(s, uv, texel, r1);
    float3 b2 = ringAvg(s, uv, texel, r1 * 2.2);
    float3 blr = sc * 0.20 + b1 * 0.50 + b2 * 0.30;

    // ---- 磨皮:1.5px 局部梯度判边缘(与模糊半径解耦)----
    float2 tx = texel * 1.5;
    float3 gx = s.sample(uv + float2(tx.x, 0.0)).rgb
              - s.sample(uv - float2(tx.x, 0.0)).rgb;
    float3 gy = s.sample(uv + float2(0.0, tx.y)).rgb
              - s.sample(uv - float2(0.0, tx.y)).rgb;
    float grad = length(gx) + length(gy);
    float keep = smoothstep(0.09, 0.36, grad);   // 发丝/眼镜/睫毛保留
    float3 smoothed = mix(blr, sc, keep);
    float st = clamp(smoothA * 0.95 * m, 0.0, 0.92);  // 滑块=0 时完全不磨
    float3 c = mix(sc, smoothed, st);
    c += (sc - blr) * (st * 0.15);               // 纹理回加,防塑料

    // ---- 美白:曝光式增益,保色相 ----
    float wh = whitenA * m;
    float knee = 1.0 - smoothstep(0.45, 0.95, lum);
    c *= min(1.0 + wh * knee * 0.52, 1.42);
    c += float3(0.008, 0.003, 0.0) * wh * knee;
    c.r += ruddyA * 0.02 * m;

    // ---- 全局亮度/饱和度 ----
    c += brightA * 0.10;
    float l3 = dot(c, float3(0.299, 0.587, 0.114));
    c = mix(float3(l3), c, satMul);
    return float4(clamp(c, 0.0, 1.0), src.a);
}

}}
