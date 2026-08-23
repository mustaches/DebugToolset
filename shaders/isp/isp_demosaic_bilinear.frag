// 双线性去马赛克（GPU 版，对应 demosaicBilinear）：mosaic 打包纹理 →
// RGB 三通道交织打包纹理（纹理宽 w*3/2）。边界像素只平均有效邻居，
// 与 CPU 核一致。CFA 排列经相位颜色 uniform 传入，shader 与图案无关。
// 寻址全部用 int：12MP 三通道帧的线性下标超过 2^24，float 会丢精度。
#include <flutter/runtime_effect.glsl>

precision highp float;
precision highp int;

uniform float uTexW;    // 输入 mosaic 打包纹理宽（w/2）
uniform float uTexH;
uniform float uWidth;   // 逻辑像素宽 w
uniform float uHeight;
uniform float uOutTexW; // 输出 RGB 打包纹理宽（w*3/2）
uniform float uPC0;     // 相位 0..3 的颜色（0=R,1=G,2=B）
uniform float uPC1;
uniform float uPC2;
uniform float uPC3;
uniform sampler2D uTex;

out vec4 fragColor;

// 取 mosaic 像素 (x,y) 的值；调用方保证坐标合法。下标*2 恒为偶数 →
// 值落在单个纹素的 RG 或 BA 内，一次采样；寻址用 int（超 2^24 精度）。
float fetchPx(int x, int y) {
  int byteOff = (y * int(uWidth) + x) * 2;
  int texel = byteOff / 4;
  int sub = byteOff - texel * 4;
  int tw = int(uTexW);
  vec2 uv = vec2((float(texel - texel / tw * tw) + 0.5) / uTexW,
                 (float(texel / tw) + 0.5) / uTexH);
  vec4 t = floor(texture(uTex, uv) * 255.0 + 0.5);
  return sub == 0 ? t.r + t.g * 256.0 : t.b + t.a * 256.0;
}

float phaseColor(int phase) {
  if (phase == 0) return uPC0;
  if (phase == 1) return uPC1;
  if (phase == 2) return uPC2;
  return uPC3;
}

// 平均有效邻居（边界自动跳过越界项），CPU 侧 count==0 回退自身值。
float avgN(int x, int y, int dx1, int dy1, int dx2, int dy2,
           int dx3, int dy3, int dx4, int dy4, int n) {
  int w = int(uWidth);
  int h = int(uHeight);
  float s = 0.0;
  float c = 0.0;
  int nx = x + dx1, ny = y + dy1;
  if (nx >= 0 && nx < w && ny >= 0 && ny < h) { s += fetchPx(nx, ny); c += 1.0; }
  nx = x + dx2; ny = y + dy2;
  if (nx >= 0 && nx < w && ny >= 0 && ny < h) { s += fetchPx(nx, ny); c += 1.0; }
  if (n > 2) {
    nx = x + dx3; ny = y + dy3;
    if (nx >= 0 && nx < w && ny >= 0 && ny < h) { s += fetchPx(nx, ny); c += 1.0; }
    nx = x + dx4; ny = y + dy4;
    if (nx >= 0 && nx < w && ny >= 0 && ny < h) { s += fetchPx(nx, ny); c += 1.0; }
  }
  if (c < 0.5) return fetchPx(x, y);
  // CPU: (sum + count~/2) ~/ count —— 整数四舍五入。
  return floor((s + floor(c / 2.0)) / c);
}

// 计算 RGB 交织缓冲中第 idx 个 16 位值（idx = pixel*3 + ch）。
float chanVal(int idx) {
  int p = idx / 3;
  int ch = idx - p * 3;
  int w = int(uWidth);
  int x = p - p / w * w;
  int y = p / w;
  int phase = (y - y / 2 * 2) * 2 + (x - x / 2 * 2);
  int own = int(phaseColor(phase));
  if (ch == own) return fetchPx(x, y);
  if (ch == 1) {
    // R/B 站点缺 G：上下左右 4 邻居。
    return avgN(x, y, -1, 0, 1, 0, 0, -1, 0, 1, 4);
  }
  if (own == 1) {
    // G 站点缺 R/B：该颜色的两个轴向邻居（横向或纵向）。
    int hPhase = (phase - phase / 2 * 2) == 0 ? phase + 1 : phase - 1;
    if (int(phaseColor(hPhase)) == ch) {
      return avgN(x, y, -1, 0, 1, 0, 0, 0, 0, 0, 2);
    }
    return avgN(x, y, 0, -1, 0, 1, 0, 0, 0, 0, 2);
  }
  // R 站点缺 B / B 站点缺 R：4 个对角邻居。
  return avgN(x, y, -1, -1, 1, -1, -1, 1, 1, 1, 4);
}

void main() {
  vec2 fc = floor(FlutterFragCoord().xy);
  int texel = int(fc.y) * int(uOutTexW) + int(fc.x);
  float vA = chanVal(texel * 2);
  float vB = chanVal(texel * 2 + 1);
  float hiA = floor(vA / 256.0), loA = vA - hiA * 256.0;
  float hiB = floor(vB / 256.0), loB = vB - hiB * 256.0;
  fragColor = vec4(loA / 255.0, hiA / 255.0, loB / 255.0, hiB / 255.0);
}
