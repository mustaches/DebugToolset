/**
 * @file isp_ccm.h
 * @brief ISP Studio C99 参考实现 —— 色彩校正矩阵节点（ccm）。
 *
 * 覆盖节点：ccm（3x3 行主序色彩校正矩阵，原地作用于交织 RGB 帧）。
 *
 * 对应的 Dart 来源：lib/modules/isp_studio/pipeline/isp_kernels.dart
 * - `applyCcm` → isp_ccm_apply
 *
 * 内存契约：无需 scratch（Dart 侧也只有矩阵的 9 元素定点副本，放栈上即可）。
 */

#ifndef ISP_CCM_H
#define ISP_CCM_H

#include "isp_common.h"

#ifdef __cplusplus
extern "C" {
#endif

/**
 * @brief 原地施加 3x3 行主序色彩校正矩阵，结果钳位到 0..max_value。
 *
 * Dart 来源：isp_kernels.dart `applyCcm`。
 * 矩阵 9 个 double 元素先转 2^20 定点（(x * 2^20).round()，四舍五入
 * 远离零，C 侧用 llround）；单位矩阵（定点表示下精确判断）直接跳过。
 * 每像素：
 *   nr = (m0*r + m1*g + m2*b + 2^19) >> 20   （ng、nb 同理）
 * 乘加在 64 位整数域进行（Dart int 为 64 位，注释亦声明 64 位不溢出），
 * >> 为算术右移（对负数等价于向下取整除法，与 Dart int 的 >> 一致），
 * 最后钳位到 [0, max_value]。
 *
 * @param rgb       交织三通道帧（w*h*3 个 uint16_t，原地修改）。
 * @param w         帧宽。
 * @param h         帧高。
 * @param matrix    9 元素行主序矩阵（double）。
 * @param max_value 采样最大值（如 10bit 为 1023）。
 * @return ISP_OK 成功；ISP_ERR_ARG 空指针；ISP_ERR_SIZE 宽高为负。
 */
int isp_ccm_apply(uint16_t *rgb, int w, int h, const double *matrix,
                  int max_value);

#ifdef __cplusplus
} /* extern "C" */
#endif

#endif /* ISP_CCM_H */
