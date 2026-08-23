// RGB 降噪·亮度（GPU 版，对应 applyRgbDenoise 的 luma 阶段）：输入 YUV
// 打包纹理，对 Y 做 3x3 全像素保边加权平均（权重 1/(1+(Δ/σ)²)，
// σ = luma*√(v+64)），U/V 直通。
#include <flutter/runtime_effect.glsl>

precision highp float;
precision highp int;

uniform float uTexW;   // YUV 打包纹理宽（w*3/2）
uniform float uTexH;
uniform float uWidth;
uniform float uHeight;
uniform float uLuma;   // σ 倍率
uniform float uMaxValue;
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
  if (ch != 0) return fetchVal(idx); // U/V 直通
  int w = int(uWidth);
  int h = int(uHeight);
  int x = p - p / w * w;
  int y = p / w;
  float v = fetchVal(p * 3);
  float sigma = uLuma * sqrt(v + 64.0);
  float sum = v;
  float wsum = 1.0;
  for (int dy = -1; dy <= 1; dy++) {
    for (int dx = -1; dx <= 1; dx++) {
      if (dx == 0 && dy == 0) continue;
      int nx = x + dx, ny = y + dy;
      if (nx < 0 || nx >= w || ny < 0 || ny >= h) continue;
      float nv = fetchVal((ny * w + nx) * 3);
      float d = (nv - v) / sigma;
      float wgt = 1.0 / (1.0 + d * d);
      sum += wgt * nv;
      wsum += wgt;
    }
  }
  return clamp(floor(sum / wsum + 0.5), 0.0, uMaxValue);
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
