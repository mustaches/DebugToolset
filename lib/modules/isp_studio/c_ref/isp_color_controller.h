/**
 * @file isp_color_controller.h
 * @brief ISP Studio C99 参考实现 —— 色彩控制器（高斯色相带选择性调整）。
 *
 * 覆盖节点：color_controller（色彩控制器）。
 *
 * 对应的 Dart 来源：
 * - lib/modules/isp_studio/pipeline/isp_kernels.dart
 *   - `adjustHslBand`（整幅入口 + 恒等直通判定）
 *   - `adjustHslBandRows`（核心算法：高斯权重 + H 偏移 + S/L 渐变）
 *   - `_clampTo`（浮点路径的收尾钳位）
 * - hsl_band_pool.dart 的 `adjustHslBandParallel` 为 PC 侧条带池并行加速，
 *   逐像素操作无跨像素依赖（Dart 注释明确串行与并行逐位一致），属纯调度
 *   层优化，不移植；嵌入式单线程串行执行即可得到相同结果。
 *
 * 内存模型：输出帧由调用方提供，无需 scratch 也无需任何 LUT 缓冲
 * （高斯权重逐像素直接计算 exp，与 Dart 逐位一致，见 .c 文件头注释）。
 * 支持 src == dst 原地处理（逐像素独立，无跨像素读）。
 *
 * 规范要点速览见 isp_common.h 文件头注释。
 */

#ifndef ISP_COLOR_CONTROLLER_H
#define ISP_COLOR_CONTROLLER_H

#include "isp_common.h"

#ifdef __cplusplus
extern "C" {
#endif

/**
 * @brief 高斯色相带选择性调整（color_controller 节点）。
 *
 * 只调整色相落在以 h_center_deg 为中心的高斯带内的像素。带内权重
 * w(Δ) = exp(-(Δ/σ)²/2)，Δ 为色环最短角距（0..180°），σ = 45°/q ——
 * q 越高带宽越窄。带内像素按权重插值施加调整：
 * - H' = H + round(h_shift_deg × w / 360 × max_value)，色环 0..max_value
 *   上环绕修正；
 * - S/L 按 1 + (gain − 1) × w 渐变（w=1 处满增益、w=0 处恒等），
 *   经 Dart `_clampTo` 浮点路径（先比界后 round）钳位到 0..max_value。
 *
 * 恒等直通：h_shift_deg == 0 且 s_gain == 1.0 且 l_gain == 1.0 时不做
 * 任何调整，仅把 src 搬到 dst（Dart 侧为零拷贝直通，C 侧输出缓冲由
 * 调用方提供故需一次 memmove；src == dst 时连拷贝也跳过）。
 *
 * 输入帧约定：交织三通道 HSL 帧，长度 w*h*3，H/S/L 均以 0..max_value
 * 量化（H 满量程对应 360°）。
 *
 * @param src          输入 HSL 帧（w*h*3 个 uint16_t）。
 * @param dst          输出 HSL 帧（w*h*3 个 uint16_t），可与 src 相同。
 * @param w            帧宽（> 0）。
 * @param h            帧高（> 0）。
 * @param max_value    采样最大值（> 0，如 10bit 为 1023）。
 * @param h_center_deg 色相带中心（度，任意实数，内部对 360 取模）。
 * @param q            带宽品质因数（必须为正有限数；σ = 45°/q）。
 * @param h_shift_deg  带内满权重处的色相偏移（度）。
 * @param s_gain       带内满权重处的饱和度增益。
 * @param l_gain       带内满权重处的亮度增益。
 * @return ISP_OK 成功；ISP_ERR_ARG 空指针或 q 非正；ISP_ERR_SIZE 尺寸非法。
 */
int isp_color_controller_apply(const uint16_t *src, uint16_t *dst,
                               int w, int h, int max_value,
                               double h_center_deg, double q,
                               double h_shift_deg, double s_gain,
                               double l_gain);

/* ---------------------------------------------------------------------------
 * LUT 模式（节点属性 codegenMode=lut）：H 域三张表（H 偏移/S 乘子/L 乘
 * 子，含高斯权重 exp）按生成期参数烘焙为 static const（wrapper 内），
 * 运行期纯查表零 exp 求值。
 * ------------------------------------------------------------------------- */

/**
 * @brief 色彩控制器 LUT 查表施加：逐像素查 shift/s_mul/l_mul 三表。
 *
 * 与 isp_color_controller_apply 直算逐位一致（表项为该 H 值上 exp 精确
 * 权重预计算，Dart 侧本就建同三张表，见 adjustHslBandRows）。
 * 调用契约：帧 H 值 <= max_value 且表长 >= max_value+1。
 *
 * @param src        输入 HSL 交织帧（w*h*3 个 uint16_t）。
 * @param dst        输出帧（w*h*3，调用方提供，可与 src 同址）。
 * @param w          帧宽。
 * @param h          帧高。
 * @param max_value  采样最大值。
 * @param shift_lut  H 偏移表（int32，可负）。
 * @param s_mul_lut  S 乘子表。
 * @param l_mul_lut  L 乘子表。
 * @return ISP_OK / ISP_ERR_ARG / ISP_ERR_SIZE。
 */
int isp_color_controller_lut_apply(const uint16_t *src, uint16_t *dst,
                                   int w, int h, int max_value,
                                   const int32_t *shift_lut,
                                   const double *s_mul_lut,
                                   const double *l_mul_lut);

#ifdef __cplusplus
} /* extern "C" */
#endif

#endif /* ISP_COLOR_CONTROLLER_H */
