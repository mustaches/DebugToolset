/**
 * @file isp_demosaic_adv.h
 * @brief ISP Studio C99 参考实现 —— 高级 Bayer 去马赛克（MHC / AAHD / AMaZE / LMMSE / IGV）。
 *
 * 覆盖节点：demosaic（去马赛克）节点的 algorithm 参数 mhc / aahd / amaze /
 * lmmse / igv 五条路径（pipeline_runner.dart 中 'demosaic' 分支的算法分派）。
 *
 * Dart 来源：lib/modules/isp_studio/pipeline/demosaic_advanced.dart 的
 * demosaicMhc / demosaicAahd / demosaicAmaze / demosaicLmmse / demosaicIgv，
 * 以及其内部公共件 _gHorz / _gVert / _fillChrominance / _median9 /
 * _rgbToLab / _conv5 / _emit / _clamp16（均移植为 .c 内 static 函数）。
 * 注意：Dart 侧五个函数均为**教学向简化实现**，本文件逐函数按其简化后的
 * 实现移植，不按原论文配方补全（方向数、窗口、迭代选向等均与 Dart 一致）。
 *
 * 共同契约（与 Dart 一致）：
 * - 所有函数先调用 isp_demosaic_bilinear()（isp_demosaic.h，另一文件提供）
 *   铺底整幅输出，再覆写内部像素；过小的图只保留双线性结果直接返回。
 * - 边界回退环宽度：MHC / IGV 为 2 像素，AAHD / AMaZE / LMMSE 为 3 像素。
 * - 输出逐像素先按 Dart `_clamp16` 语义（double 比较 0 / maxValue，
 *   再 round() 四舍五入）钳位到 0..max_value。
 * - 中间平面（G 平面、色差平面、Lab 平面、同质性计数等）全部使用调用方
 *   提供的 scratch 缓冲，内核零动态分配；MHC 无中间平面，不需要 scratch。
 *
 * 数值语义与 Dart 逐位一致的要点：
 * - 浮点累加顺序与 Dart 循环顺序完全一致（色差 5x5 邻域 dy 外层 dx 内层、
 *   variance5 的 k=-2..2、3x3 窗口等）；
 * - Dart `16 / 116` 是 double 除法（≈0.13793），C 侧写作 16.0 / 116；
 * - IGV 的 eps = maxValue*maxValue*1e-6，C 侧先转 double 再相乘，
 *   避免 32 位 int 溢出（65535^2 > 2^31，Dart int 为 64 位不溢出）；
 * - MHC 的 _conv5 用 (acc + 8) >> 4，负 acc 依赖算术右移
 *   （MSVC/GCC/主流嵌入式编译器均为算术右移，与 Dart int>> 一致）；
 * - sRGB→Lab 的 pow() 超越函数在不同 libm 间可能存在末位 ulp 差异，
 *   属固有限制，公式与分支阈值严格一致。
 */

#ifndef ISP_DEMOSAIC_ADV_H
#define ISP_DEMOSAIC_ADV_H

#include <stddef.h>
#include <stdint.h>

#include "isp_common.h"

#ifdef __cplusplus
extern "C" {
#endif

/**
 * @brief 高级去马赛克统一 scratch 大小（字节）。
 *
 * 取五个算法中的最大需求（AAHD）：每像素 12 个 double 平面
 * （gH/gV/rH/bH/rV/bV + 两幅 Lab 候选图 lH/aH/bH2/lV/aV/bV2）
 * 加 2 个 int32 平面（homH/homV）。
 * scratch 指针需按 double 对齐（8 字节）。
 */
#define ISP_DEMOSAIC_ADV_SCRATCH_BYTES(w, h)                          \
  ((size_t)(w) * (size_t)(h) *                                       \
   (12u * sizeof(double) + 2u * sizeof(int32_t)))

/**
 * @brief MHC 梯度校正线性插值去马赛克（Malvar, He, Cutler, ICASSP 2004）。
 *
 * Dart 来源：demosaic_advanced.dart `demosaicMhc`。
 * G 通道用含亮度梯度校正项的 5x5 FIR（_kGatC）；R/B 在 G 相位用横行/竖列
 * 核（_kCatGRow/_kCatGCol，按横向邻居颜色选择）、在对方相位用对角核
 * （_kCatOpp）。纯线性、无方向选择。整数卷积，(acc+8)>>4 四舍五入。
 * 边界 2 像素环与 w<5 或 h<5 的小图回退双线性。无中间平面，不需 scratch。
 *
 * @param bayer     输入 Bayer 马赛克帧（w*h 个 uint16_t）。
 * @param width     帧宽。
 * @param height    帧高。
 * @param pattern   Bayer 模式。
 * @param max_value 采样最大值（输出钳位上限）。
 * @param rgb_out   输出交织 RGB（w*h*3 个 uint16_t，调用方提供）。
 * @return ISP_OK 或负错误码。
 */
int isp_demosaic_adv_mhc(const uint16_t *bayer, int width, int height,
                         IspBayerPattern pattern, int max_value,
                         uint16_t *rgb_out);

/**
 * @brief AAHD 自适应同质性定向去马赛克（Hirakawa & Parks, IEEE TIP 2005）。
 *
 * Dart 来源：demosaic_advanced.dart `demosaicAahd`（简化实现）。
 * 水平/垂直两个方向各生成一幅候选图（G 沿方向梯度校正插值 _gHorz/_gVert，
 * R/B 经色差平滑 _fillChrominance），两候选图转 CIELab（简化 sRGB 流程
 * _rgbToLab），逐像素按 3x3 邻域同质性（Lab 距离阈值 epsL=2 / epsAB=4）
 * 计数投票选方向，计数相等时取水平候选（homH >= homV）。
 * 边界 3 像素环与 w<7 或 h<7 的小图回退双线性。
 *
 * @param bayer     输入 Bayer 马赛克帧（w*h 个 uint16_t）。
 * @param width     帧宽。
 * @param height    帧高。
 * @param pattern   Bayer 模式。
 * @param max_value 采样最大值（同时参与 Lab 归一化 1.0/maxValue）。
 * @param rgb_out   输出交织 RGB（w*h*3 个 uint16_t，调用方提供）。
 * @param scratch   临时缓冲，大小至少 ISP_DEMOSAIC_ADV_SCRATCH_BYTES(w,h)，
 *                  按 double 对齐；小图回退路径不访问，可传 NULL。
 * @return ISP_OK 或负错误码。
 */
int isp_demosaic_adv_aahd(const uint16_t *bayer, int width, int height,
                          IspBayerPattern pattern, int max_value,
                          uint16_t *rgb_out, void *scratch);

/**
 * @brief AMaZE 方向性去马赛克（Zhang & Wu, IEEE TIP 2005 路线，简化实现）。
 *
 * Dart 来源：demosaic_advanced.dart `demosaicAmaze`。
 * G 在 R/B 站点按 H/V 两方向梯度校正估计（_gHorz/_gVert），按方向梯度
 * （一阶差绝对值 + 亮度二阶差绝对值）反比加权融合；R/B 经色差平滑
 * _fillChrominance；最后对 R−G / B−G 色差平面做 3x3 中值滤波（_median9）
 * 去拉链。边界 3 像素环与 w<7 或 h<7 的小图回退双线性。
 *
 * @param bayer     输入 Bayer 马赛克帧（w*h 个 uint16_t）。
 * @param width     帧宽。
 * @param height    帧高。
 * @param pattern   Bayer 模式。
 * @param max_value 采样最大值（输出钳位上限）。
 * @param rgb_out   输出交织 RGB（w*h*3 个 uint16_t，调用方提供）。
 * @param scratch   临时缓冲，大小至少 5*w*h*sizeof(double)（统一宏
 *                  ISP_DEMOSAIC_ADV_SCRATCH_BYTES 亦满足），按 double 对齐；
 *                  小图回退路径不访问，可传 NULL。
 * @return ISP_OK 或负错误码。
 */
int isp_demosaic_adv_amaze(const uint16_t *bayer, int width, int height,
                           IspBayerPattern pattern, int max_value,
                           uint16_t *rgb_out, void *scratch);

/**
 * @brief LMMSE 去马赛克（Zhang & Wu, IEEE TIP 2005，简化实现）。
 *
 * Dart 来源：demosaic_advanced.dart `demosaicLmmse`。
 * R/B 站点沿 H/V 两方向各做梯度校正 G 估计，方向能量用 3x3 窗口内亮度
 * 二阶差分绝对值之和，按 1/(能量+eps) 逆能量加权融合
 * （eps = maxValue*1e-3，平坦区两方向等权）；R/B 经色差平滑插值。
 * 边界 3 像素环与 w<7 或 h<7 的小图回退双线性。
 *
 * @param bayer     输入 Bayer 马赛克帧（w*h 个 uint16_t）。
 * @param width     帧宽。
 * @param height    帧高。
 * @param pattern   Bayer 模式。
 * @param max_value 采样最大值（钳位上限，同时决定 eps）。
 * @param rgb_out   输出交织 RGB（w*h*3 个 uint16_t，调用方提供）。
 * @param scratch   临时缓冲，大小至少 3*w*h*sizeof(double)（统一宏
 *                  ISP_DEMOSAIC_ADV_SCRATCH_BYTES 亦满足），按 double 对齐；
 *                  小图回退路径不访问，可传 NULL。
 * @return ISP_OK 或负错误码。
 */
int isp_demosaic_adv_lmmse(const uint16_t *bayer, int width, int height,
                           IspBayerPattern pattern, int max_value,
                           uint16_t *rgb_out, void *scratch);

/**
 * @brief IGV 无阈值方向去马赛克（Pekkucuksen & Altunbasak, ICIP 2010 风格）。
 *
 * Dart 来源：demosaic_advanced.dart `demosaicIgv`（等价思想简化实现）。
 * R/B 站点先按 MHC 式梯度校正得到 H/V 两方向 G 估计（_gHorz/_gVert），
 * 再取各方向 5 样本窗口内马赛克值的方差，按 1/(方差+eps) 无阈值加权
 * 融合（eps = maxValue^2*1e-6）；R/B 经色差平滑 _fillChrominance。
 * 边界 2 像素环与 w<5 或 h<5 的小图回退双线性。
 *
 * @param bayer     输入 Bayer 马赛克帧（w*h 个 uint16_t）。
 * @param width     帧宽。
 * @param height    帧高。
 * @param pattern   Bayer 模式。
 * @param max_value 采样最大值（钳位上限，同时决定 eps）。
 * @param rgb_out   输出交织 RGB（w*h*3 个 uint16_t，调用方提供）。
 * @param scratch   临时缓冲，大小至少 3*w*h*sizeof(double)（统一宏
 *                  ISP_DEMOSAIC_ADV_SCRATCH_BYTES 亦满足），按 double 对齐；
 *                  小图回退路径不访问，可传 NULL。
 * @return ISP_OK 或负错误码。
 */
int isp_demosaic_adv_igv(const uint16_t *bayer, int width, int height,
                         IspBayerPattern pattern, int max_value,
                         uint16_t *rgb_out, void *scratch);

#ifdef __cplusplus
} /* extern "C" */
#endif

#endif /* ISP_DEMOSAIC_ADV_H */
