// 黑电平校正（GPU 版，对应 applyBlackLevel）：mosaic/mono 16 位打包纹理
// 逐相位减偏移，<=0 钳 0，否则四舍五入。
//
// 打包约定：帧字节流（uint16 小端）原样视为 RGBA8888 纹理，每纹素装 2 个
// 16 位值（R,G=值A 的 lo,hi；B,A=值B 的 lo,hi）。mono/mosaic 纹理宽 w/2。
// 寻址全部用 int：12MP 三通道帧的线性下标超过 2^24，float 会丢精度。
#include <flutter/runtime_effect.glsl>

precision highp float;
precision highp int;

uniform float uTexW;   // 打包纹理宽（纹素）
uniform float uTexH;   // 打包纹理高
uniform float uWidth;  // 逻辑像素宽 w
uniform float uMono;   // 1=mono（全像素统一偏移 uOff0），0=mosaic 按 2x2 相位
uniform float uOff0;   // 相位 0 (x偶,y偶) 偏移 / mono 统一偏移
uniform float uOff1;   // 相位 1 (x奇,y偶)
uniform float uOff2;   // 相位 2 (x偶,y奇)
uniform float uOff3;   // 相位 3 (x奇,y奇)
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

float phaseOffset(int px) {
  if (uMono > 0.5) return uOff0;
  int w = int(uWidth);
  int x = px - px / w * w;
  int y = px / w;
  int phase = (y - y / 2 * 2) * 2 + (x - x / 2 * 2);
  if (phase == 0) return uOff0;
  if (phase == 1) return uOff1;
  if (phase == 2) return uOff2;
  return uOff3;
}

float kernel(int idx) {
  float v = fetchVal(idx) - phaseOffset(idx);
  return v <= 0.0 ? 0.0 : floor(v + 0.5);
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
