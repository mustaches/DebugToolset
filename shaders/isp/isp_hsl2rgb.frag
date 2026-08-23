// HSL→RGB（GPU 版，对应 hslToRgb）：H 色环取模，S/L 归一化， hueToRgb
// 三段插值，四舍五入钳位 maxValue。浮点近似，±1 LSB。
#include <flutter/runtime_effect.glsl>

precision highp float;
precision highp int;

uniform float uTexW;   // HSL 打包纹理宽（w*3/2）
uniform float uTexH;
uniform float uWidth;
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

float hueToRgb(float p, float q, float t) {
  float tt = t;
  if (tt < 0.0) tt += 1.0;
  if (tt > 1.0) tt -= 1.0;
  if (tt < 1.0 / 6.0) return p + (q - p) * 6.0 * tt;
  if (tt < 0.5) return q;
  if (tt < 2.0 / 3.0) return p + (q - p) * (2.0 / 3.0 - tt) * 6.0;
  return p;
}

float kernel(int idx) {
  int p = idx / 3;
  int ch = idx - p * 3;
  float inv = 1.0 / uMaxValue;
  float h = fract(fetchVal(p * 3) * inv);
  float s = fetchVal(p * 3 + 1) * inv;
  float l = fetchVal(p * 3 + 2) * inv;
  float o;
  if (s == 0.0) {
    o = l;
  } else {
    float q = l < 0.5 ? l * (1.0 + s) : l + s - l * s;
    float pp = 2.0 * l - q;
    if (ch == 0) {
      o = hueToRgb(pp, q, h + 1.0 / 3.0);
    } else if (ch == 1) {
      o = hueToRgb(pp, q, h);
    } else {
      o = hueToRgb(pp, q, h - 1.0 / 3.0);
    }
  }
  return clamp(floor(o * uMaxValue + 0.5), 0.0, uMaxValue);
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
