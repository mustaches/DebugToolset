// NN 逐元素 ReLU（fp16 打包路径，对应 GpuNnBackend.reluGpu）。
//
// 输入/输出同为 nn_conv3x3_f16.frag 头注释描述的折叠线性布局（每物理
// 纹素 2 个 IEEE half，R=lo/G=hi），尺寸不变：按相同纹素地址读出 2 个
// half，max(·,0) 后原样写回。
#include <flutter/runtime_effect.glsl>

precision highp float;
precision highp int;

uniform vec2 uSize; // 物理纹理 (TW, TH)，输入输出相同
uniform sampler2D uIn;

out vec4 fragColor;

float h2f(float v) {
  float s = 1.0;
  if (v >= 32768.0) { s = -1.0; v -= 32768.0; }
  float e = floor(v / 1024.0);
  float m = v - e * 1024.0;
  if (e < 0.5) return s * m * 5.9604644775390625e-08;
  if (e > 30.5) return s * 65504.0;
  return s * (1024.0 + m) * pow(2.0, e - 25.0);
}

float f2h(float x) {
  float s = 0.0;
  float av = x;
  if (x < 0.0) { s = 32768.0; av = -x; }
  if (av >= 65520.0) return s + 31744.0;
  if (av < 6.103515625e-05) {
    return s + floor(av * 16777216.0 + 0.5);
  }
  float e = clamp(floor(log2(av)), -14.0, 15.0);
  float m = floor((av / pow(2.0, e) - 1.0) * 1024.0 + 0.5);
  if (m >= 1024.0) { m = 0.0; e += 1.0; }
  return s + (e + 15.0) * 1024.0 + m;
}

void main() {
  vec2 fc = floor(FlutterFragCoord().xy);
  vec4 p = floor(texture(uIn, (fc + 0.5) / uSize) * 255.0 + 0.5);
  float h0 = f2h(max(h2f(p.r + p.g * 256.0), 0.0));
  float h1 = f2h(max(h2f(p.b + p.a * 256.0), 0.0));
  float hi0 = floor(h0 / 256.0);
  float hi1 = floor(h1 / 256.0);
  fragColor = vec4((h0 - hi0 * 256.0) / 255.0, hi0 / 255.0,
                   (h1 - hi1 * 256.0) / 255.0, hi1 / 255.0);
}
