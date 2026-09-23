/**
 * @file isp_morphology.h
 * @brief ISP Studio C99 参考实现 —— 形态学腐蚀/膨胀（节点 morphology）。
 *
 * 覆盖节点：morphology。
 * 对应 Dart 函数：lib/modules/isp_studio/pipeline/isp_kernels.dart
 * `applyMorphology`（方形结构元 (2*radius+1)² 的逐通道极小=腐蚀 /
 * 极大=膨胀滤波；可分离两趟（水平 + 垂直），结果与直接二维窗口完全
 * 一致；边界按可用邻域取极值，即窗口裁剪到图内而非复制边缘）。
 *
 * 内存模型（规范第 2 条）：
 * Dart 原实现使用整帧 Uint16List tmp。本实现改为 **(2*radius+1) 行环形
 * 行缓冲**：每行的水平极值仅是输入行的纯函数，逐行惰性计算、行号
 * mod kLen 取槽位，窗口内行数 <= kLen 故槽位不冲突；极值为整数运算，
 * 与 Dart 整帧 tmp **逐位一致**。scratch 仅 kLen * w * channels 个
 * uint16_t，对齐无特殊要求。
 *
 * 数值语义与 Dart 逐位一致的关键点：
 * - 水平趟窗口 [x-radius, x+radius] 与垂直趟窗口 [y-radius, y+radius]
 *   均裁剪到图内（可用邻域取极值，不做边界复制）；
 * - 比较为严格小于/大于（erode ? u < v : u > v），初值取窗口首元素；
 * - 极值取自原数据，必然在 [0, max_value] 内，无需钳位。
 */

#ifndef ISP_MORPHOLOGY_H
#define ISP_MORPHOLOGY_H

#include "isp_common.h"

#ifdef __cplusplus
extern "C" {
#endif

/**
 * @brief 形态学所需 scratch 字节数。
 *
 * 推导：kLen = 2*radius+1 行环形行缓冲，每行 w*channels 个 uint16_t。
 */
#define ISP_MORPHOLOGY_SCRATCH_BYTES(w, channels, radius)              \
  ((size_t)(2 * (radius) + 1) * (size_t)(w) * (size_t)(channels) *     \
   sizeof(uint16_t))

/**
 * @brief 形态学腐蚀/膨胀（可分离两趟，原地处理）。
 *
 * Dart 来源：isp_kernels.dart `applyMorphology`。
 *
 * 处理流程：
 * 1. 水平趟：每行在裁剪到图内的窗口 [x0, x1] 内取极小（腐蚀）或
 *    极大（膨胀），写入环形行缓冲（每行仅在其首次被垂直趟需要时
 *    惰性计算，读到的是未被垂直趟覆盖的原始输入行）；
 * 2. 垂直趟：对水平趟结果按列在窗口 [y0, y1] 内取同种极值，写回
 *    data。两趟极值复合等价于 (2*radius+1)² 方形窗口一次取极值。
 *
 * @param data     像素缓冲（w*h*channels 个 uint16_t），原地修改。
 * @param width    帧宽（> 0）。
 * @param height   帧高（> 0）。
 * @param channels 通道数（>= 1；mono=1，交织 RGB=3，逐通道独立）。
 * @param erode    true=腐蚀（极小滤波），false=膨胀（极大滤波）。
 * @param radius   结构元半径；<= 0 时为空操作（对应 Dart 提前返回）。
 * @param scratch  临时缓冲，至少
 *                 ISP_MORPHOLOGY_SCRATCH_BYTES(width, channels, radius)
 *                 字节。
 * @return ISP_OK 成功；ISP_ERR_ARG 空指针或 channels < 1；
 *         ISP_ERR_SIZE 宽高 <= 0。
 */
int isp_morphology_apply(uint16_t *data, int width, int height,
                         int channels, bool erode, int radius,
                         uint16_t *scratch);

#ifdef __cplusplus
} /* extern "C" */
#endif

#endif /* ISP_MORPHOLOGY_H */
