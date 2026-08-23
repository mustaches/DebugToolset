// RGB→HSL（GPU 版，对应 rgbToHsl）：H 0..1 色环、S/L 均映射到 0..maxValue。
// 浮点实现，与 CPU double 版可能有 ±1 LSB 差（预览可接受）。
#include <flutter/runtime_effect.glsl>

precision highp float;
precision highp int;

uniform float uTexW;   // RGB 打包纹理宽（w*3/2）
uniform float uTexH;
uniform float uWidth;
uniform float uMaxValue;
uniform sampler2D uTex;

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

float kernel(int idx) {
  int p = idx / 3;
  int ch = idx - p * 3;
  float inv = 1.0 / uMaxValue;
  float r = fetchVal(p * 3) * inv;
  float g = fetchVal(p * 3 + 1) * inv;
  float b = fetchVal(p * 3 + 2) * inv;
  float mx = max(r, max(g, b));
  float mn = min(r, min(g, b));
  float l = (mx + mn) * 0.5;
  float h = 0.0;
  float s = 0.0;
  float d = mx - mn;
  if (d > 0.0) {
    s = l > 0.5 ? d / (2.0 - mx - mn) : d / (mx + mn);
    if (mx == r) {
      h = mod((g - b) / d, 6.0);
    } else if (mx == g) {
      h = (b - r) / d + 2.0;
    } else {
      h = (r - g) / d + 4.0;
    }
    h /= 6.0;
    if (h < 0.0) h += 1.0;
  }
  float v = ch == 0 ? h : (ch == 1 ? s : l);
  return clamp(floor(v * uMaxValue + 0.5), 0.0, uMaxValue);
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
