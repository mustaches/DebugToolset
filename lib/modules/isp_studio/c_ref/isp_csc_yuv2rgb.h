/**
 * @file isp_csc_yuv2rgb.h
 * @brief ISP Studio C99 参考实现 —— YUV→RGB 色彩空间转换（节点 csc_yuv2rgb）。
 *
 * Dart 语义来源：lib/modules/isp_studio/pipeline/isp_kernels.dart `yuvToRgb`。
 * 定点系数与单像素公式见 isp_csc_common.h。
 */

#ifndef ISP_CSC_YUV2RGB_H
#define ISP_CSC_YUV2RGB_H

#include "isp_common.h"

#ifdef __cplusplus
extern "C" {
#endif

/**
 * @brief YUV→RGB（节点 csc_yuv2rgb）。
 *
 * BT.601 全范围 Q16 定点，U/V 以 max_value/2 为零点：
 * r = y + ((91881*v + 32768) >> 16) 等。
 *
 * @param yuv       输入 YUV 交织帧（w*h*3）。
 * @param w         帧宽（>0）。
 * @param h         帧高（>0）。
 * @param max_value 采样最大值（>0）。
 * @param out       输出 RGB 交织帧（w*h*3，调用方提供，可同址就地）。
 * @return ISP_OK 或负错误码。
 */
int isp_csc_yuv_to_rgb(const uint16_t *yuv, int w, int h, int max_value,
                       uint16_t *out);

#ifdef __cplusplus
} /* extern "C" */
#endif

#endif /* ISP_CSC_YUV2RGB_H */
