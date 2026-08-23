// GPU 打包方案 spike：mono16 每像素 +1000（钳位 65535）。
// 验证 16 位值在 shader 内的解码（lo+hi*256）与编码（拆回两个字节）。
//
// 打包约定：mono16 帧（w*h 个 uint16，小端字节序）按原字节流视为
// (w/2) x h 的 RGBA8888 纹理——每个纹素装 2 个像素（R,G=像素0的lo,hi，
// B,A=像素1的lo,hi）。纹理即 Uint16List.buffer.asUint8List() 零拷贝上传。
#include <flutter/runtime_effect.glsl>

precision highp float;

uniform vec2 uTexSize;   // 打包纹理尺寸（w/2, h）
uniform float uWidth;    // 逻辑像素宽 w
uniform sampler2D uTex;

out vec4 fragColor;

// 从打包纹理取第 byteOff 个字节（0..255）。
float fetchByte(float byteOff) {
  float texel = floor(byteOff * 0.25);
  float sub = byteOff - texel * 4.0;
  vec2 uv = vec2((mod(texel, uTexSize.x) + 0.5) / uTexSize.x,
                 (floor(texel / uTexSize.x) + 0.5) / uTexSize.y);
  vec4 t = floor(texture(uTex, uv) * 255.0 + 0.5);
  if (sub < 0.5) return t.r;
  if (sub < 1.5) return t.g;
  if (sub < 2.5) return t.b;
  return t.a;
}

// 取逻辑像素 px 的 16 位值（小端：lo 在低地址）。
float fetchVal(float px) {
  float o = px * 2.0;
  return fetchByte(o) + fetchByte(o + 1.0) * 256.0;
}

void main() {
  vec2 fc = floor(FlutterFragCoord().xy);
  float texel = fc.y * uTexSize.x + fc.x;
  float p0 = texel * 2.0;
  float v0 = clamp(fetchVal(p0) + 1000.0, 0.0, 65535.0);
  float v1 = clamp(fetchVal(p0 + 1.0) + 1000.0, 0.0, 65535.0);
  float hi0 = floor(v0 / 256.0), lo0 = v0 - hi0 * 256.0;
  float hi1 = floor(v1 / 256.0), lo1 = v1 - hi1 * 256.0;
  fragColor = vec4(lo0 / 255.0, hi0 / 255.0, lo1 / 255.0, hi1 / 255.0);
}
