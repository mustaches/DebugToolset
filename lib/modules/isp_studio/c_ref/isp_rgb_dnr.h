/**
 * @file isp_rgb_dnr.h
 * @brief ISP Studio C99 参考实现 —— RGB 降噪节点（rgb_dnr）。
 *
 * 覆盖节点：rgb_dnr。
 * 对应 Dart 函数（lib/modules/isp_studio/pipeline/isp_kernels.dart）：
 * - applyRgbDenoise  转 YUV 后亮度 3x3 保边加权平均（权重 1/(1+(d/σ)^2)，
 *                    σ = luma×√(v+64)），色度 3x3 盒式低通并按 chroma 混合，
 *                    再转回 RGB 原地写回；
 * - rgbToYuv         BT.601 全范围 RGB→YUV，16 位定点（系数 19595/38470/7471
 *                    与 -11058/-21710/32768、32768/-27439/-5329），U/V 零点
 *                    为 maxValue/2；
 * - yuvToRgb         上述的逆变换，16 位定点（91881 / -22553 / -46801 /
 *                    116130）。
 *
 * 规范要点速览见 isp_common.h 文件头注释（C99 子集、零 malloc、帧约定
 * uint16_t* + int w/h + int max_value、错误码、数值语义与 Dart 逐位一致）。
 */

#ifndef ISP_RGB_DNR_H
#define ISP_RGB_DNR_H

#include "isp_common.h"

#ifdef __cplusplus
extern "C" {
#endif

/**
 * @brief rgb_dnr 所需 scratch 字节数（最坏情况：luma 与 chroma 同时开启）。
 *
 * 布局（均为 uint16_t，按序紧密排列）：
 * - yuv   ：w*h*3（rgbToYuv 结果，降噪在其上进行，最后经 yuvToRgb 写回）；
 * - ys    ：w*h  （亮度平面，保边加权的输入快照，仅 luma > 0 时使用）；
 * - src_u ：w*h  （色度 U 平面快照，仅 chroma > 0 时使用）；
 * - src_v ：w*h  （色度 V 平面快照，仅 chroma > 0 时使用）。
 *
 * 合计 w*h*6 个 uint16_t。仅开 luma 时实际用 w*h*4，仅开 chroma 时用
 * w*h*5，宏按最坏情况给出，调用方一次分配即可覆盖所有组合。
 */
#define ISP_RGB_DNR_SCRATCH_BYTES(w, h) \
  ((size_t)(w) * (size_t)(h) * 6u * sizeof(uint16_t))

/**
 * @brief RGB 降噪（节点 rgb_dnr）：原地处理交织 RGB 帧。
 *
 * Dart 来源：isp_kernels.dart `applyRgbDenoise`。
 * 处理流程（与 Dart 逐步对应）：
 * 1. luma <= 0 且 chroma <= 0 时不做任何修改直接返回（Dart 早退）；
 * 2. 全帧经定点 rgbToYuv 转入 scratch 的 yuv 平面；
 * 3. luma > 0：抽出亮度平面 ys，逐像素做 3x3 保边加权平均
 *    （邻居取 3x3 去掉中心、越界裁剪；权重 w = 1/(1+(d/σ)^2)，
 *    σ = luma×√(v+64)，中心权重 1），结果经 _clampTo（四舍五入+钳位）
 *    写回 yuv 的 Y；
 * 4. chroma > 0：先快照 U/V 平面到 src_u/src_v（Dart 的
 *    `Uint16List.fromList(yuv)` 等价物——循环内只读快照、只写 yuv，
 *    与像素处理顺序无关），逐像素对 U/V 做 3x3 盒式平均 avg，再按
 *    blend = clamp(chroma,0,1) 混合：src×(1-blend) + avg×blend，
 *    经 _clampTo 写回 yuv；
 * 5. 全帧经定点 yuvToRgb 写回 rgb。
 *
 * @param rgb       交织 RGB 帧（w*h*3 个 uint16_t），原地修改。
 * @param width     帧宽（> 0）。
 * @param height    帧高（> 0）。
 * @param luma      亮度降噪强度倍率（σ 的倍率，0 表示关闭亮度降噪）。
 * @param chroma    色度降噪混合比（0..1，0 表示关闭色度降噪）。
 * @param max_value 采样最大值（1..65535）。
 * @param scratch   临时缓冲，至少 ISP_RGB_DNR_SCRATCH_BYTES(width, height)。
 * @return ISP_OK 成功；ISP_ERR_ARG 空指针或 max_value 非法；
 *         ISP_ERR_SIZE 宽高 <= 0。
 */
int isp_rgb_dnr_apply(uint16_t *rgb, int width, int height, double luma,
                      double chroma, int max_value, uint16_t *scratch);

#ifdef __cplusplus
} /* extern "C" */
#endif

#endif /* ISP_RGB_DNR_H */
