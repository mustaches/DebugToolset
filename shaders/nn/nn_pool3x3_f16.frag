// NN 3x3 池化（fp16 打包路径，对应 GpuNnBackend.pool3x3Gpu）：
// MaxPool/AvgPool k3，stride/pad 由 uniform 指定（InceptionV3 的
// maxPool k3/s2/p0、maxPool k3/s1/p1 与 avgPool k3/s1/p1
// countIncludePad=false）。
//
// 布局同 nn_conv3x3_f16.frag 头注释的折叠线性布局。语义对齐
// ops.maxPool2d / ops.avgPool2d(countIncludePad: false)：越界 tap 一律
// 跳过（max 等价 -inf 填充）；avg 的除数为窗口内有效元素数（边界窗口
// 不补零、不按 9 除）。
#include <flutter/runtime_effect.glsl>

precision highp float;
precision highp int;

uniform vec2 uInSize;   // 输入物理纹理 (TW, TH)
uniform vec2 uInDims;   // 输入空间尺寸 (W, H)
uniform vec2 uOutSize;  // 输出物理纹理 (TW, TH)
uniform vec2 uOutDims;  // 输出空间尺寸 (W2, H2)
uniform float uMode;    // 0 = max，1 = avg（countIncludePad=false）
uniform float uStride;  // 1.0 或 2.0（H/W 同值）
uniform float uPad;     // 0.0 或 1.0（H/W 同值）
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

vec2 uvOf(float p, vec2 size) {
  return vec2((mod(p, size.x) + 0.5) / size.x,
              (floor(p / size.x) + 0.5) / size.y);
}

// 输入特征图：取像素 (ix,iy) 的通道 4gi..4gi+3。
vec4 fetchIn4(float gi, float ix, float iy) {
  float t = (gi * uInDims.y + iy) * uInDims.x + ix;
  vec4 p0 = floor(texture(uIn, uvOf(2.0 * t, uInSize)) * 255.0 + 0.5);
  vec4 p1 = floor(texture(uIn, uvOf(2.0 * t + 1.0, uInSize)) * 255.0 + 0.5);
  return vec4(h2f(p0.r + p0.g * 256.0), h2f(p0.b + p0.a * 256.0),
              h2f(p1.r + p1.g * 256.0), h2f(p1.b + p1.a * 256.0));
}

void main() {
  vec2 fc = floor(FlutterFragCoord().xy);
  float p = fc.y * uOutSize.x + fc.x;
  float t = floor(p * 0.5);
  float sub = p - t * 2.0;
  float hw = uOutDims.x * uOutDims.y;
  float gi = floor(t / hw);
  float rem = t - gi * hw;
  float y = floor(rem / uOutDims.x);
  float x = rem - y * uOutDims.x;

  float iy0 = y * uStride - uPad, ix0 = x * uStride - uPad;
  vec4 m = vec4(0.0);
  float cnt = 0.0;
  bool first = true;
  for (int r = 0; r < 3; r++) {
    float iy = iy0 + float(r);
    if (iy < 0.0 || iy >= uInDims.y) continue;
    for (int c = 0; c < 3; c++) {
      float ix = ix0 + float(c);
      if (ix < 0.0 || ix >= uInDims.x) continue;
      vec4 v = fetchIn4(gi, ix, iy);
      if (first) { m = v; first = false; }
      else if (uMode < 0.5) { m = max(m, v); }
      else { m += v; }
      cnt += 1.0;
    }
  }
  if (uMode >= 0.5) m /= cnt; // avg：除数为有效元素数（恒 ≥1）

  float h0 = f2h(sub < 0.5 ? m.x : m.z);
  float h1 = f2h(sub < 0.5 ? m.y : m.w);
  float hi0 = floor(h0 / 256.0);
  float hi1 = floor(h1 / 256.0);
  fragColor = vec4((h0 - hi0 * 256.0) / 255.0, hi0 / 255.0,
                   (h1 - hi1 * 256.0) / 255.0, hi1 / 255.0);
}
