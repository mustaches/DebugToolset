/**
 * @file isp_lsc.h
 * @brief ISP Studio C99 参考实现 —— 镜头阴影/平场校正（LSC）。
 *
 * 覆盖节点：lsc。
 * 对应 Dart 函数：lib/modules/isp_studio/pipeline/isp_kernels.dart `applyLsc`。
 *
 * 算法：以 (centerX, centerY)（归一化 0..1）为中心的径向二次增益曲面，
 * 增益 = 1 + strength * (r/rmax)^2，边缘亮中心暗，饱和截位到 [0, max_value]。
 * 增益与相位无关，Bayer/mono 通用（Dart 侧虽有 pattern 形参但函数体未使用，
 * 故本接口不保留该参数）。全程双精度浮点，与 Dart double 语义一致。
 *
 * 本内核原地处理，无需 scratch 缓冲。
 */

#ifndef ISP_LSC_H
#define ISP_LSC_H

#include "isp_common.h"

#ifdef __cplusplus
extern "C" {
#endif

/**
 * @brief 原地施加径向二次镜头阴影校正增益。
 *
 * Dart 来源：isp_kernels.dart `applyLsc`。
 *
 * 关键步骤（与 Dart 逐项对应）：
 * 1. strength == 0 时直接返回（Dart 为 double 精确比较，负值照常执行）；
 * 2. 中心像素坐标 cx = centerX * (width - 1)，cy = centerY * (height - 1)；
 * 3. rMax2 = ex*ex + ey*ey，其中 ex/ey 为 cx/cy 到两侧边缘的最大距离，
 *    即 ex = max(cx, width-1-cx)、ey = max(cy, height-1-cy)（均为 double）；
 *    rMax2 <= 0（仅 1x1 帧）时直接返回；
 * 4. 逐像素 gain = 1 + strength * (dx*dx + dy*dy) / rMax2，
 *    v = buf[i] * gain 后按 Dart `_clampTo` 语义截位：
 *    先在 double 上与 0 / max_value 比较钳位，再四舍五入（round，
 *    半值远离零；因负值已被前置钳位排除，floor(v+0.5) 等价）。
 *
 * @param buf       像素缓冲（w*h 个 uint16_t，原地修改）。
 * @param width     帧宽（> 0）。
 * @param height    帧高（> 0）。
 * @param strength  校正强度（0 = 关闭；负值会使中心亮边缘暗，Dart 未禁止）。
 * @param center_x  中心归一化横坐标（0..1，Dart 未做范围校验，越界照常计算）。
 * @param center_y  中心归一化纵坐标（0..1，同上）。
 * @param max_value 采样最大值（如 10bit 为 1023）。
 * @return ISP_OK 成功；ISP_ERR_ARG 空指针或 max_value < 0；
 *         ISP_ERR_SIZE 宽高 <= 0。
 */
int isp_lsc_apply(uint16_t *buf, int width, int height, double strength,
                  double center_x, double center_y, int max_value);

#ifdef __cplusplus
} /* extern "C" */
#endif

#endif /* ISP_LSC_H */
