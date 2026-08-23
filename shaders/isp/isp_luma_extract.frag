// 亮度提取（GPU 版）：RGB 打包纹理 → BT.601 亮度 mono 打包纹理
//（Y = 0.299R+0.587G+0.114B 四舍五入，与 applySharpen 的定点公式 ±1）。
#include <flutter/runtime_effect.glsl>

precision highp float;
precision highp int;

uniform float uTexW;    // 输入 RGB 打包纹理宽（w*3/2）
uniform float uTexH;
uniform float uWidth;
uniform float uOutTexW; // 输出 mono 打包纹理宽（w/2）
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

float luma(int p) {
  float r = fetchVal(p * 3);
  float g = fetchVal(p * 3 + 1);
  float b = fetchVal(p * 3 + 2);
  return floor(0.299 * r + 0.587 * g + 0.114 * b + 0.5);
}

void main() {
  vec2 fc = floor(FlutterFragCoord().xy);
  int texel = int(fc.y) * int(uOutTexW) + int(fc.x);
  int p0 = texel * 2;
  float vA = luma(p0);
  float vB = luma(p0 + 1);
  float hiA = floor(vA / 256.0), loA = vA - hiA * 256.0;
  float hiB = floor(vB / 256.0), loB = vB - hiB * 256.0;
  fragColor = vec4(loA / 255.0, hiA / 255.0, loB / 255.0, hiB / 255.0);
}
