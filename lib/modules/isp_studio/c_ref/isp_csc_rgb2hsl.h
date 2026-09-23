/**
 * @file isp_csc_rgb2hsl.h
 * @brief ISP Studio C99 参考实现 —— RGB→HSL 色彩空间转换（节点 csc_rgb2hsl）。
 *
 * Dart 语义来源：lib/modules/isp_studio/pipeline/isp_kernels.dart `rgbToHsl`。
 * 单像素公式与工具见 isp_csc_common.h。
 */

#ifndef ISP_CSC_RGB2HSL_H
#define ISP_CSC_RGB2HSL_H

#include "isp_common.h"

#ifdef __cplusplus
extern "C" {
#endif

/**
 * @brief RGB→HSL（节点 csc_rgb2hsl）。
 *
 * H 按 0..360° 映射到 0..max_value，S/L 映射到 0..max_value；
 * 灰像素（mx == mn）时 H=S=0。
 *
 * @param rgb       输入 RGB 交织帧（w*h*3）。
 * @param w         帧宽（>0）。
 * @param h         帧高（>0）。
 * @param max_value 采样最大值（>0）。
 * @param out       输出 HSL 交织帧（w*h*3，调用方提供，可同址就地）。
 * @return ISP_OK 或负错误码。
 */
int isp_csc_rgb_to_hsl(const uint16_t *rgb, int w, int h, int max_value,
                       uint16_t *out);

#ifdef __cplusplus
} /* extern "C" */
#endif

#endif /* ISP_CSC_RGB2HSL_H */
