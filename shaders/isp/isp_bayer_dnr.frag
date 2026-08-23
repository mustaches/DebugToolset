// Bayer 降噪（GPU 版，对应 applyBayerDenoise）：同相位（Bayer ±2 /
// mono ±1）3x3 保边加权平均，权重 1/(1+(Δ/σ)²)，σ = strength*√(v+64)。
// CPU 核基于快照（src 拷贝）计算，与 GPU 同时替换语义一致。
#include <flutter/runtime_effect.glsl>

precision highp float;
precision highp int;

uniform float uTexW;   // mono/mosaic 打包纹理宽（w/2）
uniform float uTexH;
uniform float uWidth;
uniform float uHeight;
uniform float uStep;   // 同相位步进：mosaic=2，mono=1
uniform float uStrength;
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

float kernel(int px) {
  int w = int(uWidth);
  int h = int(uHeight);
  int x = px - px / w * w;
  int y = px / w;
  int s = int(uStep);
  float v = fetchVal(px);
  float sigma = uStrength * sqrt(v + 64.0);
  float sum = v;
  float wsum = 1.0;
  for (int dy = -1; dy <= 1; dy++) {
    for (int dx = -1; dx <= 1; dx++) {
      if (dx == 0 && dy == 0) continue;
      int nx = x + dx * s, ny = y + dy * s;
      if (nx < 0 || nx >= w || ny < 0 || ny >= h) continue;
      float nv = fetchVal(ny * w + nx);
      float d = (nv - v) / sigma;
      float wgt = 1.0 / (1.0 + d * d);
      sum += wgt * nv;
      wsum += wgt;
    }
  }
  return floor(sum / wsum + 0.5);
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
