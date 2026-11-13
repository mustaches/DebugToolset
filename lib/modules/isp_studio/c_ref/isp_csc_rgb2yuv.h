/**
 * @file isp_csc_rgb2yuv.h
 * @brief ISP Studio C99 参考实现 —— RGB→YUV 色彩空间转换（节点 csc_rgb2yuv）。
 *
 * 支持 BT.601 / BT.709 定点矩阵与 full / limited 范围折算。
 * Dart 语义来源：lib/modules/isp_studio/pipeline/isp_kernels.dart
 * `convertRgbToYuvCsc`（全范围 BT.601 快路径等价于 `rgbToYuv`）。
 * 定点系数与单像素公式见 isp_csc_common.h。
 *
 * 内存模型：单遍直写，无中间帧缓冲，不需要任何 scratch；
 * 输入/输出均为调用方提供的交织三通道帧（w*h*3 个 uint16_t）。
 */

#ifndef ISP_CSC_RGB2YUV_H
#define ISP_CSC_RGB2YUV_H

#include "isp_common.h"

#ifdef __cplusplus
extern "C" {
#endif

/* IspCscStandard / IspCscRange 定义在 isp_csc_common.h（各变体头共用）。 */
#include "isp_csc_common.h"

/**
 * @brief RGB→YUV（节点 csc_rgb2yuv）。
 *
 * 16 位 Q16 定点矩阵：Y = (cyR*r + cyG*g + cyB*b + 32768) >> 16；
 * U/V 同构后以 max_value/2 为零点偏移；limited 时再做 219/224 压缩
 * （除法为截断取整，与 Dart `~/` 一致）。
 *
 * @param rgb       输入 RGB 交织帧（w*h*3）。
 * @param w         帧宽（>0）。
 * @param h         帧高（>0）。
 * @param max_value 采样最大值（>0）。
 * @param standard  转换矩阵标准（ISP_CSC_BT601 / BT709 / BT2020）。
 * @param range     量化范围（ISP_CSC_RANGE_FULL / ISP_CSC_RANGE_LIMITED）。
 * @param out       输出 YUV 交织帧（w*h*3，调用方提供，可与 rgb 不同址；
 *                  同址就地转换亦安全，逐像素读写）。
 * @return ISP_OK 或负错误码。
 */
int isp_csc_rgb_to_yuv(const uint16_t *rgb, int w, int h, int max_value,
                       IspCscStandard standard, IspCscRange range,
                       uint16_t *out);

#ifdef __cplusplus
} /* extern "C" */
#endif

#endif /* ISP_CSC_RGB2YUV_H */
