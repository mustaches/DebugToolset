// 荧光融合（GPU 版，对应 fuseFluorescence）：白光 RGB × 荧光 mono。
// 荧光图按 (uOffX, uOffY) 偏移做双线性重采样（边界钳位）；
// alpha 模式：α 由荧光强度经门限映射到 0..uAlphaMax，
//   out = (1−α)·WL + α·pseudo(FL)·maxValue；
// contour 模式：mask（fl ≥ 阈值）内 3x3 邻域存在 mask 外点即为边缘，
//   边缘以伪彩全强度叠加，其余取白光。
#include <flutter/runtime_effect.glsl>

precision highp float;
precision highp int;

uniform float uRgbTexW; // 白光 RGB 打包纹理宽（w*3/2）
uniform float uTexH;
uniform float uWidth;
uniform float uHeight;
uniform float uFlTexW;  // 荧光 mono 打包纹理宽（w/2）
uniform float uMode;    // 0=alpha, 1=contour
uniform float uThreshold;
uniform float uAlphaMax;
uniform float uColormap; // 0=green, 1=magenta, 2=hot
uniform float uOffX;
uniform float uOffY;
uniform float uMaxValue;
uniform sampler2D uRgb;
uniform sampler2D uFl;

out vec4 fragColor;

// 下标*2 恒为偶数 → 值落在单个纹素的 RG/BA 内，一次采样；寻址用 int
//（12MP 帧线性下标超 2^24，float 会丢精度）。sampler 不能作函数参数
//（SkSL 转译不支持），两路采样各写一份。
float fetchRgb(int idx) {
  int byteOff = idx * 2;
  int texel = byteOff / 4;
  int sub = byteOff - texel * 4;
  int tw = int(uRgbTexW);
  vec2 uv = vec2((float(texel - texel / tw * tw) + 0.5) / uRgbTexW,
                 (float(texel / tw) + 0.5) / uTexH);
  vec4 t = floor(texture(uRgb, uv) * 255.0 + 0.5);
  return sub == 0 ? t.r + t.g * 256.0 : t.b + t.a * 256.0;
}

float fetchFl(int px) {
  int byteOff = px * 2;
  int texel = byteOff / 4;
  int sub = byteOff - texel * 4;
  int tw = int(uFlTexW);
  vec2 uv = vec2((float(texel - texel / tw * tw) + 0.5) / uFlTexW,
                 (float(texel / tw) + 0.5) / uTexH);
  vec4 t = floor(texture(uFl, uv) * 255.0 + 0.5);
  return sub == 0 ? t.r + t.g * 256.0 : t.b + t.a * 256.0;
}

// 带偏移的荧光图双线性采样（边界钳位，与 CPU sampleFl 一致）。
float sampleFl(float fx, float fy) {
  fx = clamp(fx, 0.0, uWidth - 1.0);
  fy = clamp(fy, 0.0, uHeight - 1.0);
  int x0 = int(floor(fx));
  int y0 = int(floor(fy));
  int x1 = x0 + 1 < int(uWidth) ? x0 + 1 : x0;
  int y1 = y0 + 1 < int(uHeight) ? y0 + 1 : y0;
  float tx = fx - float(x0);
  float ty = fy - float(y0);
  int w = int(uWidth);
  float v00 = fetchFl(y0 * w + x0);
  float v10 = fetchFl(y0 * w + x1);
  float v01 = fetchFl(y1 * w + x0);
  float v11 = fetchFl(y1 * w + x1);
  return (v00 * (1.0 - tx) + v10 * tx) * (1.0 - ty) +
         (v01 * (1.0 - tx) + v11 * tx) * ty;
}

// 伪彩（增益 1，融合内不再叠加增益）。
float pseudo(int ch, float t) {
  if (uColormap > 1.5) {
    return ch == 0 ? min(3.0 * t, 1.0)
        : (ch == 1 ? clamp(3.0 * t - 1.0, 0.0, 1.0)
                   : clamp(3.0 * t - 2.0, 0.0, 1.0));
  }
  if (uColormap > 0.5) return ch == 1 ? 0.0 : t; // magenta
  return ch == 1 ? t : 0.0; // green
}

float kernel(int idx) {
  int p = idx / 3;
  int ch = idx - p * 3;
  int w = int(uWidth);
  int x = p - p / w * w;
  int y = p / w;
  float fl = sampleFl(float(x) + uOffX, float(y) + uOffY);
  float t = clamp(fl / uMaxValue, 0.0, 1.0);
  float pv = pseudo(ch, t);
  float wl = fetchRgb(idx);
  if (uMode > 0.5) {
    // contour：mask 内像素若 3x3 邻域存在 mask 外点即为边缘
    //（SkSL 限制：循环条件不能带 &&，提前退出用 break）。
    bool edge = false;
    if (fl >= uThreshold) {
      for (int dy = -1; dy <= 1; dy++) {
        for (int dx = -1; dx <= 1; dx++) {
          if (dx == 0 && dy == 0) continue;
          if (sampleFl(float(x + dx) + uOffX, float(y + dy) + uOffY) <
              uThreshold) {
            edge = true;
            break;
          }
        }
        if (edge) break;
      }
    }
    float v = edge ? pv * uMaxValue : wl;
    return floor(clamp(v, 0.0, uMaxValue) + 0.5);
  }
  // alpha：强度门限 → α 映射。
  float a = 0.0;
  float range = uMaxValue - uThreshold;
  if (range > 0.0 && fl > uThreshold) {
    a = min(uAlphaMax * (fl - uThreshold) / range, uAlphaMax);
  }
  return floor(clamp(wl * (1.0 - a) + pv * uMaxValue * a, 0.0, uMaxValue) + 0.5);
}

void main() {
  vec2 fc = floor(FlutterFragCoord().xy);
  int texel = int(fc.y) * int(uRgbTexW) + int(fc.x);
  float vA = kernel(texel * 2);
  float vB = kernel(texel * 2 + 1);
  float hiA = floor(vA / 256.0), loA = vA - hiA * 256.0;
  float hiB = floor(vB / 256.0), loB = vB - hiB * 256.0;
  fragColor = vec4(loA / 255.0, hiA / 255.0, loB / 255.0, hiB / 255.0);
}
