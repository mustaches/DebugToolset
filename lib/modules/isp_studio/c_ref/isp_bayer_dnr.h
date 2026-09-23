/**
 * @file isp_bayer_dnr.h
 * @brief ISP Studio C99 参考实现 —— Bayer/mono 降噪节点（bayer_dnr）。
 *
 * 覆盖节点：bayer_dnr（Bayer 降噪，W16/W17、N24/N25）。
 * 对应 Dart 函数：lib/modules/isp_studio/pipeline/isp_kernels.dart
 * `applyBayerDenoise` —— 同相位 3x3 保边加权平均，权重 1/(1+(Δ/σ)²)，
 * σ 来自 σ²=aI+b 噪声模型（a=1、b=64，σ=strength*√(I+64)）。
 *
 * 算法在写出前对整帧做快照（Dart 中 `src = Uint16List.fromList(buf)`），
 * 即所有邻域采样均取自输入原图而非已更新的像素；本实现将快照缓冲作为
 * 调用方提供的 scratch，内核零动态分配。
 *
 * 规范要点速览见 isp_common.h 文件头注释。
 */

#ifndef ISP_BAYER_DNR_H
#define ISP_BAYER_DNR_H

#include "isp_common.h"

#ifdef __cplusplus
extern "C" {
#endif

/**
 * @brief bayer_dnr 节点所需 scratch 字节数：整帧 uint16 快照。
 *
 * 推导：Dart `Uint16List.fromList(buf)` 复制整帧，长度 w*h 个 uint16_t。
 */
#define ISP_BAYER_DNR_SCRATCH_BYTES(w, h) \
  ((size_t)(w) * (size_t)(h) * sizeof(uint16_t))

/**
 * @brief Bayer/mono 同相位 3x3 保边加权降噪（原地写回）。
 *
 * Dart 来源：isp_kernels.dart `applyBayerDenoise`。
 *
 * 逐位一致要点：
 * - strength <= 0 时与 Dart 一样直接返回，不改任何像素（返回 ISP_OK）；
 * - 邻域经 isp_phase_neighbors 收集，顺序与 Dart `_phaseNeighbors`
 *   一致（dy 外层 dx 内层行优先），保证 double 累加顺序一致；
 * - σ = strength * sqrt(v + 64)（double 全程，不做定点化）；
 * - 权重 w = 1/(1+(d/σ)²)，中心像素权重固定 1.0；
 * - 结果 (sum/wsum) 经 C99 round() 舍入（与 Dart round() 同为
 *   半值远离零，此处被舍入值恒正，二者逐位一致）；
 * - 加权和为不超过样本最大值的凸组合，无需再钳位（Dart 同样无钳位）。
 *
 * @param buf      像素缓冲（w*h 个 uint16_t），原地修改。
 * @param w        帧宽（>0）。
 * @param h        帧高（>0）。
 * @param pattern  Bayer 模式指针；NULL 表示 16 位 mono（全像素 3x3）。
 *                 只判空不解引用，与 Dart `_phaseNeighbors` 一致。
 * @param strength σ 倍率；<= 0 为空操作。
 * @param scratch  调用方提供的整帧快照缓冲，大小至少
 *                 ISP_BAYER_DNR_SCRATCH_BYTES(w, h)。
 * @return ISP_OK 成功；ISP_ERR_ARG 空指针；ISP_ERR_SIZE 宽高非法。
 */
int isp_bayer_dnr_apply(uint16_t *buf, int w, int h,
                        const IspBayerPattern *pattern, double strength,
                        uint16_t *scratch);

#ifdef __cplusplus
} /* extern "C" */
#endif

#endif /* ISP_BAYER_DNR_H */
