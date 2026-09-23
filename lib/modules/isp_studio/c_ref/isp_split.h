/**
 * @file isp_split.h
 * @brief ISP Studio C99 参考实现 —— 分路/合路器组（纯平面拆分与合并，无色彩运算）。
 *
 * 覆盖节点（pipeline_runner.dart 中对应 case）：
 * - rgb_splitter / yuv_splitter / hsl_splitter：
 *   交织三通道帧（w*h*3）拆成三个单通道平面（各 w*h），纯拷贝。
 * - rgb_combiner / hsl_combiner：
 *   三个单通道平面合并为交织帧；未连接（NULL）或长度不足的通道填 0。
 * - yuv_combiner：
 *   同上，但 Y 通道缺省填 0，U/V 通道缺省填中值 max_value >> 1。
 *
 * 对应的 Dart 语义来源：lib/modules/isp_studio/pipeline/pipeline_runner.dart
 * 中 'rgb_splitter'、'yuv_splitter'、'hsl_splitter'、'rgb_combiner'、
 * 'yuv_combiner'、'hsl_combiner' 各 case（约 1640~1835 行）。
 *
 * 边界说明（不移植的 PC 侧逻辑）：
 * - Dart 分路器 case 在输入格式不匹配时先做色彩转换兜底（yuv→rgb、
 *   hsl→rgb、rgb→yuv、rgb→hsl，分别调用 yuvToRgb/hslToRgb/rgbToYuv/
 *   rgbToHsl）。色彩转换属于色彩空间组的职责，本组函数假设输入交织帧
 *   已经是目标色彩域，调用方（流水线编排层）负责格式适配。
 * - YUV 平面轨道（_Frame.yuvPlanes8，分路输出零拷贝 Uint8List 视图、
 *   合路直接引用三路 8 位平面）是 PC 侧内存优化，嵌入式参考实现不移植，
 *   一律走 16 位交织帧路径。
 * - 本组全部为纯数据搬运，无舍入、无钳位，输出值域与输入一致。
 *
 * 规范要点速览见 isp_common.h 文件头注释。
 */

#ifndef ISP_SPLIT_H
#define ISP_SPLIT_H

#include "isp_common.h"

#ifdef __cplusplus
extern "C" {
#endif

/* ---------------------------------------------------------------------------
 * 分路器（交织 → 三平面）
 *
 * 帧约定与 isp_common 一致（uint16_t* + int w/h + int max_value）。
 * 拆路是纯拷贝语义，与量化上限无关，max_value 参数仅为保持全组签名一致
 * 而保留，函数体内不使用。
 * ------------------------------------------------------------------------- */

/**
 * @brief RGB 分路：交织 RGB 帧拆为 R/G/B 三个单通道平面。
 *
 * Dart 来源：pipeline_runner.dart 'rgb_splitter' case 的拆路循环
 * （rData[i] = data[3*i]; gData[i] = data[3*i+1]; bData[i] = data[3*i+2]）。
 * 纯拷贝，无算术运算，输出值与输入逐位一致。
 *
 * @param src       交织输入帧，长度 w*h*3。
 * @param w         帧宽（>0）。
 * @param h         帧高（>0）。
 * @param max_value 采样最大值（保留参数，本函数不使用）。
 * @param out_r     R 平面输出缓冲（调用方提供，容量 w*h）。
 * @param out_g     G 平面输出缓冲（调用方提供，容量 w*h）。
 * @param out_b     B 平面输出缓冲（调用方提供，容量 w*h）。
 * @return ISP_OK 成功；ISP_ERR_ARG 空指针；ISP_ERR_SIZE 宽高非法。
 */
int isp_split_rgb(const uint16_t *src, int w, int h, int max_value,
                  uint16_t *out_r, uint16_t *out_g, uint16_t *out_b);

/**
 * @brief YUV 分路：交织 YUV 帧拆为 Y/U/V 三个单通道平面。
 *
 * Dart 来源：pipeline_runner.dart 'yuv_splitter' case 的拆路循环
 * （srcIdx 步进 3，依次取 Y/U/V）。纯拷贝。
 * 注意：Dart 的 yuvPlanes8 零拷贝轨道不移植（见文件头说明）。
 *
 * @param src       交织输入帧，长度 w*h*3。
 * @param w         帧宽（>0）。
 * @param h         帧高（>0）。
 * @param max_value 采样最大值（保留参数，本函数不使用）。
 * @param out_y     Y 平面输出缓冲（调用方提供，容量 w*h）。
 * @param out_u     U 平面输出缓冲（调用方提供，容量 w*h）。
 * @param out_v     V 平面输出缓冲（调用方提供，容量 w*h）。
 * @return ISP_OK 成功；ISP_ERR_ARG 空指针；ISP_ERR_SIZE 宽高非法。
 */
int isp_split_yuv(const uint16_t *src, int w, int h, int max_value,
                  uint16_t *out_y, uint16_t *out_u, uint16_t *out_v);

/**
 * @brief HSL 分路：交织 HSL 帧拆为 H/S/L 三个单通道平面。
 *
 * Dart 来源：pipeline_runner.dart 'hsl_splitter' case 的拆路循环。纯拷贝。
 *
 * @param src       交织输入帧，长度 w*h*3。
 * @param w         帧宽（>0）。
 * @param h         帧高（>0）。
 * @param max_value 采样最大值（保留参数，本函数不使用）。
 * @param out_h     H 平面输出缓冲（调用方提供，容量 w*h）。
 * @param out_s     S 平面输出缓冲（调用方提供，容量 w*h）。
 * @param out_l     L 平面输出缓冲（调用方提供，容量 w*h）。
 * @return ISP_OK 成功；ISP_ERR_ARG 空指针；ISP_ERR_SIZE 宽高非法。
 */
int isp_split_hsl(const uint16_t *src, int w, int h, int max_value,
                  uint16_t *out_h, uint16_t *out_s, uint16_t *out_l);

/* ---------------------------------------------------------------------------
 * 合路器（三平面 → 交织）
 *
 * 每路输入带一个有效长度参数（该平面中的有效样本数），对应 Dart 的
 * `i < data.length` 判断：指针为 NULL（端口未连接）或 i 超出有效长度时，
 * 该像素位置填缺省值。正常整帧连接时传入 w*h 即可。
 * ------------------------------------------------------------------------- */

/**
 * @brief RGB 合路：R/G/B 三平面合并为交织 RGB 帧，缺省值填 0。
 *
 * Dart 来源：pipeline_runner.dart 'rgb_combiner' case：
 * combined[3*i+c] = (data != null && i < data.length) ? data[i] : 0。
 *
 * @param in_r      R 平面（NULL 表示未连接，整路填 0）。
 * @param r_len     in_r 有效样本数（对应 Dart rData.length）。
 * @param in_g      G 平面（NULL 表示未连接）。
 * @param g_len     in_g 有效样本数。
 * @param in_b      B 平面（NULL 表示未连接）。
 * @param b_len     in_b 有效样本数。
 * @param w         帧宽（>0）。
 * @param h         帧高（>0）。
 * @param max_value 采样最大值（保留参数，RGB 合路缺省值恒 0，不使用）。
 * @param dst       交织输出缓冲（调用方提供，容量 w*h*3）。
 * @return ISP_OK 成功；ISP_ERR_ARG dst 为空；ISP_ERR_SIZE 宽高非法。
 */
int isp_combine_rgb(const uint16_t *in_r, int r_len,
                    const uint16_t *in_g, int g_len,
                    const uint16_t *in_b, int b_len,
                    int w, int h, int max_value, uint16_t *dst);

/**
 * @brief YUV 合路：Y/U/V 三平面合并为交织 YUV 帧；
 *        Y 缺省填 0，U/V 缺省填中值 max_value >> 1。
 *
 * Dart 来源：pipeline_runner.dart 'yuv_combiner' case：
 * mid = max >> 1；Y 缺省 0，U/V 缺省 mid（`max >> 1` 为算术右移，
 * 等价非负 max_value 的向下取整除 2，与 C 的 >> 一致）。
 * 注意：Dart 的 yuvPlanes8 零拷贝轨道不移植（见文件头说明）。
 *
 * @param in_y      Y 平面（NULL 表示未连接，整路填 0）。
 * @param y_len     in_y 有效样本数。
 * @param in_u      U 平面（NULL 表示未连接，整路填 max_value>>1）。
 * @param u_len     in_u 有效样本数。
 * @param in_v      V 平面（NULL 表示未连接，整路填 max_value>>1）。
 * @param v_len     in_v 有效样本数。
 * @param w         帧宽（>0）。
 * @param h         帧高（>0）。
 * @param max_value 采样最大值，用于推导 U/V 缺省中值。
 * @param dst       交织输出缓冲（调用方提供，容量 w*h*3）。
 * @return ISP_OK 成功；ISP_ERR_ARG dst 为空；ISP_ERR_SIZE 宽高非法。
 */
int isp_combine_yuv(const uint16_t *in_y, int y_len,
                    const uint16_t *in_u, int u_len,
                    const uint16_t *in_v, int v_len,
                    int w, int h, int max_value, uint16_t *dst);

/**
 * @brief HSL 合路：H/S/L 三平面合并为交织 HSL 帧，缺省值填 0。
 *
 * Dart 来源：pipeline_runner.dart 'hsl_combiner' case：缺省值恒 0。
 *
 * @param in_h      H 平面（NULL 表示未连接，整路填 0）。
 * @param h_len     in_h 有效样本数。
 * @param in_s      S 平面（NULL 表示未连接）。
 * @param s_len     in_s 有效样本数。
 * @param in_l      L 平面（NULL 表示未连接）。
 * @param l_len     in_l 有效样本数。
 * @param w         帧宽（>0）。
 * @param h         帧高（>0）。
 * @param max_value 采样最大值（保留参数，HSL 合路缺省值恒 0，不使用）。
 * @param dst       交织输出缓冲（调用方提供，容量 w*h*3）。
 * @return ISP_OK 成功；ISP_ERR_ARG dst 为空；ISP_ERR_SIZE 宽高非法。
 */
int isp_combine_hsl(const uint16_t *in_h, int h_len,
                    const uint16_t *in_s, int s_len,
                    const uint16_t *in_l, int l_len,
                    int w, int h, int max_value, uint16_t *dst);

#ifdef __cplusplus
} /* extern "C" */
#endif

#endif /* ISP_SPLIT_H */
