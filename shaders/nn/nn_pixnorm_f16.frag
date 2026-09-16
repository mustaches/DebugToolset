// NN 逐像素通道 L2 范数图（LPIPS 打分头 GPU 归约快路径，优化 16）。
//
// 对 fp16 打包特征图（折叠线性布局：逻辑纹素 T=(gi*H+y)*W+x 装通道
// 4gi..4gi+3 的 4 个 half = 2 个物理纹素）计算每个空间位置的通道
// L2 范数 norm = sqrt(Σ_c x²) + 1e-10（与 nn ops.l2NormalizeChannels
// 同口径；fp32 累加，通道数 ≤ 数百项，误差 ~1e-6 相对量级，远小于
// fp16 存储噪声）。
//
// 输出：每像素 2 个物理纹素（idx=2*i 为图 A 范数、2*i+1 为图 B），
// 纹素 RGBA 四字节 = fp32 的 IEEE754 小端字节（手动位分解——SkSL
// 不支持 uint/floatBitsToUint；norm ≥1e-10 为正规格化数）。
#include <flutter/runtime_effect.glsl>

precision highp float;
precision highp int;

uniform vec2 uInSize;    // 输入特征图物理纹理 (TW, TH)（A/B 同布局）
uniform vec2 uInDims;    // 输入逻辑空间尺寸 (W, H)
uniform vec2 uNormSize;  // 输出范数图物理纹理 (TW, TH)
uniform float uGroups;   // 通道组数（channelsPadded/4）
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
  vec2 fc = floor(FlutterFragCoord().xy);
  float p = fc.y * uNormSize.x + fc.x;
  float i = floor(p * 0.5);       // 像素下标
  float side = p - i * 2.0;       // 0=图 A 范数, 1=图 B
  float iy = floor(i / uInDims.x);
  float ix = i - iy * uInDims.x;

  float ss = 0.0;
  // SkSL 要求循环上界为常量表达式：常量大界 + 运行时 break。
  for (float g = 0.0; g < 8192.0; g += 1.0) {
    if (g >= uGroups) break;
    vec4 v = side < 0.5 ? fetchA4(g, ix, iy) : fetchB4(g, ix, iy);
    ss += v.r * v.r + v.g * v.g + v.b * v.b + v.a * v.a;
  }
  float nrm = sqrt(ss) + 1e-10;

  // fp32 位 → RGBA8 四字节（小端，手动 IEEE754 分解）。
  float sgn = 0.0;
  float av = nrm;
  if (nrm < 0.0) { sgn = 128.0; av = -nrm; }
  float e = clamp(floor(log2(av)) + 127.0, 1.0, 254.0);
  float mant = floor((av / exp2(e - 127.0) - 1.0) * 8388608.0 + 0.5);
  if (mant >= 8388608.0) { mant = 0.0; e += 1.0; }
  float b0 = mod(mant, 256.0);
  float b1 = mod(floor(mant / 256.0), 256.0);
  float b2 = mod(floor(mant / 65536.0), 128.0) + mod(e, 2.0) * 128.0;
  float b3 = floor(e / 2.0) + sgn;
  fragColor = vec4(b0, b1, b2, b3) / 255.0;
}
