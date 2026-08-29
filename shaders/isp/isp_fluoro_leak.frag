// 激发泄漏扣除（GPU 版，对应 applyFluoroLeak）：mono 逐像素
// v' = max(0, v - uSub)，uSub = min(level, maxSub) 由调用方收敛。
#include <flutter/runtime_effect.glsl>

precision highp float;
precision highp int;

uniform float uTexW;    // mono 打包纹理宽（w/2）
uniform float uTexH;
uniform float uSub;
uniform sampler2D uTex;

out vec4 fragColor;

void main() {
  vec2 fc = floor(FlutterFragCoord().xy);
  int tw = int(uTexW);
  int texel = int(fc.y) * tw + int(fc.x);
  vec2 uv = vec2((float(texel - texel / tw * tw) + 0.5) / uTexW,
                 (float(texel / tw) + 0.5) / uTexH);
  vec4 t = floor(texture(uTex, uv) * 255.0 + 0.5);
  float vA = floor(max(t.r + t.g * 256.0 - uSub, 0.0) + 0.5);
  float vB = floor(max(t.b + t.a * 256.0 - uSub, 0.0) + 0.5);
  float hiA = floor(vA / 256.0), loA = vA - hiA * 256.0;
  float hiB = floor(vB / 256.0), loB = vB - hiB * 256.0;
  fragColor = vec4(loA / 255.0, hiA / 255.0, loB / 255.0, hiB / 255.0);
}
