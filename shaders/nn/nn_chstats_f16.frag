// NN 双图逐通道 5 项统计归约（DISTS 打分头的 GPU 快路径，优化 15）。
//
// 对两张同布局 fp16 打包特征图（折叠线性布局：逻辑纹素
// T=(gi*H+y)*W+x 装通道 4gi..4gi+3 的 4 个 half = 2 个物理纹素）按带
// 计算逐通道 Σa、Σa²、Σb、Σb²、Σab 部分和（Kahan 补偿 fp32 累加，
// 与 CPU 侧 fp64 逐元素累加的差异仅求和顺序，~1e-7 相对量级）。
//
// 每个 fragment 输出一个通道的一项统计：行内线性下标
// idx = ((gi*5)+stat)*4 + ci（gi 通道组、stat 统计项、ci 组内通道），
// 一次绘制只画目标纹理的一行（一个带），故下标即 fragment 的 x 坐标。
// 纹素 RGBA 四字节 = 该 fp32 部分和的 IEEE754 小端字节（写 k/255
// 精确往返，同 fp16 打包的读侧 floor(x*255+0.5) 约定）。
// stat 顺序：0=Σa 1=Σa² 2=Σb 3=Σb² 4=Σab。
#include <flutter/runtime_effect.glsl>

precision highp float;
precision highp int;

uniform vec2 uInSize;   // 输入物理纹理 (TW, TH)（A/B 同尺寸同布局）
uniform vec2 uInDims;   // 输入逻辑空间尺寸 (W, H)
uniform sampler2D uInA;
uniform sampler2D uInB;

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

// 输入特征图：取像素 (ix,iy) 的通道 4gi..4gi+3（SkSL 不允许 sampler2D
// 作函数参数，A/B 两路各写一份）。
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

void main() {
  float idx = floor(FlutterFragCoord().x);
  float gi = floor(idx / 20.0);
  float rem = idx - gi * 20.0;
  float stat = floor(rem / 4.0);
  float ci = rem - stat * 4.0;

  // Kahan 补偿求和（单通道 fp32 累加数十万个样本时把误差压到 ~1e-7
  // 相对量级，避免朴素顺序累加的 ~1e-2 漂移）。
  float sum = 0.0;
  float comp = 0.0;
  // SkSL 要求循环上界为常量表达式：以常量大界 + 运行时 break 实现
  // （H、W ≤ 8192 恒成立——纹理边长上限）。
  for (float y = 0.0; y < 8192.0; y += 1.0) {
    if (y >= uInDims.y) break;
    for (float x = 0.0; x < 8192.0; x += 1.0) {
      if (x >= uInDims.x) break;
      vec4 va = fetchA4(gi, x, y);
      vec4 vb = fetchB4(gi, x, y);
      float a = ci < 0.5 ? va.r : ci < 1.5 ? va.g : ci < 2.5 ? va.b : va.a;
      float b = ci < 0.5 ? vb.r : ci < 1.5 ? vb.g : ci < 2.5 ? vb.b : vb.a;
      float v = stat < 0.5 ? a : stat < 1.5 ? a * a : stat < 2.5 ? b
                : stat < 3.5 ? b * b : a * b;
      float d = v - comp;
      float t = sum + d;
      comp = (t - sum) - d;
      sum = t;
    }
  }

  // fp32 位 → RGBA8 四字节（小端）：手动 IEEE754 分解（SkSL 不支持
  // uint/floatBitsToUint；exp2/log2 为 2 的幂运算无精度损失，
  // 中间量均在 fp32 精确表示范围内）。subnormal 输入（|x|<2^-126）
  // 输出全 0——统计量级不会出现。
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

