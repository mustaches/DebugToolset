// 高频边缘提取（GPU 版，对应 isp_kernels.dart 的 extractHighFreq）：
// 亮度 3x3 盒式高通 → 相对对比度 rel=|detail|/邻域均值 → 相对门限 →
// gain×√rel×maxValue 黑底白线。RGB/YUV/HSL 三域（亮度分别为 BT.601
// 定点亮度/Y/L），输入输出同为三通道打包纹理（w*3/2 × h），输出同格式
// 灰度图（rgb: v,v,v / yuv: v,mid,mid / hsl: 0,0,v）。
#include <flutter/runtime_effect.glsl>

precision highp float;
precision highp int;

uniform float uTexW;    // 三通道打包纹理宽（w*3/2）
uniform float uTexH;    // = 帧高 h
uniform float uWidth;   // 帧宽 w
uniform float uFormat;  // 0=rgb 1=yuv 2=hsl
uniform float uGain;
uniform float uRelThr;  // 相对门限（threshold/maxValue）
uniform float uMaxValue;
uniform sampler2D uTex;

out vec4 fragColor;

// 取线性下标 idx 的 16 位值（idx*2 恒为偶数 → 落在单纹素 RG 或 BA）。
// 寻址用 int：12MP 三通道帧线性下标超 2^24，float 会丢精度。
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

// 像素 (x,y) 的亮度；越界返回 -1（CPU 语义：边界按可用邻域平均）。
float lumaAt(int x, int y) {
  int w = int(uWidth);
  int h = int(uTexH);
  if (x < 0 || y < 0 || x >= w || y >= h) return -1.0;
  int p = (y * w + x) * 3;
  int fmt = int(uFormat);
  if (fmt == 1) return fetchVal(p);      // yuv: Y
  if (fmt == 2) return fetchVal(p + 2);  // hsl: L
  float r = fetchVal(p);
  float g = fetchVal(p + 1);
  float b = fetchVal(p + 2);
  return floor(0.299 * r + 0.587 * g + 0.114 * b + 0.5);
}

// 单像素边缘值：rel = |Y − 邻域均值|/max(均值, maxValue/128)，过相对
// 门限后 gain×√rel×maxValue，四舍五入截位（与 CPU _clampTo 同口径）。
float edgeAt(int x, int y) {
  float y0 = lumaAt(x, y);
  float sum = 0.0, count = 0.0;
  for (int dy = -1; dy <= 1; dy++) {
    for (int dx = -1; dx <= 1; dx++) {
      float v = lumaAt(x + dx, y + dy);
      if (v >= 0.0) {
        sum += v;
        count += 1.0;
      }
    }
  }
  float mean = sum / count;
  float rel = abs(y0 - mean) / max(mean, uMaxValue / 128.0);
  if (rel < uRelThr) rel = 0.0;
  return floor(clamp(uGain * sqrt(rel) * uMaxValue, 0.0, uMaxValue) + 0.5);
}

// 线性下标 i（= pixel*3 + ch）的输出值。
float chanValue(int i) {
  int p = i / 3;
  int ch = i - p * 3;
  int w = int(uWidth);
  int x = p - (p / w) * w;
  int y = p / w;
  float v = edgeAt(x, y);
  int fmt = int(uFormat);
  if (fmt == 1) return ch == 0 ? v : floor(uMaxValue / 2.0); // U=V=中灰
  if (fmt == 2) return ch == 2 ? v : 0.0;                    // H=0、S=0
  return v;                                                  // rgb 三通道同值
}

void main() {
  vec2 fc = floor(FlutterFragCoord().xy);
  int texel = int(fc.y) * int(uTexW) + int(fc.x);
  float vA = chanValue(texel * 2);
  float vB = chanValue(texel * 2 + 1);
  float hiA = floor(vA / 256.0), loA = vA - hiA * 256.0;
  float hiB = floor(vB / 256.0), loB = vB - hiB * 256.0;
  fragColor = vec4(loA / 255.0, hiA / 255.0, loB / 255.0, hiB / 255.0);
}
