/**
 * @file isp_multi_band_eq.h
 * @brief ISP Studio C99 参考实现 —— 多段色彩均衡器（多组高斯色相带的
 *        并联/串联合成）。
 *
 * 覆盖节点：multi_band_eq（多段色彩均衡器）。
 *
 * 对应的 Dart 来源：
 * - lib/modules/isp_studio/pipeline/isp_kernels.dart
 *   - `multiBandLuts`（多段合成三张 H 域 LUT：并联加权求和 / 串联按序
 *     级联；单段捷径委派 `hslBandLuts`）
 *   - `applyHslBandLuts`（查表施加：3 次查表 + 2 次乘法 + 1 次取模）
 *   - `_clampTo`（浮点路径的收尾钳位）
 * - pipeline_runner.dart 的 `case 'multi_band_eq'`（段参数缺省回退恒等
 *   默认、band_count 钳位 1..8、全段恒等直通）。
 * hsl_band_pool.dart 的条带池并行为 PC 侧调度优化（逐像素无依赖，
 * 与串行逐位一致），不移植。
 *
 * 内存模型：输出帧由调用方提供；直算（func 模式）无需任何 LUT 缓冲，
 * LUT 模式的三张表由调用方（wrapper）以 static const 烘焙传入。
 * 支持 src == dst 原地处理（逐像素独立，无跨像素读）。
 *
 * 规范要点速览见 isp_common.h 文件头注释。
 */

#ifndef ISP_MULTI_BAND_EQ_H
#define ISP_MULTI_BAND_EQ_H

#include "isp_common.h"

#ifdef __cplusplus
extern "C" {
#endif

/** 段数上限（与 Dart kMultiBandEqMaxBands 一致）。 */
#define ISP_MULTI_BAND_EQ_MAX_BANDS 8

/**
 * @brief 多段色彩均衡器的单段参数（与色彩控制器同构的高斯色相带）。
 *
 * 权重 w(Δ) = exp(-(Δ/σ)²/2)，Δ 为色环最短角距（0..180°），σ = 45°/q。
 */
typedef struct {
  double h;  /**< 色相带中心（度，0..360，内部按色环最短角距环绕） */
  double q;  /**< 带宽品质因数（必须为正有限数；σ = 45°/q） */
  double dh; /**< 带内满权重处的色相偏移（度，-180..180） */
  double s;  /**< 带内满权重处的饱和度增益（0..5） */
  double l;  /**< 带内满权重处的亮度增益（0..5） */
} IspMultiBandEqBand;

/**
 * @brief 多段合成三张 H 域 LUT（生成期烘焙 / 运行期建表共用）。
 *
 * 并联（serial == 0）：全部段在原 H 上各取权重，ΔH 加权求和后钳位
 * ±180°，S/L 乘子按 1+Σw·(g−1) 合成后钳位 0..5；
 * 串联（serial != 0）：按段序级联，第 i 段在前段更新后的中间色相
 * （每段累加后模 360 归一到 [0,360)）上取权重，S/L 乘性合成（钳位
 * 0..5），最终偏移取首尾色环最短路径。
 * band_count == 1 时两种模式均走色彩控制器同公式捷径（与 Dart
 * multiBandLuts 的单段委派逐位一致）；band_count == 0 合成恒等 LUT。
 * 表长须 >= max_value + 1。
 *
 * @param shift_lut  输出：H 偏移表（int32，可负）。
 * @param s_mul_lut  输出：S 乘子表。
 * @param l_mul_lut  输出：L 乘子表。
 * @param max_value  采样最大值（> 0）。
 * @param serial     0 = 并联，非 0 = 串联。
 * @param band_count 段数（0..ISP_MULTI_BAND_EQ_MAX_BANDS）。
 * @param bands      段参数数组（band_count > 0 时非空）。
 * @return ISP_OK 成功；ISP_ERR_ARG 空指针或段数非法或 q 非正。
 */
int isp_multi_band_eq_build_luts(int32_t *shift_lut, double *s_mul_lut,
                                 double *l_mul_lut, int max_value, int serial,
                                 int band_count, const IspMultiBandEqBand *bands);

/**
 * @brief LUT 查表施加：逐像素 3 次查表 + 2 次乘法 + 1 次取模。
 *
 * 与 Dart applyHslBandLuts 逐位一致（同 isp_color_controller_lut_apply
 * 的形态）。调用契约：帧 H 值 <= max_value 且表长 >= max_value+1。
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
int isp_multi_band_eq_lut_apply(const uint16_t *src, uint16_t *dst,
                                int w, int h, int max_value,
                                const int32_t *shift_lut,
                                const double *s_mul_lut,
                                const double *l_mul_lut);

/**
 * @brief 直算施加（func 模式）：逐像素按段参数合成调整量（不建表）。
 *
 * 每像素的 H 量化值是整数，合成公式与 isp_multi_band_eq_build_luts
 * 在该 H 值上的表项为同一 double 表达式序列，故直算与「建表 + 查表」
 * 逐位一致（同 isp_color_controller_apply 与 lut_apply 的关系）。
 * 全部段恒等（dh==0 且 s==1 且 l==1）或 band_count == 0 时直通拷贝
 *（src == dst 时跳过拷贝）。
 *
 * @param src        输入 HSL 交织帧（w*h*3 个 uint16_t）。
 * @param dst        输出帧（w*h*3，调用方提供，可与 src 同址）。
 * @param w          帧宽（> 0）。
 * @param h          帧高（> 0）。
 * @param max_value  采样最大值（> 0）。
 * @param serial     0 = 并联，非 0 = 串联。
 * @param band_count 段数（0..ISP_MULTI_BAND_EQ_MAX_BANDS）。
 * @param bands      段参数数组（band_count > 0 时非空）。
 * @return ISP_OK / ISP_ERR_ARG / ISP_ERR_SIZE。
 */
int isp_multi_band_eq_apply(const uint16_t *src, uint16_t *dst,
                            int w, int h, int max_value, int serial,
                            int band_count, const IspMultiBandEqBand *bands);

#ifdef __cplusplus
} /* extern "C" */
#endif

#endif /* ISP_MULTI_BAND_EQ_H */
