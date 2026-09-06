// NN conv2d GPU 版（fp16 打包路径，对应 GpuNnBackend.conv2dAsync）：
// kernel ≤7x7（含非对称 1x7/7x1 与原生 1x1），pad ≤3，步长由 uStride
// 指定（1.0 或 2.0），可选 uRelu 融合（末 pass 加 bias 后 max(·,0)）。
// （历史上只支持 3x3/p1，文件名沿用未改。）
//
// 背景：本机 Impeller（flutter test 与真实 Windows 桌面一致）的离屏渲染
// 目标只有 RGBA8——toImageSync(targetFormat: rgbaFloat32) 被静默降级为
// RGBA8（输出钳位 [0,1] 并 8bit 量化），故中间张量走 fp16 打包：
// 每个 fp32 值编码为 IEEE half 的 16bit，按小端装入 RGBA8 纹素
// （R=lo, G=hi；B/A 为下一个 half），每物理纹素 2 个 half。
//
// 折叠布局（规避 8192 纹理宽上限，任何 NCHW 形状都摊平为线性 texel 流）：
// - 特征图（cin%4==0）：逻辑纹素 T=(gi*H+y)*W+x 装通道 4gi..4gi+3 的
//   4 个 half = 2 个物理纹素 P=2T,2T+1；物理纹理宽 uInTW，按 P 线性折叠。
// - 权重：逻辑单元 cell=((go*cinG+gi)*TAPS+tap)*4+co 装
//   w[4go+co][4gi..4gi+3][tap] 的 4 个 half = 2 个物理纹素，宽 uWgtTW
//   线性折叠（本 pass 的 cinG）；TAPS = kH*kW（= uKSize.x*uKSize.y），
//   tap = r*kW + c 行主序。
// - 偏置：cell=go，宽 uBiasTW=coutG*2，高 1。
// - 输出：与特征图同布局（go 替换 gi），宽 uOutTW；多 pass 累加时
//   uAccum 为上一 pass 的输出纹理（同布局）。
//
// SkSL 限制：循环界必须为常量（MAX_CG），超出 uCinG 的迭代 break；sampler
// 不能作函数参数，故四个取数函数各自展开。
#include <flutter/runtime_effect.glsl>

precision highp float;
precision highp int;

uniform vec2 uInSize;    // 输入物理纹理 (TW, TH)
uniform vec2 uDims;      // 特征图空间尺寸 (W, H)
uniform float uCinG;     // 本 pass 输入通道组数（≤ MAX_CG）
uniform float uGiBase;   // 本 pass 起始输入通道组（多 pass 累加）
uniform vec2 uWgtSize;   // 权重物理纹理 (TW, TH)
uniform vec2 uOutSize;   // 输出物理纹理 (TW, TH)
uniform float uHasAccum; // 1=累加 uAccum（非首 pass）
uniform float uAddBias;  // 1=加偏置（末 pass）
uniform float uBiasTW;   // 偏置纹理宽（coutG*2，高 1）
uniform float uYOff;     // 输入垂直偏移：分块 padded 输入为 1.0（行 0 为
                         // 上 halo），单纹理路径为 0.0（行为与旧版逐位一致）
uniform vec2 uOutDims;   // 输出空间尺寸 (W2, Ho)；单纹理路径与 uDims 相同，
                         // 分块路径 Ho = 带高（输入为 padH = 带高+2 的
                         // padded 带，halo 行已由 stitch 写好，越界检查
                         // 不会触发，等价于零填充）
uniform float uStride;   // 空间步长（1.0 或 2.0，H/W 同值；1.0 时位级不变）
uniform vec2 uKSize;     // 卷积核 (KH, KW)（≤7；3x3 以外用于 InceptionV3）
uniform vec2 uPad;       // 填充 (padH, padW)（≤3）
uniform float uRelu;     // 1=末 pass 加 bias 后 max(·,0)（BasicConv2d 融合）
uniform sampler2D uIn;
uniform sampler2D uWgt;
uniform sampler2D uAccum;
uniform sampler2D uBias;

out vec4 fragColor;

const int MAX_CG = 64; // 单 pass 最大输入通道组数（cin ≤ 256/pass）

// half bits(0..65535, 以 float 携带) → float。
float h2f(float v) {
  float s = 1.0;
  if (v >= 32768.0) { s = -1.0; v -= 32768.0; }
  float e = floor(v / 1024.0);
  float m = v - e * 1024.0;
  if (e < 0.5) return s * m * 5.9604644775390625e-08; // 次正规: m*2^-24
  if (e > 30.5) return s * 65504.0;                   // inf/nan 钳位
  return s * (1024.0 + m) * pow(2.0, e - 25.0);       // (1+m/1024)*2^(e-15)
}

// float → half bits(0..65535, 以 float 携带)。
float f2h(float x) {
  float s = 0.0;
  float av = x;
  if (x < 0.0) { s = 32768.0; av = -x; }
  if (av >= 65520.0) return s + 31744.0; // 上溢 → inf
  if (av < 6.103515625e-05) {            // 次正规/零
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

vec4 decode2(vec4 t) {
  return vec4(h2f(t.r + t.g * 256.0), h2f(t.b + t.a * 256.0), 0.0, 0.0);
}

// 输入特征图：取像素 (ix,iy) 的通道 4gi..4gi+3。
vec4 fetchIn4(float gi, float ix, float iy) {
  float t = (gi * uDims.y + iy) * uDims.x + ix;
  vec4 p0 = floor(texture(uIn, uvOf(2.0 * t, uInSize)) * 255.0 + 0.5);
  vec4 p1 = floor(texture(uIn, uvOf(2.0 * t + 1.0, uInSize)) * 255.0 + 0.5);
  return vec4(h2f(p0.r + p0.g * 256.0), h2f(p0.b + p0.a * 256.0),
              h2f(p1.r + p1.g * 256.0), h2f(p1.b + p1.a * 256.0));
}

// 权重：cell 装 4 个输入通道（1 个输出通道）。
vec4 fetchW4(float cell) {
  vec4 p0 = floor(texture(uWgt, uvOf(2.0 * cell, uWgtSize)) * 255.0 + 0.5);
  vec4 p1 =
      floor(texture(uWgt, uvOf(2.0 * cell + 1.0, uWgtSize)) * 255.0 + 0.5);
  return vec4(h2f(p0.r + p0.g * 256.0), h2f(p0.b + p0.a * 256.0),
              h2f(p1.r + p1.g * 256.0), h2f(p1.b + p1.a * 256.0));
}

// 上一 pass 输出（输出布局）逻辑纹素 t 的 4 通道。
vec4 fetchAccum4(float t) {
  vec4 p0 = floor(texture(uAccum, uvOf(2.0 * t, uOutSize)) * 255.0 + 0.5);
  vec4 p1 =
      floor(texture(uAccum, uvOf(2.0 * t + 1.0, uOutSize)) * 255.0 + 0.5);
  return vec4(h2f(p0.r + p0.g * 256.0), h2f(p0.b + p0.a * 256.0),
              h2f(p1.r + p1.g * 256.0), h2f(p1.b + p1.a * 256.0));
}

// 偏置：cell=go 装 4 个输出通道。
vec4 fetchBias4(float go) {
  vec2 sz = vec2(uBiasTW, 1.0);
  vec4 p0 = floor(texture(uBias, uvOf(2.0 * go, sz)) * 255.0 + 0.5);
  vec4 p1 = floor(texture(uBias, uvOf(2.0 * go + 1.0, sz)) * 255.0 + 0.5);
  return vec4(h2f(p0.r + p0.g * 256.0), h2f(p0.b + p0.a * 256.0),
              h2f(p1.r + p1.g * 256.0), h2f(p1.b + p1.a * 256.0));
}

void main() {
  vec2 fc = floor(FlutterFragCoord().xy);
  float p = fc.y * uOutSize.x + fc.x;
  float t = floor(p * 0.5);
  float sub = p - t * 2.0;
  float hw = uOutDims.x * uOutDims.y;
  float go = floor(t / hw);
  float rem = t - go * hw;
  float y = floor(rem / uOutDims.x);
  float x = rem - y * uOutDims.x;

  vec4 acc = vec4(0.0);
  float taps = uKSize.x * uKSize.y;
  for (int gi0 = 0; gi0 < MAX_CG; gi0++) {
    if (float(gi0) >= uCinG) break;
    float gi = uGiBase + float(gi0);
    for (int r = 0; r < 7; r++) {
      if (float(r) >= uKSize.x) break;
      float iy = y * uStride + float(r) - uPad.x + uYOff;
      if (iy < 0.0 || iy >= uDims.y) continue;
      for (int c = 0; c < 7; c++) {
        if (float(c) >= uKSize.y) break;
        float ix = x * uStride + float(c) - uPad.y;
        if (ix < 0.0 || ix >= uDims.x) continue;
        vec4 xv = fetchIn4(gi, ix, iy);
        float cellBase =
            ((go * uCinG + float(gi0)) * taps + float(r) * uKSize.y +
                float(c)) * 4.0;
        vec4 w0 = fetchW4(cellBase);
        vec4 w1 = fetchW4(cellBase + 1.0);
        vec4 w2 = fetchW4(cellBase + 2.0);
        vec4 w3 = fetchW4(cellBase + 3.0);
        acc.x += dot(xv, w0);
        acc.y += dot(xv, w1);
        acc.z += dot(xv, w2);
        acc.w += dot(xv, w3);
      }
    }
  }
  if (uHasAccum > 0.5) acc += fetchAccum4(t);
  if (uAddBias > 0.5) acc += fetchBias4(go);
  if (uRelu > 0.5) acc = max(acc, vec4(0.0));

  float h0 = f2h(sub < 0.5 ? acc.x : acc.z);
  float h1 = f2h(sub < 0.5 ? acc.y : acc.w);
  float hi0 = floor(h0 / 256.0);
  float hi1 = floor(h1 / 256.0);
  fragColor = vec4((h0 - hi0 * 256.0) / 255.0, hi0 / 255.0,
                   (h1 - hi1 * 256.0) / 255.0, hi1 / 255.0);
}
