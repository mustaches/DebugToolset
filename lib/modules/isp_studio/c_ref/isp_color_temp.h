/**
 * @file isp_color_temp.h
 * @brief ISP Studio C99 参考实现 —— 色温调节器（color_temp_adjuster 节点）
 *        的色温模型与测量。
 *
 * 覆盖节点：color_temp_adjuster（色温调节器）。
 *
 * 对应 Dart 函数（color_temp.dart 的全部公开函数）：
 * - `cctToWhitePoint`    → isp_color_temp_white_point
 * - `colorTempGains`     → isp_color_temp_gains
 * - `colorTempCcm`       → isp_color_temp_ccm
 * - `measureCctFromRgba` → isp_color_temp_measure_cct
 *
 * 色温模型：Tanner Helland 黑体辐射近似求归一化 RGB 白点（G 恒为 1），
 * 增益为 von Kries 对角模型 gain[c] = white(target)[c] / white(reference)[c]；
 * 测量为抽样平均色 → sRGB→XYZ 色度 → McCamy 公式估计相关色温。
 *
 * 本组函数全部不需要 scratch（无帧级大缓冲；白点/增益为小数组）。
 *
 * 规范要点速览见 isp_common.h 文件头注释。
 */

#ifndef ISP_COLOR_TEMP_H
#define ISP_COLOR_TEMP_H

#include "isp_common.h"

#ifdef __cplusplus
extern "C" {
#endif

/* ---------------------------------------------------------------------------
 * 常量（Dart `kColorTempMin/Max/Default`）
 * ------------------------------------------------------------------------- */

/** 色温值域下限（开尔文）。 */
#define ISP_COLOR_TEMP_MIN 1800
/** 色温值域上限（开尔文）。 */
#define ISP_COLOR_TEMP_MAX 12000
/** 默认目标色温（D65 日光）。 */
#define ISP_COLOR_TEMP_DEFAULT 6500

/* ---------------------------------------------------------------------------
 * 色温模型
 * ------------------------------------------------------------------------- */

/**
 * @brief 色温 → 归一化 RGB 白点（G 通道恒为 1）。
 *
 * Dart 来源：color_temp.dart `cctToWhitePoint`。
 * 采用 Tanner Helland 黑体辐射近似（适用 1000K~40000K，覆盖本节点
 * 1800~12000 范围），再把 8 位白点归一化到 G=1：返回值即「该色温光源下
 * 白色物体呈现的 R/G/B 相对强度」。R 随色温降低（暖）增大，B 随色温升高
 * （冷）增大。输入色温先钳位到 [1800, 12000]。
 *
 * @param cct     相关色温（开尔文，任意 int，内部钳位）。
 * @param out_rgb 输出 [R, G, B]，G 恒为 1.0。
 * @return ISP_OK / ISP_ERR_ARG（out_rgb 为 NULL）。
 */
int isp_color_temp_white_point(int cct, double out_rgb[3]);

/**
 * @brief 由「参考（基准）色温 → 目标色温」计算 RGB 通道增益（von Kries
 *        对角模型）：gain[c] = white(target)[c] / white(reference)[c]。
 *
 * Dart 来源：color_temp.dart `colorTempGains`。
 * target == reference 时三通道增益恰为 1（恒等）。参考色温 <= 0 时按
 * 默认 6500K 处理（未设定基准时滑块相对 D65 调节）。目标色温先经
 * Dart round()（四舍五入、恰半远离零）再钳位到 [1800, 12000]。
 *
 * @param target_cct    目标色温（开尔文，浮点滑块值）。
 * @param reference_cct 参考（基准）色温；<= 0 表示未设定，按 6500K。
 * @param out_gains     输出 [rGain, gGain, bGain]，gGain 恒为 1.0。
 * @return ISP_OK / ISP_ERR_ARG（out_gains 为 NULL）。
 */
int isp_color_temp_gains(double target_cct, int reference_cct,
                         double out_gains[3]);

/**
 * @brief 由增益组成 3x3 CCM（对角阵，行优先）。
 *
 * Dart 来源：color_temp.dart `colorTempCcm`。
 *
 * @param gains    输入 [rGain, gGain, bGain]。
 * @param out_ccm  输出 9 个 double（行优先 3x3）。
 */
void isp_color_temp_ccm(const double gains[3], double out_ccm[9]);

/* ---------------------------------------------------------------------------
 * 色温测量
 * ------------------------------------------------------------------------- */

/**
 * @brief 从 RGBA8888 帧估计色温（开尔文）。
 *
 * Dart 来源：color_temp.dart `measureCctFromRgba`。
 * 步长抽样取平均 RGB（总样本压到约 4096 个），经 sRGB→XYZ（D65）矩阵求
 * 色度 (x, y)，再用 McCamy 公式
 *   CCT = 449n³ + 3525n² + 6823.3n + 5520.33，
 *   n = (x − 0.3320) / (0.1858 − y)
 * 估计相关色温，结果四舍五入后钳位到 [1800, 12000]。
 *
 * 调用契约：rgba 缓冲至少 w*h*4 字节（Dart 侧有 length 检查，C 侧无法
 * 校验，由调用方保证）。alpha 通道忽略。
 *
 * @param rgba    RGBA8888 帧（w*h*4 字节）。
 * @param w       帧宽。
 * @param h       帧高。
 * @param out_cct 输出估计色温（开尔文）。
 * @return ISP_OK 成功；
 *         ISP_ERR_ARG（空指针）；
 *         ISP_ERR_SIZE（宽高 <= 0，对应 Dart 空帧返回 null）；
 *         ISP_ERR_UNSUPPORTED（无法估计：全黑帧 sum<=1e-9 或色度奇异
 *         |0.1858−y|<1e-6，对应 Dart 返回 null）。
 */
int isp_color_temp_measure_cct(const uint8_t *rgba, int w, int h,
                               int *out_cct);

#ifdef __cplusplus
} /* extern "C" */
#endif

#endif /* ISP_COLOR_TEMP_H */
