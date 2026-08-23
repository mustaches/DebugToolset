// 通道抽取（GPU 版，对应 yuv_splitter 的 out_y 等）：三通道交织打包纹理
// 抽一个通道 → mono 打包纹理（宽 w/2）。
#include <flutter/runtime_effect.glsl>

precision highp float;
precision highp int;

uniform float uTexW;    // 输入三通道打包纹理宽（w*3/2）
uniform float uTexH;
uniform float uWidth;
uniform float uChannel; // 抽取通道（0/1/2）
uniform float uOutTexW; // 输出 mono 打包纹理宽（w/2）
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

void main() {
  vec2 fc = floor(FlutterFragCoord().xy);
  int texel = int(fc.y) * int(uOutTexW) + int(fc.x);
  int ch = int(uChannel);
  int p0 = texel * 2;
  float vA = fetchVal(p0 * 3 + ch);
  float vB = fetchVal((p0 + 1) * 3 + ch);
  float hiA = floor(vA / 256.0), loA = vA - hiA * 256.0;
  float hiB = floor(vB / 256.0), loB = vB - hiB * 256.0;
  fragColor = vec4(loA / 255.0, hiA / 255.0, loB / 255.0, hiB / 255.0);
}
