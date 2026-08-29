// 三通道合路（GPU 版，对应 hsl_combiner / rgb_combiner / yuv_combiner
// 的 16 位交织路径）：三路各来自 mono 打包纹理，打包交织为三通道纹理。
// 未连接通道填对应缺省值（uDef0/1/2）：HSL/RGB 全 0，YUV 的 U/V 为
// 色度中点（maxValue>>1）——与各自 CPU 语义一致。
#include <flutter/runtime_effect.glsl>

precision highp float;
precision highp int;

uniform float uTexW;    // mono 打包纹理宽（w/2，三路同尺寸）
uniform float uTexH;
uniform float uHas0;    // 1=通道 0 输入已连接
uniform float uHas1;    // 1=通道 1 输入已连接
uniform float uHas2;    // 1=通道 2 输入已连接
uniform float uDef0;    // 通道 0 未连接时的填充值
uniform float uDef1;    // 通道 1 未连接时的填充值
uniform float uDef2;    // 通道 2 未连接时的填充值
uniform float uOutTexW; // 输出三通道打包纹理宽（w*3/2）
uniform sampler2D uTex0;
uniform sampler2D uTex1;
uniform sampler2D uTex2;

out vec4 fragColor;

// 注意：sampler 不能作函数参数（SkSL 转译不支持），三个采样器各写一份。
// px*2 恒为偶数 → 值落在单个纹素的 RG（sub 0）或 BA（sub 2），一次采样；
// 寻址用 int（12MP 帧线性下标超 2^24，float 会丢精度）。

float fetch0(int px) {
  int byteOff = px * 2;
  int texel = byteOff / 4;
  int sub = byteOff - texel * 4;
  int tw = int(uTexW);
  vec2 uv = vec2((float(texel - texel / tw * tw) + 0.5) / uTexW,
                 (float(texel / tw) + 0.5) / uTexH);
  vec4 t = floor(texture(uTex0, uv) * 255.0 + 0.5);
  return sub == 0 ? t.r + t.g * 256.0 : t.b + t.a * 256.0;
}

float fetch1(int px) {
  int byteOff = px * 2;
  int texel = byteOff / 4;
  int sub = byteOff - texel * 4;
  int tw = int(uTexW);
  vec2 uv = vec2((float(texel - texel / tw * tw) + 0.5) / uTexW,
                 (float(texel / tw) + 0.5) / uTexH);
  vec4 t = floor(texture(uTex1, uv) * 255.0 + 0.5);
  return sub == 0 ? t.r + t.g * 256.0 : t.b + t.a * 256.0;
}

float fetch2(int px) {
  int byteOff = px * 2;
  int texel = byteOff / 4;
  int sub = byteOff - texel * 4;
  int tw = int(uTexW);
  vec2 uv = vec2((float(texel - texel / tw * tw) + 0.5) / uTexW,
                 (float(texel / tw) + 0.5) / uTexH);
  vec4 t = floor(texture(uTex2, uv) * 255.0 + 0.5);
  return sub == 0 ? t.r + t.g * 256.0 : t.b + t.a * 256.0;
}

float kernel(int idx) {
  int p = idx / 3;
  int ch = idx - p * 3;
  if (ch == 0) return uHas0 > 0.5 ? fetch0(p) : uDef0;
  if (ch == 1) return uHas1 > 0.5 ? fetch1(p) : uDef1;
  return uHas2 > 0.5 ? fetch2(p) : uDef2;
}

void main() {
  vec2 fc = floor(FlutterFragCoord().xy);
  int texel = int(fc.y) * int(uOutTexW) + int(fc.x);
  float vA = kernel(texel * 2);
  float vB = kernel(texel * 2 + 1);
  float hiA = floor(vA / 256.0), loA = vA - hiA * 256.0;
  float hiB = floor(vB / 256.0), loB = vB - hiB * 256.0;
  fragColor = vec4(loA / 255.0, hiA / 255.0, loB / 255.0, hiB / 255.0);
}
