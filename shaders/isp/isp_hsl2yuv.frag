// HSL→YUV（GPU 版，对应 hslToYuv 单遍融合）：先按 hslToRgb 求 RGB 中间
// 值（含取整钳位），再按 BT.601 定点公式求 Y/U/V。浮点近似，±1 LSB。
#include <flutter/runtime_effect.glsl>

precision highp float;
precision highp int;

uniform float uTexW;   // HSL 打包纹理宽（w*3/2）
uniform float uTexH;
uniform float uWidth;
uniform float uMaxValue;
uniform float uHalf;   // maxValue>>1（CPU 侧算好）
uniform sampler2D uTex;

out vec4 fragColor;

// idx*2 恒为偶数 → 16 位值落在单个纹素的 RG（sub 0）或 BA（sub 2），
// 一次采样。寻址用 int：12MP 三通道帧线性下标超 2^24，float 会丢精度。
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

float kernel(int idx) {
  int p = idx / 3;
  int ch = idx - p * 3;
  float inv = 1.0 / uMaxValue;
  float h = fract(fetchVal(p * 3) * inv);
  float s = fetchVal(p * 3 + 1) * inv;
  float l = fetchVal(p * 3 + 2) * inv;
  float rd, gd, bd;
  if (s == 0.0) {
    rd = l; gd = l; bd = l;
  } else {
    float q = l < 0.5 ? l * (1.0 + s) : l + s - l * s;
    float pp = 2.0 * l - q;
    rd = hueToRgb(pp, q, h + 1.0 / 3.0);
    gd = hueToRgb(pp, q, h);
    bd = hueToRgb(pp, q, h - 1.0 / 3.0);
  }
  // RGB 中间值：与 CPU 一致先取整钳位。
  float r = clamp(floor(rd * uMaxValue + 0.5), 0.0, uMaxValue);
  float g = clamp(floor(gd * uMaxValue + 0.5), 0.0, uMaxValue);
  float b = clamp(floor(bd * uMaxValue + 0.5), 0.0, uMaxValue);
  float v;
  if (ch == 0) {
    v = floor(0.299 * r + 0.587 * g + 0.114 * b + 0.5);
  } else if (ch == 1) {
    v = floor(-0.168736 * r - 0.331264 * g + 0.5 * b + 0.5) + uHalf;
  } else {
    v = floor(0.5 * r - 0.418688 * g - 0.081312 * b + 0.5) + uHalf;
  }
  return clamp(v, 0.0, uMaxValue);
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
