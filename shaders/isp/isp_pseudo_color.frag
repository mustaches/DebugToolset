// 伪彩映射（GPU 版，对应 monoPseudoColor）：mono 打包纹理 → 三通道
// 打包纹理。t = clamp(v × gain / maxValue) 后按色表映射
// （0=green / 1=magenta / 2=hot），输出 16 位量级交织 RGB。
#include <flutter/runtime_effect.glsl>

precision highp float;
precision highp int;

uniform float uTexW;    // 输入 mono 打包纹理宽（w/2）
uniform float uTexH;
uniform float uWidth;
uniform float uColormap; // 0=green, 1=magenta, 2=hot
uniform float uGain;
uniform float uMaxValue;
uniform float uOutTexW; // 输出三通道打包纹理宽（w*3/2）
uniform sampler2D uTex;

out vec4 fragColor;

// px*2 恒为偶数 → 值落在单个纹素的 RG（sub 0）或 BA（sub 2），一次采样；
// 寻址用 int（12MP 帧线性下标超 2^24，float 会丢精度）。
float fetchMono(int px) {
  int byteOff = px * 2;
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
  float t = clamp(fetchMono(p) * uGain / uMaxValue, 0.0, 1.0);
  float c;
  if (uColormap > 1.5) {
    // hot：黑 → 红 → 黄 → 白。
    c = ch == 0 ? min(3.0 * t, 1.0)
        : (ch == 1 ? clamp(3.0 * t - 1.0, 0.0, 1.0)
                   : clamp(3.0 * t - 2.0, 0.0, 1.0));
  } else if (uColormap > 0.5) {
    c = ch == 1 ? 0.0 : t; // magenta
  } else {
    c = ch == 1 ? t : 0.0; // green（ICG 惯例纯绿）
  }
  return floor(clamp(c * uMaxValue, 0.0, uMaxValue) + 0.5);
}

void main() {
  vec2 fc = floor(FlutterFragCoord().xy);
  int texel = int(fc.y) * int(uOutTexW) + int(fc.x);
  float vA = kernel(texel * 2);
  float vB = kernel(texel * 2 + 1);
  float hiA = floor(vA / 256.0), loA = vA - hiA * 256.0;
  float hiB = floor(vB / 256.0), loB = vB - hiB * 256.0;
  fragColor = vec4(loA / 255.0, hiA / 255.0, loB / 255.0, hiB / 255.0);
}
