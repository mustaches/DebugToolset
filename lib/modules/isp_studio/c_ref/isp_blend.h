/**
 * @file isp_blend.h
 * @brief ISP Studio C99 参考实现 —— 双源运算组（multiplier / adder / blender / mux4 节点）。
 *
 * 覆盖节点与 Dart 来源对应关系：
 * - multiplier（乘法器）  → isp_blend_multiply
 *     Dart: isp_kernels.dart `multiplyMono`
 *     out = (a+offset1)×(b+offset2)/maxValue 归一化相乘，截位到 0..maxValue。
 * - adder（加法器）       → isp_blend_add
 *     Dart: isp_kernels.dart `blendMono`
 *     out = a×balance + b×(1−balance) 平衡加权混合，截位到 maxValue。
 * - blender（混叠器）     → isp_blend_mask_apply
 *     Dart: isp_kernels.dart `blendMaskMono`
 *     out = 基图 + 混叠图×蒙版/maxValue×strength；叠加目标通道按基图格式
 *     （YUV 只加 Y、HSL 只加 L、RGB 三通道同加、Mono 单通道）。
 * - mux4（多路选择器）    → isp_mux4_select
 *     Dart: pipeline_runner.dart `case 'mux4'`（纯透传选择，零算法）。
 *
 * 帧约定与 isp_common.h 一致：mono 帧长度 w*h，交织三通道帧长度 w*h*3。
 * 本组函数均不需要临时缓冲（无 scratch 宏），输出/原地缓冲由调用方提供。
 * 规范要点速览见 isp_common.h 文件头注释。
 */

#ifndef ISP_BLEND_H
#define ISP_BLEND_H

#include "isp_common.h"

#ifdef __cplusplus
extern "C" {
#endif

/* ---------------------------------------------------------------------------
 * 混叠器基图格式（对应 Dart blendMaskMono 的 format 字符串参数）
 * ------------------------------------------------------------------------- */

/**
 * @brief blender 节点基图格式。
 *
 * Dart 来源：isp_kernels.dart `blendMaskMono` 的 `format` 参数
 * （'rgb' / 'yuv' / 'hsl' / 'mono'，default 分支按 mono 处理）。
 * 决定 mono 混叠图的叠加目标通道。
 */
typedef enum IspBlendFormat {
  /** 交织 RGB：mono 混叠图三通道同加（等效亮度叠加，不产生色偏）。 */
  ISP_BLEND_FORMAT_RGB = 0,
  /** 交织 YUV：mono 混叠图只加 Y（U/V 不变，锐化不产生色偏）。 */
  ISP_BLEND_FORMAT_YUV = 1,
  /** 交织 HSL：mono 混叠图只加 L（第 3 通道，下标 i+2）。 */
  ISP_BLEND_FORMAT_HSL = 2,
  /** 单通道 Mono：直接叠加。 */
  ISP_BLEND_FORMAT_MONO = 3
} IspBlendFormat;

/* ---------------------------------------------------------------------------
 * multiplier / adder / blender / mux4
 * ------------------------------------------------------------------------- */

/**
 * @brief 乘法器：两路 mono 帧逐像素归一化相乘。
 *
 * Dart 来源：isp_kernels.dart `multiplyMono`：
 * out[i] = _clampTo((a[i] + offset1) * (b[i] + offset2) / maxValue, maxValue)。
 *
 * 归一化使输出仍在原量程内；offset 可用于黑电平抬升/符号偏移，避免
 * 零值像素把另一路整体清零。全部经双精度浮点中间计算，收尾按 Dart
 * `_clampTo` 口径（先按 double 比较 0/maxValue，再四舍五入 round()）。
 *
 * Dart 中两路长度不一致按短者截断；C 侧长度由调用方以 n 给出（分辨率
 * 一致性校验在 pipeline_runner 节点分支完成，属调用方职责）。
 *
 * @param a        源 1 帧（n 个 uint16_t）。
 * @param b        源 2 帧（n 个 uint16_t）。
 * @param n        像素个数（mono 帧为 w*h）。
 * @param offset1  源 1 偏移（Dart offset1，默认 0）。
 * @param offset2  源 2 偏移（Dart offset2，默认 0）。
 * @param max_value 采样最大值。
 * @param out      输出帧（n 个 uint16_t，调用方提供；允许与 a 或 b 同址
 *                 原地计算，因每个输出像素只依赖同下标输入）。
 * @return ISP_OK；a/b/out 为 NULL、n <= 0 或 max_value <= 0 返回 ISP_ERR_ARG。
 */
int isp_blend_multiply(const uint16_t *a, const uint16_t *b, int n,
                       double offset1, double offset2, int max_value,
                       uint16_t *out);

/**
 * @brief 加法器：两路 mono 帧平衡加权混合。
 *
 * Dart 来源：isp_kernels.dart `blendMono`：
 * out[i] = _clampTo(a[i] * balance + b[i] * (1 - balance), maxValue)。
 *
 * 两路增益总和恒为 1（balance 即源 1 增益，源 2 增益 = 1−balance）。
 * 浮点中间结果按 Dart `_clampTo` 口径收尾（double 比较 + round()）。
 *
 * @param a         源 1 帧（n 个 uint16_t）。
 * @param b         源 2 帧（n 个 uint16_t）。
 * @param n         像素个数（mono 帧为 w*h）。
 * @param balance   源 1 增益（Dart balance，0..1，缺省 0.5）。
 * @param max_value 采样最大值。
 * @param out       输出帧（n 个 uint16_t，调用方提供；允许与 a 或 b 同址）。
 * @return ISP_OK；a/b/out 为 NULL、n <= 0 或 max_value <= 0 返回 ISP_ERR_ARG。
 */
int isp_blend_add(const uint16_t *a, const uint16_t *b, int n,
                  double balance, int max_value, uint16_t *out);

/**
 * @brief 混叠器：基图 + 混叠图×蒙版/maxValue×strength（原地叠加）。
 *
 * Dart 来源：isp_kernels.dart `blendMaskMono`：
 * out = 基图副本；delta = blend×mask×(strength/maxValue)；delta <= 0 的像素
 * 跳过（基图原样保留，含负 delta 不下压）；delta > 0 时按格式叠加：
 * - RGB：三通道同加（等效亮度增量，同 unsharp mask 的通道无关增量）；
 * - YUV：只加 Y（下标 i）；HSL：只加 L（下标 i+2）；Mono：直接叠加。
 * 混叠图为三通道交织（blend_channels=3）时逐通道对应叠加
 * （Y 加到 Y、U 加到 U……），与格式无关。
 *
 * 本函数为**原地**版本：base 既作输入又作输出。Dart 语义为「复制基图
 * 再叠加」，因每个输出像素只依赖同下标基图像素，原地计算结果逐位一致。
 * strength == 0（double 精确比较，同 Dart）时提前返回，基图不动。
 *
 * 缓冲长度契约（调用方保证，同 pipeline_runner 的校验口径）：
 * - base：format == ISP_BLEND_FORMAT_MONO 时 w*h，其余 w*h*3；
 * - mask：w*h（单通道）；
 * - blend：blend_channels == 1 时 w*h，== 3 时 w*h*3。
 *
 * @param base           基图（原地修改）。
 * @param blend          混叠图。
 * @param mask           蒙版（单通道 w*h）。
 * @param w              帧宽。
 * @param h              帧高。
 * @param format         基图格式（决定 mono 混叠图的叠加目标通道）。
 * @param blend_channels 混叠图通道数：1（mono）或 3（交织三通道）。
 * @param strength       混叠强度（Dart strength，缺省 1.0）。
 * @param max_value      采样最大值。
 * @return ISP_OK；base/blend/mask 为 NULL、w/h <= 0、max_value <= 0、
 *         format 或 blend_channels 非法返回 ISP_ERR_ARG。
 */
int isp_blend_mask_apply(uint16_t *base, const uint16_t *blend,
                         const uint16_t *mask, int w, int h,
                         IspBlendFormat format, int blend_channels,
                         double strength, int max_value);

/**
 * @brief 多路选择器（4 选 1）：返回 select 选中的输入指针，零算法透传。
 *
 * Dart 来源：pipeline_runner.dart `case 'mux4'`——把 select 选中的那路
 * 源输入**透传**到输出（不改数据、不复制，输出帧 = 所选上游帧；格式/宽高/
 * maxValue 随行）。C 参考实现同样只做指针选择，调用方直接使用返回指针，
 * 不要释放（指针所有权仍在调用方的各输入缓冲）。
 *
 * select 先钳位到 [1, 4]（Dart: `p['select'].toInt().clamp(1, 4)`，
 * 参数缺省为 1）。选中指针为 NULL 时原样返回 NULL——对应 Dart 的
 * 「多路选择器的源 sel 未接入输入」错误，由调用方判定处理。
 *
 * @param select 选择源序号（1..4，越界自动钳位）。
 * @param in1    源 1 帧指针（可为 NULL 表示未接入）。
 * @param in2    源 2 帧指针（可为 NULL 表示未接入）。
 * @param in3    源 3 帧指针（可为 NULL 表示未接入）。
 * @param in4    源 4 帧指针（可为 NULL 表示未接入）。
 * @return 选中的输入指针（可能为 NULL）。
 */
const uint16_t *isp_mux4_select(int select, const uint16_t *in1,
                                const uint16_t *in2, const uint16_t *in3,
                                const uint16_t *in4);

#ifdef __cplusplus
} /* extern "C" */
#endif

#endif /* ISP_BLEND_H */
