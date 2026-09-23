/**
 * @file isp_csc_yuv2hsl.h
 * @brief ISP Studio C99 参考实现 —— YUV→HSL 色彩空间转换（节点 csc_yuv2hsl，
 *        单遍融合：先定点算 RGB 中间值再求 HSL，无中间缓冲）。
 *
 * Dart 语义来源：lib/modules/isp_studio/pipeline/isp_kernels.dart `yuvToHsl`。
 * 单像素公式与工具见 isp_csc_common.h。
 */

#ifndef ISP_CSC_YUV2HSL_H
#define ISP_CSC_YUV2HSL_H

#include "isp_common.h"

#ifdef __cplusplus
extern "C" {
#endif

/**
 * @brief YUV→HSL（节点 csc_yuv2hsl，单遍融合）。
 *
 * 循环内先按 `yuvToRgb` 的定点公式算出 RGB 中间值（含钳位），再按
 * `rgbToHsl` 的逻辑求 H/S/L，不分配中间缓冲；数值结果与 YUV→RGB→HSL
 * 两段中转逐点一致。
 *
 * @param yuv       输入 YUV 交织帧（w*h*3）。
 * @param w         帧宽（>0）。
 * @param h         帧高（>0）。
 * @param max_value 采样最大值（>0）。
 * @param out       输出 HSL 交织帧（w*h*3，调用方提供，可同址就地）。
 * @return ISP_OK 或负错误码。
 */
int isp_csc_yuv_to_hsl(const uint16_t *yuv, int w, int h, int max_value,
                       uint16_t *out);

#ifdef __cplusplus
} /* extern "C" */
#endif

#endif /* ISP_CSC_YUV2HSL_H */
