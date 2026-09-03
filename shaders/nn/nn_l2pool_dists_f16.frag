// DISTS L2pooling（fp16 打包路径，对应 GpuNnBackend.l2PoolDistsGpu）：
//   out = sqrt( depthwise 3x3 Hanning conv(x², s2, p1) + 1e-12 )
// 与 ops.l2PoolingDists 同语义：零填充，输出空间尺寸 floor((H+1)/2)×
// floor((W+1)/2)（奇数尺寸语义与 maxpool 的 floor(H/2) 不同）。
//
// 布局同 nn_conv3x3_f16.frag 头注释的折叠线性布局。Hanning 核可分：
// w[r]*w[c]，w=(0.25, 0.5, 0.25)。
#include <flutter/runtime_effect.glsl>

precision highp float;
precision highp int;

uniform vec2 uInSize;   // 输入物理纹理 (TW, TH)
uniform vec2 uInDims;   // 输入空间尺寸 (W, H)
uniform vec2 uOutSize;  // 输出物理纹理 (TW, TH)
uniform vec2 uOutDims;  // 输出空间尺寸 (Wo, Ho) = ((W+1)/2, (H+1)/2)
uniform float uYOff;    // 输入垂直偏移：分块 padded 输入为 1.0（行 0 为上
                        // halo，越界行已由 stitch 写零，等价零填充），单纹理
                        // 路径为 0.0（行为与旧版逐位一致）
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

  // 3x3 Hanning（可分核 (0.25,0.5,0.25)⊗(0.25,0.5,0.25)），作用于 x²。
  vec4 acc = vec4(0.0);
  for (int r = 0; r < 3; r++) {
    float iy = 2.0 * y + float(r) - 1.0 + uYOff;
    if (iy < 0.0 || iy >= uInDims.y) continue;
    float wr = r == 1 ? 0.5 : 0.25;
    for (int c = 0; c < 3; c++) {
      float ix = 2.0 * x + float(c) - 1.0;
      if (ix < 0.0 || ix >= uInDims.x) continue;
      float wc = c == 1 ? 0.5 : 0.25;
      vec4 v = fetchIn4(gi, ix, iy);
      acc += v * v * (wr * wc);
    }
  }
  acc = sqrt(acc + vec4(1e-12));

  float h0 = f2h(sub < 0.5 ? acc.x : acc.z);
  float h1 = f2h(sub < 0.5 ? acc.y : acc.w);
  float hi0 = floor(h0 / 256.0);
  float hi1 = floor(h1 / 256.0);
  fragColor = vec4((h0 - hi0 * 256.0) / 255.0, hi0 / 255.0,
                   (h1 - hi1 * 256.0) / 255.0, hi1 / 255.0);
}
