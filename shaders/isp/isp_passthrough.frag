// GPU 流水线联通性验证：原样输出输入纹理（float32 往返 spike）。
#include <flutter/runtime_effect.glsl>

precision highp float;

uniform vec2 uSize;      // 纹理尺寸（宽, 高）
uniform sampler2D uTex;  // 输入 float 纹理

out vec4 fragColor;

void main() {
  vec2 uv = FlutterFragCoord().xy / uSize;
  fragColor = texture(uTex, uv);
}
