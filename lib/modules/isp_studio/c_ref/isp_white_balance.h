/**
 * @file isp_white_balance.h
 * @brief ISP Studio C99 参考实现 —— 白平衡节点（white_balance）。
 *
 * 覆盖节点：white_balance（灰度世界自动白平衡增益估计 + 增益施加）。
 *
 * 对应的 Dart 来源：lib/modules/isp_studio/pipeline/isp_kernels.dart
 * - `autoWhiteBalanceGains` → isp_white_balance_auto_gains
 * - `applyWhiteBalance`     → isp_white_balance_apply
 *
 * 内存契约：两个函数均无需 scratch（Dart 侧的每通道 LUT 是纯函数查表，
 * 逐像素直接计算 (v*gain).round() 再钳位与查表逐位一致，故省去 LUT 缓冲，
 * 详见 isp_white_balance.c 注释）。
 */

#ifndef ISP_WHITE_BALANCE_H
#define ISP_WHITE_BALANCE_H

#include "isp_common.h"

#ifdef __cplusplus
extern "C" {
#endif

/**
 * @brief 灰度世界自动白平衡增益估计（采样统计）。
 *
 * Dart 来源：isp_kernels.dart `autoWhiteBalanceGains`。
 * 每隔 sample_stride 个像素采一个样本，统计 R/G/B 三通道均值，
 * 返回使 R、B 均值等于 G 均值的增益：r_gain = meanG / meanR，
 * b_gain = meanG / meanB（均值为 0 时对应增益取 1.0）。
 *
 * 语义细节（与 Dart 逐项对应）：
 * - 采样下标 p 从 0 开始、步进 sample_stride，采样的是「像素」而非字节；
 * - sample_stride < 1 时按 1 处理（Dart 中 `stride < 1 ? 1 : stride`）；
 * - 和与计数用 64 位整数累加（Dart int 为 64 位，不会溢出）；
 * - 均值为 double 除法（Dart 的 `/` 对 int 也是 double 除法）；
 * - 帧像素数 w*h 为 0 时增益输出 (1.0, 1.0) 并返回 ISP_OK（同 Dart）。
 *
 * @param rgb           交织三通道帧（w*h*3 个 uint16_t）。
 * @param w             帧宽。
 * @param h             帧高。
 * @param sample_stride 采样步长（像素单位；Dart 默认 16）。
 * @param r_gain        输出：R 通道增益。
 * @param b_gain        输出：B 通道增益。
 * @return ISP_OK 成功；ISP_ERR_ARG 空指针；ISP_ERR_SIZE 宽高为负。
 */
int isp_white_balance_auto_gains(const uint16_t *rgb, int w, int h,
                                 int sample_stride, double *r_gain,
                                 double *b_gain);

/**
 * @brief 原地施加白平衡增益（只调 R、B 两通道，G 不动）。
 *
 * Dart 来源：isp_kernels.dart `applyWhiteBalance`。
 * 每通道映射 v → clamp(round(v * gain), 0, max_value)。
 * Dart 实现为每通道先建一张 max_value+1 的 LUT 再查表；查表是纯函数，
 * 此处逐像素直接计算，结果逐位一致（round 为四舍五入远离零，
 * 与 Dart double.round() 相同，C 侧用 llround 实现）。
 *
 * r_gain == 1.0 且 b_gain == 1.0 时为空操作（同 Dart 的提前返回）。
 *
 * @param rgb       交织三通道帧（w*h*3 个 uint16_t，原地修改）。
 * @param w         帧宽。
 * @param h         帧高。
 * @param r_gain    R 通道增益。
 * @param b_gain    B 通道增益。
 * @param max_value 采样最大值（如 10bit 为 1023）。
 * @return ISP_OK 成功；ISP_ERR_ARG 空指针；ISP_ERR_SIZE 宽高为负。
 */
int isp_white_balance_apply(uint16_t *rgb, int w, int h, double r_gain,
                            double b_gain, int max_value);

/* ---------------------------------------------------------------------------
 * LUT 模式（节点属性 codegenMode=lut）：表按生成期参数烘焙为 static
 * const（wrapper 内），运行期纯查表零建表成本。
 * ------------------------------------------------------------------------- */

/**
 * @brief 构建白平衡增益 LUT：lut[v] = clamp(round(v * gain), 0, max_value)。
 *
 * 与 Dart `whiteBalanceGainLut` 逐位一致（llround 即四舍五入远离零）。
 * 供 auto 模式运行期建表（增益运行期估计，无法烘焙）；manual 模式的表
 * 由生成期 Dart 建表函数直接烘焙进 wrapper。
 *
 * @param gain      通道增益。
 * @param max_value 采样最大值（表长 max_value+1）。
 * @param lut_out   输出表（容量 max_value+1 个 uint16_t）。
 * @return ISP_OK / ISP_ERR_ARG。
 */
int isp_white_balance_build_lut(double gain, int max_value,
                                uint16_t *lut_out);

/**
 * @brief 白平衡 LUT 查表施加（只调 R、B 两通道，原地）。
 *
 * 与 isp_white_balance_apply 直算逐位一致（直算内部本就建同一张表）。
 * 调用契约：帧值 <= max_value 且表长 >= max_value+1（wrapper 在
 * max_value 与烘焙域不一致时回退直算，不会越界查表）。
 *
 * @param rgb       交织三通道帧（w*h*3 个 uint16_t，原地修改）。
 * @param w         帧宽。
 * @param h         帧高。
 * @param lut_r     R 通道 LUT。
 * @param lut_b     B 通道 LUT。
 * @param max_value 采样最大值。
 * @return ISP_OK / ISP_ERR_ARG / ISP_ERR_SIZE。
 */
int isp_white_balance_lut_apply(uint16_t *rgb, int w, int h,
                                const uint16_t *lut_r, const uint16_t *lut_b,
                                int max_value);

#ifdef __cplusplus
} /* extern "C" */
#endif

#endif /* ISP_WHITE_BALANCE_H */
