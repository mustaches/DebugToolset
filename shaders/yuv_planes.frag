// YUV420 平面打包纹理预览着色器。
//
// CPU 侧把 ffmpeg 直出的 yuv420p 帧（Y 平面 w*h，U/V 平面各 (w/2)*(h/2)
// 顺序排列）原样当作一张 (w/4) x (h*3/2) 的 RGBA8888 图片上传（每个
// RGBA 纹素装 4 个连续字节，零重排、零转换），本 shader 在 GPU 上按
// 扁平字节偏移解包并做 BT.601 上色 / 单平面灰度显示，CPU 零逐像素
// 工作。limited range 扩展也在 GPU 完成（uLimited=1）。
#include <flutter/runtime_effect.glsl>

precision highp float;

uniform vec2 uOffset;     // 绘制矩形左上角（画布坐标）
uniform vec2 uDrawSize;   // 绘制矩形尺寸
uniform vec2 uSrcSize;    // 视频逻辑尺寸（宽, 高）
uniform float uMode;      // 0=YUV→RGB 彩色, 1=Y 灰度, 2=U 灰度, 3=V 灰度
uniform float uLimited;   // 1=limited range（tv），0=full range（pc）
uniform sampler2D uTex;   // 打包纹理：宽 w/4，高 h*3/2

out vec4 fragColor;

// 取打包缓冲中第 byteOffset 个字节的样本（0..1）。纹理宽 = w/4 纹素，
// 高 = w*h*1.5/4 / (w/4) = h*1.5 纹素行。
float fetchSample(float byteOffset) {
  float texW = uSrcSize.x * 0.25;
  float texel = floor(byteOffset * 0.25);
  float ch = byteOffset - texel * 4.0;
  vec2 uv = vec2((mod(texel, texW) + 0.5) / texW,
                 (floor(texel / texW) + 0.5) / (uSrcSize.y * 1.5));
  vec4 t = texture(uTex, uv);
  if (ch < 0.5) return t.r;
  if (ch < 1.5) return t.g;
  if (ch < 2.5) return t.b;
  return t.a;
}

float expandY(float y) {
  return clamp((y - 16.0 / 255.0) * (255.0 / 219.0), 0.0, 1.0);
}

float expandC(float c) {
  return clamp((c - 0.5) * (255.0 / 224.0) + 0.5, 0.0, 1.0);
}

void main() {
  vec2 pos = (FlutterFragCoord().xy - uOffset) / uDrawSize * uSrcSize;
  pos = clamp(pos, vec2(0.0), uSrcSize - vec2(1.0));
  float w = uSrcSize.x;
  float y = fetchSample(floor(pos.y) * w + floor(pos.x));
  // U/V 平面：各 (w/2)*(h/2)，平铺在 Y 之后。
  vec2 cpos = floor(pos * 0.5);
  float cBase = w * uSrcSize.y;
  float u = fetchSample(cBase + cpos.y * w * 0.5 + cpos.x);
  float v = fetchSample(cBase + w * uSrcSize.y * 0.25 +
                        cpos.y * w * 0.5 + cpos.x);
  if (uLimited > 0.5) {
    y = expandY(y);
    u = expandC(u);
    v = expandC(v);
  }
  if (uMode > 0.5) {
    // 单平面灰度（Y/U/V 分路预览）。
    float g = uMode < 1.5 ? y : (uMode < 2.5 ? u : v);
    fragColor = vec4(g, g, g, 1.0);
  } else {
    // BT.601 全范围 YUV→RGB（u/v 以 0.5 为零点）。
    float cu = u - 0.5;
    float cv = v - 0.5;
    fragColor = vec4(clamp(y + 1.402 * cv, 0.0, 1.0),
                     clamp(y - 0.344136 * cu - 0.714136 * cv, 0.0, 1.0),
                     clamp(y + 1.772 * cu, 0.0, 1.0), 1.0);
  }
}
