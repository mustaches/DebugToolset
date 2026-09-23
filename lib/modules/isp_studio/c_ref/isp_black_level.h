/**
 * @file isp_black_level.h
 * @brief ISP Studio C99 参考实现 —— 黑电平校正节点（black_level）。
 *
 * 覆盖节点：
 * - black_level（黑电平校正）：mosaic/CFA 帧按 2x2 平铺的四相位分别扣除
 *   偏移；mono（荧光链）帧用 r 参数作为统一偏移扣除。
 *
 * 对应的 Dart 语义来源：
 * - lib/modules/isp_studio/pipeline/isp_kernels.dart `applyBlackLevel`
 *   （Bayer/CFA 2x2 四相位偏移扣除，原地修改，截零不截顶）；
 * - lib/modules/isp_studio/pipeline/pipeline_runner.dart `case 'black_level'`
 *   的 mono 分支（`frame.format == 'mono'` 时用 r 参数统一扣除）。
 *
 * 规范要点速览见 isp_common.h 文件头注释。
 */

#ifndef ISP_BLACK_LEVEL_H
#define ISP_BLACK_LEVEL_H

#include "isp_common.h"

#ifdef __cplusplus
extern "C" {
#endif

/**
 * @brief Bayer/CFA 帧黑电平校正：按 2x2 四相位分别扣除偏移，原地修改。
 *
 * Dart 来源：isp_kernels.dart `applyBlackLevel`。
 *
 * 算法步骤（与 Dart 逐项对应）：
 * 1. 预解析 2x2 平铺四个相位各自的偏移：相位颜色为 R 用 r，为 B 用 b；
 *    为 G 时看同行另一像素的颜色——与 R 同行（colorAt(px^1, py) == R）
 *    用 gr，与 B 同行为 gb（gr = red 行绿，gb = blue 行绿）；
 * 2. 逐像素 v = buf[i] - offsets[phase]；v <= 0 写 0，否则写 round(v)。
 *    只截零不截顶（Dart 写回 Uint16List 时超出 16 位自然回绕，C 侧
 *    转 uint16_t 同样回绕，逐位一致）。
 *
 * 本函数无 scratch 需求（相位偏移表为固定 4 元素栈数组）。
 *
 * @param bayer  像素缓冲（w*h 个 uint16_t），原地修改。
 * @param width  帧宽（> 0）。
 * @param height 帧高（> 0）。
 * @param pattern Bayer 模式（决定各相位偏移的归属）。
 * @param r      R 相位偏移。
 * @param gr     red 行绿（Gr）相位偏移。
 * @param gb     blue 行绿（Gb）相位偏移。
 * @param b      B 相位偏移。
 * @return ISP_OK 成功；ISP_ERR_ARG 空指针；ISP_ERR_SIZE 宽高 <= 0。
 */
int isp_black_level_apply(uint16_t *bayer, int width, int height,
                          IspBayerPattern pattern,
                          double r, double gr, double gb, double b);

/**
 * @brief mono 帧黑电平校正：统一偏移扣除，原地修改。
 *
 * Dart 来源：pipeline_runner.dart `case 'black_level'` 的 mono 分支
 * （`frame.format == 'mono'`：用 r 参数作为统一偏移，N01–N03）。
 * Dart 中 off == 0 时整体跳过；恒等操作，本函数统一逐像素处理，
 * 结果逐位一致（v = x - 0，round 后仍为 x）。
 *
 * @param buf    像素缓冲（w*h 个 uint16_t），原地修改。
 * @param width  帧宽（> 0）。
 * @param height 帧高（> 0）。
 * @param offset 统一黑电平偏移（对应节点参数 r）。
 * @return ISP_OK 成功；ISP_ERR_ARG 空指针；ISP_ERR_SIZE 宽高 <= 0。
 */
int isp_black_level_apply_mono(uint16_t *buf, int width, int height,
                               double offset);

#ifdef __cplusplus
} /* extern "C" */
#endif

#endif /* ISP_BLACK_LEVEL_H */
