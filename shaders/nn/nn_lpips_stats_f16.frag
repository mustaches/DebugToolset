// NN LPIPS 打分头逐通道 3 项统计归约（优化 16）：对双图 fp16 打包
// 特征图与逐像素范数图（nn_pixnorm_f16.frag 产物）按带计算
// A_c=Σ(a/na)²、B_c=Σ(b/nb)²、X_c=Σ(a/na)(b/nb) 部分和——
// (a/na − b/nb)² = A + B − 2X 展开式（Kahan 补偿 fp32 累加，与 CPU
// 侧 (tA−tB)² fp64 累加的差异为展开式舍入 + 求和顺序，真机验收见
// scratch/nn_gpu_vgg_bench 日志）。
//
// 输出：每个 (通道组 gi, 统计项 stat, 组内通道 ci) 一个物理纹素，
// idx = ((gi*3)+stat)*4 + ci（stat：0=A 1=B 2=X），一次绘制只画
// 目标纹理的一行（一个带），下标即 fragment 的 x 坐标。纹素 RGBA
// 四字节 = fp32 部分和的 IEEE754 小端字节（同 nn_chstats_f16.frag）。
#include <flutter/runtime_effect.glsl>

precision highp float;
precision highp int;

uniform vec2 uInSize;    // 特征图物理纹理 (TW, TH)（A/B 同布局）
uniform vec2 uInDims;    // 特征图逻辑空间尺寸 (W, H)
uniform vec2 uNormSize;  // 范数图物理纹理 (TW, TH)（每像素 2 纹素）
uniform sampler2D uInA;
uniform sampler2D uInB;
uniform sampler2D uNorm;

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

vec2 uvOf(float p, vec2 size) {
  return vec2((mod(p, size.x) + 0.5) / size.x,
              (floor(p / size.x) + 0.5) / size.y);
}

vec4 fetchA4(float gi, float ix, float iy) {
  float tt = (gi * uInDims.y + iy) * uInDims.x + ix;
  vec4 p0 = floor(texture(uInA, uvOf(2.0 * tt, uInSize)) * 255.0 + 0.5);
  vec4 p1 = floor(texture(uInA, uvOf(2.0 * tt + 1.0, uInSize)) * 255.0 + 0.5);
  return vec4(h2f(p0.r + p0.g * 256.0), h2f(p0.b + p0.a * 256.0),
              h2f(p1.r + p1.g * 256.0), h2f(p1.b + p1.a * 256.0));
}

vec4 fetchB4(float gi, float ix, float iy) {
  float tt = (gi * uInDims.y + iy) * uInDims.x + ix;
  vec4 p0 = floor(texture(uInB, uvOf(2.0 * tt, uInSize)) * 255.0 + 0.5);
  vec4 p1 = floor(texture(uInB, uvOf(2.0 * tt + 1.0, uInSize)) * 255.0 + 0.5);
  return vec4(h2f(p0.r + p0.g * 256.0), h2f(p0.b + p0.a * 256.0),
              h2f(p1.r + p1.g * 256.0), h2f(p1.b + p1.a * 256.0));
}

// 范数图逐纹素 fp32 解包（nn_pixnorm_f16.frag 的小端字节布局）。
float fetchNorm(float p) {
  vec4 px = floor(texture(uNorm, uvOf(p, uNormSize)) * 255.0 + 0.5);
  float b2 = px.b;
  float b3 = px.a;
  float sgn = b3 >= 128.0 ? -1.0 : 1.0;
  float e7 = b3 >= 128.0 ? b3 - 128.0 : b3;
  float e = e7 * 2.0 + floor(b2 / 128.0);
  float mant = px.r + px.g * 256.0 + (b2 - floor(b2 / 128.0) * 128.0) * 65536.0;
  return sgn * (1.0 + mant / 8388608.0) * exp2(e - 127.0);
}

void main() {
  float idx = floor(FlutterFragCoord().x);
  float gi = floor(idx / 12.0);
  float rem = idx - gi * 12.0;
  float stat = floor(rem / 4.0);
  float ci = rem - stat * 4.0;

  float sum = 0.0;
  float comp = 0.0;
  // SkSL 要求循环上界为常量表达式：常量大界 + 运行时 break。
  for (float y = 0.0; y < 8192.0; y += 1.0) {
    if (y >= uInDims.y) break;
    for (float x = 0.0; x < 8192.0; x += 1.0) {
      if (x >= uInDims.x) break;
      vec4 va = fetchA4(gi, x, y);
      vec4 vb = fetchB4(gi, x, y);
      float a = ci < 0.5 ? va.r : ci < 1.5 ? va.g : ci < 2.5 ? va.b : va.a;
      float b = ci < 0.5 ? vb.r : ci < 1.5 ? vb.g : ci < 2.5 ? vb.b : vb.a;
      float i = y * uInDims.x + x;
      float na = fetchNorm(2.0 * i);
      float nb = fetchNorm(2.0 * i + 1.0);
      float ta = a / na;
      float tb = b / nb;
      float v = stat < 0.5 ? ta * ta : stat < 1.5 ? tb * tb : ta * tb;
      float d = v - comp;
      float t = sum + d;
      comp = (t - sum) - d;
      sum = t;
    }
  }

  // fp32 位 → RGBA8 四字节（小端，手动 IEEE754 分解）。
  float sgn = 0.0;
  float av = sum;
  if (sum < 0.0) { sgn = 128.0; av = -sum; }
  float e = 0.0;
  float mant = 0.0;
  if (av >= 1.1754943508222875e-38) {
    e = clamp(floor(log2(av)) + 127.0, 1.0, 254.0);
    mant = floor((av / exp2(e - 127.0) - 1.0) * 8388608.0 + 0.5);
    if (mant >= 8388608.0) { mant = 0.0; e += 1.0; }
  }
  float b0 = mod(mant, 256.0);
  float b1 = mod(floor(mant / 256.0), 256.0);
  float b2 = mod(floor(mant / 65536.0), 128.0) + mod(e, 2.0) * 128.0;
  float b3 = floor(e / 2.0) + sgn;
  fragColor = vec4(b0, b1, b2, b3) / 255.0;
}
