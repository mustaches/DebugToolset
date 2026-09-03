// 高斯模糊（GPU 版，对应 applyGaussianBlur）：可分离两趟高斯卷积——
// 同一 shader 跑两次：uDir=0 水平趟、uDir=1 垂直趟，结果与直接二维
// 高斯一致；权重按 σ 逐 tap 计算 exp(−i²/2σ²)、wsum 归一化；边界复制
// （采样坐标钳制到图内，与 CPU 的窗口钳制等价）。
// 强度混合在垂直趟完成：out = orig×(1−strength) + blurred×strength，
// orig 取 uTexOrig（模糊前原帧纹理，与本趟输入同打包尺寸）。
// 通道间独立：RGB/YUV/HSL 交织数据按 channels=3、Mono 按 channels=1。
// 已知口径差异：水平趟结果经 16 位打包往返一次（CPU 中间为 double），
// 与 CPU 逐值差 ≤1。
#include <flutter/runtime_effect.glsl>

precision highp float;
precision highp int;

uniform float uTexW;     // 打包纹理宽（w*channels/2）
uniform float uTexH;     // 打包纹理高（= 帧高）
uniform float uWidth;    // 帧宽（像素）
uniform float uChannels; // 通道数（RGB/YUV/HSL=3，Mono=1）
uniform float uDir;      // 0=水平趟，1=垂直趟
uniform float uSigma;    // 高斯 σ
uniform float uStrength; // 混合强度（仅垂直趟生效）
uniform sampler2D uTex;     // 本趟输入（垂直趟时为水平趟结果）
uniform sampler2D uTexOrig; // 模糊前原帧（垂直趟强度混合用）

out vec4 fragColor;

// 注：SkSL 不支持 sampler2D 作函数参数，uTex/uTexOrig 各写一个取数函数。
float fetchVal(int idx) {
  int byteOff = idx * 2;
  int texel = byteOff / 4;
  int sub = byteOff - texel * 4;
  int tw = int(uTexW);
  vec2 uv = vec2((float(texel - texel / tw * tw) + 0.5) / uTexW,
                 (float(texel / tw) + 0.5) / uTexH);
  vec4 c = floor(texture(uTex, uv) * 255.0 + 0.5);
  return sub == 0 ? c.r + c.g * 256.0 : c.b + c.a * 256.0;
}

float fetchOrig(int idx) {
  int byteOff = idx * 2;
  int texel = byteOff / 4;
  int sub = byteOff - texel * 4;
  int tw = int(uTexW);
  vec2 uv = vec2((float(texel - texel / tw * tw) + 0.5) / uTexW,
                 (float(texel / tw) + 0.5) / uTexH);
  vec4 c = floor(texture(uTexOrig, uv) * 255.0 + 0.5);
  return sub == 0 ? c.r + c.g * 256.0 : c.b + c.a * 256.0;
}

float blurVal(int idx) {
  int chs = int(uChannels);
  int p = idx / chs;
  int ch = idx - p * chs;
  int w = int(uWidth);
  int hgt = int(uTexH);
  int x = p - p / w * w;
  int y = p / w;
  float sigma = uSigma;
  int r = int(ceil(3.0 * sigma));
  float sum = 0.0;
  float wsum = 0.0;
  // 常量循环界（σ ≤ 10 → r ≤ 30，与节点参数 max 一致），越界/超半径
  // 迭代用 continue 跳过——SkSL 后端不接受动态循环边界。
  for (int i = -30; i <= 30; i++) {
    if (i < -r || i > r) continue;
    float wgt = exp(-float(i * i) / (2.0 * sigma * sigma));
    int sx, sy;
    if (uDir < 0.5) {
      // 边界复制（SkSL 无 int 版 clamp/min/max，经 float 转换）。
      sx = int(clamp(float(x + i), 0.0, float(w - 1)));
      sy = y;
    } else {
      sx = x;
      sy = int(clamp(float(y + i), 0.0, float(hgt - 1)));
    }
    sum += fetchVal((sy * w + sx) * chs + ch) * wgt;
    wsum += wgt;
  }
  float blurred = sum / wsum;
  if (uDir < 0.5) return blurred; // 水平趟不混合
  float orig = fetchOrig(idx);
  return orig + (blurred - orig) * uStrength;
}

void main() {
  vec2 fc = floor(FlutterFragCoord().xy);
  int texel = int(fc.y) * int(uTexW) + int(fc.x);
  float vA = floor(blurVal(texel * 2) + 0.5);
  float vB = floor(blurVal(texel * 2 + 1) + 0.5);
  float hiA = floor(vA / 256.0), loA = vA - hiA * 256.0;
  float hiB = floor(vB / 256.0), loB = vB - hiB * 256.0;
  fragColor = vec4(loA / 255.0, hiA / 255.0, loB / 255.0, hiB / 255.0);
}
