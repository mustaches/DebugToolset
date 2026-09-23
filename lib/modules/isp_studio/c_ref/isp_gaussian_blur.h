/**
 * @file isp_gaussian_blur.h
 * @brief ISP Studio C99 参考实现 —— 高斯模糊（节点 gaussian_blur）。
 *
 * 覆盖节点：gaussian_blur。
 * 对应 Dart 函数：lib/modules/isp_studio/pipeline/isp_kernels.dart
 * `applyGaussianBlur`（可分离两趟高斯：水平 + 垂直，核半径 ceil(3σ)、
 * 归一化权重、边界复制、strength 强度混合；mono=1 / 交织=3 通道）。
 *
 * 内存模型（规范第 2 条）：
 * Dart 原实现使用整帧 Float64List 作为水平趟结果 tmp。嵌入式帧缓冲紧张，
 * 本实现改为 **(2*radius+1) 行环形行缓冲**：每行的水平模糊值仅是输入行
 * 的纯函数，与计算顺序无关，逐行惰性计算并按行号 mod kLen 取槽位，窗口
 * 内行数 <= kLen 故槽位不冲突，结果与 Dart 整帧 tmp **逐位一致**。
 * scratch 布局：前 kLen 个 double 为高斯权重核，其后 kLen * w * channels
 * 个 double 为环形行缓冲（均为 double，8 字节对齐由调用方保证基址对齐即可）。
 *
 * 数值语义与 Dart 逐位一致的关键点：
 * - 权重 exp(-(i*i) / (2*σ*σ))，按 i 升序累加 kSum 后逐个 /= kSum；
 * - 水平/垂直趟均按 k 升序累加，边界下标钳位（复制边缘像素）；
 * - 写回 (orig + (acc - orig) * strength).round()，Dart round() 与 C
 *   round() 同为半程远离零的四舍五入；写回 Uint16List 按 mod 2^16 截断，
 *   与 C 的 (uint16_t) 转换同义（strength<=1 时为凸组合不会越界）。
 */

#ifndef ISP_GAUSSIAN_BLUR_H
#define ISP_GAUSSIAN_BLUR_H

#include "isp_common.h"

#include <math.h>

#ifdef __cplusplus
extern "C" {
#endif

/**
 * @brief 高斯模糊所需 scratch 字节数。
 *
 * 推导：kLen = 2*radius+1；scratch = kLen 个 double（权重核）
 *      + kLen * w * channels 个 double（环形行缓冲）。
 * radius 可由 isp_gaussian_blur_radius(sigma) 求得。
 */
#define ISP_GAUSSIAN_BLUR_SCRATCH_BYTES(w, channels, radius)            \
  ((size_t)(2 * (radius) + 1) * sizeof(double) +                       \
   (size_t)(2 * (radius) + 1) * (size_t)(w) * (size_t)(channels) *     \
       sizeof(double))

/**
 * @brief 由 σ 求高斯核半径 radius = ceil(3σ)。
 *
 * Dart 来源：applyGaussianBlur 中 `(3 * sigma).ceil()`。
 * 供调用方代入 ISP_GAUSSIAN_BLUR_SCRATCH_BYTES 计算 scratch 大小。
 *
 * @param sigma 高斯标准差。
 * @return 核半径；sigma <= 0 时返回 0（对应 Dart 的提前返回，为空操作）。
 */
ISP_INLINE int isp_gaussian_blur_radius(double sigma) {
  if (sigma <= 0.0) return 0;
  return (int)ceil(3.0 * sigma);
}

/**
 * @brief 高斯模糊（可分离两趟，原地处理）。
 *
 * Dart 来源：isp_kernels.dart `applyGaussianBlur`。
 *
 * 处理流程：
 * 1. 计算核半径 radius = ceil(3σ)，权重 v = exp(-(i*i)/(2σ²)) 归一化；
 * 2. 水平趟：逐行对 [x-radius, x+radius] 窗口按权重卷积，下标钳位到
 *    图内（边界复制），结果写入环形行缓冲（每行仅在其首次被垂直趟
 *    需要时惰性计算，保证读到的是未被垂直趟覆盖的原始输入行）；
 * 3. 垂直趟：对窗口内各行水平结果按权重累加，再做强度混合
 *    out = orig + (acc - orig) * strength，四舍五入后写回 data。
 *
 * @param data     像素缓冲（w*h*channels 个 uint16_t），原地修改。
 * @param width    帧宽（> 0）。
 * @param height   帧高（> 0）。
 * @param channels 通道数（>= 1；mono=1，交织 RGB=3）。
 * @param sigma    高斯标准差；<= 0 时为空操作（对应 Dart 提前返回）。
 * @param strength 混合强度；<= 0 时为空操作（对应 Dart 提前返回）。
 * @param scratch  临时缓冲，至少
 *                 ISP_GAUSSIAN_BLUR_SCRATCH_BYTES(width, channels,
 *                 isp_gaussian_blur_radius(sigma)) 字节，8 字节对齐。
 * @return ISP_OK 成功；ISP_ERR_ARG 空指针或 channels < 1；
 *         ISP_ERR_SIZE 宽高 <= 0。
 */
int isp_gaussian_blur_apply(uint16_t *data, int width, int height,
                            int channels, double sigma, double strength,
                            void *scratch);

#ifdef __cplusplus
} /* extern "C" */
#endif

#endif /* ISP_GAUSSIAN_BLUR_H */
