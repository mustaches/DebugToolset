// 激发归一化增益施加（GPU 版，对应 applyFluoroNormalize 的增益施加
// 部分）：mono 逐像素 v' = clamp(v × uGain, 0, uMaxValue)。全帧均值
// 统计（聚集操作）由调用方 CPU 桥接完成，增益作为 uniform 传入。
#include <flutter/runtime_effect.glsl>

precision highp float;
precision highp int;

uniform float uTexW;    // mono 打包纹理宽（w/2）
uniform float uTexH;
uniform float uGain;
uniform float uMaxValue;
uniform sampler2D uTex;

out vec4 fragColor;

void main() {
  vec2 fc = floor(FlutterFragCoord().xy);
  int tw = int(uTexW);
  int texel = int(fc.y) * tw + int(fc.x);
  vec2 uv = vec2((float(texel - texel / tw * tw) + 0.5) / uTexW,
                 (float(texel / tw) + 0.5) / uTexH);
  vec4 t = floor(texture(uTex, uv) * 255.0 + 0.5);
  float vA = floor(clamp((t.r + t.g * 256.0) * uGain, 0.0, uMaxValue) + 0.5);
  float vB = floor(clamp((t.b + t.a * 256.0) * uGain, 0.0, uMaxValue) + 0.5);
  float hiA = floor(vA / 256.0), loA = vA - hiA * 256.0;
  float hiB = floor(vB / 256.0), loB = vB - hiB * 256.0;
  fragColor = vec4(loA / 255.0, hiA / 255.0, loB / 255.0, hiB / 255.0);
}
