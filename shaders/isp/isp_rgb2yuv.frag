// RGB→YUV（GPU 版，对应 convertRgbToYuvCsc）：BT.601/BT.709 ×
// full/limited 全参数化（系数经 uniform 传入）。浮点近似（CPU 为 16 位
// 定点移位），±1 LSB；limited 的符号感知四舍五入与 CPU 一致。
#include <flutter/runtime_effect.glsl>

precision highp float;
precision highp int;

uniform float uTexW;   // RGB 打包纹理宽（w*3/2）
uniform float uTexH;
uniform float uWidth;
uniform float uMaxValue;
uniform float uHalf;   // maxValue>>1
uniform float uCyR;    // Y 系数（浮点，如 0.299）
uniform float uCyG;
uniform float uCyB;
uniform float uCuR;    // U 系数（uCuB 恒为 0.5）
uniform float uCuG;
uniform float uCvG;    // V 系数（uCvR 恒为 0.5）
uniform float uCvB;
uniform float uOffY;   // limited 的 Y 偏移（(maxValue*16+127)~/255）
uniform float uLimited; // 1=limited range
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
  float y = floor(uCyR * r + uCyG * g + uCyB * b + 0.5);
  float u = floor(uCuR * r + uCuG * g + 0.5 * b + 0.5) + uHalf;
  float v = floor(0.5 * r + uCvG * g + uCvB * b + 0.5) + uHalf;
  if (uLimited > 0.5) {
    y = uOffY + floor((y * 219.0 + 127.0) / 255.0);
    float du = u - uHalf;
    u = uHalf + floor((du * 224.0 + (du >= 0.0 ? 127.0 : -127.0)) / 255.0);
    float dv = v - uHalf;
    v = uHalf + floor((dv * 224.0 + (dv >= 0.0 ? 127.0 : -127.0)) / 255.0);
  }
  float o = ch == 0 ? y : (ch == 1 ? u : v);
  return clamp(o, 0.0, uMaxValue);
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
