// 时域 IIR 降噪（GPU 版，对应 applyTemporalIir）：Y = αF + (1−α)Yprev。
// 帧差超过 uMotionThr 的像素判为运动，强制 α=1（用当前帧，避免拖影）；
// 调用方以 1e9 阈值表示关闭运动自适应。历史帧为上一帧输出的独立纹理。
#include <flutter/runtime_effect.glsl>

precision highp float;
precision highp int;

uniform float uTexW;    // mono 打包纹理宽（w/2）
uniform float uTexH;
uniform float uAlpha;
uniform float uMotionThr;
uniform sampler2D uTex;
uniform sampler2D uHist;

out vec4 fragColor;

void main() {
  vec2 fc = floor(FlutterFragCoord().xy);
  int tw = int(uTexW);
  int texel = int(fc.y) * tw + int(fc.x);
  vec2 uv = vec2((float(texel - texel / tw * tw) + 0.5) / uTexW,
                 (float(texel / tw) + 0.5) / uTexH);
  vec4 tf = floor(texture(uTex, uv) * 255.0 + 0.5);
  vec4 th = floor(texture(uHist, uv) * 255.0 + 0.5);
  float fA = tf.r + tf.g * 256.0, pA = th.r + th.g * 256.0;
  float fB = tf.b + tf.a * 256.0, pB = th.b + th.a * 256.0;
  float aA = abs(fA - pA) > uMotionThr ? 1.0 : uAlpha;
  float aB = abs(fB - pB) > uMotionThr ? 1.0 : uAlpha;
  float vA = floor(aA * fA + (1.0 - aA) * pA + 0.5);
  float vB = floor(aB * fB + (1.0 - aB) * pB + 0.5);
  float hiA = floor(vA / 256.0), loA = vA - hiA * 256.0;
  float hiB = floor(vB / 256.0), loB = vB - hiB * 256.0;
  fragColor = vec4(loA / 255.0, hiA / 255.0, loB / 255.0, hiB / 255.0);
}
