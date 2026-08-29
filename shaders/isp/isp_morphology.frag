// 形态学腐蚀/膨胀（GPU 版，对应 applyMorphology）：方形结构元
// (2×radius+1)² 的逐通道极小（erode）/极大（dilate）滤波，可分离两趟
// 实现——同一 shader 跑两次：uDir=0 水平趟、uDir=1 垂直趟，结果与直接
// 二维窗口完全一致；边界按可用邻域取极值（窗口裁剪到图内）。
// 通道间独立：RGB 交织数据按 channels=3、mono 按 channels=1 处理。
#include <flutter/runtime_effect.glsl>

precision highp float;
precision highp int;

uniform float uTexW;     // 打包纹理宽（w*channels/2）
uniform float uTexH;     // 打包纹理高（= 帧高）
uniform float uWidth;    // 帧宽（像素）
uniform float uChannels; // 通道数（RGB=3，Mono=1）
uniform float uDir;      // 0=水平趟，1=垂直趟
uniform float uErode;    // 1=腐蚀（极小），0=膨胀（极大）
uniform float uRadius;   // 结构元半径
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

float kernel(int idx) {
  int chs = int(uChannels);
  int p = idx / chs;
  int ch = idx - p * chs;
  int w = int(uWidth);
  int hgt = int(uTexH);
  int x = p - p / w * w;
  int y = p / w;
  int r = int(uRadius);
  bool erode = uErode > 0.5;
  float best = fetchVal(idx);
  // 常量循环界（半径上限 8，与节点参数 max 一致），越界/超半径迭代
  // 用 continue 跳过——SkSL 后端不接受动态循环边界。
  if (uDir < 0.5) {
    // 水平趟：行内 [x-r, x+r]（裁剪到图内）取极值。
    for (int i = -8; i <= 8; i++) {
      int nx = x + i;
      if (i < -r || i > r || nx < 0 || nx >= w) continue;
      float v = fetchVal((y * w + nx) * chs + ch);
      best = erode ? min(best, v) : max(best, v);
    }
  } else {
    // 垂直趟：列内 [y-r, y+r]（裁剪到图内）取极值。
    for (int i = -8; i <= 8; i++) {
      int ny = y + i;
      if (i < -r || i > r || ny < 0 || ny >= hgt) continue;
      float v = fetchVal((ny * w + x) * chs + ch);
      best = erode ? min(best, v) : max(best, v);
    }
  }
  return best;
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
