// 色调映射 RGBA8 显示图 → I420 打包纹理（(w/4)x(h*3/2)，字节流即
// yuv420p）：导出 MP4 的 GPU 出图格式——回读 12.4MB/帧（4K）替代
// 33MB/帧 RGBA，ffmpeg 输入直接吃 yuv420p（NVENC 原生格式，免其内部
// rgba→yuv420p 的 CPU 转换）。BT.601 limited 矩阵（与 ffmpeg swscale
// rgba→yuv420p 默认转换同口径）；色度 2x2 均值下采样，与 swscale 的
// 双线性插值可能有 ±1 LSB 差异（可接受，见调用处注释）。
#include <flutter/runtime_effect.glsl>

precision highp float;
precision highp int;

uniform float uPackedW;  // 打包纹理宽（w/4）
uniform float uPackedH;  // 打包纹理高（h*3/2）
uniform float uFrameW;   // 帧宽 w
uniform float uFrameH;   // 帧高 h
uniform sampler2D uTex;  // 色调映射 RGBA8 显示图（w x h）

out vec4 fragColor;

vec3 rgb8(int x, int y) {
  vec2 uv = vec2((float(x) + 0.5) / uFrameW, (float(y) + 0.5) / uFrameH);
  return texture(uTex, uv).rgb;
}

// BT.601 limited：Y 16..235/255，U/V 16..240/255（中心 128）。
float luma(vec3 c) {
  return 16.0 / 255.0 +
         (0.299 * c.r + 0.587 * c.g + 0.114 * c.b) * (219.0 / 255.0);
}
vec2 chroma(vec3 c) {
  float u = 128.0 / 255.0 +
            (-0.168736 * c.r - 0.331264 * c.g + 0.5 * c.b) * (224.0 / 255.0);
  float v = 128.0 / 255.0 +
            (0.5 * c.r - 0.418688 * c.g - 0.081312 * c.b) * (224.0 / 255.0);
  return vec2(u, v);
}
vec3 rgb8Avg2x2(int x, int y) {
  vec3 s = rgb8(2 * x, 2 * y) + rgb8(2 * x + 1, 2 * y) +
           rgb8(2 * x, 2 * y + 1) + rgb8(2 * x + 1, 2 * y + 1);
  return s * 0.25;
}

// I420 线性字节下标 → 采样值：Y 平面全分辨率，U/V 平面半分辨率。
float sampleAt(int linear) {
  int w = int(uFrameW);
  int h = int(uFrameH);
  int ySize = w * h;
  if (linear < ySize) {
    return luma(rgb8(linear - linear / w * w, linear / w));
  }
  int uSize = ySize / 4;
  int cw = w / 2;
  if (linear < ySize + uSize) {
    int idx = linear - ySize;
    return chroma(rgb8Avg2x2(idx - idx / cw * cw, idx / cw)).x;
  }
  int idx = linear - ySize - uSize;
  return chroma(rgb8Avg2x2(idx - idx / cw * cw, idx / cw)).y;
}

// 每纹素打包 4 个连续流字节。
void main() {
  vec2 fc = floor(FlutterFragCoord().xy);
  int tx = int(fc.x);
  int ty = int(fc.y);
  int linear = (ty * int(uPackedW) + tx) * 4;
  fragColor = vec4(
      floor(sampleAt(linear) * 255.0 + 0.5) / 255.0,
      floor(sampleAt(linear + 1) * 255.0 + 0.5) / 255.0,
      floor(sampleAt(linear + 2) * 255.0 + 0.5) / 255.0,
      floor(sampleAt(linear + 3) * 255.0 + 0.5) / 255.0);
}
