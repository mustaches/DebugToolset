// 多段色彩均衡器（GPU 版，对应 CPU multiBandLuts + applyHslBandLuts）：
// 多组（≤8 段）高斯色相带的并联/串联合成。段参数经 uBands 数组传入
//（每段 5 个 float：色相中心°、σ°=45°/q、ΔH°、S 增益、L 增益），
// uCount 为有效段数（恒等段已由调用侧跳过不上传——其对并联求和/串联
// 级联均无贡献），uMode 0=并联 1=串联。
// 数学口径与 CPU 一致：w = exp(-0.5·(Δ/σ)²)，Δ 为色环最短角距；
// 并联：ΔH 加权求和后 clamp ±180°，乘子 1+Σw·(g−1) clamp 0..5；
// 串联：按段序级联，后段在前段更新后的中间色相（mod 360 归一）上取
// 权重，增益乘性合成，最终偏移取首尾色环最短路径。
// 单段退化（uCount=1）与 isp_hsl_band.frag 同结果。GPU 权重 float
// 直求 exp（CPU 为 double 烘焙 LUT 查表），精度口径同其它 GPU 节点
//（对拍容差 ±2 LSB）。
// 注意：SkSL 不支持动态下标索引 uniform 数组，8 段循环经宏完全展开、
// 数组下标全部为字面常量（PAR_BAND/SER_BAND，编译期由预处理器展开）。
#include <flutter/runtime_effect.glsl>

precision highp float;
precision highp int;

uniform float uTexW;   // HSL 打包纹理宽（w*3/2）
uniform float uTexH;
uniform float uWidth;
uniform float uMaxValue;
uniform float uCount;    // 有效段数（1..8）
uniform float uMode;     // 0=并联 1=串联
uniform float uBands[40]; // 8 段 × 5 参数（h°、σ°、dh°、s、l）
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

// 段在色相 hDeg（度）上的高斯权重：色环最短角距（center/sigma 以参数
// 传入——数组下标必须在调用处保持字面常量）。
float bandWeight(float center, float sigma, float hDeg) {
  float d = mod(abs(hDeg - center), 360.0);
  if (d > 180.0) d = 360.0 - d;
  float x = d / sigma;
  return exp(-0.5 * x * x);
}

// 并联段累加：第 B 段（字面常量下标）在原 H 上取权重加权求和。
#define PAR_BAND(B) \
  if (B < cnt) { \
    float w = bandWeight(uBands[B * 5], uBands[B * 5 + 1], hDeg); \
    dhSum += w * uBands[B * 5 + 2]; \
    sSum += w * (uBands[B * 5 + 3] - 1.0); \
    lSum += w * (uBands[B * 5 + 4] - 1.0); \
  }

// 串联段级联：第 B 段在前段更新后的中间色相 hCur 上取权重，增益乘性
// 合成，hCur 模 360 归一（GLSL mod 对正模数恒非负）。
#define SER_BAND(B) \
  if (B < cnt) { \
    float w = bandWeight(uBands[B * 5], uBands[B * 5 + 1], hCur); \
    sAcc *= 1.0 + w * (uBands[B * 5 + 3] - 1.0); \
    lAcc *= 1.0 + w * (uBands[B * 5 + 4] - 1.0); \
    hCur = mod(hCur + w * uBands[B * 5 + 2], 360.0); \
  }

float kernel(int idx) {
  int ch = idx - idx / 3 * 3;
  float v = fetchVal(idx);
  // 同像素的 H：ch 0/1/2 分别回退 0/1/2 个值
  float hDeg = fetchVal(idx - ch) * 360.0 / uMaxValue;
  int cnt = int(uCount);
  float shiftDeg, sMul, lMul;
  if (uMode < 0.5) {
    // 并联：全部段在原 H 上各取权重，加权求和。
    float dhSum = 0.0, sSum = 0.0, lSum = 0.0;
    PAR_BAND(0) PAR_BAND(1) PAR_BAND(2) PAR_BAND(3)
    PAR_BAND(4) PAR_BAND(5) PAR_BAND(6) PAR_BAND(7)
    shiftDeg = clamp(dhSum, -180.0, 180.0);
    sMul = clamp(1.0 + sSum, 0.0, 5.0);
    lMul = clamp(1.0 + lSum, 0.0, 5.0);
  } else {
    // 串联：按段序级联，后段在前段更新后的中间色相上取权重。
    float hCur = hDeg;
    float sAcc = 1.0, lAcc = 1.0;
    SER_BAND(0) SER_BAND(1) SER_BAND(2) SER_BAND(3)
    SER_BAND(4) SER_BAND(5) SER_BAND(6) SER_BAND(7)
    // 首尾色环最短路径（mod 结果恒 [0,360)，只需单边归一）。
    float dd = mod(hCur - hDeg, 360.0);
    if (dd > 180.0) dd -= 360.0;
    shiftDeg = dd;
    sMul = clamp(sAcc, 0.0, 5.0);
    lMul = clamp(lAcc, 0.0, 5.0);
  }
  if (ch == 0) {
    float m = uMaxValue + 1.0;
    float r = v + shiftDeg / 360.0 * uMaxValue;
    // Dart round() 为「远离零取整」；floor(x+0.5) 仅对非负等价。
    float shifted = sign(r) * floor(abs(r) + 0.5);
    return mod(mod(shifted, m) + m, m);
  }
  float mul = ch == 1 ? sMul : lMul;
  return clamp(floor(v * mul + 0.5), 0.0, uMaxValue);
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
