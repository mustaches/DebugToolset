/**
 * @file isp_clahe.h
 * @brief ISP Studio C99 参考实现 —— 自适应直方图均衡（CLAHE，对比度受限）。
 *
 * 覆盖节点：ahe。
 * 对应 Dart 函数：lib/modules/isp_studio/pipeline/isp_kernels.dart
 * `applyClahe`（RGB 版）与 `applyClaheMono`（单通道版），内部依赖
 * `_claheTileLuts`（分 tile 直方图 → 裁剪再分配 → CDF LUT）、
 * `_claheBilinear`（4 tile 中心 LUT 双线性插值）与 `_clampTo`。
 *
 * 算法步骤（RGB 版）：
 * 1. 逐像素求亮度 Y（BT.601 定点加权和，与 applySharpen 一致）；
 * 2. 按 blockSize 分 tile 统计 256 bin 直方图，按 clipLimit（tile 内平均
 *    计数的倍数）裁剪、超出量均匀再分配，再由累积分布（CDF）得各 tile
 *    的均衡 LUT（bin → 均衡亮度，0..max_value）；
 * 3. 每像素的均衡亮度由周围 4 个 tile 中心的 LUT 双线性插值得到
 *    （tile 中心位于各 tile 中点，边缘像素钳到最近 tile，避免块效应）；
 * 4. 三通道按 Y'/Y 等比缩放（保持 hue/sat 不变），strength 为均衡亮度
 *    与原亮度的混合比（0 = 原图直通，直接跳过）。
 * 单通道版无需亮度提取与色度缩放，帧本身即亮度平面，逐像素写回
 * v + (le - v) * strength。
 *
 * 内存契约：tile LUT 表、直方图与亮度平面（仅 RGB 版）全部走调用方提供的
 * scratch，大小由 ISP_CLAHE_SCRATCH_BYTES(w, h, block_size) 给出；
 * scratch 基址需按 double 对齐（8 字节）。mono 版只使用 scratch 前部的
 * LUT + 直方图区，亮度平面区闲置，为统一契约仍按同一宏申请。
 */

#ifndef ISP_CLAHE_H
#define ISP_CLAHE_H

#include "isp_common.h"

#ifdef __cplusplus
extern "C" {
#endif

/* ---------------------------------------------------------------------------
 * 常量与 scratch 大小宏
 * ------------------------------------------------------------------------- */

/** CLAHE 直方图 bin 数（亮度按 max_value 等比落入 256 bin，Dart `_claheBins`）。 */
#define ISP_CLAHE_BINS 256

/**
 * @brief block_size 的 Dart 兜底修正（`if (blockSize < 2) blockSize = 32`）。
 * 参数会被求值两次，禁止传入带副作用的表达式。
 */
#define ISP_CLAHE_BLOCK(bs) (((bs) < 2) ? 32 : (bs))

/**
 * @brief 单方向 tile 数：Dart `(n + blockSize - 1) ~/ blockSize` 向上取整除。
 * 参数会被多次求值，禁止传入带副作用的表达式。
 */
#define ISP_CLAHE_TILE_DIM(n, bs) \
  (((n) + ISP_CLAHE_BLOCK(bs) - 1) / ISP_CLAHE_BLOCK(bs))

/**
 * @brief CLAHE 所需 scratch 字节数。
 *
 * 布局（按书写顺序紧密排列，前两个区为 double，天然满足对齐）：
 * - tile LUT 表：tilesX*tilesY*256 个 double；
 * - tile 直方图工作区：256 个 double；
 * - 亮度平面 ys（仅 RGB 版使用）：w*h 个 uint16_t。
 *
 * block_size 必须与调用 isp_clahe_apply / isp_clahe_apply_mono 时传入的
 * 值一致（宏内已含 <2 → 32 的 Dart 兜底修正）。w/h/block_size 会被多次
 * 求值，禁止传入带副作用的表达式。
 */
#define ISP_CLAHE_SCRATCH_BYTES(w, h, block_size)                          \
  ((size_t)ISP_CLAHE_TILE_DIM((w), (block_size)) *                         \
       (size_t)ISP_CLAHE_TILE_DIM((h), (block_size)) *                     \
       (size_t)ISP_CLAHE_BINS * sizeof(double) +                           \
   (size_t)ISP_CLAHE_BINS * sizeof(double) +                               \
   (size_t)(w) * (size_t)(h) * sizeof(uint16_t))

/* ---------------------------------------------------------------------------
 * 接口
 * ------------------------------------------------------------------------- */

/**
 * @brief RGB 帧原地施加 CLAHE（BT.601 亮度均衡 + 三通道等比缩放）。
 *
 * Dart 来源：isp_kernels.dart `applyClahe`（含 `_claheTileLuts` /
 * `_claheBilinear` / `_clampTo`）。
 *
 * 关键数值语义（与 Dart 逐项对应）：
 * - 亮度 Y = (19595*R + 38470*G + 7471*B + 32768) >> 16，Dart int 为 64 位，
 *   和最大约 4.29e9 超出 32 位，本实现用 int64_t 累加保持一致；
 * - bin 下标 = v * 256 ~/ (max_value + 1)（整数截断除）；
 * - 裁剪阈值 limit = clip_limit * count / 256（double），超出量 excess
 *   均匀再分配 per = excess / 256，CDF 累加顺序 b 升序
 *   （cdf += hist[b] + per；lut = cdf / count * max_value），浮点求值
 *   顺序与 Dart 原式一致；
 * - 双线性坐标 fy = (y + 0.5) / blockSize - 0.5，ty0 = floor(fy)，
 *   wy = fy - ty0；ty0 < 0 或 >= tilesY-1 时钳到边界 tile 且 wy = 0；
 * - v <= 0 的黑像素保持不动；
 * - 通道写回按 Dart `_clampTo` 的 double 路径：先在 double 上与
 *   0 / max_value 比较钳位，再四舍五入（C99 round()，半值远离零，
 *   与 Dart double.round() 同语义）。
 *
 * @param rgb        交织 RGB 帧（w*h*3 个 uint16_t，原地修改）。
 * @param width      帧宽（> 0）。
 * @param height     帧高（> 0）。
 * @param block_size tile 边长（< 2 时按 Dart 语义修正为 32）。
 * @param clip_limit 裁剪倍数（<= 0 时按 Dart 语义修正为 1.0）。
 * @param strength   混合比（<= 0 时为空操作，直接返回 ISP_OK；> 1 的外推
 *                   Dart 未禁止，照常计算）。
 * @param max_value  采样最大值（如 10bit 为 1023，16bit 为 65535）。
 * @param scratch    临时缓冲，至少 ISP_CLAHE_SCRATCH_BYTES(width, height,
 *                   block_size) 字节，8 字节对齐。
 * @return ISP_OK 成功；ISP_ERR_ARG 空指针或 max_value <= 0；
 *         ISP_ERR_SIZE 宽高 <= 0。
 */
int isp_clahe_apply(uint16_t *rgb, int width, int height, int block_size,
                    double clip_limit, double strength, int max_value,
                    void *scratch);

/**
 * @brief 单通道帧原地施加 CLAHE（`applyClahe` 的单通道版）。
 *
 * Dart 来源：isp_kernels.dart `applyClaheMono`。
 * 单通道帧直接作为亮度平面做分块直方图均衡，无需亮度提取与色度缩放；
 * 逐像素写回 _clampTo(v + (le - v) * strength, max_value)，v <= 0 的
 * 纯黑像素与 RGB 版一致保持不动。用于单通道视频信号（如荧光 Mono 链）。
 *
 * @param mono       单通道帧（w*h 个 uint16_t，原地修改）。
 * @param width      帧宽（> 0）。
 * @param height     帧高（> 0）。
 * @param block_size tile 边长（< 2 时修正为 32）。
 * @param clip_limit 裁剪倍数（<= 0 时修正为 1.0）。
 * @param strength   混合比（<= 0 时空操作，直接返回 ISP_OK）。
 * @param max_value  采样最大值。
 * @param scratch    临时缓冲，至少 ISP_CLAHE_SCRATCH_BYTES(width, height,
 *                   block_size) 字节（mono 版只用前部 LUT + 直方图区），
 *                   8 字节对齐。
 * @return ISP_OK 成功；ISP_ERR_ARG 空指针或 max_value <= 0；
 *         ISP_ERR_SIZE 宽高 <= 0。
 */
int isp_clahe_apply_mono(uint16_t *mono, int width, int height,
                         int block_size, double clip_limit, double strength,
                         int max_value, void *scratch);

#ifdef __cplusplus
} /* extern "C" */
#endif

#endif /* ISP_CLAHE_H */
