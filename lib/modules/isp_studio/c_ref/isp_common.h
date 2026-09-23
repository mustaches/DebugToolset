/**
 * @file isp_common.h
 * @brief ISP Studio C99 参考实现 —— 公共基础层（错误码 / 内联工具 / CFA 相位 / 小数组工具声明）。
 *
 * 本文件是整个 c_ref 目录的风格与契约样板，后续所有算法文件必须遵循下列规范：
 *
 * 【规范要点速览】
 * 1. ANSI C99：只用 stdint.h / stdbool.h / string.h / math.h / stddef.h；
 *    允许 for-init 声明与 // 注释；禁用 VLA、alloca、malloc/free（内核零动态分配）。
 * 2. 内存模型：所有输出缓冲与临时缓冲由调用方提供；需要 scratch 的函数用
 *    显式 scratch 指针参数 + 配套宏给出所需大小，例如：
 *    @code
 *    #define ISP_FPN_SCRATCH_BYTES(w, h) ((size_t)(w) * (size_t)(h) * sizeof(uint16_t))
 *    int isp_fpn_apply(..., uint16_t *scratch);
 *    @endcode
 * 3. 帧约定：像素缓冲为 uint16_t*，宽/高/通道数为 int，采样最大值为 int max_value；
 *    交织三通道帧长度 w*h*3，mono/mosaic 帧长度 w*h。
 * 4. 命名：函数 isp_<模块>_<动作> 蛇形；类型 isp_xxx_t；宏/枚举全大写；
 *    头文件守卫 ISP_XXX_H；每个 .c 第一行 include 自己的 .h。
 * 5. 错误处理：参数可失败的函数返回 int（ISP_OK=0，负值为错误码，统一定义于本文件）；
 *    不会失败的返回 void。
 * 6. 注释：中文，Doxygen 风格；每个函数注明对应的 Dart 来源（文件 + 函数名）；
 *    算法关键步骤有中文解说。
 * 7. 数值语义必须与 Dart 实现逐位一致（同样的定点系数、舍入方式、边界处理）。
 *
 * 对应的 Dart 语义来源：lib/modules/isp_studio/pipeline/isp_kernels.dart
 * （BayerPattern 枚举与 colorAt、bayerMaxValue、_rccbAt/_rccgAt/_rcccAt/_ryycyAt/_rgbIrAt、
 *   _phaseNeighbors、_sortedValues、_clampTo 等公共 helper）。
 */

#ifndef ISP_COMMON_H
#define ISP_COMMON_H

#include <stdint.h>
#include <stdbool.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

/* ---------------------------------------------------------------------------
 * 内联函数宏
 *
 * 说明：MSVC 的 C 模式（cl 编译 .c）对 C99 的 inline 关键字支持较晚，且大量
 * 嵌入式交叉编译器只认 __inline；GCC/Clang/MSVC C++ 则用标准 inline。
 * 因此统一经 ISP_INLINE 宏分派，头文件中的小工具全部以 ISP_INLINE 定义，
 * 每个翻译单元各持一份静态副本，无跨 TU 链接问题。
 * ------------------------------------------------------------------------- */
#if defined(_MSC_VER) && !defined(__cplusplus)
#define ISP_INLINE static __inline
#else
#define ISP_INLINE static inline
#endif

/* ---------------------------------------------------------------------------
 * 错误码（规范第 5 条）
 * ------------------------------------------------------------------------- */

/** 成功。 */
#define ISP_OK 0
/** 参数非法（空指针、越界坐标、非法枚举值等）。 */
#define ISP_ERR_ARG (-1)
/** 尺寸非法（宽高 <= 0、缓冲不足、stride 不匹配等）。 */
#define ISP_ERR_SIZE (-2)
/** 请求的组合/格式不受支持。 */
#define ISP_ERR_UNSUPPORTED (-3)
/** 内部状态不满足调用前提（如未初始化、顺序错误）。 */
#define ISP_ERR_STATE (-4)

/* ---------------------------------------------------------------------------
 * 通道 id 约定（与 Dart 一致：isp_kernels.dart 840 行注释）
 * 0=R 1=G 2=B 3=C(clear 全色) 4=Y(黄) 5=Cy(青) 6=IR。
 * C ≈ R+G+B，Y ≈ R+G，Cy ≈ G+B。
 * ------------------------------------------------------------------------- */
#define ISP_CH_R 0
#define ISP_CH_G 1
#define ISP_CH_B 2
#define ISP_CH_C 3
#define ISP_CH_Y 4
#define ISP_CH_CY 5
#define ISP_CH_IR 6

/* ---------------------------------------------------------------------------
 * 通用小工具
 * ------------------------------------------------------------------------- */

/** 取小值宏。参数会被求值两次，禁止传入带副作用的表达式。 */
#define ISP_MIN(a, b) ((a) < (b) ? (a) : (b))

/** 取大值宏。参数会被求值两次，禁止传入带副作用的表达式。 */
#define ISP_MAX(a, b) ((a) > (b) ? (a) : (b))

/**
 * @brief 将 int 值钳位到 [0, max_value] 后转为 uint16_t。
 *
 * Dart 来源：isp_kernels.dart `_clampTo` 的整数路径（v < 0 ? 0 :
 * (v > maxValue ? maxValue : v)），各 kernel 写回像素前的统一收尾。
 * 本函数只接收整数输入，不涉及 _clampTo 的 round() 分支；
 * 浮点中间结果请先按各 kernel 的 Dart 原式舍入为 int 再调用本函数。
 *
 * @param v         输入值。
 * @param max_value 采样最大值（如 10bit 为 1023，16bit 为 65535）。
 * @return 钳位后的值。
 */
ISP_INLINE uint16_t isp_clamp_u16(int v, int max_value) {
  if (v < 0) return 0;
  if (v > max_value) return (uint16_t)max_value;
  return (uint16_t)v;
}

/**
 * @brief 将 int 值钳位到 [lo, hi]。
 *
 * Dart 来源：各 kernel 中散落的 v.clamp(lo, hi) 整数用法。
 *
 * @param v  输入值。
 * @param lo 下界（要求 lo <= hi，调用方保证）。
 * @param hi 上界。
 * @return 钳位后的值。
 */
ISP_INLINE int isp_clamp_int(int v, int lo, int hi) {
  if (v < lo) return lo;
  if (v > hi) return hi;
  return v;
}

/* ---------------------------------------------------------------------------
 * Bayer 模式
 * ------------------------------------------------------------------------- */

/**
 * @brief Bayer 滤色阵列 2x2 平铺模式。
 *
 * Dart 来源：isp_kernels.dart `enum BayerPattern`，枚举值顺序一致：
 * rggb=0, bggr=1, grbg=2, gbrg=3（兼容直接按 Dart 侧序号传参）。
 */
typedef enum IspBayerPattern {
  /** (0,0)=R (1,0)=G / (0,1)=G (1,1)=B */
  ISP_BAYER_RGGB = 0,
  /** (0,0)=B (1,0)=G / (0,1)=G (1,1)=R */
  ISP_BAYER_BGGR = 1,
  /** (0,0)=G (1,0)=R / (0,1)=B (1,1)=G */
  ISP_BAYER_GRBG = 2,
  /** (0,0)=G (1,0)=B / (0,1)=R (1,1)=G */
  ISP_BAYER_GBRG = 3
} IspBayerPattern;

/**
 * @brief 查询 Bayer 模式下像素 (x, y) 所属通道。
 *
 * Dart 来源：isp_kernels.dart `BayerPattern.colorAt`。
 * 相位 phase = ((y & 1) << 1) | (x & 1)，查 2x2 表。
 *
 * @param pattern Bayer 模式。
 * @param x       像素列。
 * @param y       像素行。
 * @return 通道 id：ISP_CH_R / ISP_CH_G / ISP_CH_B。
 *         pattern 非法时返回 ISP_CH_G（防御性兜底，调用方不应依赖）。
 */
ISP_INLINE int isp_bayer_color_at(IspBayerPattern pattern, int x, int y) {
  static const int kRggb[4] = {0, 1, 1, 2};
  static const int kBggr[4] = {2, 1, 1, 0};
  static const int kGrbg[4] = {1, 0, 2, 1};
  static const int kGbrg[4] = {1, 2, 0, 1};
  const int phase = ((y & 1) << 1) | (x & 1);
  switch (pattern) {
    case ISP_BAYER_RGGB: return kRggb[phase];
    case ISP_BAYER_BGGR: return kBggr[phase];
    case ISP_BAYER_GRBG: return kGrbg[phase];
    case ISP_BAYER_GBRG: return kGbrg[phase];
    default: return ISP_CH_G;
  }
}

/**
 * @brief 指定位深的采样最大值。
 *
 * Dart 来源：isp_kernels.dart `bayerMaxValue`：(1 << bitDepth) - 1。
 *
 * @param bit_depth 位深（1..31，典型为 8/10/12/14/16）。
 * @return (1 << bit_depth) - 1。
 */
ISP_INLINE int isp_bayer_max_value(int bit_depth) { return (1 << bit_depth) - 1; }

/* ---------------------------------------------------------------------------
 * 非 Bayer CFA 相位函数（通道 id 约定见 ISP_CH_* 宏）
 * ------------------------------------------------------------------------- */

/**
 * @brief RCCB 2x2 平铺：R C / C B。
 *
 * Dart 来源：isp_kernels.dart `_rccbAt`。
 * @verbatim
 * (0,0)=R  (1,0)=C
 * (0,1)=C  (1,1)=B
 * @endverbatim
 */
ISP_INLINE int isp_cfa_rccb_at(int x, int y) {
  static const int kT[4] = {0, 3, 3, 2};
  return kT[((y & 1) << 1) | (x & 1)];
}

/**
 * @brief RCCG 2x2 平铺：R C / C G。
 *
 * Dart 来源：isp_kernels.dart `_rccgAt`。
 * @verbatim
 * (0,0)=R  (1,0)=C
 * (0,1)=C  (1,1)=G
 * @endverbatim
 */
ISP_INLINE int isp_cfa_rccg_at(int x, int y) {
  static const int kT[4] = {0, 3, 3, 1};
  return kT[((y & 1) << 1) | (x & 1)];
}

/**
 * @brief RCCC 2x2 平铺：R C / C C。
 *
 * Dart 来源：isp_kernels.dart `_rcccAt`。
 * @verbatim
 * (0,0)=R  (1,0)=C
 * (0,1)=C  (1,1)=C
 * @endverbatim
 */
ISP_INLINE int isp_cfa_rccc_at(int x, int y) {
  return ((x & 1) == 0 && (y & 1) == 0) ? ISP_CH_R : ISP_CH_C;
}

/**
 * @brief RYYCy 2x2 平铺：R Y / Y Cy。
 *
 * Dart 来源：isp_kernels.dart `_ryycyAt`。
 * @verbatim
 * (0,0)=R  (1,0)=Y
 * (0,1)=Y  (1,1)=Cy
 * @endverbatim
 */
ISP_INLINE int isp_cfa_ryycy_at(int x, int y) {
  static const int kT[4] = {0, 4, 4, 5};
  return kT[((y & 1) << 1) | (x & 1)];
}

/**
 * @brief RGB-IR 4x4 平铺（常见布局之一）。
 *
 * Dart 来源：isp_kernels.dart `_rgbIrAt`。
 * @verbatim
 * R  G  IR G
 * G  B  G  IR
 * IR G  R  G
 * G  IR G  B
 * @endverbatim
 */
ISP_INLINE int isp_cfa_rgbir_at(int x, int y) {
  static const int kT[16] = {
      0, 1, 6, 1, /* */
      1, 2, 1, 6, /* */
      6, 1, 0, 1, /* */
      1, 6, 1, 2, /* */
  };
  return kT[(y & 3) * 4 + (x & 3)];
}

/* ---------------------------------------------------------------------------
 * 小数组工具（实现见 isp_common.c）
 * ------------------------------------------------------------------------- */

/**
 * @brief 对 uint16_t 数组原地升序插入排序。
 *
 * Dart 来源：isp_kernels.dart `_sortedValues` 中的 `..sort()`（升序）。
 * 邻域收集的元素个数最多 8~24，插入排序在此规模下优于快排且零栈风险。
 * n <= 1 或 vals 为 NULL 时为空操作（防御性兜底，不算错误）。
 *
 * @param vals 待排序数组（原地修改）。
 * @param n    元素个数。
 */
void isp_sort_u16(uint16_t *vals, int n);

/**
 * @brief 求 uint16_t 数组的中位数（先原地排序，再取上中位）。
 *
 * Dart 来源：isp_kernels.dart `_sortedValues` + `vals[vals.length ~/ 2]`
 * （applyDpc 等处的中位数取法）。注意 Dart 的 `length ~/ 2` 对偶数长度取
 * 的是**上中位**（第 n/2 项，0 基），本函数保持一致，不做 (a+b)/2 平均。
 *
 * 警告：本函数会原地排序，破坏 vals 原有顺序。
 *
 * @param vals 样本数组（原地修改）。
 * @param n    样本个数；n <= 0 或 vals 为 NULL 时返回 0（兜底）。
 * @return 中位数值。
 */
uint16_t isp_median_u16(uint16_t *vals, int n);

/**
 * @brief 收集 (x, y) 的 3x3 处理邻域样本值（Bayer 同相位 / mono 全像素）。
 *
 * Dart 来源：isp_kernels.dart `_phaseNeighbors` + `_sortedValues` 的取值
 * 部分。Dart 分两步（先收集邻居下标，再按下标取值），本函数融合为一步，
 * 直接向 out 写入样本值；收集顺序与 Dart 完全一致（dy 外层、dx 内层、
 * 行优先），因此排序/中位数结果逐位一致。
 *
 * 语义细节（与 Dart 逐项对应）：
 * - pattern 为 NULL 表示 16 位 mono：步进 ±1，收集全像素 3x3 的 8 邻域；
 * - pattern 非 NULL 表示 Bayer 马赛克：步进 ±2，收集同相位最多 8 邻域
 *   （具体是哪种 Bayer 模式不影响邻居集合，只影响相位含义，故此处不读
 *   *pattern 的值，与 Dart 中 `_phaseNeighbors` 只判空一致）；
 * - 中心像素自身不收集；越界邻居裁剪丢弃。
 *
 * @param buf     像素缓冲（w*h 个 uint16_t）。
 * @param w       帧宽。
 * @param h       帧高。
 * @param x       中心像素列。
 * @param y       中心像素行。
 * @param pattern Bayer 模式指针；NULL 表示 mono。只判空，不解引用。
 * @param out     输出数组，容量至少 8。
 * @return 实际收集到的邻居个数（0..8；角落为 3，边缘为 5）。
 */
int isp_phase_neighbors(const uint16_t *buf, int w, int h, int x, int y,
                        const IspBayerPattern *pattern, uint16_t *out);

#ifdef __cplusplus
} /* extern "C" */
#endif

#endif /* ISP_COMMON_H */
