// yuv420p 流帧 → 16 位打包 RGB（GPU 播放路径的源转换）：解码器原生
// yuv420p（12.4MB/4K 帧，为 RGBA 的 1/2.67）原样打包上传为
// (w/4)x(h*3/2) RGBA 纹理（每纹素 4 字节零重排），BT.601 矩阵 + 范围
// 扩展在本 pass 完成（uLimited=1 时 limited→full；与 ffmpeg RGBA 直出
// 的 mpeg→pc 扩展语义一致）。
#include <flutter/runtime_effect.glsl>

precision highp float;
precision highp int;

uniform float uSrcW;    // 打包纹理宽（w/4 纹素）
uniform float uSrcH;    // 打包纹理高（h*3/2）
uniform float uTexW;    // 输出打包纹理宽（w*3/2）
uniform float uFrameW;  // 帧宽 w
uniform float uFrameH;  // 帧高 h
uniform float uMaxValue;
uniform float uLimited; // 1 = limited(tv) 需扩展，0 = full(pc)
uniform sampler2D uTex;

out vec4 fragColor;

// 按帧线性字节下标取字节：texel = linear/4，子字节 linear%4
float fetchByte(int linear) {
  int sw = int(uSrcW);
  int texel = linear / 4;
  int sub = linear - texel * 4;
  vec2 uv = vec2((float(texel - texel / sw * sw) + 0.5) / uSrcW,
                 (float(texel / sw) + 0.5) / uSrcH);
  vec4 t = floor(texture(uTex, uv) * 255.0 + 0.5);
  return sub == 0 ? t.r : (sub == 1 ? t.g : (sub == 2 ? t.b : t.a));
}

float kernel(int idx) {
  int px = idx / 3;
  int ch = idx - px * 3;
  int w = int(uFrameW), h = int(uFrameH);
  int x = px - px / w * w;
  int y = px / w;
  // 平面布局：Y（w 字节/行）→ U（w/2 字节/行）→ V（w/2 字节/行）
  float Y = fetchByte(y * w + x);
  int uvRow = w / 2;
  float U = fetchByte(w * h + (y / 2) * uvRow + x / 2);
  float V = fetchByte(w * h + (w * h) / 4 + (y / 2) * uvRow + x / 2);
  float r, g, b;
  if (uLimited > 0.5) {
    float yf = 1.164 * (Y - 16.0);
    r = yf + 1.596 * (V - 128.0);
    g = yf - 0.391 * (U - 128.0) - 0.813 * (V - 128.0);
    b = yf + 2.018 * (U - 128.0);
  } else {
    r = Y + 1.402 * (V - 128.0);
    g = Y - 0.344 * (U - 128.0) - 0.714 * (V - 128.0);
    b = Y + 1.772 * (U - 128.0);
  }
  float v8 = ch == 0 ? r : (ch == 1 ? g : b);
  return floor(clamp(v8, 0.0, 255.0) * uMaxValue / 255.0 + 0.5);
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
