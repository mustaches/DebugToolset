// Gr/Gb 均衡（GPU 版，对应 applyGrGbBalance）：仅绿相位生效，Gr/Gb 各乘
// 增益（CPU 侧统计好经 uniform 传入），非绿像素直通。钳位 0..65535 与
// CPU 核一致（注意 CPU 核钳 65535 而非 maxValue）。
#include <flutter/runtime_effect.glsl>

precision highp float;
precision highp int;

uniform float uTexW;
uniform float uTexH;
uniform float uWidth;
uniform float uGainGr;  // Gr（与 R 同行的绿）增益
uniform float uGainGb;  // Gb（与 B 同行的绿）增益
uniform float uPC0;     // 相位 0..3 的颜色（0=R,1=G,2=B）
uniform float uPC1;
uniform float uPC2;
uniform float uPC3;
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

float phaseColor(int phase) {
  if (phase == 0) return uPC0;
  if (phase == 1) return uPC1;
  if (phase == 2) return uPC2;
  return uPC3;
}

float kernel(int idx) {
  float v = fetchVal(idx);
  int w = int(uWidth);
  int x = idx - idx / w * w;
  int y = idx / w;
  int phase = (y - y / 2 * 2) * 2 + (x - x / 2 * 2);
  if (phaseColor(phase) != 1.0) return v; // 非绿直通
  // Gr/Gb 判定与 CPU 一致：横向相邻相位颜色为 R 的是 Gr。
  int hPhase = (phase - phase / 2 * 2) == 0 ? phase + 1 : phase - 1;
  float gain = phaseColor(hPhase) == 0.0 ? uGainGr : uGainGb;
  return clamp(floor(v * gain + 0.5), 0.0, 65535.0);
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
