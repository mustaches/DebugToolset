/**
 * @file isp_levels.h
 * @brief ISP Studio C99 参考实现 —— 曲线调节器（levels_curves 节点）。
 *
 * 覆盖节点：levels_curves（曲线调节器）。
 *
 * 对应 Dart 函数：
 * - levels_curve.dart `levelsCurveModeFromParam`   → isp_levels_curve_mode_from_name
 * - levels_curve.dart `gammaCurveEval`             → isp_levels_gamma_eval
 * - levels_curve.dart `gammaFromPoint`             → isp_levels_gamma_from_point
 * - levels_curve.dart `normalizeLevelsPoints`      → isp_levels_normalize_points
 * - levels_curve.dart `levelsCurveIsIdentity`      → isp_levels_curve_is_identity
 * - levels_curve.dart `levelsCurveEval`（含 _splineEval/_linearEval/_bezierEval/
 *   _deCasteljau 四个内部函数）                    → isp_levels_curve_eval
 * - levels_curve.dart `levelsCurveLut`             → isp_levels_curve_lut
 * - isp_kernels.dart `applyLevelsCurve`            → isp_levels_apply_rgb
 *
 * 曲线值域固定 0..4095（12bit 满量程），端点 A1(0,0) / C1(4095,4095)。
 * 控制点以扁平 double 数组表示：points_xy[2*i]=x，points_xy[2*i+1]=y，
 * 对应 Dart 侧的 `List<List<double>>`（`[[x, y], …]`）。
 *
 * 规范要点速览见 isp_common.h 文件头注释。
 */

#ifndef ISP_LEVELS_H
#define ISP_LEVELS_H

#include "isp_common.h"

#ifdef __cplusplus
extern "C" {
#endif

/* ---------------------------------------------------------------------------
 * 常量
 * ------------------------------------------------------------------------- */

/** 曲线值域上限（Dart `kLevelsMax`）。 */
#define ISP_LEVELS_MAX 4095
/** LUT 级数（0..4095 共 4096 级）。 */
#define ISP_LEVELS_LUT_SIZE 4096

/* ---------------------------------------------------------------------------
 * 曲线生成公式（Dart `enum LevelsCurveMode`，枚举值顺序一致）
 * ------------------------------------------------------------------------- */
typedef enum IspLevelsCurveMode {
  /** Fritsch–Carlson 单调三次样条（默认）：平滑且单调，段内无过冲。 */
  ISP_LEVELS_CURVE_SPLINE = 0,
  /** 贝塞尔曲线：控制点整体作为控制多边形，De Casteljau 求值 + 二分反解。 */
  ISP_LEVELS_CURVE_BEZIER = 1,
  /** 线段法：控制点间直线连接，不做平滑。 */
  ISP_LEVELS_CURVE_LINEAR = 2,
  /** gamma 曲线：y = max·(x/max)^(1/γ)，忽略控制点。 */
  ISP_LEVELS_CURVE_GAMMA = 3
} IspLevelsCurveMode;

/* ---------------------------------------------------------------------------
 * scratch 契约
 *
 * isp_levels_curve_eval / isp_levels_curve_lut 需要一块 double 临时区：
 * - spline 模式：段斜率 d[n-1] + 端点切线 m[n]，共 2n-1 个 double；
 * - bezier 模式：De Casteljau 递推数组 v[n]，共 n 个 double；
 * - linear / gamma 模式：不使用 scratch（可传 NULL）。
 * 统一按上界 2n 个 double 提供。
 * ------------------------------------------------------------------------- */

/** eval/lut 所需 scratch 的 double 个数（n 为控制点个数）。 */
#define ISP_LEVELS_SCRATCH_DOUBLES(point_count) ((size_t)(point_count) * 2u)
/** eval/lut 所需 scratch 的字节数（n 为控制点个数）。 */
#define ISP_LEVELS_SCRATCH_BYTES(point_count) \
  (ISP_LEVELS_SCRATCH_DOUBLES(point_count) * sizeof(double))

/* ---------------------------------------------------------------------------
 * 节点参数解析 / 控制点规范化
 * ------------------------------------------------------------------------- */

/**
 * @brief 从节点参数名还原曲线生成公式（未知/缺失回退样条）。
 *
 * Dart 来源：levels_curve.dart `levelsCurveModeFromParam`。
 *
 * @param name 参数字符串（"bezier"/"linear"/"gamma"，其余含 NULL 均为 spline）。
 * @return 曲线模式。
 */
IspLevelsCurveMode isp_levels_curve_mode_from_name(const char *name);

/**
 * @brief 规范化控制点：钳位到 0..4095、按 x 升序排序、去除重复 x
 *        （保后者）、强制首尾为 x=0 / x=4095 的端点（y 保留）。
 *
 * Dart 来源：levels_curve.dart `normalizeLevelsPoints`。
 * 空列表（point_count <= 0 或 points_xy 为 NULL）回退恒等曲线
 * {{0,0},{4095,4095}}。结果保证 x 严格递增、点数 >= 2，可直接交给
 * isp_levels_curve_eval / isp_levels_curve_lut。
 *
 * @param points_xy    输入控制点（扁平 [x0,y0,x1,y1,…]）。
 * @param point_count  输入控制点个数。
 * @param out_xy       输出控制点缓冲（容量见 out_capacity）。
 * @param out_capacity 输出缓冲容量（点数）；至少为 max(point_count, 2)。
 * @param out_count    输出实际点数（>= 2）。
 * @return ISP_OK / ISP_ERR_ARG（空指针）/ ISP_ERR_SIZE（容量不足）。
 */
int isp_levels_normalize_points(const double *points_xy, int point_count,
                                double *out_xy, int out_capacity,
                                int *out_count);

/**
 * @brief 恒等判定：所有控制点都在对角线上（|y-x| <= 1e-9）。
 *
 * Dart 来源：levels_curve.dart `levelsCurveIsIdentity`。
 *
 * @param points_xy   控制点数组。
 * @param point_count 控制点个数（<= 0 或 NULL 视为恒等）。
 * @return 恒等返回 true。
 */
bool isp_levels_curve_is_identity(const double *points_xy, int point_count);

/* ---------------------------------------------------------------------------
 * gamma 曲线
 * ------------------------------------------------------------------------- */

/**
 * @brief gamma 曲线求值：y = max·(x/max)^(1/γ)。
 *
 * Dart 来源：levels_curve.dart `gammaCurveEval`。
 * γ = 1 为恒等；γ > 1 提亮中间调，γ < 1 压暗。端点 x=0/max 恒为 0/max。
 *
 * @param x     输入（0..4095 域）。
 * @param gamma γ 值。
 * @return 曲线值。
 */
double isp_levels_gamma_eval(double x, double gamma);

/**
 * @brief 由控制点位置反解 gamma：γ = ln(x/max) / ln(y/max)。
 *
 * Dart 来源：levels_curve.dart `gammaFromPoint`（返回 null 对应本函数
 * 返回 false）。
 *
 * @param x         控制点 x（须在 (0, 4095) 开区间）。
 * @param y         控制点 y（须在 (0, 4095) 开区间）。
 * @param out_gamma 输出 γ。
 * @return 可定义返回 true；x/y 越出开区间或 out_gamma 为 NULL 返回 false。
 */
bool isp_levels_gamma_from_point(double x, double y, double *out_gamma);

/* ---------------------------------------------------------------------------
 * 传递函数求值与 LUT 生成
 * ------------------------------------------------------------------------- */

/**
 * @brief 按 mode 指定的生成公式求传递函数在 x 处的值。
 *
 * Dart 来源：levels_curve.dart `levelsCurveEval`（spline → Fritsch–Carlson
 * 单调三次 Hermite `_splineEval`；bezier → 二分反解 + De Casteljau
 * `_bezierEval`；linear → `_linearEval`；gamma → `gammaCurveEval`）。
 *
 * points_xy 须先经 isp_levels_normalize_points 规范化（x 严格递增、
 * 点数 >= 2）。gamma 模式忽略 points_xy（可传 NULL）。
 *
 * @param points_xy   规范化控制点。
 * @param point_count 控制点个数。
 * @param x           求值位置（0..4095 域）。
 * @param mode        曲线模式。
 * @param gamma       γ 值（仅 gamma 模式使用）。
 * @param scratch     临时区，大小 ISP_LEVELS_SCRATCH_BYTES(point_count)；
 *                    linear/gamma 模式可为 NULL。
 * @return 曲线值（浮点，未舍入未钳位）。
 */
double isp_levels_curve_eval(const double *points_xy, int point_count,
                             double x, IspLevelsCurveMode mode, double gamma,
                             double *scratch);

/**
 * @brief 生成 0..4095 共 4096 级的传递函数 LUT。
 *
 * Dart 来源：levels_curve.dart `levelsCurveLut`。每级取
 * levelsCurveEval(x).round().clamp(0, 4095)（Dart round() 为四舍五入、
 * 恰半远离零，与 C99 round() 同语义）。
 *
 * @param points_xy   规范化控制点（x 严格递增、点数 >= 2；
 *                    gamma 模式忽略，可传 NULL）。
 * @param point_count 控制点个数。
 * @param mode        曲线模式。
 * @param gamma       γ 值（仅 gamma 模式使用）。
 * @param scratch     临时区，大小 ISP_LEVELS_SCRATCH_BYTES(point_count)；
 *                    linear/gamma 模式可为 NULL。
 * @param lut_out     输出 LUT，容量 ISP_LEVELS_LUT_SIZE（4096）个 uint16_t。
 * @return ISP_OK / ISP_ERR_ARG（空指针、点数不足、x 非严格递增）。
 */
int isp_levels_curve_lut(const double *points_xy, int point_count,
                         IspLevelsCurveMode mode, double gamma,
                         double *scratch, uint16_t *lut_out);

/* ---------------------------------------------------------------------------
 * LUT 应用（帧级 kernel）
 * ------------------------------------------------------------------------- */

/**
 * @brief RGB 帧逐通道过传递函数 LUT（交织三通道，长度 w*h*3）。
 *
 * Dart 来源：isp_kernels.dart `applyLevelsCurve`。
 * 帧值先按 max_value 线性缩放到 LUT 域（0..4095）查表，结果再缩放回
 * 0..max_value；max_value == 4095 时直通查表。缩放均为带中点舍入偏置的
 * 整数除法（Dart `~/` 向下取整，正数域与 C 截断除法一致）：
 *   idx = (v * 4095 + (max_value >> 1)) ~/ max_value
 *   out = (lut[idx] * max_value + 2047) ~/ 4095
 * 恒等 LUT 由调用方判定并跳过本核（Dart 侧不拷贝）。
 *
 * 允许 in-place（rgb == out）：out[i] 只依赖 rgb[i]。
 * 调用契约：帧值 <= max_value；Dart 在越界时抛 RangeError，C 侧改为
 * 将查表下标钳位到 4095 以避免越界读（防御性差异，正常数据不触发）。
 *
 * @param rgb       输入交织 RGB 帧（w*h*3 个 uint16_t）。
 * @param w         帧宽。
 * @param h         帧高。
 * @param lut       4096 级 LUT（isp_levels_curve_lut 生成）。
 * @param max_value 采样最大值（> 0）。
 * @param out       输出帧（w*h*3 个 uint16_t，可与 rgb 相同）。
 * @return ISP_OK / ISP_ERR_ARG（空指针、max_value <= 0）/ ISP_ERR_SIZE。
 */
int isp_levels_apply_rgb(const uint16_t *rgb, int w, int h,
                         const uint16_t *lut, int max_value, uint16_t *out);

#ifdef __cplusplus
} /* extern "C" */
#endif

#endif /* ISP_LEVELS_H */
