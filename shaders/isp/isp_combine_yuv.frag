// YUV 合路（GPU 版，对应 yuv_combiner 的 16 位交织路径）：Y 来自 mono
// 打包纹理（未连接时填 0），U/V 从上游 YUV 打包纹理原样抽取（未连接时
// 填 uMid = maxValue>>1）。
#include <flutter/runtime_effect.glsl>

precision highp float;
precision highp int;

uniform float uYTexW;   // Y mono 打包纹理宽（w/2）
uniform float uYTexH;
uniform float uUvTexW;  // UV 源三通道打包纹理宽（w*3/2）
uniform float uUvTexH;
uniform float uWidth;
uniform float uHasY;    // 1=Y 输入已连接
uniform float uHasUV;   // 1=U/V 输入已连接（同源 YUV 纹理）
uniform float uMid;     // 色度默认值（maxValue>>1）
uniform float uOutTexW; // 输出 YUV 打包纹理宽（w*3/2）
uniform sampler2D uYTex;
uniform sampler2D uUvTex;

out vec4 fragColor;

// 注意：sampler 不能作函数参数（SkSL 转译不支持），两个采样器各写一份。
// 下标*2 恒为偶数 → 值落在单个纹素的 RG/BA 内，一次采样；寻址用 int
//（12MP 帧线性下标超 2^24，float 会丢精度）。

float fetchY(int px) {
  int byteOff = px * 2;
  int texel = byteOff / 4;
  int sub = byteOff - texel * 4;
  int tw = int(uYTexW);
  vec2 uv = vec2((float(texel - texel / tw * tw) + 0.5) / uYTexW,
                 (float(texel / tw) + 0.5) / uYTexH);
  vec4 t = floor(texture(uYTex, uv) * 255.0 + 0.5);
  return sub == 0 ? t.r + t.g * 256.0 : t.b + t.a * 256.0;
}

float fetchUv(int idx) {
  int byteOff = idx * 2;
  int texel = byteOff / 4;
  int sub = byteOff - texel * 4;
  int tw = int(uUvTexW);
  vec2 uv = vec2((float(texel - texel / tw * tw) + 0.5) / uUvTexW,
                 (float(texel / tw) + 0.5) / uUvTexH);
  vec4 t = floor(texture(uUvTex, uv) * 255.0 + 0.5);
  return sub == 0 ? t.r + t.g * 256.0 : t.b + t.a * 256.0;
}

float kernel(int idx) {
  int p = idx / 3;
  int ch = idx - p * 3;
  if (ch == 0) return uHasY > 0.5 ? fetchY(p) : 0.0;
  if (uHasUV < 0.5) return uMid;
  return fetchUv(p * 3 + ch);
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
