// 混叠器（GPU 版，对应 blendMaskMono 正常模式）：
// out = clamp(基图 + 混叠图×蒙版/maxValue×混叠强度)。三路打包纹理采样：
// 基图（RGB/YUV/HSL 三通道交织或 Mono 单通道）、混叠图（三通道或
// Mono，通道数按 uBlendChs）、蒙版（Mono）。
// 混叠图为 mono 时按基图格式选目标通道：YUV 只加 Y、HSL 只加 L、
// RGB 三通道同加、Mono 单通道；为三通道时逐通道对应叠加。
// 注：sampler 不作为函数参数传递（SkSL 转译不支持），三路采样内联展开。
#include <flutter/runtime_effect.glsl>

precision highp float;
precision highp int;

uniform float uBaseTexW;  // 基图打包纹理宽（w*baseChs/2）
uniform float uBlendTexW; // 混叠图打包纹理宽
uniform float uMaskTexW;  // 蒙版打包纹理宽（w/2）
uniform float uTexH;
uniform float uWidth;     // 帧宽（像素）
uniform float uBaseChs;   // 基图通道数（1=mono，3=rgb/yuv/hsl）
uniform float uBlendChs;  // 混叠图通道数（1 / 3）
uniform float uFormat;    // 基图格式：0=rgb 1=yuv 2=hsl 3=mono
uniform float uStrength;
uniform float uMaxValue;
uniform sampler2D uBaseTex;
uniform sampler2D uBlendTex;
uniform sampler2D uMaskTex;

out vec4 fragColor;

float fetchBase(int idx) {
  int byteOff = idx * 2;
  int texel = byteOff / 4;
  int sub = byteOff - texel * 4;
  int tw = int(uBaseTexW);
  vec2 uv = vec2((float(texel - texel / tw * tw) + 0.5) / uBaseTexW,
                 (float(texel / tw) + 0.5) / uTexH);
  vec4 t = floor(texture(uBaseTex, uv) * 255.0 + 0.5);
  return sub == 0 ? t.r + t.g * 256.0 : t.b + t.a * 256.0;
}

float fetchBlend(int idx) {
  int byteOff = idx * 2;
  int texel = byteOff / 4;
  int sub = byteOff - texel * 4;
  int tw = int(uBlendTexW);
  vec2 uv = vec2((float(texel - texel / tw * tw) + 0.5) / uBlendTexW,
                 (float(texel / tw) + 0.5) / uTexH);
  vec4 t = floor(texture(uBlendTex, uv) * 255.0 + 0.5);
  return sub == 0 ? t.r + t.g * 256.0 : t.b + t.a * 256.0;
}

float fetchMask(int idx) {
  int byteOff = idx * 2;
  int texel = byteOff / 4;
  int sub = byteOff - texel * 4;
  int tw = int(uMaskTexW);
  vec2 uv = vec2((float(texel - texel / tw * tw) + 0.5) / uMaskTexW,
                 (float(texel / tw) + 0.5) / uTexH);
  vec4 t = floor(texture(uMaskTex, uv) * 255.0 + 0.5);
  return sub == 0 ? t.r + t.g * 256.0 : t.b + t.a * 256.0;
}

float kernel(int idx) {
  int chs = int(uBaseChs);
  int p = idx / chs;
  int ch = idx - p * chs;
  int fmt = int(uFormat);
  float base = fetchBase(idx);
  float mv = fetchMask(p);
  if (mv <= 0.0) return base;
  float bv;
  bool apply;
  if (int(uBlendChs) == 1) {
    // mono 混叠图：按基图格式选目标通道（rgb 全通道；yuv/mono 0 通道；
    // hsl 第 2 通道 L）。
    bv = fetchBlend(p);
    apply = fmt == 0 || ((fmt == 1 || fmt == 3) && ch == 0) ||
        (fmt == 2 && ch == 2);
  } else {
    // 三通道混叠图：逐通道对应叠加。
    bv = fetchBlend(p * 3 + ch);
    apply = true;
  }
  if (!apply) return base;
  float delta = bv * mv * uStrength / uMaxValue;
  return clamp(floor(base + delta + 0.5), 0.0, uMaxValue);
}

void main() {
  vec2 fc = floor(FlutterFragCoord().xy);
  int texel = int(fc.y) * int(uBaseTexW) + int(fc.x);
  float vA = kernel(texel * 2);
  float vB = kernel(texel * 2 + 1);
  float hiA = floor(vA / 256.0), loA = vA - hiA * 256.0;
  float hiB = floor(vB / 256.0), loB = vB - hiB * 256.0;
  fragColor = vec4(loA / 255.0, hiA / 255.0, loB / 255.0, hiB / 255.0);
}
