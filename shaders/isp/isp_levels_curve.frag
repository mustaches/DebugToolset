// 曲线调节器（GPU 版，对应 applyLevelsCurve）：RGB 逐通道 LUT 映射。
// LUT 为 0..4095 共 4096 级 16 位打包纹理（2048×1），由调用方用
// levelsCurveLut 在 CPU 生成（样条/贝塞尔/线段/gamma 四种生成公式
// 与 CPU 同一函数）。映射与 CPU 同式：
// idx = round(v × 4095 / maxValue)，out = round(lut[idx] × maxValue / 4095)。
#include <flutter/runtime_effect.glsl>

precision highp float;
precision highp int;

uniform float uTexW;    // RGB 打包纹理宽（w*3/2）
uniform float uTexH;
uniform float uMaxValue;
uniform float uLutTexW; // 2048
uniform sampler2D uTex;
uniform sampler2D uLut;

out vec4 fragColor;

// LUT idx*2 恒为偶数 → 值落在单个纹素的 RG（sub 0）或 BA（sub 2）。
float fetchLut(int idx) {
  int byteOff = idx * 2;
  int texel = byteOff / 4;
  int sub = byteOff - texel * 4;
  int tw = int(uLutTexW);
  vec2 uv = vec2((float(texel - texel / tw * tw) + 0.5) / uLutTexW, 0.5);
  vec4 t = floor(texture(uLut, uv) * 255.0 + 0.5);
  return sub == 0 ? t.r + t.g * 256.0 : t.b + t.a * 256.0;
}

float mapVal(float v) {
  int idx = int(floor(v * 4095.0 / uMaxValue + 0.5));
  return floor(fetchLut(idx) * uMaxValue / 4095.0 + 0.5);
}

void main() {
  // 纹素对齐：输入输出同为三通道打包（同 isp_apply_gains）。
  vec2 fc = floor(FlutterFragCoord().xy);
  int tw = int(uTexW);
  int texel = int(fc.y) * tw + int(fc.x);
  vec2 uv = vec2((float(texel - texel / tw * tw) + 0.5) / uTexW,
                 (float(texel / tw) + 0.5) / uTexH);
  vec4 t = floor(texture(uTex, uv) * 255.0 + 0.5);
  float vA = mapVal(t.r + t.g * 256.0);
  float vB = mapVal(t.b + t.a * 256.0);
  float hiA = floor(vA / 256.0), loA = vA - hiA * 256.0;
  float hiB = floor(vB / 256.0), loB = vB - hiB * 256.0;
  fragColor = vec4(loA / 255.0, hiA / 255.0, loB / 255.0, hiB / 255.0);
}
