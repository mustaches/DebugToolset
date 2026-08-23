// CLAHE 逐像素应用（GPU 版，对应 applyClaheMono 的第 2/3 步）：tile 直方图
// 统计 + 裁剪 + CDF 在 CPU 完成并打包为 16 位 LUT 纹理（线性字节流，下标
// = tileLinear*256+bin），本 shader 做 4 tile 双线性插值与 strength 混合。
#include <flutter/runtime_effect.glsl>

precision highp float;
precision highp int;

uniform float uTexW;    // 输入 mono 打包纹理宽（w/2）
uniform float uTexH;
uniform float uWidth;   // 逻辑像素宽 w
uniform float uHeight;
uniform float uBlock;   // tile 边长（像素）
uniform float uTilesX;
uniform float uTilesY;
uniform float uStrength;
uniform float uMaxValue;
uniform float uLutTexW; // LUT 打包纹理宽/高（线性流）
uniform float uLutTexH;
uniform sampler2D uTex;
uniform sampler2D uLut;

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

// LUT 取值（下标 tileLinear*256+bin，恒落在单纹素内，同上）。
float lutVal(int tileLinear, int bin) {
  int byteOff = (tileLinear * 256 + bin) * 2;
  int texel = byteOff / 4;
  int sub = byteOff - texel * 4;
  int tw = int(uLutTexW);
  vec2 uv = vec2((float(texel - texel / tw * tw) + 0.5) / uLutTexW,
                 (float(texel / tw) + 0.5) / uLutTexH);
  vec4 t = floor(texture(uLut, uv) * 255.0 + 0.5);
  return sub == 0 ? t.r + t.g * 256.0 : t.b + t.a * 256.0;
}

float kernel(int px) {
  float v = fetchVal(px);
  if (v <= 0.0) return 0.0; // 与 CPU 一致：纯黑保持不动
  int w = int(uWidth);
  int x = px - px / w * w;
  int y = px / w;
  float fy = (float(y) + 0.5) / uBlock - 0.5;
  float ty0f = floor(fy);
  float wy = fy - ty0f;
  if (ty0f < 0.0) { ty0f = 0.0; wy = 0.0; }
  else if (ty0f >= uTilesY - 1.0) { ty0f = uTilesY - 1.0; wy = 0.0; }
  int ty0 = int(ty0f);
  int ty1 = ty0 + 1 < int(uTilesY) ? ty0 + 1 : ty0;
  float fx = (float(x) + 0.5) / uBlock - 0.5;
  float tx0f = floor(fx);
  float wx = fx - tx0f;
  if (tx0f < 0.0) { tx0f = 0.0; wx = 0.0; }
  else if (tx0f >= uTilesX - 1.0) { tx0f = uTilesX - 1.0; wx = 0.0; }
  int tx0 = int(tx0f);
  int tx1 = tx0 + 1 < int(uTilesX) ? tx0 + 1 : tx0;
  int bin = int(floor(v * 256.0 / (uMaxValue + 1.0)));
  int tilesX = int(uTilesX);
  float l00 = lutVal(ty0 * tilesX + tx0, bin);
  float l01 = lutVal(ty0 * tilesX + tx1, bin);
  float l10 = lutVal(ty1 * tilesX + tx0, bin);
  float l11 = lutVal(ty1 * tilesX + tx1, bin);
  float top = l00 + (l01 - l00) * wx;
  float bottom = l10 + (l11 - l10) * wx;
  float le = top + (bottom - top) * wy;
  return clamp(floor(v + (le - v) * uStrength + 0.5), 0.0, uMaxValue);
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
