/**
 * @file isp_highlight.h
 * @brief ISP Studio C99 参考实现 —— 高光恢复节点（highlight）。
 *
 * 覆盖节点：highlight（高光恢复，W18/W19）。
 * 对应 Dart 函数：lib/modules/isp_studio/pipeline/isp_kernels.dart
 * `applyHighlightRecovery`：
 * - recover 模式：达到膝点（knee×maxValue）的饱和像素用同相位未饱和
 *   邻域均值重建（无可用邻域则保持原值）；
 * - clip 模式：膝点以上软压缩 v'=kneePt+d*range/(range+d)，平滑收敛
 *   到 maxValue，避免硬切色块。
 *
 * recover 模式需整帧快照（Dart `src = Uint16List.fromList(buf)`），
 * 由调用方提供 scratch；clip 模式逐像素独立，无需 scratch。
 *
 * 规范要点速览见 isp_common.h 文件头注释。
 */

#ifndef ISP_HIGHLIGHT_H
#define ISP_HIGHLIGHT_H

#include "isp_common.h"

#ifdef __cplusplus
extern "C" {
#endif

/**
 * @brief 高光恢复模式（对应 Dart `mode` 字符串）。
 *
 * Dart 中 mode == 'clip' 走软压缩分支，其余一律走 recover 分支；
 * 本枚举非法值按参数错误处理（ISP_ERR_ARG），与 Dart 的字符串兜底
 * 不同，请调用方显式选择。
 */
typedef enum IspHighlightMode {
  /** 饱和像素用同相位未饱和邻域均值重建（Dart 默认 'recover'）。 */
  ISP_HIGHLIGHT_RECOVER = 0,
  /** 膝点以上软压缩（Dart mode == 'clip'）。 */
  ISP_HIGHLIGHT_CLIP = 1
} IspHighlightMode;

/**
 * @brief highlight 节点 recover 模式所需 scratch 字节数：整帧 uint16 快照。
 *
 * 推导：Dart recover 分支 `Uint16List.fromList(buf)` 复制整帧，
 * 长度 w*h 个 uint16_t。clip 模式不使用 scratch（可传 NULL）。
 */
#define ISP_HIGHLIGHT_SCRATCH_BYTES(w, h) \
  ((size_t)(w) * (size_t)(h) * sizeof(uint16_t))

/**
 * @brief 高光恢复（原地写回）。
 *
 * Dart 来源：isp_kernels.dart `applyHighlightRecovery`。
 *
 * 逐位一致要点：
 * - 膝点 kneePt = clamp(knee, 0, 1) * maxValue，为 **double**，所有
 *   “达到膝点”判定（src[i] < / >= / <= kneePt）均为 int 提升 double
 *   后的浮点比较（如 kneePt=920.7 时 921 才算饱和），不得取整后再比；
 * - clip：range = maxValue - kneePt（double），range <= 0 时空操作；
 *   v' = kneePt + d*range/(range+d)，经 C99 round() 舍入（与 Dart
 *   round() 同为半值远离零，被舍入值恒正），结果必 <= maxValue，
 *   Dart 无钳位，此处同样不钳位；
 * - recover：先快照整帧，仅处理 src[i] >= kneePt 的像素；邻域经
 *   isp_phase_neighbors 收集（同相位/全像素 3x3，顺序与 Dart
 *   `_phaseNeighbors` 一致），跳过 >= kneePt 的邻居；均值
 *   (sum + count/2) / count 为**整数**除法（Dart
 *   `(sum + count ~/ 2) ~/ count`，正数截断，与 C 的 / 一致）；
 *   count == 0 时保持原值。
 *
 * @param buf       像素缓冲（w*h 个 uint16_t），原地修改。
 * @param w         帧宽（>0）。
 * @param h         帧高（>0）。
 * @param pattern   Bayer 模式指针；NULL 表示 16 位 mono。只判空不解引用，
 *                  与 Dart `_phaseNeighbors` 一致。clip 模式未使用。
 * @param max_value 采样最大值（如 10bit 为 1023，16bit 为 65535）。
 * @param mode      ISP_HIGHLIGHT_RECOVER / ISP_HIGHLIGHT_CLIP。
 * @param knee      膝点比例（Dart 侧 clamp 到 [0,1]，本函数内同样钳制）。
 * @param scratch   recover 模式：整帧快照缓冲，大小至少
 *                  ISP_HIGHLIGHT_SCRATCH_BYTES(w, h)；clip 模式可传 NULL。
 * @return ISP_OK 成功；ISP_ERR_ARG 空指针或非法 mode；
 *         ISP_ERR_SIZE 宽高非法。
 */
int isp_highlight_apply(uint16_t *buf, int w, int h,
                        const IspBayerPattern *pattern, int max_value,
                        IspHighlightMode mode, double knee,
                        uint16_t *scratch);

/* ---------------------------------------------------------------------------
 * LUT 模式（节点属性 codegenMode=lut，仅 clip 分支）：膝点压缩表按生成
 * 期参数烘焙为 static const（wrapper 内），运行期纯查表零建表成本。
 * ------------------------------------------------------------------------- */

/**
 * @brief 高光 clip LUT 查表施加：逐值查表（v <= 膝点恒等，以上软压缩）。
 *
 * 与 isp_highlight_apply 的 clip 分支逐位一致（表项 = round(kneePt +
 * d*range/(range+d)) 的逐值预计算）。调用契约：帧值不超过表长-1。
 *
 * @param buf       帧缓冲（w*h 个 uint16_t，原地修改）。
 * @param w         帧宽。
 * @param h         帧高。
 * @param lut       clip 映射表。
 * @return ISP_OK / ISP_ERR_ARG / ISP_ERR_SIZE。
 */
int isp_highlight_clip_lut_apply(uint16_t *buf, int w, int h,
                                 const uint16_t *lut);

#ifdef __cplusplus
} /* extern "C" */
#endif

#endif /* ISP_HIGHLIGHT_H */
