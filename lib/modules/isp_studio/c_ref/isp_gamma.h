/**
 * @file isp_gamma.h
 * @brief ISP Studio C99 参考实现 —— 伽马/色调映射节点（gamma）。
 *
 * 覆盖节点：gamma（brightness / contrast / gamma 色调映射，16 位交织
 * RGB → 8 位 RGBA8888 输出）。
 *
 * 对应的 Dart 来源：lib/modules/isp_studio/pipeline/isp_kernels.dart
 * - `_tonemapLut`（内部 LUT 构建）+ `tonemapToRgba` → isp_gamma_tonemap_to_rgba
 *
 * 内存契约：
 * - 色调映射 LUT 大小为 max_value+1 字节（16bit 输入即 64KB），不能放栈上，
 *   由调用方提供 scratch，所需大小见 ISP_GAMMA_LUT_BYTES 宏；
 * - RGBA 输出缓冲同样由调用方提供，大小 w*h*4 字节。
 */

#ifndef ISP_GAMMA_H
#define ISP_GAMMA_H

#include "isp_common.h"

#ifdef __cplusplus
extern "C" {
#endif

/**
 * @brief 色调映射 LUT scratch 所需字节数：max_value+1 个 uint8_t。
 *
 * Dart 来源：isp_kernels.dart `_tonemapLut` 的 `Uint8List(maxValue + 1)`。
 * 用法示例：
 * @code
 * static uint8_t lut[ISP_GAMMA_LUT_BYTES(65535)];
 * static uint8_t rgba[W * H * 4];
 * isp_gamma_tonemap_to_rgba(frame, W, H, 65535, 2.2, 0.0, 1.0, rgba, lut);
 * @endcode
 */
#define ISP_GAMMA_LUT_BYTES(max_value) \
  ((size_t)((max_value) + 1) * sizeof(uint8_t))

/**
 * @brief 16 位交织 RGB → 8 位 RGBA8888 色调映射（alpha 恒 255）。
 *
 * Dart 来源：isp_kernels.dart `tonemapToRgba`（LUT 构建见 `_tonemapLut`）。
 * LUT 构建（对每个可能的输入值 v ∈ [0, max_value]）：
 *   c = v / max_value                        （double 除法）
 *   c += brightness
 *   c = (c - 0.5) * contrast + 0.5           （绕 0.5 施加对比度）
 *   c 钳位到 [0, 1]
 *   c = pow(c, 1 / gamma)                    （inv_gamma 只算一次，同 Dart）
 *   c 钳位到 [0, 1]
 *   lut[v] = round(c * 255)                  （四舍五入远离零，即 llround）
 * 逐像素：r/g/b 先钳位到 max_value（只钳上界，输入为无符号不可能为负，
 * 与 Dart 一致），再各查一次表；alpha 写 255。
 *
 * @param rgb         交织三通道帧（w*h*3 个 uint16_t）。
 * @param w           帧宽。
 * @param h           帧高。
 * @param max_value   采样最大值，必须 >= 1（Dart 中 < 1 抛参数错误）。
 * @param gamma       伽马值，必须 > 0（Dart 中 <= 0 抛参数错误）。
 * @param brightness  亮度偏移（Dart 默认 0.0）。
 * @param contrast    对比度（Dart 默认 1.0）。
 * @param out_rgba    输出 RGBA8888 缓冲（w*h*4 字节，调用方提供）。
 * @param lut_scratch 色调映射 LUT scratch（ISP_GAMMA_LUT_BYTES(max_value)
 *                    字节，调用方提供）。
 * @return ISP_OK 成功；ISP_ERR_ARG 空指针 / max_value < 1 / gamma <= 0；
 *         ISP_ERR_SIZE 宽高为负。
 */
int isp_gamma_tonemap_to_rgba(const uint16_t *rgb, int w, int h,
                              int max_value, double gamma, double brightness,
                              double contrast, uint8_t *out_rgba,
                              uint8_t *lut_scratch);

#ifdef __cplusplus
} /* extern "C" */
#endif

#endif /* ISP_GAMMA_H */
