/**
 * @file isp_grgb_balance.h
 * @brief ISP Studio C99 参考实现 —— Gr/Gb 均衡（消迷宫伪影）。
 *
 * 覆盖节点：grgb_balance。
 * 对应 Dart 函数：lib/modules/isp_studio/pipeline/isp_kernels.dart
 * `applyGrGbBalance`。
 *
 * 算法：统计两个绿色通道相位（Gr = 与 R 同行的 G，Gb = 与 B 同行的 G）
 * 的全局均值，两相位向两者中点按 strength 比例收敛：
 *   target = (meanGr + meanGb) / 2
 *   gainGr = 1 + (target / meanGr - 1) * strength
 *   gainGb = 1 + (target / meanGb - 1) * strength
 * 仅 Bayer 马赛克有意义，pattern 为必选参数（与 Dart required 一致）。
 *
 * 本内核原地处理，两遍扫描（先统计后施加），无需 scratch 缓冲。
 */

#ifndef ISP_GRGB_BALANCE_H
#define ISP_GRGB_BALANCE_H

#include "isp_common.h"

#ifdef __cplusplus
extern "C" {
#endif

/**
 * @brief 原地施加 Gr/Gb 相位均衡增益。
 *
 * Dart 来源：isp_kernels.dart `applyGrGbBalance`。
 *
 * 关键步骤（与 Dart 逐项对应）：
 * 1. strength <= 0 时直接返回；
 * 2. 第一遍：对所有 colorAt(x,y)==G 的像素，按其水平邻相位分类——
 *    colorAt(x^1, y)==R 为 Gr，否则为 Gb——分别累加和与计数
 *    （x^1 翻转列奇偶，即取同行另一相位；对四种 Bayer 模式均成立）；
 * 3. 任一相位计数为 0 时直接返回（不修改）；
 * 4. meanGr = sumGr / cntGr、meanGb = sumGb / cntGb（Dart int/int
 *    的 `/` 为 double 除法，非整除）；均值 <= 0 时直接返回；
 * 5. 第二遍：仅 G 相位像素乘以对应相位增益后截位。
 *    注意 Dart 此处固定钳位到 65535（不随 max_value），本实现保持一致。
 *    截位语义同 `_clampTo`：先在 double 上钳位，再四舍五入
 *    （round，半值远离零；floor(v+0.5) 在非负域等价）。
 *
 * @param buf      像素缓冲（w*h 个 uint16_t，原地修改）。
 * @param width    帧宽（> 0）。
 * @param height   帧高（> 0）。
 * @param pattern  Bayer 模式（必选，四种 Bayer 平铺均支持）。
 * @param strength 收敛强度（<= 0 = 关闭；1.0 = 完全收敛到中点；
 *                 > 1 为过冲，Dart 未禁止）。
 * @return ISP_OK 成功；ISP_ERR_ARG 空指针；ISP_ERR_SIZE 宽高 <= 0。
 */
int isp_grgb_balance_apply(uint16_t *buf, int width, int height,
                           IspBayerPattern pattern, double strength);

#ifdef __cplusplus
} /* extern "C" */
#endif

#endif /* ISP_GRGB_BALANCE_H */
