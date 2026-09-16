// RGBA8 流帧 → 16 位打包 RGB（GPU 版 rgba8ToRgb16）：播放路径的源转换。
// 输入为 RGBA8888 纹理（w×h，CPU 零转换直接上传）；输出 16 位打包纹理
// （w*3/2 × h），每纹素装 2 个 16 位值（低字节在 R/B，高字节在 G/A）。
// 数值口径与 CPU 一致：v16 = round(v8 * maxValue / 255)（丢弃 alpha）。
#include <flutter/runtime_effect.glsl>

precision highp float;
precision highp int;

uniform float uSrcW;    // 输入纹理宽（= 帧宽 w）
uniform float uSrcH;    // 输入纹理高（= 帧高 h）
uniform float uTexW;    // 输出打包纹理宽（w*3/2）
uniform float uMaxValue;
uniform sampler2D uTex;

out vec4 fragColor;

// 通道流第 idx 个值（0..w*h*3）：像素 = idx/3，通道 = idx%3
float fetchCh(int idx) {
  int px = idx / 3;
  int ch = idx - px * 3;
  int sw = int(uSrcW);
  vec2 uv = vec2((float(px - px / sw * sw) + 0.5) / uSrcW,
                 (float(px / sw) + 0.5) / uSrcH);
  vec4 t = floor(texture(uTex, uv) * 255.0 + 0.5);
  float v8 = ch == 0 ? t.r : (ch == 1 ? t.g : t.b);
  return floor(v8 * uMaxValue / 255.0 + 0.5);
}

void main() {
  vec2 fc = floor(FlutterFragCoord().xy);
  int texel = int(fc.y) * int(uTexW) + int(fc.x);
  float vA = fetchCh(texel * 2);
  float vB = fetchCh(texel * 2 + 1);
  float hiA = floor(vA / 256.0), loA = vA - hiA * 256.0;
  float hiB = floor(vB / 256.0), loB = vB - hiB * 256.0;
  fragColor = vec4(loA / 255.0, hiA / 255.0, loB / 255.0, hiB / 255.0);
}
