/**
 * @file isp_adjust.h
 * @brief ISP Studio C99 参考实现 —— 六调节器（色彩域内调参核，全部原地修改）。
 *
 * 覆盖节点（Dart pipeline_runner.dart 的节点分发）与对应 Dart 函数：
 * - hsl_debugger             → adjustHsl             （HSL 调节器）
 * - rgb_debugger             → adjustRgb             （RGB 调节器）
 * - yuv_debugger             → adjustYuv             （YUV 调节器）
 * - sat_bright_adjuster      → adjustSatBright       （色饱和度/亮度调节器）
 * - bright_contrast_adjuster → adjustBrightContrast  （亮度/对比度调节器）
 * - color_balance            → applyColorBalance     （色彩平衡）
 *
 * Dart 来源：lib/modules/isp_studio/pipeline/isp_kernels.dart
 * （上述六个公开函数及私有 _colorBalanceRgb / _colorBalanceYuv，
 *   HSL 往返转换 rgbToHsl / hslToRgb / _hueToRgb，收尾 _clampTo）。
 *
 * 与 Dart 的契约差异（数值语义不变，仅调用形态差异）：
 * - Dart 的「恒等直通返回原数据不拷贝」在 C 中改为：参数校验通过后直接
 *   return ISP_OK，不触碰帧数据；
 * - 全部核原地（in-place）修改调用方帧缓冲，帧约定与 isp_common.h 一致
 *   （交织三通道 uint16_t*，长 w*h*3；mono 帧长 w*h）；
 * - 全部核逐像素独立、无跨像素依赖，均不需要 scratch 缓冲。
 *   color_balance 的 HSL 域在 Dart 中经 hslToRgb/rgbToHsl 整帧往返
 *   （两次整帧中间缓冲），此处按像素融合三段计算：中间 RGB 仍先按
 *   _clampTo 语义量化为整数再参与下一步，与整帧往返逐位一致，
 *   因此无需中间帧缓冲，也没有配套 SCRATCH_BYTES 宏。
 */

#ifndef ISP_ADJUST_H
#define ISP_ADJUST_H

#include "isp_common.h"

#ifdef __cplusplus
extern "C" {
#endif

/**
 * @brief 调参核的输入帧色彩域（对应 Dart 侧的 format 字符串参数）。
 *
 * Dart 来源：isp_kernels.dart adjustSatBright / adjustBrightContrast /
 * applyColorBalance 的 format 参数（'rgb'/'yuv'/'hsl'/'mono'）。
 * 注意 applyColorBalance 不支持 mono（Dart 侧 default 分支抛 StateError），
 * 本实现返回 ISP_ERR_UNSUPPORTED。
 */
typedef enum IspAdjustFormat {
  /** 'rgb'：交织 R/G/B 三通道。 */
  ISP_ADJ_FMT_RGB = 0,
  /** 'yuv'：交织 Y/U/V 三通道，色度中点为 max_value>>1。 */
  ISP_ADJ_FMT_YUV = 1,
  /** 'hsl'：交织 H/S/L 三通道，H 量程 0..max_value 对应 0..360°。 */
  ISP_ADJ_FMT_HSL = 2,
  /** 'mono'：单通道亮度帧，长 w*h（仅亮度/对比度调节器支持）。 */
  ISP_ADJ_FMT_MONO = 3
} IspAdjustFormat;

/**
 * @brief HSL 调节器：H 色环循环偏移，S/L 乘增益，原地修改。
 *
 * Dart 来源：isp_kernels.dart adjustHsl。
 * shift = round(h_shift_deg / 360 × max_value)；
 * H' = ((H + shift) % m + m) % m（m = max_value + 1，修正 C 负数取模）；
 * S' = S × s_gain、L' = L × l_gain，先四舍五入再钳位 0..max_value。
 * 三参数均为恒等值（0 / 1.0 / 1.0）时直接返回 ISP_OK 不动数据。
 *
 * @param hsl         HSL 交织帧（w*h*3 个 uint16_t，原地修改）。
 * @param w           帧宽（>0）。
 * @param h           帧高（>0）。
 * @param max_value   采样最大值（>0）。
 * @param h_shift_deg 色相偏移角度（度，可为负，色环循环）。
 * @param s_gain      饱和度增益。
 * @param l_gain      明度增益。
 * @return ISP_OK；参数非法返回 ISP_ERR_ARG / ISP_ERR_SIZE。
 */
int isp_adjust_hsl(uint16_t *hsl, int w, int h, int max_value,
                   double h_shift_deg, double s_gain, double l_gain);

/**
 * @brief RGB 调节器：R/G/B 三通道分别乘增益，原地修改。
 *
 * Dart 来源：isp_kernels.dart adjustRgb。
 * c' = c × gain，先四舍五入再钳位 0..max_value。
 * 三增益均为 1.0 时直接返回 ISP_OK 不动数据。
 *
 * @param rgb       RGB 交织帧（w*h*3 个 uint16_t，原地修改）。
 * @param w         帧宽（>0）。
 * @param h         帧高（>0）。
 * @param max_value 采样最大值（>0）。
 * @param r_gain    R 通道增益。
 * @param g_gain    G 通道增益。
 * @param b_gain    B 通道增益。
 * @return ISP_OK；参数非法返回 ISP_ERR_ARG / ISP_ERR_SIZE。
 */
int isp_adjust_rgb(uint16_t *rgb, int w, int h, int max_value,
                   double r_gain, double g_gain, double b_gain);

/**
 * @brief YUV 调节器：Y 乘增益；U/V 绕中点缩放，原地修改。
 *
 * Dart 来源：isp_kernels.dart adjustYuv。
 * half = max_value >> 1；Y' = Y × y_gain；
 * U' = half + (U − half) × u_gain，V' 同理（色度增益不改变中性色点）；
 * 先四舍五入再钳位 0..max_value。三增益均为 1.0 时直接返回 ISP_OK 不动数据。
 *
 * @param yuv       YUV 交织帧（w*h*3 个 uint16_t，原地修改）。
 * @param w         帧宽（>0）。
 * @param h         帧高（>0）。
 * @param max_value 采样最大值（>0）。
 * @param y_gain    亮度增益。
 * @param u_gain    U 色度增益。
 * @param v_gain    V 色度增益。
 * @return ISP_OK；参数非法返回 ISP_ERR_ARG / ISP_ERR_SIZE。
 */
int isp_adjust_yuv(uint16_t *yuv, int w, int h, int max_value,
                   double y_gain, double u_gain, double v_gain);

/**
 * @brief 色饱和度/亮度调节器：按色彩域施加饱和度与亮度增益，原地修改。
 *
 * Dart 来源：isp_kernels.dart adjustSatBright。
 * - RGB 域：Y = 0.299R + 0.587G + 0.114B（BT.601 全范围），
 *   c' = (Y + (c − Y) × sat_gain) × bright_gain；
 * - YUV 域：Y' = Y × bright_gain；U/V 绕中点（max_value>>1）乘 sat_gain；
 * - HSL 域：H 不变；S' = S × sat_gain；L' = L × bright_gain。
 * 均先四舍五入再钳位 0..max_value。format 不支持 mono。
 * 两增益均为 1.0 时直接返回 ISP_OK 不动数据。
 *
 * @param data        交织三通道帧（w*h*3 个 uint16_t，原地修改）。
 * @param w           帧宽（>0）。
 * @param h           帧高（>0）。
 * @param format      色彩域（ISP_ADJ_FMT_RGB / YUV / HSL）。
 * @param max_value   采样最大值（>0）。
 * @param sat_gain    色饱和度增益。
 * @param bright_gain 亮度增益。
 * @return ISP_OK；format 非法返回 ISP_ERR_UNSUPPORTED，
 *         其余参数非法返回 ISP_ERR_ARG / ISP_ERR_SIZE。
 */
int isp_adjust_sat_bright(uint16_t *data, int w, int h,
                          IspAdjustFormat format, int max_value,
                          double sat_gain, double bright_gain);

/**
 * @brief 亮度/对比度调节器：按色彩域对亮度施加调节，原地修改。
 *
 * Dart 来源：isp_kernels.dart adjustBrightContrast。
 * 公式：base = baseline_pct/100 × max_value；
 * Y' = ((Y × bright_pct/100) − base) × gain_pct/100 + base，
 * 先四舍五入再钳位 0..max_value。
 * - RGB 域：逐像素求 BT.601 亮度 y（double），y <= 0 的纯黑像素保持不变；
 *   否则 ratio = adjust(round(y)) / y，R/G/B 各乘 ratio 后舍入钳位；
 * - YUV 域：直接作用于 Y 通道，U/V 不变；
 * - HSL 域：作用于 L 通道，H/S 不变；
 * - Mono 域：直接作用于单通道亮度（帧长 w*h）。
 * bright_pct == 100 且 gain_pct == 100 时为恒等（与基线无关），
 * 直接返回 ISP_OK 不动数据。
 *
 * @param data         帧缓冲（三通道域 w*h*3、mono 域 w*h 个 uint16_t，原地修改）。
 * @param w            帧宽（>0）。
 * @param h            帧高（>0）。
 * @param format       色彩域（RGB / YUV / HSL / MONO 均支持）。
 * @param max_value    采样最大值（>0）。
 * @param bright_pct   亮度百分比（100 为恒等）。
 * @param baseline_pct 基线百分比（满量程百分比，默认 50）。
 * @param gain_pct     对比度增益百分比（100 为恒等）。
 * @return ISP_OK；format 非法返回 ISP_ERR_UNSUPPORTED，
 *         其余参数非法返回 ISP_ERR_ARG / ISP_ERR_SIZE。
 */
int isp_adjust_bright_contrast(uint16_t *data, int w, int h,
                               IspAdjustFormat format, int max_value,
                               double bright_pct, double baseline_pct,
                               double gain_pct);

/**
 * @brief 色彩平衡：RGB/YUV/HSL 三域中间调色彩偏移，原地修改。
 *
 * Dart 来源：isp_kernels.dart applyColorBalance / _colorBalanceRgb /
 * _colorBalanceYuv（HSL 域经 rgbToHsl / hslToRgb 往返）。
 * 三个滑杆值 [-100, 100] 分别对应 青↔红、洋红↔绿、黄↔蓝；正值向后二者
 * （红/绿/蓝）偏移。偏移按 BT.601 亮度的中间调权重 w = 1 − |2Y−1| 加权
 * （中间调最强，纯黑/纯白不受影响），先四舍五入再钳位 0..max_value。
 * - RGB 域：偏移量 = 值/100 × max_value，直接加到 R/G/B 通道；
 * - YUV 域：青↔红 → V 轴、黄↔蓝 → U 轴、洋红↔绿为 U/V 对角
 *   （绿 = −U−V，洋红 = +U+V）；色度偏移量 = 值/100 × max_value/2，
 *   Y 通道不变，中间调权重直接取 Y 通道；
 * - HSL 域：按像素融合 HSL→RGB→加性偏移→HSL 往返（中间 RGB 先量化为
 *   整数再参与下一步，与 Dart 整帧往返逐位一致，无需中间缓冲）。
 * format 不支持 mono（返回 ISP_ERR_UNSUPPORTED）。
 * 三值全 0 时直接返回 ISP_OK 不动数据。
 *
 * @param data          交织三通道帧（w*h*3 个 uint16_t，原地修改）。
 * @param w             帧宽（>0）。
 * @param h             帧高（>0）。
 * @param format        色彩域（ISP_ADJ_FMT_RGB / YUV / HSL）。
 * @param max_value     采样最大值（>0）。
 * @param cyan_red      青↔红滑杆值（-100..100，正值偏红）。
 * @param magenta_green 洋红↔绿滑杆值（-100..100，正值偏绿）。
 * @param yellow_blue   黄↔蓝滑杆值（-100..100，正值偏蓝）。
 * @return ISP_OK；format 非法返回 ISP_ERR_UNSUPPORTED，
 *         其余参数非法返回 ISP_ERR_ARG / ISP_ERR_SIZE。
 */
int isp_adjust_color_balance(uint16_t *data, int w, int h,
                             IspAdjustFormat format, int max_value,
                             double cyan_red, double magenta_green,
                             double yellow_blue);

/* ---------------------------------------------------------------------------
 * LUT 模式（节点属性 codegenMode=lut）：增益表按生成期参数烘焙为 static
 * const（wrapper 内），运行期纯查表零建表成本。
 * ------------------------------------------------------------------------- */

/**
 * @brief 构建通道增益 LUT：lut[v] = clampTo(v * gain, max_value)（先比界
 *        再 round，与 Dart adjustGainLut 逐位一致）。
 *
 * @param gain      通道增益。
 * @param max_value 采样最大值（表长 max_value+1）。
 * @param lut_out   输出表（容量 max_value+1 个 uint16_t）。
 * @return ISP_OK / ISP_ERR_ARG。
 */
int isp_adjust_build_gain_lut(double gain, int max_value,
                              uint16_t *lut_out);

/**
 * @brief 三通道增益 LUT 查表施加（R/G/B 各一张表，非原地）。
 *
 * 与 isp_adjust_rgb 直算逐位一致（逐值 clampTo(v*gain) 预计算）。
 * 调用契约：帧值 <= max_value 且表长 >= max_value+1。
 *
 * @param rgb       输入交织三通道帧（w*h*3 个 uint16_t）。
 * @param w         帧宽。
 * @param h         帧高。
 * @param max_value 采样最大值。
 * @param lut_r     R 通道 LUT。
 * @param lut_g     G 通道 LUT。
 * @param lut_b     B 通道 LUT。
 * @param out       输出帧（w*h*3，调用方提供，可与 rgb 同址）。
 * @return ISP_OK / ISP_ERR_ARG / ISP_ERR_SIZE。
 */
int isp_adjust_lut3_apply(const uint16_t *rgb, int w, int h, int max_value,
                          const uint16_t *lut_r, const uint16_t *lut_g,
                          const uint16_t *lut_b, uint16_t *out);

/**
 * @brief 亮度/对比度 LUT 查表施加（LUT 模式）：mono/yuv(Y)/hsl(L) 域查
 *        adjust_lut；RGB 域 adjust 映射改查表、除法保留（ratio =
 *        adjust_lut[round(y)] / y，分母是完整 double 亮度，无法表化）。
 *
 * 与 isp_adjust_bright_contrast 直算逐位一致：adjust_lut[y] 为 adjust
 * 一维映射的逐值预计算。调用契约：帧值 <= max_value 且表长 >=
 * max_value+1。
 *
 * @param data        帧缓冲（三通道域 w*h*3、mono 域 w*h，原地修改）。
 * @param w           帧宽。
 * @param h           帧高。
 * @param format      色彩域。
 * @param max_value   采样最大值。
 * @param adjust_lut  adjust 一维映射表。
 * @return ISP_OK / ISP_ERR_ARG / ISP_ERR_SIZE / ISP_ERR_UNSUPPORTED。
 */
int isp_adjust_bc_lut_apply(uint16_t *data, int w, int h,
                            IspAdjustFormat format, int max_value,
                            const uint16_t *adjust_lut);

#ifdef __cplusplus
} /* extern "C" */
#endif

#endif /* ISP_ADJUST_H */
