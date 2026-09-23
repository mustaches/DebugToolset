/**
 * @file isp_dpc.h
 * @brief ISP Studio C99 参考实现 —— 坏点校正节点（dpc）。
 *
 * 覆盖节点：
 * - dpc（坏点校正，W06/W07、N06–N09）：与同相位（mono 为全像素）3x3
 *   邻域中位数比较，离群超过 threshold（满量程百分比）即判定为坏点；
 *   median 模式用邻域中位数替换，directional 模式沿梯度最小方向取
 *   两点平均替换（保边更好）。
 *
 * 对应的 Dart 语义来源：
 * - lib/modules/isp_studio/pipeline/isp_kernels.dart `applyDpc`
 *   （邻域收集经公共 helper isp_phase_neighbors + isp_median_u16，
 *   与 Dart `_phaseNeighbors`/`_sortedValues` 逐位一致）。
 *
 * 规范要点速览见 isp_common.h 文件头注释。
 */

#ifndef ISP_DPC_H
#define ISP_DPC_H

#include "isp_common.h"

#ifdef __cplusplus
extern "C" {
#endif

/**
 * @brief DPC 替换模式（对应 Dart `applyDpc` 的 mode 字符串参数）。
 */
typedef enum IspDpcMode {
  /** 'median'：用邻域中位数替换坏点。 */
  ISP_DPC_MEDIAN = 0,
  /** 'directional'：沿梯度最小方向取对称两点平均替换。 */
  ISP_DPC_DIRECTIONAL = 1
} IspDpcMode;

/**
 * @brief 坏点校正：离群超阈值即替换，原地修改。
 *
 * Dart 来源：isp_kernels.dart `applyDpc`。
 *
 * 算法步骤（与 Dart 逐项对应）：
 * 1. 阈值换算 thr = threshold / 100 * max_value（满量程百分比 → 采样值，
 *    双精度浮点，与像素-中位数差比较时 Dart 将整数差提升为 double，
 *    差值最大 65535，double 可精确表示，C 侧同式逐位一致）；
 * 2. 逐像素收集处理邻域：pattern 为 NULL（mono）取全像素 3x3 的 8 邻域
 *    （步进 ±1），非 NULL（Bayer）取同相位最多 8 邻域（步进 ±2），
 *    中心自身不收集、越界裁剪（复用 isp_phase_neighbors）；
 * 3. 邻域排序取上中位 med（复用 isp_median_u16，Dart `vals[n ~/ 2]`）；
 * 4. |buf[i] - med| <= thr 判为非坏点，跳过；
 * 5. median 模式直接替换为 med；directional 模式在水平/垂直/主对角/
 *    副对角四个方向各取一对对称点（间距同邻域步进），选 |va - vb|
 *    最小的一对，写 (va + vb + 1) >> 1；四方向全越界时回退 med。
 *
 * 本函数无 scratch 需求（邻域缓冲为固定 8 元素栈数组）。
 *
 * @param buf       像素缓冲（w*h 个 uint16_t），原地修改。
 * @param width     帧宽（> 0）。
 * @param height    帧高（> 0）。
 * @param pattern   Bayer 模式指针；NULL 表示 16 位 mono（只判空，与
 *                  isp_phase_neighbors 约定一致）。
 * @param threshold 离群阈值，满量程百分比（Dart 默认 5.0）。
 * @param mode      替换模式（ISP_DPC_MEDIAN / ISP_DPC_DIRECTIONAL）。
 * @param max_value 采样最大值（Dart 默认 65535）。
 * @return ISP_OK 成功；ISP_ERR_ARG 空指针或非法模式；
 *         ISP_ERR_SIZE 宽高 <= 0。
 */
int isp_dpc_apply(uint16_t *buf, int width, int height,
                  const IspBayerPattern *pattern, double threshold,
                  IspDpcMode mode, int max_value);

#ifdef __cplusplus
} /* extern "C" */
#endif

#endif /* ISP_DPC_H */
