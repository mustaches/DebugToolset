// YUV 调节器（GPU 版，对应 adjustYuv）：Y 乘增益；U/V 围绕中点 uHalf
// 缩放（色度增益不改变中性色点），四舍五入钳位 maxValue。
#include <flutter/runtime_effect.glsl>

precision highp float;
precision highp int;

uniform float uTexW;   // YUV 打包纹理宽（w*3/2）
uniform float uTexH;
uniform float uWidth;
uniform float uMaxValue;
uniform float uHalf;   // maxValue>>1
uniform float uYGain;
uniform float uUGain;
uniform float uVGain;
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

float kernel(int idx) {
  int ch = idx - idx / 3 * 3;
  float v = fetchVal(idx);
  float o;
  if (ch == 0) {
    o = v * uYGain;
  } else {
    float gain = ch == 1 ? uUGain : uVGain;
    o = uHalf + (v - uHalf) * gain;
  }
  return clamp(floor(o + 0.5), 0.0, uMaxValue);
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
