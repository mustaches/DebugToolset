// 加法器（GPU 版，对应 isp_kernels.dart 的 blendMono）：两路 mono
// 打包纹理（w/2 × h，同尺寸由调用方校验）逐像素平衡加权混合
// out = clamp(a×balance + b×(1−balance), 0, maxValue)（两路增益
// 总和恒为 1）。注：sampler 不作为函数参数传递（SkSL 转译不支持），
// 两路采样内联展开。
#include <flutter/runtime_effect.glsl>

precision highp float;
precision highp int;

uniform float uTexW;    // mono 打包纹理宽（w/2）
uniform float uTexH;
uniform float uBalance; // 源1 平衡增益（源2 = 1−balance）
uniform float uMaxValue;
uniform sampler2D uTexA;
uniform sampler2D uTexB;

out vec4 fragColor;

void main() {
  vec2 fc = floor(FlutterFragCoord().xy);
  int tw = int(uTexW);
  int texel = int(fc.y) * tw + int(fc.x);
  // 取一个纹素内的两个 16 位 mono 值（RG / BA）。
  vec2 uv = vec2((float(texel - texel / tw * tw) + 0.5) / uTexW,
                 (float(texel / tw) + 0.5) / uTexH);
  vec4 ta = floor(texture(uTexA, uv) * 255.0 + 0.5);
  vec4 tb = floor(texture(uTexB, uv) * 255.0 + 0.5);
  float wb = 1.0 - uBalance;
  float vA = floor(clamp(
      (ta.r + ta.g * 256.0) * uBalance + (tb.r + tb.g * 256.0) * wb,
      0.0, uMaxValue) + 0.5);
  float vB = floor(clamp(
      (ta.b + ta.a * 256.0) * uBalance + (tb.b + tb.a * 256.0) * wb,
      0.0, uMaxValue) + 0.5);
  float hiA = floor(vA / 256.0), loA = vA - hiA * 256.0;
  float hiB = floor(vB / 256.0), loB = vB - hiB * 256.0;
  fragColor = vec4(loA / 255.0, hiA / 255.0, loB / 255.0, hiB / 255.0);
}
