// 色调映射出图（GPU 版，对应 tonemapToRgba / monoToRgba / yuvToRgba /
// hslToRgb+tonemapToRgba 的链末默认色调映射）：任意 16 位打包格式 →
// 8 位 RGBA 显示图（w x h），直接作为预览 ui.Image。
// uFormat: 0=RGB 1=mono/mosaic 2=YUV 3=HSL。
#include <flutter/runtime_effect.glsl>

precision highp float;
precision highp int;

uniform float uTexW;    // 输入打包纹理宽
uniform float uTexH;
uniform float uWidth;   // 逻辑像素宽 w（= 输出图宽）
uniform float uMaxValue;
uniform float uFormat;
uniform float uInvGamma;   // 1/gamma
uniform float uBrightness;
uniform float uContrast;
uniform float uHalf;       // maxValue>>1（YUV 用）
uniform sampler2D uTex;

out vec4 fragColor;

// idx*2 恒为偶数 → 值落在单个纹素的 RG/BA 内，一次采样；寻址用 int
//（12MP 帧线性下标超 2^24，float 会丢精度）。
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

float hueToRgb(float p, float q, float t) {
  float tt = t;
  if (tt < 0.0) tt += 1.0;
  if (tt > 1.0) tt -= 1.0;
  if (tt < 1.0 / 6.0) return p + (q - p) * 6.0 * tt;
  if (tt < 0.5) return q;
  if (tt < 2.0 / 3.0) return p + (q - p) * (2.0 / 3.0 - tt) * 6.0;
  return p;
}

float tonemapChan(float v) {
  float c = clamp(v, 0.0, uMaxValue) / uMaxValue;
  c += uBrightness;
  c = (c - 0.5) * uContrast + 0.5;
  c = clamp(c, 0.0, 1.0);
  c = pow(c, uInvGamma);
  c = clamp(c, 0.0, 1.0);
  return floor(c * 255.0 + 0.5) / 255.0;
}

void main() {
  vec2 fc = floor(FlutterFragCoord().xy);
  int p = int(fc.y) * int(uWidth) + int(fc.x);
  float r, g, b;
  if (uFormat < 0.5) {
    r = fetchVal(p * 3);
    g = fetchVal(p * 3 + 1);
    b = fetchVal(p * 3 + 2);
  } else if (uFormat < 1.5) {
    r = fetchVal(p); g = r; b = r;
  } else if (uFormat < 2.5) {
    float y = fetchVal(p * 3);
    float u = fetchVal(p * 3 + 1) - uHalf;
    float v = fetchVal(p * 3 + 2) - uHalf;
    r = clamp(floor(y + 1.402 * v + 0.5), 0.0, uMaxValue);
    g = clamp(floor(y - 0.344136 * u - 0.714136 * v + 0.5), 0.0, uMaxValue);
    b = clamp(floor(y + 1.772 * u + 0.5), 0.0, uMaxValue);
  } else {
    float inv = 1.0 / uMaxValue;
    float h = fract(fetchVal(p * 3) * inv);
    float s = fetchVal(p * 3 + 1) * inv;
    float l = fetchVal(p * 3 + 2) * inv;
    if (s == 0.0) {
      r = l * uMaxValue; g = r; b = r;
    } else {
      float q = l < 0.5 ? l * (1.0 + s) : l + s - l * s;
      float pp = 2.0 * l - q;
      r = hueToRgb(pp, q, h + 1.0 / 3.0) * uMaxValue;
      g = hueToRgb(pp, q, h) * uMaxValue;
      b = hueToRgb(pp, q, h - 1.0 / 3.0) * uMaxValue;
    }
    r = clamp(floor(r + 0.5), 0.0, uMaxValue);
    g = clamp(floor(g + 0.5), 0.0, uMaxValue);
    b = clamp(floor(b + 0.5), 0.0, uMaxValue);
  }
  fragColor = vec4(tonemapChan(r), tonemapChan(g), tonemapChan(b), 1.0);
}
