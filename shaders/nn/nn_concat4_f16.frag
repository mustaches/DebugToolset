// NN 通道拼接（fp16 打包路径，对应 GpuNnBackend.concatChannelsGpu）：
// 把 ≤4 路同 H×W 的打包特征图沿通道维拼成一张（Inception 分支合并）。
// 各路通道数须为 4 的倍数（通道组整组对齐），输出通道组 go 落在第 i
// 路的条件是 uGEnd[i-1] ≤ go < uGEnd[i]（uGEnd 为通道组前缀和，不足
// 4 路时高位前缀和重复置为总组数，使后续分支不可达，sampler 绑哑纹理）。
//
// 纯字节拷贝：不做 fp16 编解码，RGBA8 纹素按同物理下标（2T+sub）原样
// 搬运（同 nn_stitch3_f16.frag），位级精确。
#include <flutter/runtime_effect.glsl>

precision highp float;
precision highp int;

uniform vec2 uOutSize;  // 输出物理纹理 (TW, TH)
uniform vec2 uDims;     // 空间尺寸 (W, H)（各路相同）
uniform vec4 uGEnd;     // 各路通道组数前缀和（组 = 4 通道）
uniform vec2 uSize0;    // 第 0 路物理纹理 (TW, TH)
uniform vec2 uSize1;
uniform vec2 uSize2;
uniform vec2 uSize3;
uniform sampler2D uSrc0;
uniform sampler2D uSrc1;
uniform sampler2D uSrc2;
uniform sampler2D uSrc3;

out vec4 fragColor;

vec2 uvOf(float p, vec2 size) {
  return vec2((mod(p, size.x) + 0.5) / size.x,
              (floor(p / size.x) + 0.5) / size.y);
}

void main() {
  vec2 fc = floor(FlutterFragCoord().xy);
  float p = fc.y * uOutSize.x + fc.x;
  float t = floor(p * 0.5);
  float sub = p - t * 2.0;
  float hw = uDims.x * uDims.y;
  float go = floor(t / hw);
  float rem = t - go * hw;
  float y = floor(rem / uDims.x);
  float x = rem - y * uDims.x;

  if (go < uGEnd.x) {
    float ts = (go * uDims.y + y) * uDims.x + x;
    fragColor = texture(uSrc0, uvOf(2.0 * ts + sub, uSize0));
  } else if (go < uGEnd.y) {
    float gLoc = go - uGEnd.x;
    float ts = (gLoc * uDims.y + y) * uDims.x + x;
    fragColor = texture(uSrc1, uvOf(2.0 * ts + sub, uSize1));
  } else if (go < uGEnd.z) {
    float gLoc = go - uGEnd.y;
    float ts = (gLoc * uDims.y + y) * uDims.x + x;
    fragColor = texture(uSrc2, uvOf(2.0 * ts + sub, uSize2));
  } else {
    float gLoc = go - uGEnd.z;
    float ts = (gLoc * uDims.y + y) * uDims.x + x;
    fragColor = texture(uSrc3, uvOf(2.0 * ts + sub, uSize3));
  }
}
