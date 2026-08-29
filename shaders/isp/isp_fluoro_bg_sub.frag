// 自发荧光背景扣除（GPU 版，对应 applyFluoroBackground 的扣除部分）：
// 块均值表（聚集统计）由调用方 CPU 桥接计算并打包上传；本 pass 逐像素
// 查所在块的均值 bg，v' = max(0, v - uStrength × bg)。
#include <flutter/runtime_effect.glsl>

precision highp float;
precision highp int;

uniform float uTexW;     // mono 打包纹理宽（w/2）
uniform float uTexH;
uniform float uWidth;    // 像素宽 w
uniform float uBs;       // 块边长 blockSize
uniform float uBx;       // 水平块数
uniform float uStrength;
uniform float uMeansTexW; // 块均值打包纹理宽（ceil(bx/2)）
uniform float uMeansTexH; // 块均值打包纹理高（by）
uniform sampler2D uTex;
uniform sampler2D uMeans;

out vec4 fragColor;

// 均值表 idx*2 恒为偶数 → 值落在单个纹素的 RG（sub 0）或 BA（sub 2）。
float fetchMean(int idx) {
  int byteOff = idx * 2;
  int texel = byteOff / 4;
  int sub = byteOff - texel * 4;
  int tw = int(uMeansTexW);
  vec2 uv = vec2((float(texel - texel / tw * tw) + 0.5) / uMeansTexW,
                 (float(texel / tw) + 0.5) / uMeansTexH);
  vec4 t = floor(texture(uMeans, uv) * 255.0 + 0.5);
  return sub == 0 ? t.r + t.g * 256.0 : t.b + t.a * 256.0;
}

void main() {
  vec2 fc = floor(FlutterFragCoord().xy);
  int tw = int(uTexW);
  int texel = int(fc.y) * tw + int(fc.x);
  vec2 uv = vec2((float(texel - texel / tw * tw) + 0.5) / uTexW,
                 (float(texel / tw) + 0.5) / uTexH);
  vec4 t = floor(texture(uTex, uv) * 255.0 + 0.5);
  int w = int(uWidth);
  int bs = int(uBs);
  int bx = int(uBx);
  int p0 = texel * 2;
  int p1 = p0 + 1;
  int bg0 = (p0 / w / bs) * bx + (p0 - p0 / w * w) / bs;
  int bg1 = (p1 / w / bs) * bx + (p1 - p1 / w * w) / bs;
  float vA = floor(max(t.r + t.g * 256.0 - uStrength * fetchMean(bg0), 0.0) + 0.5);
  float vB = floor(max(t.b + t.a * 256.0 - uStrength * fetchMean(bg1), 0.0) + 0.5);
  float hiA = floor(vA / 256.0), loA = vA - hiA * 256.0;
  float hiB = floor(vB / 256.0), loB = vB - hiB * 256.0;
  fragColor = vec4(loA / 255.0, hiA / 255.0, loB / 255.0, hiB / 255.0);
}
