/**
 * @file isp_demosaic.h
 * @brief ISP Studio C99 参考实现 —— 去马赛克基础组（demosaic 节点）。
 *
 * 覆盖节点：demosaic 的 bilinear（Bayer）路径与全部非 Bayer CFA 路径
 * （RCCB / RCCG / RCCC / RYYCy / RGB-IR）。
 *
 * 对应 Dart 函数（lib/modules/isp_studio/pipeline/isp_kernels.dart）：
 * - demosaicBilinear（含 _avgNeighbors / _demosaicPixel / 内部像素快速路径；
 *   快速路径与通用邻域平均在内部像素上代数等价，C 版统一走通用路径，逐位一致）
 * - demosaicRccb（含 rccg 开关）
 * - demosaicRccc
 * - demosaicRyycy
 * - demosaicRgbIr（含 irSubtraction 红外扣除）
 * 以及公共 helper _interpChannel / _channelAt / _clampTo。
 *
 * 通道 id 与 CFA 相位函数复用 isp_common.h（ISP_CH_* / isp_cfa_*_at /
 * isp_bayer_color_at）。所有函数均不需 scratch：逐像素邻域平均，
 * 输出缓冲（w*h*3 个 uint16_t）由调用方提供。
 */

#ifndef ISP_DEMOSAIC_H
#define ISP_DEMOSAIC_H

#include "isp_common.h"

#ifdef __cplusplus
extern "C" {
#endif

/**
 * @brief Bayer 帧 bilinear 去马赛克为交织 RGB（w*h*3）。
 *
 * Dart 来源：isp_kernels.dart `demosaicBilinear`。
 * 语义：自身通道保留真值；R/B 站点缺 G 取轴向 4 邻居平均；G 站点缺 R/B
 * 取该颜色轴向邻居平均；R<->B 站点取对角邻居平均。边缘用可用邻居，
 * 平均式为 (sum + count/2) / count（Dart `(sum + count ~/ 2) ~/ count`，
 * 即四舍五入的整数除法）；无可用邻居时回退像素自身值。
 * 本路径不钳位（平均值天然不超界，与 Dart 一致）。
 *
 * @param bayer   输入 Bayer 帧（w*h 个 uint16_t）。
 * @param width   帧宽（> 0）。
 * @param height  帧高（> 0）。
 * @param pattern Bayer 模式。
 * @param rgb_out 输出交织 RGB 缓冲（w*h*3 个 uint16_t，调用方提供）。
 * @return ISP_OK；空指针返回 ISP_ERR_ARG；宽高 <= 0 返回 ISP_ERR_SIZE。
 */
int isp_demosaic_bilinear(const uint16_t *bayer, int width, int height,
                          IspBayerPattern pattern, uint16_t *rgb_out);

/**
 * @brief RCCB / RCCG 去马赛克。
 *
 * Dart 来源：isp_kernels.dart `demosaicRccb`（rccg 参数）。
 * RCCB：R、B 直接插值，G = round(C - (R+B)/2.0)（Dart `(r + b) / 2` 为
 * double 除法，经 _clampTo 的 round() 四舍五入、半值远离零）。
 * RCCG：R、G 直接插值，B = C - R - G（纯整数，经 _clampTo 钳位）。
 * 缺失通道经 3x3（不够再 5x5）邻域同类样本平均插值，仍无则回退自身值。
 *
 * @param mosaic   输入马赛克帧（w*h 个 uint16_t）。
 * @param width    帧宽（> 0）。
 * @param height   帧高（> 0）。
 * @param rccg     false=RCCB 布局，true=RCCG 布局。
 * @param max_value 采样最大值（如 10bit 为 1023，16bit 为 65535）。
 * @param rgb_out  输出交织 RGB 缓冲（w*h*3，调用方提供）。
 * @return ISP_OK / ISP_ERR_ARG / ISP_ERR_SIZE。
 */
int isp_demosaic_rccb(const uint16_t *mosaic, int width, int height,
                      bool rccg, int max_value, uint16_t *rgb_out);

/**
 * @brief RCCC 去马赛克：仅 R 与 Clear 样本。
 *
 * Dart 来源：isp_kernels.dart `demosaicRccc`。
 * C ≈ R+G+B，无其他信息时设 G = B = round((C - R) / 2.0)
 * （Dart `(c - r) / 2` 为 double 除法，经 _clampTo round()）。
 *
 * @param mosaic   输入马赛克帧（w*h 个 uint16_t）。
 * @param width    帧宽（> 0）。
 * @param height   帧高（> 0）。
 * @param max_value 采样最大值。
 * @param rgb_out  输出交织 RGB 缓冲（w*h*3，调用方提供）。
 * @return ISP_OK / ISP_ERR_ARG / ISP_ERR_SIZE。
 */
int isp_demosaic_rccc(const uint16_t *mosaic, int width, int height,
                      int max_value, uint16_t *rgb_out);

/**
 * @brief RYYCy 去马赛克：Y ≈ R+G，Cy ≈ G+B。
 *
 * Dart 来源：isp_kernels.dart `demosaicRyycy`。
 * G = clamp(Y - R)（钳位后的值），B = clamp(Cy - G)（用上一步钳位后的 G）。
 * 均为纯整数路径。
 *
 * @param mosaic   输入马赛克帧（w*h 个 uint16_t）。
 * @param width    帧宽（> 0）。
 * @param height   帧高（> 0）。
 * @param max_value 采样最大值。
 * @param rgb_out  输出交织 RGB 缓冲（w*h*3，调用方提供）。
 * @return ISP_OK / ISP_ERR_ARG / ISP_ERR_SIZE。
 */
int isp_demosaic_ryycy(const uint16_t *mosaic, int width, int height,
                       int max_value, uint16_t *rgb_out);

/**
 * @brief RGB-IR（4x4 CFA）去马赛克，含红外分量扣除。
 *
 * Dart 来源：isp_kernels.dart `demosaicRgbIr`。
 * R/G/B 各自从 4x4 采样点插值，IR 同样插值；每个通道减去
 * ir * irSubtraction（double 乘法）后经 _clampTo（double 比较 +
 * round() 四舍五入、半值远离零）写回。
 *
 * @param mosaic         输入马赛克帧（w*h 个 uint16_t）。
 * @param width          帧宽（> 0）。
 * @param height         帧高（> 0）。
 * @param max_value      采样最大值。
 * @param ir_subtraction 红外扣除系数（Dart 侧语义 0..1，默认 0.5；
 *                       不做范围钳制以保持与 Dart 逐位一致）。
 * @param rgb_out        输出交织 RGB 缓冲（w*h*3，调用方提供）。
 * @return ISP_OK / ISP_ERR_ARG / ISP_ERR_SIZE。
 */
int isp_demosaic_rgb_ir(const uint16_t *mosaic, int width, int height,
                        int max_value, double ir_subtraction,
                        uint16_t *rgb_out);

#ifdef __cplusplus
} /* extern "C" */
#endif

#endif /* ISP_DEMOSAIC_H */
