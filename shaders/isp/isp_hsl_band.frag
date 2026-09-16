// 色彩控制器（GPU 版，对应 adjustHslBand）：高斯色相带选择性调整。
// 权重 w(Δ°) = exp(-(Δ/σ)²/2)，Δ 为色环最短角距，σ = uSigma（CPU 侧按
// 45°/q 折算）。H' = round(H + uHShift·w/360·maxValue) 色环循环；
// S/L 按 1+w·(gain-1) 插值增益后钳位。权重按同像素的 H 计算（S/L 通道
// 取同一三元组的 H）。GPU 直接求 exp，CPU 为 0.05° 步进 LUT 线性插值，
// 两者为浮点近似（对拍口径 ±2 LSB）。
#include <flutter/runtime_effect.glsl>

precision highp float;
precision highp int;

uniform float uTexW;   // HSL 打包纹理宽（w*3/2）
uniform float uTexH;
uniform float uWidth;
uniform float uMaxValue;
uniform float uHCenter; // 色相中心（度）
uniform float uSigma;   // 高斯带宽 σ（度）= 45°/q
uniform float uHShift;  // 带中心满权重的色相偏移（度）
uniform float uSGain;
uniform float uLGain;
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

// 色环最短角距的高斯权重
float bandWeight(float hVal) {
  float hDeg = hVal * 360.0 / uMaxValue;
  float d = mod(abs(hDeg - uHCenter), 360.0);
  if (d > 180.0) d = 360.0 - d;
  float x = d / uSigma;
  return exp(-0.5 * x * x);
}

float kernel(int idx) {
  int ch = idx - idx / 3 * 3;
  float v = fetchVal(idx);
  // 同像素的 H：ch 0/1/2 分别回退 0/1/2 个值
  float w = bandWeight(fetchVal(idx - ch));
  if (ch == 0) {
    float m = uMaxValue + 1.0;
    float r = v + uHShift * w / 360.0 * uMaxValue;
    // Dart round() 为「远离零取整」；floor(x+0.5) 仅对非负等价。
    float shifted = sign(r) * floor(abs(r) + 0.5);
    return mod(mod(shifted, m) + m, m);
  }
  float gain = ch == 1 ? uSGain : uLGain;
  return clamp(floor(v * (1.0 + (gain - 1.0) * w) + 0.5), 0.0, uMaxValue);
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
