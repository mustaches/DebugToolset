// 高光恢复（GPU 版，对应 applyHighlightRecovery）：
// uMode=0 recover：达到膝点的饱和像素用同相位（Bayer ±2 / mono ±1）未饱和
//   邻域均值重建（无可用邻域保持原值）；
// uMode=1 clip：膝点以上软压缩 knee + d*range/(range+d)。
// CPU recover 基于快照（src 拷贝），与 GPU 同时替换语义一致。
#include <flutter/runtime_effect.glsl>

precision highp float;
precision highp int;

uniform float uTexW;   // mono/mosaic 打包纹理宽（w/2）
uniform float uTexH;
uniform float uWidth;
uniform float uHeight;
uniform float uStep;   // 同相位步进：mosaic=2，mono=1
uniform float uMode;
uniform float uKneePt; // knee*maxValue
uniform float uMaxValue;
uniform sampler2D uTex;

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

float kernel(int px) {
  float v = fetchVal(px);
  if (uMode > 0.5) {
    // clip：膝点以上软压缩。
    float range = uMaxValue - uKneePt;
    if (range <= 0.0 || v <= uKneePt) return v;
    float d = v - uKneePt;
    return floor(uKneePt + d * range / (range + d) + 0.5);
  }
  // recover。
  if (v < uKneePt) return v;
  int w = int(uWidth);
  int h = int(uHeight);
  int x = px - px / w * w;
  int y = px / w;
  int s = int(uStep);
  float sum = 0.0;
  float cnt = 0.0;
  for (int dy = -1; dy <= 1; dy++) {
    for (int dx = -1; dx <= 1; dx++) {
      if (dx == 0 && dy == 0) continue;
      int nx = x + dx * s, ny = y + dy * s;
      if (nx < 0 || nx >= w || ny < 0 || ny >= h) continue;
      float nv = fetchVal(ny * w + nx);
      if (nv >= uKneePt) continue;
      sum += nv;
      cnt += 1.0;
    }
  }
  if (cnt < 0.5) return v;
  // CPU: (sum + count~/2) ~/ count —— 整数四舍五入。
  return floor((sum + floor(cnt / 2.0)) / cnt);
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
