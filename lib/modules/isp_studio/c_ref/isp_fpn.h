/**
 * @file isp_fpn.h
 * @brief ISP Studio C99 参考实现 —— 行/列固定图案噪声校正（FPN）。
 *
 * 覆盖节点：fpn。
 * 对应 Dart 函数：lib/modules/isp_studio/pipeline/isp_kernels.dart `applyFpn`
 * 及其私有 helper `_verticalBoxMean` / `_horizontalBoxMean` / `_gradientEdge`
 * / `_dilateMask` / `_clampedMedian`。
 *
 * 算法（估计与施加分离 + 边缘掩膜，逐方向执行）：
 * 1. 低通分离内容：行偏移估计前做垂直滑窗盒式均值（窗口 [y-radius, y+radius]
 *    截断），残差 = 原图 - 低通；列方向用水平滑窗均值；
 * 2. 边缘掩膜：梯度超过 2*maxCorr 的像素按 radius 沿统计垂直方向膨胀，
 *    被掩膜像素不参与中位数统计；
 * 3. 残差行/列中位数（排序后第 n>>1 项，0 基）即偏移的稳健估计；
 * 4. 校正量限幅 ±maxCorr（double 比较），v = buf - corr，v <= 0 截零，
 *    否则按 Dart round()（半值远离零）舍入后写回 Uint16List（模 2^16 截断）。
 *
 * 执行顺序：先行后列；列方向的低通/掩膜基于行校正后的画面（与 Dart 一致）。
 * Dart 侧虽有 pattern 形参但函数体未使用（行/列统计不区分相位），故本接口
 * 不保留该参数；applyFpn 也无 maxValue 形参（只做截零，不做饱和钳位）。
 *
 * 需要 scratch 缓冲（低通 + 边缘图 + 膨胀掩膜 + 滑窗列和 + 中位数收集），
 * 大小见 ISP_FPN_SCRATCH_BYTES(w, h)。
 */

#ifndef ISP_FPN_H
#define ISP_FPN_H

#include "isp_common.h"

#ifdef __cplusplus
extern "C" {
#endif

/**
 * @brief isp_fpn_apply 所需 scratch 字节数。
 *
 * 布局（按此顺序切分，int32 区在前保证对齐）：
 * - 低通缓冲（预舍入为 int32）：w*h * sizeof(int32_t)
 * - 中位数收集缓冲：max(w,h) * sizeof(int32_t)
 * - 垂直滑窗列和/膨胀列计数（复用同一块）：w * sizeof(int32_t)
 * - 梯度边缘图 + 膨胀掩膜：w*h * 2 * sizeof(uint8_t)
 *
 * scratch 基地址需至少 4 字节对齐（静态数组/malloc 天然满足）。
 */
#define ISP_FPN_SCRATCH_BYTES(w, h)                                       \
  ((size_t)(w) * (size_t)(h) * (sizeof(int32_t) + 2u * sizeof(uint8_t)) + \
   (size_t)(w) * sizeof(int32_t) +                                        \
   ((size_t)(w) > (size_t)(h) ? (size_t)(w) : (size_t)(h)) *              \
       sizeof(int32_t))

/**
 * @brief 原地施加行/列固定图案噪声校正。
 *
 * Dart 来源：isp_kernels.dart `applyFpn`。
 *
 * 关键步骤（与 Dart 逐项对应）：
 * 1. row/col 全关时直接返回（Dart 首行 `if (!row && !col) return;`）；
 * 2. 行方向：`_verticalBoxMean` 求垂直滑窗盒式均值——Dart 存入 Float32List
 *    （double 除法后窄化为 float32），使用时 `.round()`（半值远离零）。
 *    本实现把「窄化为 float32 再舍入」合并为一步：low = round((float)
 *    ((double)colSum / count))，结果逐位一致；
 * 3. `_gradientEdge(vertical: true)`：|buf[y+1][x] - buf[y-1][x]| >
 *    2*maxCorr（int 提升为 double 比较）判为水平边缘，首末行恒 0；
 * 4. `_dilateMask(vertical: true)`：沿垂直方向滑窗 [y-radius, y+radius]
 *    计数 > 0 即掩膜（Dart 的逐列计数 + 行优先遍历只是缓存优化，语义为
 *    纯滑窗膨胀，本实现逐字移植同一滑窗过程）；
 * 5. 逐行收集未掩膜像素的残差 buf - low，取第 n>>1 项（0 基）为中位数。
 *    Dart 用 `_clampedMedian` 桶计数：桶 0 收 < -maxCorr、末桶收 > maxCorr、
 *    中间每整数一桶，定位首个累计 > n>>1 的桶后再限幅。可证明其结果恒等于
 *    clamp(排序后第 n>>1 项, ±maxCorr)（下溢桶命中时真中位数必 < -maxCorr，
 *    限幅后相同；上溢同理；中间桶返回值恰为该整数本身），故本实现用
 *    quickselect 直接取次序统计量再限幅，逐位等价且内存与 maxCorr 无关；
 * 6. corr == 0（double 精确比较）跳过本行；否则 v = buf - corr（double），
 *    v <= 0 写 0，否则写 round(v)（半值远离零，正值等价 floor(v+0.5)），
 *    按 Dart Uint16List 语义模 2^16 截断（corr 为负且 buf 接近 65535 时
 *    可能回绕，与 Dart 一致）；
 * 7. 列方向同理（水平盒式均值 + 水平梯度掩膜 + 逐列统计），在行校正后的
 *    画面上执行。Dart 的 64 列分块纯为缓存优化，统计与施加逐列独立，
 *    本实现按逐列处理，结果一致。
 *
 * @param buf           像素缓冲（w*h 个 uint16_t，原地修改）。
 * @param width         帧宽（> 0）。
 * @param height        帧高（> 0）。
 * @param row_enable    非 0 使能行方向校正（Dart `row`）。
 * @param col_enable    非 0 使能列方向校正（Dart `col`）。
 * @param max_corr      校正量限幅阈值（Dart `maxCorr`，默认 64；必须 >= 0
 *                      且有限。Dart 对负值/NaN 会因桶数非法直接抛异常，
 *                      本实现显式拒绝）。
 * @param radius        滑窗半径（Dart `radius`，默认 8；0..16383。上限保证
 *                      (2*radius+1)*65535 不溢出 int32——Dart 的 Int32List
 *                      列和在更大 radius 下会回绕，该病态情形不予模拟）。
 * @param scratch       临时缓冲，至少 ISP_FPN_SCRATCH_BYTES(width, height)
 *                      字节，4 字节对齐。
 * @param scratch_bytes scratch 实际字节数。
 * @return ISP_OK 成功；ISP_ERR_ARG 空指针 / max_corr 非法 / radius 越界；
 *         ISP_ERR_SIZE 宽高 <= 0 或 scratch 不足。
 */
int isp_fpn_apply(uint16_t *buf, int width, int height, int row_enable,
                  int col_enable, double max_corr, int radius, void *scratch,
                  size_t scratch_bytes);

#ifdef __cplusplus
} /* extern "C" */
#endif

#endif /* ISP_FPN_H */
