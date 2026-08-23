// 镜头阴影/平场校正（GPU 版，对应 applyLsc）：以归一化中心为原点的
// 径向二次增益曲面，增益 = 1 + strength*(r/rmax)²，饱和截位 maxValue。
#include <flutter/runtime_effect.glsl>

precision highp float;
precision highp int;

uniform float uTexW;   // mono/mosaic 打包纹理宽（w/2）
uniform float uTexH;
uniform float uWidth;
uniform float uHeight;
uniform float uCx;     // centerX*(w-1)
uniform float uCy;     // centerY*(h-1)
uniform float uRMax2;  // max(cx,w-1-cx)² + max(cy,h-1-cy)²
uniform float uStrength;
uniform float uMaxValue;
uniform sampler2D uTex;

out vec4 fragColor;

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

float kernel(int px) {
  int w = int(uWidth);
  float x = float(px - px / w * w);
  float y = float(px / w);
  float dx = x - uCx;
  float dy = y - uCy;
  float gain = 1.0 + uStrength * (dx * dx + dy * dy) / uRMax2;
  return clamp(floor(fetchVal(px) * gain + 0.5), 0.0, uMaxValue);
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
