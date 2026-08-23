// CCM 色彩校正（GPU 版，对应 applyCcm）：3x3 行主序矩阵乘，四舍五入
// 钳位 maxValue。CPU 为 2^20 定点，此处浮点等价（±1 LSB）。
#include <flutter/runtime_effect.glsl>

precision highp float;
precision highp int;

uniform float uTexW;   // RGB 打包纹理宽（w*3/2）
uniform float uTexH;
uniform float uWidth;
uniform float uMaxValue;
uniform float uM0;  // 矩阵 9 元素（行主序）
uniform float uM1;
uniform float uM2;
uniform float uM3;
uniform float uM4;
uniform float uM5;
uniform float uM6;
uniform float uM7;
uniform float uM8;
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
  float r = fetchVal(p * 3);
  float g = fetchVal(p * 3 + 1);
  float b = fetchVal(p * 3 + 2);
  float v;
  if (ch == 0) {
    v = uM0 * r + uM1 * g + uM2 * b;
  } else if (ch == 1) {
    v = uM3 * r + uM4 * g + uM5 * b;
  } else {
    v = uM6 * r + uM7 * g + uM8 * b;
  }
  return clamp(floor(v + 0.5), 0.0, uMaxValue);
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
