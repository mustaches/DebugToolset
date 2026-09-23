/**
 * @file isp_fluoro.h
 * @brief ISP Studio C99 参考实现 —— 荧光处理组。
 *
 * 覆盖节点：fluoro_leak / fluoro_background / fluoro_normalize /
 *           fluoro_temporal / pseudo_color / fluoro_fusion。
 * 对应 Dart 函数：lib/modules/isp_studio/pipeline/isp_kernels.dart 中的
 * - `applyFluoroLeak`       激发泄漏统一电平扣除（扣除量限幅 maxSub）
 * - `applyFluoroBackground` 块均值低频背景估计 + 按 strength 比例扣除
 * - `applyFluoroNormalize`  全帧均值归一化 v' = v × ref / max(mean, eps)
 * - `applyTemporalIir`      时域 IIR 降噪 Y = αF + (1−α)Yprev（运动自适应）
 * - `monoPseudoColor`       mono → 伪彩 RGB（green/magenta/hot 色表）
 * - `fuseFluorescence`      白光 RGB + 荧光 mono 融合（双线性配准 +
 *                           threshold→α 映射 + alpha/contour 两模式）
 *
 * 帧约定与 isp_common.h 一致：mono 帧 w*h 个 uint16_t，交织 RGB 帧 w*h*3 个。
 * 除 fluoro_background 需要调用方提供 scratch（宏见下）外，其余内核零临时缓冲。
 */

#ifndef ISP_FLUORO_H
#define ISP_FLUORO_H

#include "isp_common.h"

#ifdef __cplusplus
extern "C" {
#endif

/* ---------------------------------------------------------------------------
 * 伪彩色表 / 融合模式枚举
 * ------------------------------------------------------------------------- */

/**
 * @brief 伪彩色表（Dart 来源：`monoPseudoColor`/`fuseFluorescence` 的
 *        colormap 字符串参数：'green'/'magenta'/'hot'）。
 */
typedef enum IspFluoroColormap {
  /** ICG 荧光惯例的纯绿映射：R=0, G=t, B=0。 */
  ISP_FLUORO_CMAP_GREEN = 0,
  /** 品红映射：R=t, G=0, B=t。 */
  ISP_FLUORO_CMAP_MAGENTA = 1,
  /** 黑体辐射色表：黑 → 红 → 黄 → 白。 */
  ISP_FLUORO_CMAP_HOT = 2
} IspFluoroColormap;

/**
 * @brief 荧光融合模式（Dart 来源：`fuseFluorescence` 的 mode 字符串参数：
 *        'alpha'/'contour'）。
 */
typedef enum IspFluoroFusionMode {
  /** α 混合：RGB_f = (1−α)·WL + α·pseudo(FL)。 */
  ISP_FLUORO_FUSION_ALPHA = 0,
  /** 轮廓叠加：荧光 mask 的 3x3 轮廓处以伪彩全强度替换，其余透传白光。 */
  ISP_FLUORO_FUSION_CONTOUR = 1
} IspFluoroFusionMode;

/* ---------------------------------------------------------------------------
 * fluoro_background 的 scratch 契约
 *
 * Dart `applyFluoroBackground` 内部有两块临时数据：
 * 1. 块均值表 means：bx*by 个 double（bx/by 为水平/垂直块数，按块大小
 *    向上取整分块，块大小下限 2）；
 * 2. 输入帧的完整副本 src：w*h 个 uint16_t（扣除前先备份，保证读取的是
 *    扣除前的原值，与 Dart 的 Uint16List.fromList(mono) 一致）。
 *
 * 调用方按下述宏分配一块连续 scratch 传入；本内核内部布局为：
 * [0, means_bytes) 存 double 块均值表（放首部保证 8 字节对齐），
 * [means_bytes, 总长) 存 uint16_t 输入副本。
 * ------------------------------------------------------------------------- */

/** 块大小的有效值（Dart：blockSize < 2 时按 2 处理）。 */
#define ISP_FLUORO_BG_EFFECTIVE_BS(bs) ((bs) < 2 ? 2 : (bs))

/** 块均值表项数：ceil(w/bs) * ceil(h/bs)，bs 自动按下限 2 钳位。 */
#define ISP_FLUORO_BG_BLOCK_COUNT(w, h, bs)                       \
  ((size_t)(((w) + ISP_FLUORO_BG_EFFECTIVE_BS(bs) - 1) /          \
            ISP_FLUORO_BG_EFFECTIVE_BS(bs)) *                     \
   (size_t)(((h) + ISP_FLUORO_BG_EFFECTIVE_BS(bs) - 1) /          \
            ISP_FLUORO_BG_EFFECTIVE_BS(bs)))

/**
 * @brief isp_fluoro_background_apply 所需 scratch 字节数：
 *        块均值表（double）+ 输入帧副本（uint16_t）。
 */
#define ISP_FLUORO_BACKGROUND_SCRATCH_BYTES(w, h, bs)             \
  (ISP_FLUORO_BG_BLOCK_COUNT(w, h, bs) * sizeof(double) +         \
   (size_t)(w) * (size_t)(h) * sizeof(uint16_t))

/* ---------------------------------------------------------------------------
 * 函数声明
 * ------------------------------------------------------------------------- */

/**
 * @brief 激发泄漏扣除（节点 fluoro_leak）：原地统一扣除泄漏电平。
 *
 * Dart 来源：isp_kernels.dart `applyFluoroLeak`。
 *
 * 关键步骤（与 Dart 逐项对应）：
 * 1. 扣除量 sub = min(level, max_sub)（Dart：level < maxSub ? level : maxSub）；
 * 2. sub <= 0 时直接返回（double 精确比较）；
 * 3. 逐像素 v = mono[i] − sub（double 运算）；v <= 0 写 0，否则写
 *    round(v)（Dart round 半值远离零，此处 v > 0 故 floor(v+0.5) 等价）。
 *    Dart 侧无上限钳位（减正数不会超量程），本函数同样不钳上限。
 *
 * @param mono    mono 帧（w*h 个 uint16_t，原地修改）。
 * @param width   帧宽（> 0）。
 * @param height  帧高（> 0）。
 * @param level   泄漏电平（ADC 计数，可为小数）。
 * @param max_sub 扣除量上限。
 * @return ISP_OK 成功；ISP_ERR_ARG 空指针；ISP_ERR_SIZE 宽高 <= 0。
 */
int isp_fluoro_leak_apply(uint16_t *mono, int width, int height, double level,
                          double max_sub);

/**
 * @brief 自发荧光背景扣除（节点 fluoro_background）：块均值估计低频背景，
 *        按比例扣除。
 *
 * Dart 来源：isp_kernels.dart `applyFluoroBackground`。
 *
 * 关键步骤（与 Dart 逐项对应）：
 * 1. strength <= 0 直接返回；块大小 bs = max(block_size, 2)；
 * 2. 按 bs×bs 向上取整分块（边缘块截短），逐块求像素均值（sum 为 64 位
 *    整数累加、均值 = sum/count 转 double），写入 scratch 的块均值表；
 * 3. 把输入帧完整复制到 scratch 的 src 副本（Dart：Uint16List.fromList）；
 * 4. 逐像素查所属块均值 bg，v = src[i] − strength × bg；v <= 0 写 0，
 *    否则写 round(v)。同 fluoro_leak，无上限钳位。
 *
 * @param mono       mono 帧（w*h 个 uint16_t，原地修改）。
 * @param width      帧宽（> 0）。
 * @param height     帧高（> 0）。
 * @param block_size 背景估计块边长（< 2 时按 2 处理）。
 * @param strength   扣除比例（0..1；Dart 未做上限校验，>1 照常计算）。
 * @param scratch    临时缓冲，至少 ISP_FLUORO_BACKGROUND_SCRATCH_BYTES(
 *                   width, height, block_size) 字节，按 double 对齐。
 * @return ISP_OK 成功；ISP_ERR_ARG 空指针；ISP_ERR_SIZE 宽高 <= 0。
 */
int isp_fluoro_background_apply(uint16_t *mono, int width, int height,
                                int block_size, double strength, void *scratch);

/**
 * @brief 激发参考归一化（节点 fluoro_normalize）：以全帧均值估计激发强度，
 *        把画面增益拉到参考电平。
 *
 * Dart 来源：isp_kernels.dart `applyFluoroNormalize`。
 *
 * 关键步骤（与 Dart 逐项对应）：
 * 1. reference <= 0 直接返回；
 * 2. 全帧求和（64 位整数累加），mean = sum / (w*h)（double）；
 * 3. mean < epsilon 直接返回（Dart 语义等价于分母取 max(mean, eps) 后
 *    gain = 1 的短路：mean < eps 时不动帧）；
 * 4. gain = reference / mean；gain == 1.0（double 精确比较）直接返回；
 * 5. 逐像素 v = mono[i] × gain，按 Dart `_clampTo` 截位：先与 0/max_value
 *    比较钳位，再四舍五入（floor(v+0.5)）。
 *
 * @param mono      mono 帧（w*h 个 uint16_t，原地修改）。
 * @param width     帧宽（> 0）。
 * @param height    帧高（> 0）。
 * @param reference 参考电平（<= 0 时关闭）。
 * @param epsilon   均值下限（防除零）。
 * @param max_value 采样最大值。
 * @return ISP_OK 成功；ISP_ERR_ARG 空指针或 max_value < 0；
 *         ISP_ERR_SIZE 宽高 <= 0。
 */
int isp_fluoro_normalize_apply(uint16_t *mono, int width, int height,
                               double reference, double epsilon, int max_value);

/**
 * @brief 时域 IIR 降噪（节点 fluoro_temporal）：Y = αF + (1−α)Yprev。
 *
 * Dart 来源：isp_kernels.dart `applyTemporalIir`。Dart 返回 (输出帧, 新历史
 * 帧)，C 侧历史缓冲由调用方持有、本函数原地更新，语义一一对应：
 * - has_history 为 false（对应 Dart history == null 或尺寸不符）：直通，
 *   out = 当前帧拷贝，并把当前帧拷入 history（成为新历史）；
 * - has_history 为 true：α 先钳位到 [0,1]；motion_adapt 开启时，帧差
 *   |F − Yprev| > max_value/16（double 阈值）的像素强制 α=1；逐像素
 *   out = round(α·F + (1−α)·Yprev)（Dart 不钳位到 max_value，本函数同）；
 *   结束后把 out 拷回 history（Dart 新历史 = 输出帧副本）。
 *
 * 支持 out 与 mono 或 history 同缓冲（逐像素先读后写；history == out 时
 * 末尾回拷自动跳过）。
 *
 * @param mono         当前帧（w*h 个 uint16_t）。
 * @param history      历史帧缓冲（w*h 个 uint16_t，调用方持有；本函数更新）。
 * @param has_history  history 是否已含有效上一帧（false 时直通并初始化历史）。
 * @param out          输出帧（w*h 个 uint16_t）。
 * @param width        帧宽（> 0）。
 * @param height       帧高（> 0）。
 * @param alpha        当前帧权重（钳位到 [0,1]）。
 * @param motion_adapt 运动自适应开关（帧差超阈值强制 α=1 防拖影）。
 * @param max_value    采样最大值（仅用于运动阈值 max_value/16）。
 * @return ISP_OK 成功；ISP_ERR_ARG 空指针；ISP_ERR_SIZE 宽高 <= 0。
 */
int isp_fluoro_temporal_iir_apply(const uint16_t *mono, uint16_t *history,
                                  bool has_history, uint16_t *out, int width,
                                  int height, double alpha, bool motion_adapt,
                                  int max_value);

/**
 * @brief 伪彩映射（节点 pseudo_color）：mono 灰度按增益归一化后映射为
 *        伪彩 RGB。
 *
 * Dart 来源：isp_kernels.dart `monoPseudoColor`。
 *
 * 关键步骤（与 Dart 逐项对应）：
 * 1. t = mono[i] × gain / max_value（double），钳位到 [0,1]；
 * 2. 按色表映射：green（0,t,0）、magenta（t,0,t）、
 *    hot（min(3t,1), clamp(3t−1,0,1), clamp(3t−2,0,1)，黑→红→黄→白）；
 * 3. 每通道 v = c × max_value，按 Dart `_clampTo` 截位（先钳位再
 *    floor(v+0.5) 舍入），写入 w*h*3 交织 RGB 输出。
 *
 * @param mono      mono 帧（w*h 个 uint16_t）。
 * @param out_rgb   输出交织 RGB（w*h*3 个 uint16_t，调用方提供）。
 * @param width     帧宽（> 0）。
 * @param height    帧高（> 0）。
 * @param colormap  色表枚举。
 * @param gain      增益（归一化前乘，1.0 为原始量程）。
 * @param max_value 采样最大值。
 * @return ISP_OK 成功；ISP_ERR_ARG 空指针、max_value <= 0 或非法色表；
 *         ISP_ERR_SIZE 宽高 <= 0。
 */
int isp_fluoro_pseudo_color_apply(const uint16_t *mono, uint16_t *out_rgb,
                                  int width, int height,
                                  IspFluoroColormap colormap, double gain,
                                  int max_value);

/**
 * @brief 荧光融合（节点 fluoro_fusion）：白光 RGB 与荧光 mono 融合出图。
 *
 * Dart 来源：isp_kernels.dart `fuseFluorescence`。
 *
 * 关键步骤（与 Dart 逐项对应）：
 * 1. 荧光图按 (offset_x, offset_y) 偏移做双线性重采样配准：采样坐标先
 *    钳位到 [0, w−1]/[0, h−1]（double），floor 取整点后按 tx/ty 双线性
 *    插值（边界 x1/y1 回退为 x0/y0）；
 * 2. t = fl / max_value 钳位 [0,1] 后按色表得伪彩 (pr, pg, pb)（增益恒 1，
 *    融合内不再叠加增益）；
 * 3. contour 模式：fl >= threshold 的像素若 3x3 邻域（同样经偏移采样）
 *    存在 < threshold 的点即判为轮廓，轮廓处以伪彩全强度写出，其余像素
 *    透传白光 RGB；
 * 4. alpha 模式：range = max_value − threshold；range > 0 且 fl > threshold
 *    时 α = alpha_max × (fl − threshold)/range（上限 alpha_max），否则 α=0；
 *    逐通道 out = _clampTo(wl×(1−α) + pseudo×max_value×α, max_value)。
 *
 * @param rgb_wl    白光交织 RGB 帧（w*h*3 个 uint16_t）。
 * @param mono_fl   荧光 mono 帧（w*h 个 uint16_t，与白光同分辨率）。
 * @param out_rgb   输出交织 RGB（w*h*3 个 uint16_t，调用方提供）。
 * @param width     帧宽（> 0）。
 * @param height    帧高（> 0）。
 * @param mode      融合模式（alpha / contour）。
 * @param threshold 荧光门限（α 映射起点 / contour 的 mask 阈值）。
 * @param alpha_max α 上限（Dart 默认 0.8）。
 * @param colormap  伪彩色表。
 * @param offset_x  荧光图配准横向偏移（采样坐标 = x + offset_x，可为小数）。
 * @param offset_y  荧光图配准纵向偏移。
 * @param max_value 采样最大值。
 * @return ISP_OK 成功；ISP_ERR_ARG 空指针、max_value <= 0、非法模式或
 *         非法色表；ISP_ERR_SIZE 宽高 <= 0。
 */
int isp_fluoro_fuse_apply(const uint16_t *rgb_wl, const uint16_t *mono_fl,
                          uint16_t *out_rgb, int width, int height,
                          IspFluoroFusionMode mode, double threshold,
                          double alpha_max, IspFluoroColormap colormap,
                          double offset_x, double offset_y, int max_value);

/* ---------------------------------------------------------------------------
 * LUT 模式（节点属性 codegenMode=lut）：伪彩色表按生成期参数烘焙为
 * static const（wrapper 内），运行期纯查表零建表成本。
 * ------------------------------------------------------------------------- */

/**
 * @brief 伪彩 LUT 查表施加：mono 帧逐值经三通道色表映射为交织 RGB。
 *
 * 与 isp_fluoro_pseudo_color_apply 直算逐位一致（表项 = t 钳位后查色表
 * 再按 _clampTo 截位的逐值预计算）。调用契约：帧值 <= max_value 且
 * 表长 >= max_value+1。
 *
 * @param mono      输入 mono 帧（w*h 个 uint16_t）。
 * @param out_rgb   输出交织 RGB 帧（w*h*3，调用方提供）。
 * @param width     帧宽。
 * @param height    帧高。
 * @param lut_r     R 通道色表。
 * @param lut_g     G 通道色表。
 * @param lut_b     B 通道色表。
 * @param max_value 采样最大值。
 * @return ISP_OK / ISP_ERR_ARG / ISP_ERR_SIZE。
 */
int isp_fluoro_pseudo_color_lut_apply(const uint16_t *mono, uint16_t *out_rgb,
                                      int width, int height,
                                      const uint16_t *lut_r,
                                      const uint16_t *lut_g,
                                      const uint16_t *lut_b, int max_value);

#ifdef __cplusplus
} /* extern "C" */
#endif

#endif /* ISP_FLUORO_H */
