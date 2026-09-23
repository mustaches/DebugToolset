/**
 * @file isp_sharpen.h
 * @brief ISP Studio C99 参考实现 —— 锐化节点（sharpen）。
 *
 * 覆盖节点：sharpen。
 * 对应 Dart 函数（lib/modules/isp_studio/pipeline/isp_kernels.dart）：
 * - applySharpen  亮度 unsharp mask：detail = Y − 3x3 盒式模糊，
 *                 |detail| < threshold 视为噪声置零，Y' = Y + amount×detail，
 *                 三通道按 Y'/Y 等比缩放并截位到 [0, maxValue]。
 *
 * 规范要点速览见 isp_common.h 文件头注释（C99 子集、零 malloc、帧约定
 * uint16_t* + int w/h + int max_value、错误码、数值语义与 Dart 逐位一致）。
 */

#ifndef ISP_SHARPEN_H
#define ISP_SHARPEN_H

#include "isp_common.h"

#ifdef __cplusplus
extern "C" {
#endif

/**
 * @brief sharpen 所需 scratch 字节数。
 *
 * 布局：ys 亮度平面 w*h 个 uint16_t（BT.601 定点亮度，先行全帧算出，
 * 锐化循环内只读 ys、只写 rgb，因此可安全原地处理 rgb）。
 */
#define ISP_SHARPEN_SCRATCH_BYTES(w, h) \
  ((size_t)(w) * (size_t)(h) * sizeof(uint16_t))

/**
 * @brief 锐化（节点 sharpen）：亮度 unsharp mask，原地处理交织 RGB 帧。
 *
 * Dart 来源：isp_kernels.dart `applySharpen`。
 * 处理流程（与 Dart 逐步对应）：
 * 1. amount == 0 时不做任何修改直接返回（Dart 早退）；
 * 2. 全帧求 BT.601 定点亮度 ys = (19595R + 38470G + 7471B + 32768) >> 16
 *    （与 rgbToYuv 的 Y 同一公式；系数和恰为 65536，结果不超 uint16，无钳位）；
 * 3. 逐像素：detail = Y − 3x3 盒式均值（含中心、越界裁剪、double 除法）；
 * 4. |detail| < threshold 置零；detail == 0 或 Y <= 0 时该像素保持不变；
 * 5. Y' = clamp(Y + amount×detail, 0, maxValue)，scale = Y'/Y，
 *    三通道分别乘 scale 后经 _clampTo（四舍五入+钳位）写回。
 *
 * @param rgb       交织 RGB 帧（w*h*3 个 uint16_t），原地修改。
 * @param width     帧宽（> 0）。
 * @param height    帧高（> 0）。
 * @param amount    锐化强度（detail 的增益，0 表示关闭）。
 * @param threshold 噪声门限（码值量纲），|detail| 小于它时置零。
 * @param max_value 采样最大值（1..65535）。
 * @param scratch   临时缓冲，至少 ISP_SHARPEN_SCRATCH_BYTES(width, height)。
 * @return ISP_OK 成功；ISP_ERR_ARG 空指针或 max_value 非法；
 *         ISP_ERR_SIZE 宽高 <= 0。
 */
int isp_sharpen_apply(uint16_t *rgb, int width, int height, double amount,
                      double threshold, int max_value, uint16_t *scratch);

#ifdef __cplusplus
} /* extern "C" */
#endif

#endif /* ISP_SHARPEN_H */
