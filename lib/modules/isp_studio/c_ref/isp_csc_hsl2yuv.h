/**
 * @file isp_csc_hsl2yuv.h
 * @brief ISP Studio C99 参考实现 —— HSL→YUV 色彩空间转换（节点 csc_hsl2yuv，
 *        单遍融合：先算 RGB 中间值再定点求 YUV，无中间缓冲）。
 *
 * Dart 语义来源：lib/modules/isp_studio/pipeline/isp_kernels.dart `hslToYuv`。
 * 单像素公式与工具见 isp_csc_common.h。
 */

#ifndef ISP_CSC_HSL2YUV_H
#define ISP_CSC_HSL2YUV_H

#include "isp_common.h"

#ifdef __cplusplus
extern "C" {
#endif

/**
 * @brief HSL→YUV（节点 csc_hsl2yuv，单遍融合）。
 *
 * 循环内先按 `hslToRgb` 的逻辑算出 RGB 中间值（含 _clampTo 舍入与钳位），
 * 再按 `rgbToYuv` 的 BT.601 全范围定点公式求 Y/U/V，不分配中间缓冲；
 * 数值结果与 HSL→RGB→YUV 两段中转逐点一致。
 *
 * @param hsl       输入 HSL 交织帧（w*h*3）。
 * @param w         帧宽（>0）。
 * @param h         帧高（>0）。
 * @param max_value 采样最大值（>0）。
 * @param out       输出 YUV 交织帧（w*h*3，调用方提供，可同址就地）。
 * @return ISP_OK 或负错误码。
 */
int isp_csc_hsl_to_yuv(const uint16_t *hsl, int w, int h, int max_value,
                       uint16_t *out);

#ifdef __cplusplus
} /* extern "C" */
#endif

#endif /* ISP_CSC_HSL2YUV_H */
