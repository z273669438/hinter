// hinter.ci.metal — 美颜合成核(移植自安卓 GLSL beautyCombine)
// 单 pass:瘦脸位移采样 + 肤色×椭圆双掩码磨皮 + 定向美白红润
//
// 关键约束:本核在**任意坐标**采样(瘦脸位移),Core Image 会把它判定为
// **通用核 CIKernel**(不是 CIColorKernel)。Swift 端必须用
// CIKernel(functionName:fromMetalLibraryData:) 加载,否则报
// "Cannot initialize CIColorKernel because the kernel appears to be a CIKernel"。
//
// 编译(必须两步,缺一即空库/链接失败):
//   xcrun metal -fcikernel -c -target air64-apple-ios15.0.0 hinter.ci.metal -o k.air
//   xcrun metallib -cikernel k.air -o default.metallib
//
// 坐标系:sampler.coord() 归一化、原点左下;face/jaw 左上原点(Vision 已翻转),
// 核内用 disp = (x, 1-y) 统一到左上原点到 0..1。
// 半径口径:face.zw 已经是脸框全宽的 0.55/0.62 倍,即≈脸椭圆真半径,
// 不能再乘放大系数(乘 1.75 会伸到头发上,磨出"杂色伪影")。

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

// 肤色掩码(YCbCr 窗口)。过渡带刻意放宽:逐像素窄阈值会把视频噪点
// 放大成"彩色斑块",放宽后掩码连续,杂色消失
static inline float skinMaskOf(float3 c) {
    float cb = -0.168736 * c.r - 0.331264 * c.g + 0.5 * c.b;
    float cr = 0.5 * c.r - 0.418688 * c.g - 0.081312 * c.b;
    return smoothstep(-0.26, -0.06, cb) *
           (1.0 - smoothstep(-0.02, 0.06, cb)) *
           smoothstep(0.00, 0.14, cr) *
           (1.0 - smoothstep(0.16, 0.34, cr));
}

extern "C" { namespace coreimage {

float4 hinterBeauty(sampler s, sampler blur,
                    float smoothA, float whitenA, float ruddyA,
                    float brightA, float satMul, float slimA,
                    float4 face, float faceOn, float4 jaw, float2 texel) {
    float2 uv = s.coord();                   // 归一化,左下原点
    float2 disp = float2(uv.x, 1.0 - uv.y);  // 左上原点(与 face 同基)
    float2 fc = face.xy;
    float2 fr = max(face.zw, float2(0.045)); // 无脸时椭圆≈0 → 几乎不处理

    float3 sc0 = s.sample(uv).rgb;           // 位移前的源色(给瘦脸的肤色门控)
    float skinHere = skinMaskOf(sc0);

    // ---- 瘦脸:只推皮肤,不碰头发/背景 ----
    // hh:0=下巴(下方, y 大) → 1=额角(上方, y 小)
    if (slimA > 0.001 && faceOn > 0.5 && skinHere > 0.05) {
        float chinY = fc.y + fr.y * 0.80;
        float topY = fc.y - fr.y * 1.00;
        float hh = clamp((disp.y - chinY) / (topY - chinY), 0.0, 1.0);
        float hw = max(jawHalf(jaw, hh), 0.04);
        float dx = disp.x - fc.x;
        float rr = length((disp - fc) / fr);
        // 纵向只在下颌段;hh>0.5(眼/太阳穴以上)完全不碰
        float vBand = smoothstep(0.02, 0.16, hh) *
                      (1.0 - smoothstep(0.30, 0.50, hh));
        // 横向沿脸缘窄带(到脸椭圆边缘即止,不外拖)
        float band = smoothstep(0.45, 0.90, rr) * (1.0 - smoothstep(0.98, 1.12, rr));
        float lat = smoothstep(0.15, 0.75, fabs(dx) / max(fr.x, 0.05));
        float sh = slimA * hw * 0.11 * band * vBand * lat;
        // 肤色门控:头发/墙一律不动(0.15 起坡,0.75 满强度)
        sh *= smoothstep(0.15, 0.75, skinHere);
        float slope = (jawHalf(jaw, min(hh + 0.10, 1.0)) -
                       jawHalf(jaw, max(hh - 0.10, 0.0))) / 0.20;
        float inv = rsqrt(1.0 + slope * slope);
        disp.x += (dx < 0.0 ? -sh : sh) * inv;
        disp.y += fabs(sh) * slope * inv * 0.6;
        // 采样必须夹在画面内,否则边缘被拉伸成拖影
        uv = clamp(float2(disp.x, 1.0 - disp.y), 0.002, 0.998);
    }

    float4 src = s.sample(uv);
    float3 sc = src.rgb;
    float3 blr = blur.sample(uv).rgb;
    float lum = dot(sc, float3(0.299, 0.587, 0.114));

    float skinCol = skinMaskOf(sc);

    // ---- 空间掩码:椭圆半径就用 face.zw(不再放大),框缘淡出 ----
    float2 mr = fr * 1.02;
    float spatialMask = 1.0 - smoothstep(0.82, 1.10, length((disp - fc) / mr));
    float chinLine = fc.y + fr.y * 0.95;               // 左上原点:y 大 = 下
    spatialMask *= 1.0 - smoothstep(chinLine - 0.04, chinLine + 0.10, disp.y);

    float m = skinCol * spatialMask * mix(0.45, 1.0, faceOn);
    // 曝光门控几乎不参与中调:近距离自动曝光会把脸推亮,旧门槛(0.74/0.88)
    // 会让"走近一点效果就变弱",这里只在接近纯白/极暗时让开
    m *= 1.0 - smoothstep(0.94, 1.00, lum);
    m *= smoothstep(0.02, 0.10, lum);

    // ---- 磨皮:低频混合 ----
    // 边缘保护必须用**1~2 像素尺度的局部梯度**,不能用 |原图-模糊图|:
    // 模糊半径越大该差值越大,大半径下整张脸都被判成"边缘"→磨皮自动取消,
    // 这正是"近距离(大半径)磨不掉、远距离能磨一点"的原因
    float2 tx = texel * 1.5;
    float3 gx = s.sample(uv + float2(tx.x, 0.0)).rgb
              - s.sample(uv - float2(tx.x, 0.0)).rgb;
    float3 gy = s.sample(uv + float2(0.0, tx.y)).rgb
              - s.sample(uv - float2(0.0, tx.y)).rgb;
    float grad = length(gx) + length(gy);
    float keep = smoothstep(0.05, 0.20, grad);     // 发丝/眼镜/睫毛保留,皮肤孔洞不保留
    float3 smoothed = mix(blr, sc, keep);
    float st = clamp((0.20 + 0.62 * smoothA) * m, 0.0, 0.90);
    float3 c = mix(sc, smoothed, st);
    c += (sc - blr) * (st * 0.15);                  // 纹理回加,防塑料感

    // ---- 美白:曝光式增益(乘法),保住色相与唇色 ----
    float wh = whitenA * m;
    float knee = 1.0 - smoothstep(0.45, 0.95, lum); // 只提中间调,高光让开
    float gain = min(1.0 + wh * knee * 0.52, 1.42);
    c *= gain;
    c += float3(0.008, 0.003, 0.0) * wh * knee;     // 极轻微暖调
    c.r += ruddyA * 0.02 * m;

    // ---- 全局亮度/饱和度 ----
    c += brightA * 0.10;
    float l3 = dot(c, float3(0.299, 0.587, 0.114));
    c = mix(float3(l3), c, satMul);
    return float4(clamp(c, 0.0, 1.0), src.a);
}

}}
