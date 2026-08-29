// 亮度/对比度调节（GPU 版，对应 isp_kernels.dart 的
// adjustBrightContrast）：base = baselinePct/100 × maxValue；
// Y' = clamp(((Y × brightPct/100) − base) × gainPct/100 + base,
// 0..maxValue)。RGB/YUV/HSL 三通道交织纹理与 mono 单通道纹理同一
// shader（uChannels 区分）：YUV 作用于 Y、HSL 作用于 L、Mono 逐值、
// RGB 按 Y'/Y 等比缩放三通道（Y=0 纯黑像素保持 0）。
#include <flutter/runtime_effect.glsl>

precision highp float;
precision highp int;

uniform float uTexW;    // 打包纹理宽（三通道 w*3/2，mono w/2）
uniform float uTexH;    // = 帧高 h
uniform float uWidth;   // 帧宽 w
uniform float uChannels; // 3 = rgb/yuv/hsl 交织；1 = mono
uniform float uFormat;  // 0=rgb 1=yuv 2=hsl（mono 时忽略）
uniform float uBrightScale; // brightPct/100
uniform float uBase;        // baselinePct/100 × maxValue
uniform float uGainScale;   // gainPct/100
uniform float uMaxValue;
uniform sampler2D uTex;

out vec4 fragColor;

// 取线性下标 idx 的 16 位值（idx*2 恒为偶数 → 落在单纹素 RG 或 BA）。
float fetchVal(int idx) {
  int byteOff = idx * 2;
  int texel = byteOff / 4;
  int sub = byteOff - texel * 4;
  int tw = int(uTexW);
  vec2 uv = vec2((float(texel - texel / tw * tw) + 0.5) / uTexW,
                 (float(texel / tw) + 0.5) / uTexH);
  vec4 t = floor(texture(uTex, uv) * 255.0 + 0.5);
  return sub == 0 ? t.r + t.g * 256.0 : t.b + t.a * 256.0;
}

float adjust(float y) {
  return clamp(((y * uBrightScale) - uBase) * uGainScale + uBase,
               0.0, uMaxValue);
}

// 线性下标 i 的输出值（三通道交织时 i = pixel*3 + ch）。
float chanValue(int i) {
  if (uChannels > 1.5) {
    int p = i / 3;
    int ch = i - p * 3;
    int fmt = int(uFormat);
    if (fmt == 1) {
      // yuv：只调 Y，U/V 直通。
      float v = fetchVal(i);
      return ch == 0 ? floor(adjust(v) + 0.5) : v;
    }
    if (fmt == 2) {
      // hsl：只调 L，H/S 直通。
      float v = fetchVal(i);
      return ch == 2 ? floor(adjust(v) + 0.5) : v;
    }
    // rgb：BT.601 亮度按比例缩放（与 CPU 同公式，float 亮度 ±1）。
    float r = fetchVal(p * 3);
    float g = fetchVal(p * 3 + 1);
    float b = fetchVal(p * 3 + 2);
    float y = 0.299 * r + 0.587 * g + 0.114 * b;
    if (y <= 0.0) return 0.0; // 纯黑像素保持 0
    float ratio = adjust(floor(y + 0.5)) / y;
    return floor(clamp(fetchVal(i) * ratio, 0.0, uMaxValue) + 0.5);
  }
  // mono：逐值调节。
  return floor(adjust(fetchVal(i)) + 0.5);
}

void main() {
  vec2 fc = floor(FlutterFragCoord().xy);
  int texel = int(fc.y) * int(uTexW) + int(fc.x);
  float vA = chanValue(texel * 2);
  float vB = chanValue(texel * 2 + 1);
  float hiA = floor(vA / 256.0), loA = vA - hiA * 256.0;
  float hiB = floor(vB / 256.0), loB = vB - hiB * 256.0;
  fragColor = vec4(loA / 255.0, hiA / 255.0, loB / 255.0, hiB / 255.0);
}
