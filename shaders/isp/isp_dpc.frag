// 坏点校正（GPU 版，对应 applyDpc 的 median 模式）：3x3 同相位（Bayer
// ±2 / mono ±1）邻域中位数，偏离超过阈值即替换。
// 注意：CPU 核为原地顺序修改（后处理像素可见前面像素的替换结果），
// GPU 为快照同时替换——孤立的相邻坏点簇结果可能略有差异。
// 中位数用稳定秩选择实现（SkSL 不支持 while 循环与动态数组下标）。
#include <flutter/runtime_effect.glsl>

precision highp float;
precision highp int;

uniform float uTexW;   // mono/mosaic 打包纹理宽（w/2）
uniform float uTexH;
uniform float uWidth;
uniform float uHeight;
uniform float uStep;   // 同相位步进：mosaic=2，mono=1
uniform float uThr;    // 阈值（threshold/100*maxValue）
uniform sampler2D uTex;

out vec4 fragColor;

// idx*2 恒为偶数 → 值落在单个纹素的 RG/BA 内，一次采样；int 寻址。
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

// 取 (dx,dy) 同相位邻居；越界返回 65535 哨兵（不影响秩选择结果）。
float nb(int x, int y, int dx, int dy, int s, int w, int h, inout int cnt) {
  int nx = x + dx * s, ny = y + dy * s;
  if (nx < 0 || nx >= w || ny < 0 || ny >= h) return 65535.0;
  cnt++;
  return fetchVal(ny * w + nx);
}

float kernel(int px) {
  int w = int(uWidth);
  int h = int(uHeight);
  int x = px - px / w * w;
  int y = px / w;
  int s = int(uStep);
  float v = fetchVal(px);
  int cnt = 0;
  float n0 = nb(x, y, -1, -1, s, w, h, cnt);
  float n1 = nb(x, y, 0, -1, s, w, h, cnt);
  float n2 = nb(x, y, 1, -1, s, w, h, cnt);
  float n3 = nb(x, y, -1, 0, s, w, h, cnt);
  float n4 = nb(x, y, 1, 0, s, w, h, cnt);
  float n5 = nb(x, y, -1, 1, s, w, h, cnt);
  float n6 = nb(x, y, 0, 1, s, w, h, cnt);
  float n7 = nb(x, y, 1, 1, s, w, h, cnt);
  if (cnt == 0) return v;
  int k = cnt / 2; // 与 CPU 一致：升序第 length~/2 项
  // 稳定秩：#{小于} + #{同值且下标更小}，秩 k 唯一对应中位数。
  int r0 = int(n1 < n0) + int(n2 < n0) + int(n3 < n0) + int(n4 < n0) +
      int(n5 < n0) + int(n6 < n0) + int(n7 < n0);
  int r1 = int(n0 <= n1) + int(n2 < n1) + int(n3 < n1) + int(n4 < n1) +
      int(n5 < n1) + int(n6 < n1) + int(n7 < n1);
  int r2 = int(n0 <= n2) + int(n1 <= n2) + int(n3 < n2) + int(n4 < n2) +
      int(n5 < n2) + int(n6 < n2) + int(n7 < n2);
  int r3 = int(n0 <= n3) + int(n1 <= n3) + int(n2 <= n3) + int(n4 < n3) +
      int(n5 < n3) + int(n6 < n3) + int(n7 < n3);
  int r4 = int(n0 <= n4) + int(n1 <= n4) + int(n2 <= n4) + int(n3 <= n4) +
      int(n5 < n4) + int(n6 < n4) + int(n7 < n4);
  int r5 = int(n0 <= n5) + int(n1 <= n5) + int(n2 <= n5) + int(n3 <= n5) +
      int(n4 <= n5) + int(n6 < n5) + int(n7 < n5);
  int r6 = int(n0 <= n6) + int(n1 <= n6) + int(n2 <= n6) + int(n3 <= n6) +
      int(n4 <= n6) + int(n5 <= n6) + int(n7 < n6);
  int r7 = int(n0 <= n7) + int(n1 <= n7) + int(n2 <= n7) + int(n3 <= n7) +
      int(n4 <= n7) + int(n5 <= n7) + int(n6 <= n7);
  float med = n0;
  if (r1 == k) med = n1;
  if (r2 == k) med = n2;
  if (r3 == k) med = n3;
  if (r4 == k) med = n4;
  if (r5 == k) med = n5;
  if (r6 == k) med = n6;
  if (r7 == k) med = n7;
  return abs(v - med) > uThr ? med : v;
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
