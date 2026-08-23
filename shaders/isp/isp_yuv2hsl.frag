// YUV→HSL（GPU 版，对应 yuvToHsl 单遍融合）：先按 yuvToRgb 求 RGB 中间
// 值（含取整钳位），再按 rgbToHsl 求 H/S/L。浮点近似，±1 LSB。
#include <flutter/runtime_effect.glsl>

precision highp float;
precision highp int;

uniform float uTexW;   // YUV 打包纹理宽（w*3/2）
uniform float uTexH;
uniform float uWidth;
uniform float uMaxValue;
uniform float uHalf;   // maxValue>>1
uniform sampler2D uTex;

out vec4 fragColor;

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

float kernel(int idx) {
  int p = idx / 3;
  int ch = idx - p * 3;
  float y = fetchVal(p * 3);
  float u = fetchVal(p * 3 + 1) - uHalf;
  float v = fetchVal(p * 3 + 2) - uHalf;
  // RGB 中间值：与 CPU 一致的取整钳位。
  float ri = clamp(floor(y + 1.402 * v + 0.5), 0.0, uMaxValue);
  float gi = clamp(floor(y - 0.344136 * u - 0.714136 * v + 0.5), 0.0, uMaxValue);
  float bi = clamp(floor(y + 1.772 * u + 0.5), 0.0, uMaxValue);
  float inv = 1.0 / uMaxValue;
  float r = ri * inv;
  float g = gi * inv;
  float b = bi * inv;
  float mx = max(r, max(g, b));
  float mn = min(r, min(g, b));
  float l = (mx + mn) * 0.5;
  float h = 0.0;
  float s = 0.0;
  float d = mx - mn;
  if (d > 0.0) {
    s = l > 0.5 ? d / (2.0 - mx - mn) : d / (mx + mn);
    if (mx == r) {
      h = mod((g - b) / d, 6.0);
    } else if (mx == g) {
      h = (b - r) / d + 2.0;
    } else {
      h = (r - g) / d + 4.0;
    }
    h /= 6.0;
    if (h < 0.0) h += 1.0;
  }
  float o = ch == 0 ? h : (ch == 1 ? s : l);
  return clamp(floor(o * uMaxValue + 0.5), 0.0, uMaxValue);
}

void main() {
  vec2 fc = floor(FlutterFragCoord().xy);
  int texel = int(fc.y) * int(uTexW) + int(fc.x);
  float vA = kernel(texel * 2);
  float vB = kernel(texel * 2 + 1);
  float hiA = floor(vA / 256.0), loA = vA - hiA * 256.0;
  float hiB = floor(vB / 256.0), loB = vB - hiB * 256.0;
  fragColor = vec4(loA / 255.0, hiA / 255.0, loB / 255.0, hiB / 255.0);
}
