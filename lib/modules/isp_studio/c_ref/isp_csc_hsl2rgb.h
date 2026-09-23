/**
 * @file isp_csc_hsl2rgb.h
 * @brief ISP Studio C99 参考实现 —— HSL→RGB 色彩空间转换（节点 csc_hsl2rgb）。
 *
 * Dart 语义来源：lib/modules/isp_studio/pipeline/isp_kernels.dart
 * `hslToRgb` + `_hueToRgb`。单像素公式与工具见 isp_csc_common.h。
 */

#ifndef ISP_CSC_HSL2RGB_H
#define ISP_CSC_HSL2RGB_H

#include "isp_common.h"

#ifdef __cplusplus
extern "C" {
#endif

/**
 * @brief HSL→RGB（节点 csc_hsl2rgb）。
 *
 * H 输入先归一化再按 % 1.0 环绕（H = max_value 时回到 0°）；S = 0 时
 * R=G=B=L；否则按 hueToRgb 分段逻辑展开。
 *
 * @param hsl       输入 HSL 交织帧（w*h*3）。
 * @param w         帧宽（>0）。
 * @param h         帧高（>0）。
 * @param max_value 采样最大值（>0）。
 * @param out       输出 RGB 交织帧（w*h*3，调用方提供，可同址就地）。
 * @return ISP_OK 或负错误码。
 */
int isp_csc_hsl_to_rgb(const uint16_t *hsl, int w, int h, int max_value,
                       uint16_t *out);

#ifdef __cplusplus
} /* extern "C" */
#endif

#endif /* ISP_CSC_HSL2RGB_H */
