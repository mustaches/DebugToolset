// 锐化施加（GPU 版，对应 applySharpen）：亮度 unsharp mask——
// detail = Y − 3x3 盒式均值（Y 来自 luma_extract 的 mono 纹理），
// |detail| < threshold 置零，Y' = Y + amount×detail，三通道按 Y'/Y
// 等比缩放并钳位 maxValue。detail==0 或 v<=0 时直通（与 CPU 一致）。
#include <flutter/runtime_effect.glsl>

precision highp float;
precision highp int;

uniform float uTexW;   // RGB 打包纹理宽（w*3/2）
uniform float uTexH;
uniform float uYTexW;  // Y mono 打包纹理宽（w/2）
uniform float uYTexH;
uniform float uWidth;
uniform float uHeight;
uniform float uAmount;
uniform float uThreshold;
uniform float uMaxValue;
uniform sampler2D uTex;
uniform sampler2D uYTex;

out vec4 fragColor;

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

float kernel(int idx) {
  int p = idx / 3;
  int ch = idx - p * 3;
  float v = fetchVal(idx);
  int w = int(uWidth);
  int h = int(uHeight);
  int x = p - p / w * w;
  int y = p / w;
  float yv = fetchY(p);
  float sum = 0.0;
  float cnt = 0.0;
  for (int dy = -1; dy <= 1; dy++) {
    for (int dx = -1; dx <= 1; dx++) {
      int nx = x + dx, ny = y + dy;
      if (nx < 0 || nx >= w || ny < 0 || ny >= h) continue;
      sum += fetchY(ny * w + nx);
      cnt += 1.0;
    }
  }
  float detail = yv - sum / cnt;
  if (abs(detail) < uThreshold) detail = 0.0;
  if (detail == 0.0 || yv <= 0.0) return v; // 直通
  float y2 = clamp(yv + uAmount * detail, 0.0, uMaxValue);
  float scale = y2 / yv;
  return clamp(floor(v * scale + 0.5), 0.0, uMaxValue);
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
