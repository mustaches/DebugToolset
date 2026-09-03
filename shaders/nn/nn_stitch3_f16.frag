// NN 分块（band）halo 拼接：从输入张量的连续若干带中抽取全局行区间
// [uG0m1, uG0m1+uPadH)（即目标带 [g0, g0+th) 加上下各 1 行 halo），
// 生成 padded 带纹理（布局同 nn_conv3x3_f16.frag 头注释的折叠线性布局，
// 空间尺寸 (uW, uPadH)，uPadH = th+2）。行 0 / 行 uPadH-1 为 halo：
// 来自相邻带的对应行；图像顶/底之外写零（等价 conv pad=1 / L2pooling
// 的零填充）。
//
// 纯字节拷贝：不做 fp16 编解码，RGBA8 纹素按同物理下标（2T+sub）原样
// 搬运，位级精确。
//
// 源带最多 3 张（uSrcA/uSrcB/uSrcC，按全局行升序；不足时 uStartB/uStartC
// 置 uH 使分支不被选中，sampler 绑哑纹理）。覆盖超过 3 张带的形态由
// Dart 侧预检拒绝（UnsupportedError → 回退 CPU）。
#include <flutter/runtime_effect.glsl>

precision highp float;
precision highp int;

uniform vec2 uOutSize;  // 输出物理纹理 (TW, TH)
uniform float uW;       // 空间宽
uniform float uPadH;    // padded 带高（th+2）
uniform float uG0m1;    // padded 行 0 对应的全局行（g0-1）
uniform float uH;       // 图像总高（越界行写零）
uniform float uStartA;  // 源带 A 起始全局行
uniform float uSrcAH;   // 源带 A 高度
uniform float uStartB;  // 源带 B 起始全局行（无则 = uH）
uniform float uSrcBH;   // 源带 B 高度
uniform float uStartC;  // 源带 C 起始全局行（无则 = uH）
uniform float uSrcCH;   // 源带 C 高度
uniform vec2 uSizeA;    // 源带 A 物理纹理 (TW, TH)
uniform vec2 uSizeB;
uniform vec2 uSizeC;
uniform sampler2D uSrcA;
uniform sampler2D uSrcB;
uniform sampler2D uSrcC;

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
  float hw = uW * uPadH;
  float gi = floor(t / hw);
  float rem = t - gi * hw;
  float y = floor(rem / uW);
  float x = rem - y * uW;
  float gr = uG0m1 + y;

  if (gr < 0.0 || gr >= uH) {
    fragColor = vec4(0.0); // 图像外 halo：half 0
    return;
  }
  float t2;
  if (gr < uStartB) {
    t2 = (gi * uSrcAH + (gr - uStartA)) * uW + x;
    fragColor = texture(uSrcA, uvOf(2.0 * t2 + sub, uSizeA));
  } else if (gr < uStartC) {
    t2 = (gi * uSrcBH + (gr - uStartB)) * uW + x;
    fragColor = texture(uSrcB, uvOf(2.0 * t2 + sub, uSizeB));
  } else {
    t2 = (gi * uSrcCH + (gr - uStartC)) * uW + x;
    fragColor = texture(uSrcC, uvOf(2.0 * t2 + sub, uSizeC));
  }
}
