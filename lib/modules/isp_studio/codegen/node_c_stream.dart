/// ISP 节点编组「黑盒子 C 代码」（行级流水）：节点行核发射器。
///
/// 覆盖三类行核（流式模型见 stream_plan.dart 文件头）：
/// - **点对点**（emitStreamRowKernel）：给定输入行通道 C 表达式（物化流
///   行缓冲元素 / 外部输入行指针元素 / 上游融合节点的局部变量），发射
///   与该类型 c_ref 循环体**位级一致**的逐像素 C 语句（`for (x)` 循环
///   体内），输出为新的局部变量（或零开销别名表达式）；
/// - **垂直窗口**（emitStreamWindowKernel）：dpc/sharpen/edge_extract/
///   rgb_dnr/bayer_dnr/demosaic(bilinear)/highlight(recover)，经
///   StreamWindowAccess 的窗口行指针采样（环形取模 / 外部输入整帧夹取），
///   边界按 c_ref 语义裁剪；dpc 原地语义经输出环复刻；
/// - **分离趟**（_wMorphology/_wGaussianBlur）：水平趟在发射层作为派生
///   环写入（_emitWindowPreamble），此处为垂直趟（morphology 截断极值 /
///   gaussian 夹取卷积 + 强度混合）。
///
/// 行核注释标注对应 c_ref 出处（文件 + 函数）。行核内像素行号统一经
/// [StreamKernelCtx.rowVar] 引用（'y' = 零延迟阶段驱动行，'yo' = 延迟
/// 阶段输出行 yo = y - D）。
///
/// 参数烘焙/Bypass/LUT 模式（codegenMode=lut）语义与整帧版
/// （node_c_gen*.dart）一致：参数全部烘焙为数值常量或 static const 表
/// （生成期经 Dart 侧同一建表函数生成）；Bypass 在生成期已知，直接发射
/// 对应语义（多为直通别名，零语句）；「max_value == 烘焙域 ? 查表 : 直算」
/// 的回退以行内三元实现（两分支均为纯函数，与整帧版逐位一致）。
/// combiner 未连接通道（整帧版传 NULL 由 c_ref 填缺省值）直接发射常量
/// 填充（YUV 的 U/V 缺省 max_value>>1，其余 0）。
///
/// Bayer 域节点（black_level）的像素相位由行循环的 x/y 奇偶得（
/// `((y & 1) << 1) | (x & 1)`），四相位偏移在生成期按烘焙 pattern 解析。
library;

import 'dart:typed_data';

import '../models/isp_graph.dart';
import '../models/isp_node.dart';
import '../pipeline/color_temp.dart';
import '../pipeline/isp_kernels.dart';
import '../pipeline/levels_curve.dart';
import 'group_c_plan.dart';
import 'group_c_target.dart';
import 'node_c_gen.dart';

/// 行核发射结果：[lines] 为 for-x 循环体内的语句（不含缩进，发射层统一
/// 加 6 空格）；[outputs] 为 wrapper 输出端口名 → 通道 C 表达式（局部
/// 变量 / 常量 / 零开销别名）。
typedef StreamKernelResult = (List<String> lines, Map<String, List<String>> outputs);

/// 行核发射上下文：变量分配 + 共享 helper / 文件级声明 / 前奏登记。
class StreamKernelCtx {
  int _seq = 0;

  /// 已使用的共享 helper 名（依赖闭包在 [helperDefs] 解析）。
  final Set<String> helpers = {};

  /// 文件级声明（生成期烘焙表：LUT / black_level 相位偏移 / ccm 定点矩阵）。
  final List<String> fileDecls = [];
  final Set<String> _fileDeclKeys = {};

  /// run() 内 y 循环之前的前奏语句（lsc 径向常量、blender 比例系数、
  /// hsl_debugger 色环偏移等，均为每 run 一次的运行期量；按内容去重——
  /// 尾部冲刷会二次发射延迟阶段的行核）。
  final List<String> prelude = [];
  final Set<String> _preludeKeys = {};

  /// 登记一条前奏语句（按内容去重）。
  void addPrelude(String line) {
    if (_preludeKeys.add(line)) prelude.add(line);
  }

  /// 批量登记前奏语句（按内容去重）。
  void addPreludeAll(Iterable<String> lines) {
    for (final l in lines) {
      addPrelude(l);
    }
  }

  /// gamma 节点色调映射 LUT 登记：ident → (gamma, brightness, contrast)
  /// （已含 Bypass 退化）；发射层据此生成 scratch LUT 区与构建循环。
  final Map<String, (double, double, double)> gammaLuts = {};

  /// x86 FP64 HSL 行核已登记（top .c 需附带 isp_csc_sse.h 及其依赖头）。
  bool cscSseUsed = false;

  /// 分配 for-x 循环体内唯一的局部变量名。
  String freshVar() => 'v${_seq++}';

  /// 像素行坐标变量名（'y' = 零延迟阶段的驱动行；'yo' = 延迟阶段的
  /// 输出行 yo = y - D）。行核内所有依赖像素行号的表达式（Bayer 相位、
  /// lsc 径向坐标、窗口边界判断）统一经此引用。
  String rowVar = 'y';

  /// 登记一个共享 helper（含传递依赖）。
  void useHelper(String name) {
    assert(_kHelperDefs.containsKey(name), '未知 helper: $name');
    if (!helpers.add(name)) return;
    for (final d in _kHelperDeps[name] ?? const <String>[]) {
      useHelper(d);
    }
  }

  /// 登记文件级声明（按 key 去重）。
  void addFileDecl(String key, String decl) {
    if (_fileDeclKeys.add(key)) fileDecls.add(decl);
  }

  /// 已登记 helper 的 C 定义文本（依赖闭包，按 [_kHelperDefs] 定义序）。
  String helperDefs() => [
        for (final e in _kHelperDefs.entries)
          if (helpers.contains(e.key)) e.value,
      ].join('\n\n');
}

/// 重建节点生成上下文（与 GroupCPlan 规划时同一口径：活动输入端口格式
/// 由 wrapper 端口列表 + 类型端口类型推导，lutDomainMax 沿图重算）。
/// [target] 贯通导出目标 CPU（lut_fixed 行核 SIMD 变体选择）。
CNodeGenCtx streamNodeCtx(IspGraph graph, GroupCPlan plan, String nodeId,
    {GroupCTarget target = GroupCTarget.cortexA53_55}) {
  final n = plan.members[nodeId]!;
  final type = IspNodeRegistry.byId(n.typeId)!;
  return CNodeGenCtx(
    node: n,
    type: type,
    ident: plan.idents[nodeId]!,
    inputFormats: {
      for (final cp in plan.wrappers[nodeId]!.inputs)
        cp.name:
            cFrameFormatOfPort(type.inputPort(cp.name)?.type ?? IspPortType.mono),
    },
    lutDomainMax: lutDomainMaxOf(graph, n),
    target: target,
  );
}

// ---------------------------------------------------------------------------
// 共享 helper 库（bb.c 顶部按需发射；均为 c_ref 私有 static 工具的复刻，
// 逐函数标注出处）
// ---------------------------------------------------------------------------

const Map<String, List<String>> _kHelperDeps = {
  'bb_bc_map': ['bb_clamp_to'],
  'bb_levels_apply': [],
  'bb_rgb_to_hsl_px': ['bb_csc_coeffs', 'bb_euclid_mod', 'bb_clamp_to'],
  'bb_hsl_to_rgb_px': ['bb_euclid_mod', 'bb_hue_to_rgb', 'bb_clamp_to'],
  'bb_rgb_to_yuv_px': ['bb_csc_coeffs'],
  'bb_yuv_to_rgb_px': ['bb_csc_coeffs'],
};

const Map<String, String> _kHelperDefs = {
  'bb_clamp_to': '''
/* Dart _clampTo 浮点路径：先按 double 原值与 0/max_value 比较，界内才
 * round()（Dart round 半值远离零，同 C99 round）。出处：isp_blend.c
 * blend_clamp_to / isp_adjust.c isp_adjust_clamp_to /
 * isp_csc_common.h isp_csc_clamp_d（三处同语义）。
 * round 用快路径（界内 v ≥ 0）：floor(v+0.5) + 加法进位修正（t 恰为整
 * 数且 v 严格小于中点 t-0.5 时退一格），与 round(v) 逐位一致——libm
 * round/lround 是函数调用，逐像素路径上占耗时大头（实测 4K ~64ms/帧）。 */
static uint16_t bb_clamp_to(double v, int max_value) {
  if (v < 0) return 0;
  if (v > (double)max_value) return (uint16_t)max_value;
  {
    const double t = v + 0.5;
    const int r = (int)t;
    return (uint16_t)(t == (double)r && v < t - 0.5 ? r - 1 : r);
  }
}''',
  'bb_clamp_i64': '''
/* int64 域钳位到 [0, max_value]（Dart int 为 64 位，极端增益/矩阵下
 * 中间值可超 int32，须在 64 位域先钳位再窄化）。出处：isp_ccm.c
 * isp_ccm_clamp_i64_ / isp_white_balance.c isp_wb_clamp_ll_（同语义）。 */
static uint16_t bb_clamp_i64(int64_t v, int max_value) {
  if (v < 0) return 0;
  if (v > (int64_t)max_value) return (uint16_t)max_value;
  return (uint16_t)v;
}''',
  'bb_round_pos': '''
/* Dart round() 的非负路径（floor(v+0.5)）：仅用于调用点已保证 v > 0
 * 的场合。出处：isp_fluoro.c isp_fluoro__round_pos。 */
static uint16_t bb_round_pos(double v) { return (uint16_t)floor(v + 0.5); }''',
  'bb_clamp01': '''
/* Dart v.clamp(0.0, 1.0)。出处：isp_fluoro.c isp_fluoro__clamp01。 */
static double bb_clamp01(double v) {
  if (v < 0.0) return 0.0;
  if (v > 1.0) return 1.0;
  return v;
}''',
  'bb_clamp_q14': '''
/* Q14 定点乘 + 钳位（codegenMode=lut_fixed）：out = clamp((in*q + 2^13)
 * >> 14)。乘子生成期按 round(mul × 2^14) 烘焙，与 FP64 (double)in × mul
 * 再 round 的偏差 ≤1 LSB（仅当 FP64 乘积距 .5 边界小于 in/2^15 时可能
 * 差 1）。int64 乘积防溢出（uint16 输入 × 5×2^14 超出 int32）；面向无
 * FP64 SIMD 的嵌入式核（A55 NEON 仅 FP32，FP64 只能标量 FPU）。NEON/
 * SSE2 行核（lut_fixed 行函数）内的同款计算为 32 位通道：q ≥ 2^14
 * （mul ≥ 1）且 in 超域时结果必钳到 max_value，先钳位输入与之等价
 * （向量比较选择，无分支）。 */
static uint16_t bb_clamp_q14(int in_v, int32_t q, int max_value) {
  const int64_t r = ((int64_t)in_v * q + 8192) >> 14;
  if (r < 0) return 0;
  if (r > (int64_t)max_value) return (uint16_t)max_value;
  return (uint16_t)r;
}''',
  'bb_bc_map': '''
/* 亮度/对比度单点映射 adjust(y)。出处：isp_adjust.c isp_adjust_bc_map
 * （Dart adjustBrightContrast 内 adjust 闭包）。 */
static int bb_bc_map(int y, double bs, double base, double gs, int max_value) {
  return (int)bb_clamp_to(((y * bs) - base) * gs + base, max_value);
}''',
  'bb_levels_apply': '''
/* levels_curves 传递函数查表（max_value != 4095 时按「加半除数再整除」
 * 线性缩放往返；4095 快路径直通查表）。出处：isp_levels.c
 * isp_levels_apply_rgb 循环体的单点版。 */
static uint16_t bb_levels_apply(const uint16_t *lut, uint16_t v,
                                int max_value) {
  int idx;
  if (max_value == 4095) return lut[v];
  idx = ((int)v * 4095 + (max_value >> 1)) / max_value;
  if (idx > 4095) idx = 4095;
  if (idx < 0) idx = 0;
  return (uint16_t)(((int)lut[idx] * max_value + 2047) / 4095);
}''',
  'bb_csc_coeffs': '''
/* BT.601 全范围正/逆变换 Q16 定点系数（出处：isp_csc_common.h，
 * 与 isp_kernels.dart 常量逐值一致）。 */
#define BB_CSC_CY_R_601 19595   /* 0.299    * 65536 */
#define BB_CSC_CY_G_601 38470   /* 0.587    * 65536 */
#define BB_CSC_CY_B_601 7471    /* 0.114    * 65536 */
#define BB_CSC_CU_R_601 (-11058) /* -0.168736 * 65536 */
#define BB_CSC_CU_G_601 (-21710) /* -0.331264 * 65536 */
#define BB_CSC_CU_B_601 32768   /* 0.5      * 65536 */
#define BB_CSC_CV_R_601 32768   /* 0.5      * 65536 */
#define BB_CSC_CV_G_601 (-27439) /* -0.418688 * 65536 */
#define BB_CSC_CV_B_601 (-5329)  /* -0.081312 * 65536 */
#define BB_CSC_CR_V 91881       /* 1.402     * 65536 */
#define BB_CSC_CG_U (-22553)    /* -0.344136 * 65536 */
#define BB_CSC_CG_V (-46801)    /* -0.714136 * 65536 */
#define BB_CSC_CB_U 116130      /* 1.772     * 65536 */''',
  'bb_euclid_mod': '''
/* Dart double 的 % 等价（欧几里得取模，除数 b > 0 时结果 ∈ [0, b)）。
 * 出处：isp_csc_common.h isp_csc_euclid_mod。 */
static double bb_euclid_mod(double a, double b) {
  double r = fmod(a, b);
  if (r < 0) r += b;
  return r;
}''',
  'bb_hue_to_rgb': '''
/* HSL→RGB 的分段 hue 映射。出处：isp_csc_common.h isp_csc_hue_to_rgb
 * （Dart isp_kernels.dart _hueToRgb）。 */
static double bb_hue_to_rgb(double p, double q, double t) {
  double tt = t;
  if (tt < 0) tt += 1;
  if (tt > 1) tt -= 1;
  if (tt < 1.0 / 6.0) return p + (q - p) * 6.0 * tt;
  if (tt < 1.0 / 2.0) return q;
  if (tt < 2.0 / 3.0) return p + (q - p) * (2.0 / 3.0 - tt) * 6.0;
  return p;
}''',
  'bb_rgb_to_hsl_px': '''
/* 单像素 RGB→HSL（Dart rgbToHsl 循环体）。出处：isp_csc_common.h
 * isp_csc_rgb_to_hsl_px；isp_adjust.c 的同名工具同结果（欧几里得取模
 * 与 fmod+修正逐位一致）。 */
static void bb_rgb_to_hsl_px(int ri, int gi, int bi, int max_value,
                             double inv, uint16_t *out) {
  const double r = ri * inv;
  const double g = gi * inv;
  const double b = bi * inv;
  double mx = g > b ? g : b;
  double mn = g < b ? g : b;
  double h = 0.0, s = 0.0, d, l;
  mx = r > mx ? r : mx;
  mn = r < mn ? r : mn;
  l = (mx + mn) / 2.0;
  d = mx - mn;
  if (d > 0) {
    s = l > 0.5 ? d / (2.0 - mx - mn) : d / (mx + mn);
    if (mx == r) {
      h = bb_euclid_mod((g - b) / d, 6.0);
    } else if (mx == g) {
      h = (b - r) / d + 2.0;
    } else {
      h = (r - g) / d + 4.0;
    }
    h /= 6.0;
    if (h < 0) h += 1.0;
  }
  out[0] = bb_clamp_to(h * max_value, max_value);
  out[1] = bb_clamp_to(s * max_value, max_value);
  out[2] = bb_clamp_to(l * max_value, max_value);
}''',
  'bb_hsl_to_rgb_px': '''
/* 单像素 HSL→RGB（Dart hslToRgb 循环体；H=max_value 时归一化恰为 1.0，
 * 取模后环绕回 0°，与 Dart 一致）。出处：isp_csc_common.h
 * isp_csc_hsl_to_rgb_px；isp_adjust.c 的同名工具同结果。 */
static void bb_hsl_to_rgb_px(int hv, int sv, int lv, int max_value,
                             double inv, int *ri, int *gi, int *bi) {
  const double h = bb_euclid_mod(hv * inv, 1.0);
  const double s = sv * inv;
  const double l = lv * inv;
  double r, g, b;
  if (s == 0) {
    r = g = b = l;
  } else {
    const double q = l < 0.5 ? l * (1.0 + s) : l + s - l * s;
    const double p = 2.0 * l - q;
    r = bb_hue_to_rgb(p, q, h + 1.0 / 3.0);
    g = bb_hue_to_rgb(p, q, h);
    b = bb_hue_to_rgb(p, q, h - 1.0 / 3.0);
  }
  *ri = bb_clamp_to(r * max_value, max_value);
  *gi = bb_clamp_to(g * max_value, max_value);
  *bi = bb_clamp_to(b * max_value, max_value);
}''',
  'bb_rgb_to_yuv_px': '''
/* 单像素 RGB→YUV 定点公式（BT.601 全范围，Dart rgbToYuv 循环体）。
 * 出处：isp_csc_common.h isp_csc_rgb_to_yuv_px。 */
static void bb_rgb_to_yuv_px(int r, int g, int b, int half, int max_value,
                             uint16_t *out) {
  const int y = (int)(((int64_t)BB_CSC_CY_R_601 * r +
                       (int64_t)BB_CSC_CY_G_601 * g +
                       (int64_t)BB_CSC_CY_B_601 * b + 32768) >> 16);
  const int u = (int)(((int64_t)BB_CSC_CU_R_601 * r +
                       (int64_t)BB_CSC_CU_G_601 * g +
                       (int64_t)BB_CSC_CU_B_601 * b + 32768) >> 16) + half;
  const int v = (int)(((int64_t)BB_CSC_CV_R_601 * r +
                       (int64_t)BB_CSC_CV_G_601 * g +
                       (int64_t)BB_CSC_CV_B_601 * b + 32768) >> 16) + half;
  out[0] = isp_clamp_u16(y, max_value);
  out[1] = isp_clamp_u16(u, max_value);
  out[2] = isp_clamp_u16(v, max_value);
}''',
  'bb_yuv_to_rgb_px': '''
/* 单像素 YUV→RGB 定点中间值（Dart yuvToRgb 循环体，含三元钳位；乘积
 * int64 累加，>> 16 算术右移）。出处：isp_csc_common.h
 * isp_csc_yuv_to_rgb_px。 */
static void bb_yuv_to_rgb_px(int y, int u_in, int v_in, int half,
                             int max_value, int *ri, int *gi, int *bi) {
  const int u = u_in - half;
  const int v = v_in - half;
  const int r = y + (int)(((int64_t)BB_CSC_CR_V * v + 32768) >> 16);
  const int g = y + (int)(((int64_t)BB_CSC_CG_U * u +
                           (int64_t)BB_CSC_CG_V * v + 32768) >> 16);
  const int b = y + (int)(((int64_t)BB_CSC_CB_U * u + 32768) >> 16);
  *ri = isp_clamp_int(r, 0, max_value);
  *gi = isp_clamp_int(g, 0, max_value);
  *bi = isp_clamp_int(b, 0, max_value);
}''',
};

// ---------------------------------------------------------------------------
// 行核入口与小工具
// ---------------------------------------------------------------------------

/// 发射一个节点的逐像素行核。不支持的类型抛 [ArgumentError]（调用前应
/// 经 validateGroupBlackBoxExport 校验）。
/// [inputs]：wrapper 输入端口名 → 通道 C 表达式；null 表示未连接的次要
/// 输入（仅 combiner，行核发射缺省常量）。
StreamKernelResult emitStreamRowKernel(
    StreamKernelCtx s, CNodeGenCtx ctx, Map<String, List<String>?> inputs) {
  switch (ctx.node.typeId) {
    case 'black_level':
      return _kBlackLevel(s, ctx, inputs);
    case 'highlight':
      // recover（窗口语义）由 emitStreamWindowKernel 处理；clip 为纯逐像素。
      return _kHighlightClip(s, ctx, inputs);
    case 'morphology':
      // radius <= 0（c_ref 空操作早退）或 Bypass：直通；radius >= 1 的
      // 窗口形态由 emitStreamWindowKernel 处理。
      return _alias(
          _in(inputs, _isMonoPath(ctx) ? 'in_mono' : 'in'),
          _isMonoPath(ctx) ? 'out_mono' : 'out');
    case 'gaussian_blur':
      // strength <= 0 或 sigma <= 0（c_ref 空操作早退）：直通；正常形态
      // 由 emitStreamWindowKernel 处理（gaussian_blur 非 Process 类，无
      // Bypass）。
      final inPort = _activePort(ctx, const ['in', 'in_yuv', 'in_hsl', 'in_mono']);
      final fmt = ctx.inputFormats[inPort] ?? 'rgb';
      final outPort = switch (fmt) {
        'yuv' => 'out_yuv',
        'hsl' => 'out_hsl',
        'mono' => 'out_mono',
        _ => 'out_rgb',
      };
      return _alias(_in(inputs, inPort), outPort);
    case 'lsc':
      return _kLsc(s, ctx, inputs);
    case 'white_balance':
      return _kWhiteBalance(s, ctx, inputs);
    case 'ccm':
      return _kCcm(s, ctx, inputs);
    case 'gamma':
      return _kGamma(s, ctx, inputs);
    case 'csc_rgb2yuv':
      return _kCscRgb2Yuv(s, ctx, inputs);
    case 'csc_rgb2hsl':
      return _kCscOne(s, ctx, inputs, 'rgb2hsl');
    case 'csc_yuv2rgb':
      return _kCscOne(s, ctx, inputs, 'yuv2rgb');
    case 'csc_yuv2hsl':
      return _kCscOne(s, ctx, inputs, 'yuv2hsl');
    case 'csc_hsl2rgb':
      return _kCscOne(s, ctx, inputs, 'hsl2rgb');
    case 'csc_hsl2yuv':
      return _kCscOne(s, ctx, inputs, 'hsl2yuv');
    case 'hsl_debugger':
      return _kHslDebugger(s, ctx, inputs);
    case 'rgb_debugger':
      return _kRgbDebugger(s, ctx, inputs);
    case 'yuv_debugger':
      return _kYuvDebugger(s, ctx, inputs);
    case 'sat_bright_adjuster':
      return _kSatBright(s, ctx, inputs);
    case 'bright_contrast_adjuster':
      return _kBrightContrast(s, ctx, inputs);
    case 'levels_curves':
      return _kLevelsCurves(s, ctx, inputs);
    case 'color_balance':
      return _kColorBalance(s, ctx, inputs);
    case 'color_temp_adjuster':
      return _kColorTemp(s, ctx, inputs);
    case 'color_controller':
      return _kColorController(s, ctx, inputs);
    case 'multi_band_eq':
      return _kMultiBandEq(s, ctx, inputs);
    case 'fluoro_leak':
      return _kFluoroLeak(s, ctx, inputs);
    case 'pseudo_color':
      return _kPseudoColor(s, ctx, inputs);
    case 'rgb_splitter':
      return _kSplitter(s, ctx, inputs, 'rgb');
    case 'yuv_splitter':
      return _kSplitter(s, ctx, inputs, 'yuv');
    case 'hsl_splitter':
      return _kSplitter(s, ctx, inputs, 'hsl');
    case 'rgb_combiner':
      return _kCombiner(s, ctx, inputs, 'rgb');
    case 'yuv_combiner':
      return _kCombiner(s, ctx, inputs, 'yuv');
    case 'hsl_combiner':
      return _kCombiner(s, ctx, inputs, 'hsl');
    case 'multiplier':
      return _kMultiplier(s, ctx, inputs);
    case 'adder':
      return _kAdder(s, ctx, inputs);
    case 'blender':
      return _kBlender(s, ctx, inputs);
    case 'mux4':
      return _kMux4(s, ctx, inputs);
  }
  throw ArgumentError('节点类型 ${ctx.node.typeId} 暂不支持行级流水导出');
}

/// 取输入端口通道表达式（无来源属规划错误）。
List<String> _in(Map<String, List<String>?> inputs, String port) {
  final v = inputs[port];
  if (v == null) {
    throw StateError('行核输入端口 $port 无来源（规划层应保证已连接或外部输入）');
  }
  return v;
}

/// 直通别名（零语句）：输出端口直接引用输入通道表达式。
StreamKernelResult _alias(List<String> ie, String outPort) =>
    (const [], {outPort: ie});

/// highlight（mode=clip）：膝点以上软压缩，纯逐像素（recover 为窗口
/// 语义，见 _kHighlightRecover）。出处：isp_highlight.c
/// isp_highlight_apply 的 clip 分支：膝点 kneePt = clamp01(knee) ×
/// max_value，range = max_value − kneePt，range <= 0 或 v <= kneePt 时
/// 保持原值，否则 v' = kneePt + d×range/(range+d)（渐近 max_value，
/// round 半值远离零，无钳位）。LUT 模式（codegenMode=lut）：压缩表生成
/// 期烘焙（Dart highlightClipLut，域 0..lutDomainMax），max_value 一致
/// 走查表（isp_highlight_clip_lut_apply 语义），不一致回退直算。
/// highlight(clip) 整行行核可用性（与 [_kHighlightClip] 同口径）：非
/// bypass、LUT 模式。
bool highlightClipRowOk(Map<String, dynamic> params) {
  if (params['bypass'] == true) return false;
  return params['codegenMode'] == 'lut';
}

/// highlight(clip) LUT 模式整行函数源码（[id] 前缀，烘焙域 [n]）：NEON/
/// SSE2 + 标量双变体（随导出目标分叉）。mono 1 通道输入输出；域匹配
/// （max_value == n）走 SIMD gather 查 clip 表；域失配标量回退（膝点
/// 压缩直算），与融合行核逐位一致。
String _highlightClipRowFn(String id, int n, double knee, GroupCTarget target) {
  final scalarTail = '''
  const double kp_ = ${cNum(knee)} * (double)max_value;
  const double range_ = (double)max_value - kp_;
  for (; x < w; x++) {
    out[x] = (max_value == $n)
        ? ${id}_clip_lut[in[x]]
        : (uint16_t)((range_ <= 0.0 || (double)in[x] <= kp_)
            ? in[x]
            : (uint16_t)round(kp_ + ((double)in[x] - kp_) * range_ /
                                        (range_ + (double)in[x] - kp_)));
  }
}''';
  if (target.isX86) {
    return '''
/* highlight clip LUT 模式整行函数（SSE2/标量双变体，逐位一致；
 * 仅单节点独占阶段被调用，见 top .c 阶段发射）。 */
#if defined(__SSE2__) || defined(_M_X64) || (defined(_M_IX86_FP) && _M_IX86_FP >= 2)
#include <emmintrin.h>
#endif
static void ${id}_row(const uint16_t *in, uint16_t *out, int w,
                      int max_value) {
  int x = 0;
#if defined(__SSE2__) || defined(_M_X64) || (defined(_M_IX86_FP) && _M_IX86_FP >= 2)
  if (max_value == $n) {
    for (; x + 8 <= w; x += 8) {
      const __m128i pv = _mm_loadu_si128((const __m128i *)(in + (size_t)x));
      uint16_t t_[8], l_[8];
      int k;
      _mm_storeu_si128((__m128i *)t_, pv);
      for (k = 0; k < 8; k++) {
        l_[k] = ${id}_clip_lut[t_[k]];
      }
      _mm_storeu_si128((__m128i *)(out + (size_t)x),
                       _mm_loadu_si128((const __m128i *)l_));
    }
  }
#endif
$scalarTail''';
  }
  return '''
/* highlight clip LUT 模式整行函数（NEON/标量双变体，逐位一致；
 * 仅单节点独占阶段被调用，见 top .c 阶段发射）。 */
#if defined(__ARM_NEON) || defined(__ARM_NEON__)
#include <arm_neon.h>
#endif
static void ${id}_row(const uint16_t *in, uint16_t *out, int w,
                      int max_value) {
  int x = 0;
#if defined(__ARM_NEON) || defined(__ARM_NEON__)
  if (max_value == $n) {
    for (; x + 8 <= w; x += 8) {
      /* 8 像素：mono VLD1 → 标量 gather 查表 → VST1。 */
      const uint16x8_t pv = vld1q_u16(in + (size_t)x);
      uint16_t t_[8], l_[8];
      int k;
      vst1q_u16(t_, pv);
      for (k = 0; k < 8; k++) {
        l_[k] = ${id}_clip_lut[t_[k]];
      }
      vst1q_u16(out + (size_t)x, vld1q_u16(l_));
    }
  }
#endif
$scalarTail''';
}

StreamKernelResult _kHighlightClip(
    StreamKernelCtx s, CNodeGenCtx ctx, Map<String, List<String>?> inputs) {
  final mono = _isMonoPath(ctx);
  final inPort = mono ? 'in_mono' : 'in';
  final outPort = mono ? 'out_mono' : 'out';
  final ie = _in(inputs, inPort);
  if (ctx.boolParam('bypass')) return _alias(ie, outPort);
  final knee = ctx.doubleParam('knee').clamp(0.0, 1.0);
  final lutMode = ctx.strParam('codegenMode') == 'lut';
  if (lutMode) {
    final n = ctx.lutDomainMax;
    final lut = highlightClipLut(ctx.doubleParam('knee'), n);
    s.addFileDecl('${ctx.ident}_clip_lut', '''
/* highlight clip LUT 模式：膝点压缩表生成期烘焙（Dart highlightClipLut，
 * 域 0..$n）；max_value 一致走查表，不一致回退直算（同公式）。 */
static const uint16_t ${ctx.ident}_clip_lut[${n + 1}] = {
${cU16Table(lut)}
};''');
    // 整行行核（NEON/SSE2/标量双变体，随导出目标分叉）：仅 1 通道输入
    // （RAW 'in' 或 'in_mono'）登记；仅单节点独占阶段被调用。
    if (ie.length == 1) {
      s.addFileDecl('${ctx.ident}_row',
          _highlightClipRowFn(ctx.ident, n, knee, ctx.target));
    }
  }
  final kp = s.freshVar();
  final range = s.freshVar();
  final o = s.freshVar();
  final direct =
      '($range <= 0.0 || (double)${ie[0]} <= $kp) ? ${ie[0]} : (uint16_t)round($kp + ((double)${ie[0]} - $kp) * $range / ($range + (double)${ie[0]} - $kp))';
  return (
    [
      'const double $kp = ${cNum(knee)} * (double)max_value;',
      'const double $range = (double)max_value - $kp;',
      lutMode
          ? 'const uint16_t $o = (max_value == ${ctx.lutDomainMax}) ? ${ctx.ident}_clip_lut[${ie[0]}] : $direct;'
          : 'const uint16_t $o = $direct;',
    ],
    {outPort: [o]},
  );
}

/// RAW 域双形态选路（与 node_c_gen_raw.dart _isMonoPath 同口径）。
bool _isMonoPath(CNodeGenCtx ctx) {
  final f = ctx.inputFormats;
  if (f.containsKey('in')) return false;
  return f.containsKey('in_mono');
}

/// 多形态互斥输入选路：返回首个在 inputFormats 中的候选端口。
String _activePort(CNodeGenCtx ctx, List<String> candidates) {
  for (final p in candidates) {
    if (ctx.inputFormats.containsKey(p)) return p;
  }
  return candidates.first;
}

// ---------------------------------------------------------------------------
// RAW / RGB 域与链尾
// ---------------------------------------------------------------------------

/// black_level：Bayer 2x2 四相位 / mono 统一偏移扣除。
/// 出处：isp_black_level.c isp_black_level_apply（第二步逐像素循环）/
/// isp_black_level_apply_mono；v <= 0 截零、四舍五入写回（不截顶）。
/// black_level（Bayer 四相位形态）x86 专属 FP64 整行函数源码（[id] 前缀）：
/// SSE2 双像素（相位偏移随 x 奇偶交替——同行两相位由 (y&1) 选出烘焙表
/// `<id>_off` 的一对常量；v ≤ 0 截零、v > 0 取 floor(v+0.5) 四舍五入写回，
/// 与融合行核逐位一致）。行核带 y 形参（相位高半部），top 层调用点特判。
/// ARM 目标不登记（NEON 无 FP64 SIMD）。
String _blackLevelRowFn(String id, GroupCTarget target) {
  assert(target.isX86);
  final scalarTail = '''
  for (; x < w; x++) {
    const double v_ =
        (double)in[x] - ${id}_off[((y & 1) << 1) | (x & 1)];
    out[x] = (v_ <= 0.0) ? (uint16_t)0 : (uint16_t)(long)round(v_);
  }
}''';
  return '''
/* black_level 整行函数（x86 专属：FP64 SSE2 双像素快路径，与标量逐位
 * 一致；仅单节点独占阶段被调用，见 top .c 阶段发射）。 */
#if defined(_M_X64) || defined(_M_AMD64) || defined(__x86_64__) ||           \\
    defined(__SSE2__) || (defined(_M_IX86_FP) && _M_IX86_FP >= 2)
#include <emmintrin.h>
#endif
static void ${id}_row(const uint16_t *in, uint16_t *out, int w,
                      int max_value, int y) {
  int x = 0;
  (void)max_value;
#if defined(_M_X64) || defined(_M_AMD64) || defined(__x86_64__) ||           \\
    defined(__SSE2__) || (defined(_M_IX86_FP) && _M_IX86_FP >= 2)
  {
    const int ph = (y & 1) << 1;
    /* 同行两像素的相位偏移：x 偶 → ph|0、x 奇 → ph|1（Bayer 2x2 循环）。 */
    const __m128d offv = _mm_set_pd(${id}_off[ph | 1], ${id}_off[ph | 0]);
    const __m128d zero = _mm_setzero_pd();
    const __m128d half = _mm_set1_pd(0.5);
    for (; x + 2 <= w; x += 2) {
      const __m128d vv = _mm_sub_pd(
          _mm_cvtepi32_pd(
              _mm_set_epi32(0, 0, (int)in[(size_t)x + 1u], (int)in[(size_t)x])),
          offv);
      /* v ≤ 0 截零；否则 floor(v+0.5)（cvttpd 向零截断，v > 0 时与
       * round 同值）。 */
      const __m128i ri = _mm_cvttpd_epi32(
          _mm_andnot_pd(_mm_cmple_pd(vv, zero), _mm_add_pd(vv, half)));
      out[(size_t)x + 0u] = (uint16_t)_mm_cvtsi128_si32(ri);
      out[(size_t)x + 1u] = (uint16_t)_mm_cvtsi128_si32(_mm_srli_si128(ri, 4));
    }
  }
#endif
$scalarTail''';
}

StreamKernelResult _kBlackLevel(
    StreamKernelCtx s, CNodeGenCtx ctx, Map<String, List<String>?> inputs) {
  final mono = _isMonoPath(ctx);
  final inPort = mono ? 'in_mono' : 'in';
  final outPort = mono ? 'out_mono' : 'out';
  final ie = _in(inputs, inPort);
  if (ctx.boolParam('bypass')) return _alias(ie, outPort);
  final String offExpr;
  if (mono) {
    offExpr = cNum(ctx.doubleParam('r'));
  } else {
    // 生成期按烘焙 pattern 解析四相位偏移（isp_black_level_apply 第一步：
    // R/B 相位直接用 r/b；G 相位看同行另一像素（px^1）的颜色，与 R 同行
    // 为 gr、与 B 同行为 gb）。
    final pattern = switch (ctx.strParam('cfaPattern').toUpperCase()) {
      'BGGR' => BayerPattern.bggr,
      'GRBG' => BayerPattern.grbg,
      'GBRG' => BayerPattern.gbrg,
      _ => BayerPattern.rggb,
    };
    final r = ctx.doubleParam('r');
    final gr = ctx.doubleParam('gr');
    final gb = ctx.doubleParam('gb');
    final b = ctx.doubleParam('b');
    final off = List<double>.filled(4, 0.0);
    for (var py = 0; py < 2; py++) {
      for (var px = 0; px < 2; px++) {
        final phase = (py << 1) | px;
        final color = pattern.colorAt(px, py);
        off[phase] = color == 0
            ? r
            : color == 2
                ? b
                : (pattern.colorAt(px ^ 1, py) == 0 ? gr : gb);
      }
    }
    s.addFileDecl('${ctx.ident}_off', '''
/* black_level 四相位偏移（phase = (py << 1) | px，生成期按烘焙 Bayer
 * pattern 解析；出处：isp_black_level.c isp_black_level_apply 第一步）。 */
static const double ${ctx.ident}_off[4] = {
  ${off.map(cNum).join(', ')},
};''');
    // Bayer 形态 x86 专属整行行核（FP64 SSE2 双像素，行核带 y 形参——
    // 相位偏移随行奇偶交替；仅单节点独占阶段被调用，见 group_c_export_bb
    // 阶段发射特判）。
    if (ctx.target.isX86) {
      s.addFileDecl('${ctx.ident}_row', _blackLevelRowFn(ctx.ident, ctx.target));
    }
    offExpr = '${ctx.ident}_off[((${s.rowVar} & 1) << 1) | (x & 1)]';
  }
  final v = s.freshVar();
  final o = s.freshVar();
  return (
    [
      'const double $v = (double)${ie[0]} - $offExpr;',
      'const uint16_t $o = ($v <= 0.0) ? (uint16_t)0 : (uint16_t)(long)round($v);',
    ],
    {outPort: [o]},
  );
}

/// lsc：径向二次增益曲面校正（增益与相位无关，bayer/mono 同一路径）。
/// 出处：isp_lsc.c isp_lsc_apply。r_max2 <= 0（仅 1x1 帧）时 c_ref 整体
/// 早退不动数据；行核以增益 1 兜底（round(v)=v，逐位一致）。
StreamKernelResult _kLsc(
    StreamKernelCtx s, CNodeGenCtx ctx, Map<String, List<String>?> inputs) {
  final mono = _isMonoPath(ctx);
  final inPort = mono ? 'in_mono' : 'in';
  final outPort = mono ? 'out_mono' : 'out';
  final ie = _in(inputs, inPort);
  if (ctx.boolParam('bypass')) return _alias(ie, outPort);
  final strength = ctx.doubleParam('strength');
  if (strength == 0.0) return _alias(ie, outPort); // c_ref 早退
  final id = ctx.ident;
  s.useHelper('bb_clamp_to');
  s.addPreludeAll([
    'const double ${id}_cx = ${cNum(ctx.doubleParam('centerX'))} * (double)(w - 1);',
    'const double ${id}_cy = ${cNum(ctx.doubleParam('centerY'))} * (double)(h - 1);',
    'const double ${id}_ex = ISP_MAX(${id}_cx, (double)(w - 1) - ${id}_cx);',
    'const double ${id}_ey = ISP_MAX(${id}_cy, (double)(h - 1) - ${id}_cy);',
    'const double ${id}_rm2 = ${id}_ex * ${id}_ex + ${id}_ey * ${id}_ey;',
  ]);
  final dx = s.freshVar();
  final dy = s.freshVar();
  final gain = s.freshVar();
  final o = s.freshVar();
  return (
    [
      'const double $dx = (double)x - ${id}_cx;',
      'const double $dy = (double)${s.rowVar} - ${id}_cy;',
      'const double $gain = ${id}_rm2 > 0.0 ? 1.0 + ${cNum(strength)} * ($dx * $dx + $dy * $dy) / ${id}_rm2 : 1.0;',
      'const uint16_t $o = bb_clamp_to((double)${ie[0]} * $gain, max_value);',
    ],
    {outPort: [o]},
  );
}

/// white_balance（manual；auto 模式需全帧统计，校验期拒绝）：R/B 通道
/// 增益映射。出处：isp_white_balance.c isp_white_balance_apply（Dart 先
/// 建 LUT 再查表，查表与逐点直算逐位一致，c_ref 直算不建表）。
/// LUT 模式（codegenMode=lut）：生成期烘焙双通道表（Dart
/// whiteBalanceGainLut，域 0..lutDomainMax），max_value 一致走查表、
/// 不一致回退直算（行内三元，同公式）。
StreamKernelResult _kWhiteBalance(
    StreamKernelCtx s, CNodeGenCtx ctx, Map<String, List<String>?> inputs) {
  final ie = _in(inputs, 'in');
  if (ctx.boolParam('bypass')) return _alias(ie, 'out');
  var rGain = ctx.doubleParam('rGain');
  if (rGain <= 0) rGain = 1.0;
  var bGain = ctx.doubleParam('bGain');
  if (bGain <= 0) bGain = 1.0;
  if (rGain == 1.0 && bGain == 1.0) {
    return _alias(ie, 'out'); // c_ref 恒等早退（double 精确比较）
  }
  s.useHelper('bb_clamp_i64');
  final lutMode = ctx.strParam('codegenMode') == 'lut';
  if (lutMode) {
    final n = ctx.lutDomainMax;
    for (final (name, lut) in [
      ('lut_r', whiteBalanceGainLut(rGain, n)),
      ('lut_b', whiteBalanceGainLut(bGain, n)),
    ]) {
      s.addFileDecl('${ctx.ident}_$name', '''
/* white_balance LUT 模式：生成期按节点参数烘焙（Dart
 * whiteBalanceGainLut，域 0..$n）；max_value 一致走查表，不一致回退
 * 直算（同公式，数值一致）。 */
static const uint16_t ${ctx.ident}_$name[${n + 1}] = {
${cU16Table(lut)}
};''');
    }
    // 整行行核（NEON/SSE2/标量双变体，随导出目标分叉；仅单节点独占阶段
    // 被调用，见 group_c_export_bb 阶段发射特判）。
    s.addFileDecl('${ctx.ident}_row',
        _whiteBalanceLutRowFn(ctx.ident, n, rGain, bGain, ctx.target));
  }
  final lines = <String>[];
  String mapCh(String expr, String lutName, double gain) {
    final o = s.freshVar();
    lines.add(lutMode
        ? 'const uint16_t $o = (max_value == ${ctx.lutDomainMax}) ? ${ctx.ident}_$lutName[$expr] : bb_clamp_i64(llround((double)$expr * ${cNum(gain)}), max_value);'
        : 'const uint16_t $o = bb_clamp_i64(llround((double)$expr * ${cNum(gain)}), max_value);');
    return o;
  }

  // 只映射 R（0）与 B（2），G（1）保持不动（同 c_ref 循环体）。
  return (
    lines,
    {
      'out': [mapCh(ie[0], 'lut_r', rGain), ie[1], mapCh(ie[2], 'lut_b', bGain)],
    },
  );
}

/// white_balance 整行行核可用性（与 [_kWhiteBalance] 同口径）：非 bypass、
/// 非恒等（rGain/bGain 全 1）、codegenMode=lut。不可用返回 null，否则返回
/// 归一化后的 (rGain, bGain)。
(double, double)? whiteBalanceRowGains(Map<String, dynamic> params) {
  if (params['bypass'] == true) return null;
  var rGain = (params['rGain'] as num?)?.toDouble() ?? 0.0;
  if (rGain <= 0) rGain = 1.0;
  var bGain = (params['bGain'] as num?)?.toDouble() ?? 0.0;
  if (bGain <= 0) bGain = 1.0;
  if (rGain == 1.0 && bGain == 1.0) return null;
  if (params['codegenMode'] != 'lut') return null;
  return (rGain, bGain);
}

/// white_balance（LUT 模式）整行函数源码（[id] 前缀，烘焙域 [n]）：
/// NEON/SSE2 + 标量双变体（随导出目标分叉）。域匹配（max_value == n）
/// 走 SIMD gather（lut_r/lut_b 查表 + G 恒等）；域失配标量回退
/// bb_clamp_i64(llround(v×gain))，与融合行核逐位一致。
String _whiteBalanceLutRowFn(
    String id, int n, double rGain, double bGain, GroupCTarget target) {
  final scalarTail = '''
  for (; x < w; x++) {
    out[(size_t)x * 3u + 0u] = (max_value == $n)
        ? ${id}_lut_r[in[(size_t)x * 3u + 0u]]
        : bb_clamp_i64(llround((double)in[(size_t)x * 3u + 0u] * ${cNum(rGain)}), max_value);
    out[(size_t)x * 3u + 1u] = in[(size_t)x * 3u + 1u];
    out[(size_t)x * 3u + 2u] = (max_value == $n)
        ? ${id}_lut_b[in[(size_t)x * 3u + 2u]]
        : bb_clamp_i64(llround((double)in[(size_t)x * 3u + 2u] * ${cNum(bGain)}), max_value);
  }
}''';
  if (target.isX86) {
    final masks = '    const __m128i lm0 = _mm_setr_epi16(-1, 0, 0, 0, 0, 0, 0, 0);\n'
        '    const __m128i lm1 = _mm_setr_epi16(0, -1, 0, 0, 0, 0, 0, 0);\n'
        '    const __m128i lm2 = _mm_setr_epi16(0, 0, -1, 0, 0, 0, 0, 0);\n'
        '    const __m128i lm3 = _mm_setr_epi16(0, 0, 0, -1, 0, 0, 0, 0);\n'
        '    const __m128i lm4 = _mm_setr_epi16(0, 0, 0, 0, -1, 0, 0, 0);\n'
        '    const __m128i lm5 = _mm_setr_epi16(0, 0, 0, 0, 0, -1, 0, 0);\n'
        '    const __m128i lm6 = _mm_setr_epi16(0, 0, 0, 0, 0, 0, -1, 0);\n'
        '    const __m128i lm7 = _mm_setr_epi16(0, 0, 0, 0, 0, 0, 0, -1);\n';
    final deint =
        _sse2Deinterleave3('i0', 'i1', 'i2', 'rv', 'gv', 'bv').join('\n');
    final reint =
        _sse2Reinterleave3('lrv', 'gv', 'lbv', 'o0', 'o1', 'o2').join('\n');
    return '''
/* white_balance LUT 模式整行函数（SSE2/标量双变体，逐位一致；
 * 仅单节点独占阶段被调用，见 top .c 阶段发射）。 */
#if defined(__SSE2__) || defined(_M_X64) || (defined(_M_IX86_FP) && _M_IX86_FP >= 2)
#include <emmintrin.h>
#endif
static void ${id}_row(const uint16_t *in, uint16_t *out, int w,
                      int max_value) {
  int x = 0;
#if defined(__SSE2__) || defined(_M_X64) || (defined(_M_IX86_FP) && _M_IX86_FP >= 2)
  if (max_value == $n) {
$masks    for (; x + 8 <= w; x += 8) {
      const __m128i i0 =
          _mm_loadu_si128((const __m128i *)(in + (size_t)x * 3u));
      const __m128i i1 =
          _mm_loadu_si128((const __m128i *)(in + (size_t)x * 3u + 8u));
      const __m128i i2 =
          _mm_loadu_si128((const __m128i *)(in + (size_t)x * 3u + 16u));
$deint      uint16_t r_[8], b_[8], lr_[8], lb_[8];
      int k;
      _mm_storeu_si128((__m128i *)r_, rv);
      _mm_storeu_si128((__m128i *)b_, bv);
      for (k = 0; k < 8; k++) {
        lr_[k] = ${id}_lut_r[r_[k]];
        lb_[k] = ${id}_lut_b[b_[k]];
      }
      const __m128i lrv = _mm_loadu_si128((const __m128i *)lr_);
      const __m128i lbv = _mm_loadu_si128((const __m128i *)lb_);
$reint      _mm_storeu_si128((__m128i *)(out + (size_t)x * 3u), o0);
      _mm_storeu_si128((__m128i *)(out + (size_t)x * 3u + 8u), o1);
      _mm_storeu_si128((__m128i *)(out + (size_t)x * 3u + 16u), o2);
    }
  }
#endif
$scalarTail''';
  }
  return '''
/* white_balance LUT 模式整行函数（NEON/标量双变体，逐位一致；
 * 仅单节点独占阶段被调用，见 top .c 阶段发射）。 */
#if defined(__ARM_NEON) || defined(__ARM_NEON__)
#include <arm_neon.h>
#endif
static void ${id}_row(const uint16_t *in, uint16_t *out, int w,
                      int max_value) {
  int x = 0;
#if defined(__ARM_NEON) || defined(__ARM_NEON__)
  if (max_value == $n) {
    for (; x + 8 <= w; x += 8) {
      /* 8 像素：VLD3 解交织 → R/B 标量 gather 查表 → G 恒等 →
       * VST3 重交织。 */
      const uint16x8x3_t px = vld3q_u16(in + (size_t)x * 3u);
      uint16_t r_[8], b_[8], lr_[8], lb_[8];
      int k;
      vst1q_u16(r_, px.val[0]);
      vst1q_u16(b_, px.val[2]);
      for (k = 0; k < 8; k++) {
        lr_[k] = ${id}_lut_r[r_[k]];
        lb_[k] = ${id}_lut_b[b_[k]];
      }
      uint16x8x3_t opx;
      opx.val[0] = vld1q_u16(lr_);
      opx.val[1] = px.val[1];
      opx.val[2] = vld1q_u16(lb_);
      vst3q_u16(out + (size_t)x * 3u, opx);
    }
  }
#endif
$scalarTail''';
}

/// ccm 行核可用性解析：返回 (Q20 系数 m, 是否恒等)。与 [_kCcm] 同口径
///（matrix 解析 + 单位矩阵判定 + bypass 由调用方检查）。
(List<int>, bool) ccmMatrixOf(Map<String, dynamic> params) {
  final raw = params['matrix'];
  final values = [
    for (var i = 0; i < 9; i++)
      raw is List && i < raw.length
          ? (raw[i] as num).toDouble()
          : (i % 4 == 0 ? 1.0 : 0.0),
  ];
  final m = [for (final x in values) (x * 1048576).round()];
  var isIdentity = true;
  for (var i = 0; i < 9; i++) {
    if (m[i] != (i % 4 == 0 ? 1 << 20 : 0)) {
      isIdentity = false;
      break;
    }
  }
  return (m, isIdentity);
}

/// ccm（Q20 定点矩阵）整行函数源码（[id] 前缀）：NEON/SSE2 + 标量双变体
/// （随导出目标分叉），与融合行核（bb_clamp_i64 直算）逐位一致。
/// 域保证：max_value ≤ 32767 且输入在域内（≤ max_value）走 SIMD（int32
/// 系数 × int32 像素 → int64 累加，|Σ| ≤ 3×2^31×32767 < 2^48；>>20 后
/// |值| ≤ 2^28 收窄回 int32 再钳位——AArch32 无 64 位比较）；其余走标量
/// int64（与融合行核同口径）。SSE2 无 64 位算术右移，用 +2^63 偏置 →
/// 逻辑右移 → 减偏置还原（|Σ+524288| < 2^48，偏置不环绕）。
String _ccmRowFn(String id, List<int> m, GroupCTarget target) {
  final scalarTail = '''
  for (; x < w; x++) {
    const int r = in[(size_t)x * 3u + 0u];
    const int g = in[(size_t)x * 3u + 1u];
    const int b = in[(size_t)x * 3u + 2u];
    out[(size_t)x * 3u + 0u] = bb_clamp_i64((${id}_m[0] * (int64_t)r + ${id}_m[1] * (int64_t)g + ${id}_m[2] * (int64_t)b + 524288) >> 20, max_value);
    out[(size_t)x * 3u + 1u] = bb_clamp_i64((${id}_m[3] * (int64_t)r + ${id}_m[4] * (int64_t)g + ${id}_m[5] * (int64_t)b + 524288) >> 20, max_value);
    out[(size_t)x * 3u + 2u] = bb_clamp_i64((${id}_m[6] * (int64_t)r + ${id}_m[7] * (int64_t)g + ${id}_m[8] * (int64_t)b + 524288) >> 20, max_value);
  }
}''';
  if (target.isX86) {
    final masks = '    const __m128i lm0 = _mm_setr_epi16(-1, 0, 0, 0, 0, 0, 0, 0);\n'
        '    const __m128i lm1 = _mm_setr_epi16(0, -1, 0, 0, 0, 0, 0, 0);\n'
        '    const __m128i lm2 = _mm_setr_epi16(0, 0, -1, 0, 0, 0, 0, 0);\n'
        '    const __m128i lm3 = _mm_setr_epi16(0, 0, 0, -1, 0, 0, 0, 0);\n'
        '    const __m128i lm4 = _mm_setr_epi16(0, 0, 0, 0, -1, 0, 0, 0);\n'
        '    const __m128i lm5 = _mm_setr_epi16(0, 0, 0, 0, 0, -1, 0, 0);\n'
        '    const __m128i lm6 = _mm_setr_epi16(0, 0, 0, 0, 0, 0, -1, 0);\n'
        '    const __m128i lm7 = _mm_setr_epi16(0, 0, 0, 0, 0, 0, 0, -1);\n';
    final deint =
        _sse2Deinterleave3('i0', 'i1', 'i2', 'rv', 'gv', 'bv').join('\n');
    final reint =
        _sse2Reinterleave3('o0v', 'o1v', 'o2v', 'o0', 'o1', 'o2').join('\n');
    final StringBuffer body = StringBuffer();
    body.writeln('      /* 每通道：mul_epu32 int64 积（负系数取 |m| 乘再 sub 取负——'
        'mul_epu32 的 64 位积对负系数多出 r×2^32 项，非有符号积；仅低 32'
        '位相乘语义下可忽略，64 位累加必须显式取负）→ add_epi64 累加 →'
        '+524288 → 2^63 偏置还原算术 >>20 → 提取低 32 位组回 4 lane →'
        'int32 钳位 → lo/hi 打包为 8×int16。 */');
    String term(String src, String splat, int mv) => mv >= 0
        ? '_mm_mul_epu32($src, $splat)'
        : '_mm_sub_epi64(vzero64, _mm_mul_epu32($src, $splat))';
    for (var c = 0; c < 3; c++) {
      final coeffs = [m[3 * c], m[3 * c + 1], m[3 * c + 2]];
      body.writeln('      {');
      for (final side in ['l', 'h']) {
        for (final sub in ['0', '1']) {
          final rSrc = sub == '0' ? 'r$side' : '_mm_srli_epi64(r$side, 32)';
          final gSrc = sub == '0' ? 'g$side' : '_mm_srli_epi64(g$side, 32)';
          final bSrc = sub == '0' ? 'b$side' : '_mm_srli_epi64(b$side, 32)';
          body.writeln(
              '        __m128i a$c$side$sub = ${term(rSrc, 'vc${c}r', coeffs[0])};');
          body.writeln(
              '        a$c$side$sub = _mm_add_epi64(a$c$side$sub, ${term(gSrc, 'vc${c}g', coeffs[1])});');
          body.writeln(
              '        a$c$side$sub = _mm_add_epi64(a$c$side$sub, ${term(bSrc, 'vc${c}b', coeffs[2])});');
          body.writeln(
              '        a$c$side$sub = _mm_add_epi64(a$c$side$sub, vhalf64);');
          body.writeln(
              '        a$c$side$sub = _mm_sub_epi64(_mm_srli_epi64(_mm_add_epi64(a$c$side$sub, vbias64), 20), vbias64s);');
        }
        body.writeln(
            '        o$c$side = _mm_unpacklo_epi32(_mm_shuffle_epi32(a$c${side}0, _MM_SHUFFLE(2, 0, 2, 0)), _mm_shuffle_epi32(a$c${side}1, _MM_SHUFFLE(2, 0, 2, 0)));');
      }
      body.writeln('      }');
    }
    final clamps = StringBuffer();
    for (var c = 0; c < 3; c++) {
      for (final side in ['l', 'h']) {
        for (final line in _sse2Clamp032('o$c$side', 'vmax32', 'vzero32')) {
          clamps.writeln('      ${line.replaceAll('\n', '\n      ')}');
        }
      }
    }
    final packs = StringBuffer();
    for (var c = 0; c < 3; c++) {
      packs.writeln('      o${c}v = _mm_packs_epi32(o${c}l, o${c}h);');
    }
    return '''
/* ccm（Q20 定点矩阵）整行函数（SSE2/标量双变体，逐位一致；
 * 仅单节点独占阶段被调用，见 top .c 阶段发射）。 */
#if defined(__SSE2__) || defined(_M_X64) || (defined(_M_IX86_FP) && _M_IX86_FP >= 2)
#include <emmintrin.h>
#endif
static void ${id}_row(const uint16_t *in, uint16_t *out, int w,
                      int max_value) {
  int x = 0;
#if defined(__SSE2__) || defined(_M_X64) || (defined(_M_IX86_FP) && _M_IX86_FP >= 2)
  if (max_value <= 32767) {
    /* 系数按 |m| splat（负系数由 term 以 sub_epi64 取负）。 */
    const __m128i vc0r = _mm_set1_epi32(${m[0].abs()});
    const __m128i vc0g = _mm_set1_epi32(${m[1].abs()});
    const __m128i vc0b = _mm_set1_epi32(${m[2].abs()});
    const __m128i vc1r = _mm_set1_epi32(${m[3].abs()});
    const __m128i vc1g = _mm_set1_epi32(${m[4].abs()});
    const __m128i vc1b = _mm_set1_epi32(${m[5].abs()});
    const __m128i vc2r = _mm_set1_epi32(${m[6].abs()});
    const __m128i vc2g = _mm_set1_epi32(${m[7].abs()});
    const __m128i vc2b = _mm_set1_epi32(${m[8].abs()});
    const __m128i vhalf64 = _mm_set_epi32(0, 524288, 0, 524288);
    /* 2^63 偏置（int64 算术右移还原用，无 _mm_srai_epi64）。 */
    const __m128i vbias64 = _mm_set_epi32(0x80000000, 0, 0x80000000, 0);
    const __m128i vbias64s = _mm_srli_epi64(vbias64, 20);
    const __m128i vmax32 = _mm_set1_epi32(max_value);
    const __m128i vzero32 = _mm_setzero_si128();
    const __m128i vzero64 = _mm_setzero_si128();
    const __m128i vzero16 = _mm_setzero_si128();
$masks    for (; x + 8 <= w; x += 8) {
      const __m128i i0 =
          _mm_loadu_si128((const __m128i *)(in + (size_t)x * 3u));
      const __m128i i1 =
          _mm_loadu_si128((const __m128i *)(in + (size_t)x * 3u + 8u));
      const __m128i i2 =
          _mm_loadu_si128((const __m128i *)(in + (size_t)x * 3u + 16u));
$deint      const __m128i rl = _mm_unpacklo_epi16(rv, vzero16);
      const __m128i rh = _mm_unpackhi_epi16(rv, vzero16);
      const __m128i gl = _mm_unpacklo_epi16(gv, vzero16);
      const __m128i gh = _mm_unpackhi_epi16(gv, vzero16);
      const __m128i bl = _mm_unpacklo_epi16(bv, vzero16);
      const __m128i bh = _mm_unpackhi_epi16(bv, vzero16);
      __m128i o0l, o0h, o1l, o1h, o2l, o2h, o0v, o1v, o2v;
${body.toString()}$clamps${packs.toString()}      /* 重交织写回（R/G/B → 连续 3 通道）。 */
$reint      _mm_storeu_si128((__m128i *)(out + (size_t)x * 3u), o0);
      _mm_storeu_si128((__m128i *)(out + (size_t)x * 3u + 8u), o1);
      _mm_storeu_si128((__m128i *)(out + (size_t)x * 3u + 16u), o2);
    }
  }
#endif
$scalarTail''';
  }
  final neonBody = StringBuffer();
  neonBody.writeln('      /* 每通道：vmull_n/vmlal_n int64 累加 → +524288 →');
  neonBody.writeln('       * >>20（vshrq_n_s64 算术）→ vmovn 收窄 int32 → [0,max]');
  neonBody.writeln('       * 钳位（AArch32 无 64 位比较，钳位在 32 位域）。 */');
  for (var c = 0; c < 3; c++) {
    neonBody.writeln('      {');
    for (final side in ['l', 'h']) {
      for (final sub in ['0', '1']) {
        final get = sub == '0' ? 'vget_low_s32' : 'vget_high_s32';
        neonBody.writeln(
            '        int64x2_t a$side$sub = vmull_n_s32($get(r$side), c${c}r);');
        neonBody.writeln(
            '        a$side$sub = vmlal_n_s32(a$side$sub, $get(g$side), c${c}g);');
        neonBody.writeln(
            '        a$side$sub = vmlal_n_s32(a$side$sub, $get(b$side), c${c}b);');
        neonBody.writeln(
            '        a$side$sub = vshrq_n_s64(vaddq_s64(a$side$sub, vhalf64), 20);');
      }
      neonBody.writeln(
          '        o$c$side = vcombine_s32(vmovn_s64(a${side}0), vmovn_s64(a${side}1));');
      neonBody.writeln(
          '        o$c$side = vmaxq_s32(vminq_s32(o$c$side, vmax32), vzero32);');
    }
    neonBody.writeln('      }');
  }
  return '''
/* ccm（Q20 定点矩阵）整行函数（NEON/标量双变体，逐位一致；
 * 仅单节点独占阶段被调用，见 top .c 阶段发射）。 */
#if defined(__ARM_NEON) || defined(__ARM_NEON__)
#include <arm_neon.h>
#endif
static void ${id}_row(const uint16_t *in, uint16_t *out, int w,
                      int max_value) {
  int x = 0;
#if defined(__ARM_NEON) || defined(__ARM_NEON__)
  if (max_value <= 32767) {
    const int32_t c0r = ${m[0]};
    const int32_t c0g = ${m[1]};
    const int32_t c0b = ${m[2]};
    const int32_t c1r = ${m[3]};
    const int32_t c1g = ${m[4]};
    const int32_t c1b = ${m[5]};
    const int32_t c2r = ${m[6]};
    const int32_t c2g = ${m[7]};
    const int32_t c2b = ${m[8]};
    const int64x2_t vhalf64 = vdupq_n_s64(524288);
    const int32x4_t vmax32 = vdupq_n_s32(max_value);
    const int32x4_t vzero32 = vdupq_n_s32(0);
    for (; x + 8 <= w; x += 8) {
      /* 8 像素：VLD3 解交织 → int64 累加（见上）→ vmovn 窄化 → VST3。 */
      const uint16x8x3_t px = vld3q_u16(in + (size_t)x * 3u);
      const int32x4_t rl = vreinterpretq_s32_u32(vmovl_u16(vget_low_u16(px.val[0])));
      const int32x4_t rh = vreinterpretq_s32_u32(vmovl_u16(vget_high_u16(px.val[0])));
      const int32x4_t gl = vreinterpretq_s32_u32(vmovl_u16(vget_low_u16(px.val[1])));
      const int32x4_t gh = vreinterpretq_s32_u32(vmovl_u16(vget_high_u16(px.val[1])));
      const int32x4_t bl = vreinterpretq_s32_u32(vmovl_u16(vget_low_u16(px.val[2])));
      const int32x4_t bh = vreinterpretq_s32_u32(vmovl_u16(vget_high_u16(px.val[2])));
      int32x4_t o0l, o0h, o1l, o1h, o2l, o2h;
${neonBody.toString()}      uint16x8x3_t opx;
      opx.val[0] = vcombine_u16(vmovn_u32(vreinterpretq_u32_s32(o0l)),
                                vmovn_u32(vreinterpretq_u32_s32(o0h)));
      opx.val[1] = vcombine_u16(vmovn_u32(vreinterpretq_u32_s32(o1l)),
                                vmovn_u32(vreinterpretq_u32_s32(o1h)));
      opx.val[2] = vcombine_u16(vmovn_u32(vreinterpretq_u32_s32(o2l)),
                                vmovn_u32(vreinterpretq_u32_s32(o2h)));
      vst3q_u16(out + (size_t)x * 3u, opx);
    }
  }
#endif
$scalarTail''';
}

/// ccm：3x3 色彩校正矩阵（Q20 定点乘加）。出处：isp_ccm.c
/// isp_ccm_apply。定点系数 m[i] = (matrix[i] * 2^20).round() 与单位矩阵
/// 判定在生成期完成（同一表达式，逐位一致）；单位矩阵时 c_ref 早退直通。
StreamKernelResult _kCcm(
    StreamKernelCtx s, CNodeGenCtx ctx, Map<String, List<String>?> inputs) {
  final ie = _in(inputs, 'in');
  if (ctx.boolParam('bypass')) return _alias(ie, 'out');
  final (m, isIdentity) = ccmMatrixOf(ctx.node.paramValues);
  if (isIdentity) return _alias(ie, 'out'); // c_ref 定点恒等早退
  s.useHelper('bb_clamp_i64');
  s.addFileDecl('${ctx.ident}_m', '''
/* ccm Q20 定点矩阵：m[i] = (matrix[i] * 2^20).round()，生成期烘焙
 * （与 isp_ccm.c isp_ccm_apply 的运行期换算同一表达式）。 */
static const int64_t ${ctx.ident}_m[9] = {
  ${m.join(', ')},
};''');
  // 整行行核（NEON/SSE2/标量双变体，随导出目标分叉）：仅当全部系数可
  // 放入 int32（|m| ≤ 2^31-1，SIMD 系数上限）时登记；仅单节点独占阶段
  // 被调用，见 group_c_export_bb 阶段发射特判。
  if (m.every((v) => v.abs() <= 2147483647)) {
    s.addFileDecl('${ctx.ident}_row', _ccmRowFn(ctx.ident, m, ctx.target));
  }
  final id = ctx.ident;
  final lines = <String>[];
  final outs = <String>[];
  for (var row = 0; row < 3; row++) {
    final o = s.freshVar();
    lines.add('const uint16_t $o = bb_clamp_i64('
        '(${id}_m[${row * 3}] * (int64_t)${ie[0]} + '
        '${id}_m[${row * 3 + 1}] * (int64_t)${ie[1]} + '
        '${id}_m[${row * 3 + 2}] * (int64_t)${ie[2]} + 524288) >> 20, '
        'max_value);');
    outs.add(o);
  }
  return (lines, {'out': outs});
}

/// gamma 整行函数源码（[id] 前缀）：NEON/SSE2 + 标量双变体（随导出目标
/// 分叉）。16 位交织 RGB → 8 位 RGBA：输入只钳上界（与融合行核同口径）
/// 后查运行期色调映射 LUT（top 层 scratch 构建，形参传入），alpha 恒
/// 255；SIMD 解交织 → 钳位 → gather → 4 通道字节重交织，与融合行核
/// 逐位一致。
String _gammaRowFn(String id, GroupCTarget target) {
  final scalarTail = '''
  for (; x < w; x++) {
    out[(size_t)x * 4u + 0u] =
        lut[in[(size_t)x * 3u + 0u] > max_value ? max_value : in[(size_t)x * 3u + 0u]];
    out[(size_t)x * 4u + 1u] =
        lut[in[(size_t)x * 3u + 1u] > max_value ? max_value : in[(size_t)x * 3u + 1u]];
    out[(size_t)x * 4u + 2u] =
        lut[in[(size_t)x * 3u + 2u] > max_value ? max_value : in[(size_t)x * 3u + 2u]];
    out[(size_t)x * 4u + 3u] = 255;
  }
}''';
  if (target.isX86) {
    final masks = '    const __m128i lm0 = _mm_setr_epi16(-1, 0, 0, 0, 0, 0, 0, 0);\n'
        '    const __m128i lm1 = _mm_setr_epi16(0, -1, 0, 0, 0, 0, 0, 0);\n'
        '    const __m128i lm2 = _mm_setr_epi16(0, 0, -1, 0, 0, 0, 0, 0);\n'
        '    const __m128i lm3 = _mm_setr_epi16(0, 0, 0, -1, 0, 0, 0, 0);\n'
        '    const __m128i lm4 = _mm_setr_epi16(0, 0, 0, 0, -1, 0, 0, 0);\n'
        '    const __m128i lm5 = _mm_setr_epi16(0, 0, 0, 0, 0, -1, 0, 0);\n'
        '    const __m128i lm6 = _mm_setr_epi16(0, 0, 0, 0, 0, 0, -1, 0);\n'
        '    const __m128i lm7 = _mm_setr_epi16(0, 0, 0, 0, 0, 0, 0, -1);\n';
    final deint =
        _sse2Deinterleave3('i0', 'i1', 'i2', 'rv', 'gv', 'bv').join('\n');
    return '''
/* gamma 整行函数（SSE2/标量双变体，逐位一致；
 * 仅单节点独占阶段被调用，见 top .c 阶段发射）。 */
#if defined(__SSE2__) || defined(_M_X64) || (defined(_M_IX86_FP) && _M_IX86_FP >= 2)
#include <emmintrin.h>
#endif
static void ${id}_row(const uint16_t *in, uint8_t *out, int w,
                      int max_value, const uint8_t *lut) {
  int x = 0;
#if defined(__SSE2__) || defined(_M_X64) || (defined(_M_IX86_FP) && _M_IX86_FP >= 2)
  {
    /* 输入钳上界：min_epu16 经 subs/sub 模拟（SSE2 无 min_epu16）。 */
    const __m128i vmax16 = _mm_set1_epi16((short)max_value);
    const __m128i a255 = _mm_set1_epi8((char)255);
$masks    for (; x + 8 <= w; x += 8) {
      const __m128i i0 =
          _mm_loadu_si128((const __m128i *)(in + (size_t)x * 3u));
      const __m128i i1 =
          _mm_loadu_si128((const __m128i *)(in + (size_t)x * 3u + 8u));
      const __m128i i2 =
          _mm_loadu_si128((const __m128i *)(in + (size_t)x * 3u + 16u));
$deint      const __m128i rc = _mm_sub_epi16(rv, _mm_subs_epu16(rv, vmax16));
      const __m128i gc = _mm_sub_epi16(gv, _mm_subs_epu16(gv, vmax16));
      const __m128i bc = _mm_sub_epi16(bv, _mm_subs_epu16(bv, vmax16));
      uint16_t r_[8], g_[8], b_[8];
      uint8_t lr_[8], lg_[8], lb_[8];
      int k;
      _mm_storeu_si128((__m128i *)r_, rc);
      _mm_storeu_si128((__m128i *)g_, gc);
      _mm_storeu_si128((__m128i *)b_, bc);
      for (k = 0; k < 8; k++) {
        lr_[k] = lut[r_[k]];
        lg_[k] = lut[g_[k]];
        lb_[k] = lut[b_[k]];
      }
      /* 4 通道字节重交织（无 pshufb：unpacklo_epi8 两对 → unpack_epi16
       * 两半 → 2×16B 存储，恰为 8 像素 × 4 通道）。 */
      const __m128i rv8 = _mm_loadl_epi64((const __m128i *)lr_);
      const __m128i gv8 = _mm_loadl_epi64((const __m128i *)lg_);
      const __m128i bv8 = _mm_loadl_epi64((const __m128i *)lb_);
      const __m128i rg = _mm_unpacklo_epi8(rv8, gv8);
      const __m128i ba = _mm_unpacklo_epi8(bv8, a255);
      _mm_storeu_si128((__m128i *)(out + (size_t)x * 4u),
                       _mm_unpacklo_epi16(rg, ba));
      _mm_storeu_si128((__m128i *)(out + (size_t)x * 4u + 16u),
                       _mm_unpackhi_epi16(rg, ba));
    }
  }
#endif
$scalarTail''';
  }
  return '''
/* gamma 整行函数（NEON/标量双变体，逐位一致；
 * 仅单节点独占阶段被调用，见 top .c 阶段发射）。 */
#if defined(__ARM_NEON) || defined(__ARM_NEON__)
#include <arm_neon.h>
#endif
static void ${id}_row(const uint16_t *in, uint8_t *out, int w,
                      int max_value, const uint8_t *lut) {
  int x = 0;
#if defined(__ARM_NEON) || defined(__ARM_NEON__)
  {
    const uint16x8_t vmaxv = vdupq_n_u16((uint16_t)max_value);
    for (; x + 8 <= w; x += 8) {
      /* 8 像素：VLD3 解交织 → 钳上界 → 标量 gather 查表 → VST4（RGBA）。 */
      uint16x8x3_t px = vld3q_u16(in + (size_t)x * 3u);
      uint16_t r_[8], g_[8], b_[8];
      uint8_t lr_[8], lg_[8], lb_[8];
      int k;
      px.val[0] = vminq_u16(px.val[0], vmaxv);
      px.val[1] = vminq_u16(px.val[1], vmaxv);
      px.val[2] = vminq_u16(px.val[2], vmaxv);
      vst1q_u16(r_, px.val[0]);
      vst1q_u16(g_, px.val[1]);
      vst1q_u16(b_, px.val[2]);
      for (k = 0; k < 8; k++) {
        lr_[k] = lut[r_[k]];
        lg_[k] = lut[g_[k]];
        lb_[k] = lut[b_[k]];
      }
      uint8x8x4_t opx;
      opx.val[0] = vld1_u8(lr_);
      opx.val[1] = vld1_u8(lg_);
      opx.val[2] = vld1_u8(lb_);
      opx.val[3] = vdup_n_u8(255);
      vst4_u8(out + (size_t)x * 4u, opx);
    }
  }
#endif
$scalarTail''';
}

/// gamma：16 位交织 RGB → 8 位 RGBA 色调映射（链尾物化点）。
/// 出处：isp_gamma.c isp_gamma_tonemap_to_rgba。色调映射 LUT 由发射层在
/// run() 开头构建（scratch 区，复刻 _tonemapLut 循环）；行核逐像素查表，
/// 输入只钳上界（Dart 同），alpha 恒 255。Bypass 退化为默认参数
/// （gamma=2.2, brightness=0, contrast=1，与整帧版一致）。
StreamKernelResult _kGamma(
    StreamKernelCtx s, CNodeGenCtx ctx, Map<String, List<String>?> inputs) {
  final ie = _in(inputs, 'in');
  var g = ctx.doubleParam('gamma');
  if (g <= 0) g = 2.2;
  var br = ctx.doubleParam('brightness');
  var ct = ctx.doubleParam('contrast');
  if (ct <= 0) ct = 1.0;
  if (ctx.boolParam('bypass')) {
    g = 2.2;
    br = 0.0;
    ct = 1.0;
  }
  s.gammaLuts[ctx.ident] = (g, br, ct);
  // 整行行核（NEON/SSE2/标量双变体，随导出目标分叉；16 位 RGB → 8 位
  // RGBA，LUT 由 top 层 scratch 构建经形参传入）；仅单节点独占阶段被
  // 调用，见 group_c_export_bb 阶段发射特判（gamma 行核调用带 LUT 指针
  // 形参）。
  s.addFileDecl('${ctx.ident}_row', _gammaRowFn(ctx.ident, ctx.target));
  final vars = [for (var c = 0; c < 3; c++) s.freshVar()];
  return (
    [
      for (var c = 0; c < 3; c++)
        'const int ${vars[c]} = ${ie[c]} > max_value ? max_value : ${ie[c]};',
    ],
    {
      'out_rgba': [
        '${ctx.ident}_lut[${vars[0]}]',
        '${ctx.ident}_lut[${vars[1]}]',
        '${ctx.ident}_lut[${vars[2]}]',
        '255',
      ],
    },
  );
}

// ---------------------------------------------------------------------------
// ColorTrans（6 变体）
// ---------------------------------------------------------------------------

/// CSC 逐像素转换（供 csc_* 节点与 splitter 格式兜底复用）。
/// [variant]：'rgb2yuv601'（BT.601 全范围）/ 'rgb2hsl' / 'yuv2rgb' /
/// 'hsl2rgb' / 'yuv2hsl' / 'hsl2yuv'。返回 3 通道 C 表达式。
List<String> _emitCscPx(
    StreamKernelCtx s, String variant, List<String> ie, List<String> lines) {
  final a = s.freshVar();
  switch (variant) {
    case 'rgb2yuv601':
      s.useHelper('bb_rgb_to_yuv_px');
      lines.addAll([
        'uint16_t $a[3];',
        'bb_rgb_to_yuv_px(${ie[0]}, ${ie[1]}, ${ie[2]}, max_value >> 1, max_value, $a);',
      ]);
    case 'rgb2hsl':
      s.useHelper('bb_rgb_to_hsl_px');
      lines.addAll([
        'uint16_t $a[3];',
        'bb_rgb_to_hsl_px(${ie[0]}, ${ie[1]}, ${ie[2]}, max_value, 1.0 / max_value, $a);',
      ]);
    case 'yuv2rgb':
      s.useHelper('bb_yuv_to_rgb_px');
      lines.addAll([
        'int $a[3];',
        'bb_yuv_to_rgb_px(${ie[0]}, ${ie[1]}, ${ie[2]}, max_value >> 1, max_value, $a, $a + 1, $a + 2);',
      ]);
    case 'hsl2rgb':
      s.useHelper('bb_hsl_to_rgb_px');
      lines.addAll([
        'int $a[3];',
        'bb_hsl_to_rgb_px(${ie[0]}, ${ie[1]}, ${ie[2]}, max_value, 1.0 / max_value, $a, $a + 1, $a + 2);',
      ]);
    case 'yuv2hsl':
      s.useHelper('bb_yuv_to_rgb_px');
      s.useHelper('bb_rgb_to_hsl_px');
      final b = s.freshVar();
      lines.addAll([
        'int $a[3];',
        'bb_yuv_to_rgb_px(${ie[0]}, ${ie[1]}, ${ie[2]}, max_value >> 1, max_value, $a, $a + 1, $a + 2);',
        'uint16_t $b[3];',
        'bb_rgb_to_hsl_px($a[0], $a[1], $a[2], max_value, 1.0 / max_value, $b);',
      ]);
      return ['$b[0]', '$b[1]', '$b[2]'];
    case 'hsl2yuv':
      s.useHelper('bb_hsl_to_rgb_px');
      s.useHelper('bb_rgb_to_yuv_px');
      final b = s.freshVar();
      lines.addAll([
        'int $a[3];',
        'bb_hsl_to_rgb_px(${ie[0]}, ${ie[1]}, ${ie[2]}, max_value, 1.0 / max_value, $a, $a + 1, $a + 2);',
        'uint16_t $b[3];',
        'bb_rgb_to_yuv_px($a[0], $a[1], $a[2], max_value >> 1, max_value, $b);',
      ]);
      return ['$b[0]', '$b[1]', '$b[2]'];
    default:
      throw ArgumentError('未知 CSC 变体: $variant');
  }
  return ['$a[0]', '$a[1]', '$a[2]'];
}

/// csc_rgb2yuv：BT.601/709 + 全/有限范围定点转换（standard/range 烘焙）。
/// 出处：isp_csc_rgb2yuv.c isp_csc_rgb_to_yuv 主循环（BT.601 全范围快
/// 路径与 isp_csc_common.h isp_csc_rgb_to_yuv_px 逐位等价）。
StreamKernelResult _kCscRgb2Yuv(
    StreamKernelCtx s, CNodeGenCtx ctx, Map<String, List<String>?> inputs) {
  final ie = _in(inputs, 'in');
  if (ctx.boolParam('bypass')) return _alias(ie, 'out');
  // 系数默认 BT.601；仅 standard == 'bt709' 切换（cuB/cvR 沿用 601 的
  // 32768，与 Dart 一致）。
  final bt709 = ctx.strParam('standard') == 'bt709';
  final limited = ctx.strParam('range') == 'limited';
  final cyR = bt709 ? 13933 : 19595;
  final cyG = bt709 ? 46871 : 38470;
  final cyB = bt709 ? 4732 : 7471;
  final cuR = bt709 ? -7509 : -11058;
  final cuG = bt709 ? -25260 : -21710;
  final cuB = 32768;
  final cvR = 32768;
  final cvG = bt709 ? -29759 : -27439;
  final cvB = bt709 ? -3009 : -5329;
  final id = ctx.ident;
  final y = s.freshVar();
  final u = s.freshVar();
  final v = s.freshVar();
  final lines = <String>[
    'int $y = (int)(((int64_t)$cyR * ${ie[0]} + (int64_t)$cyG * ${ie[1]} + (int64_t)$cyB * ${ie[2]} + 32768) >> 16);',
    'int $u = (int)(((int64_t)$cuR * ${ie[0]} + (int64_t)$cuG * ${ie[1]} + (int64_t)$cuB * ${ie[2]} + 32768) >> 16) + (max_value >> 1);',
    'int $v = (int)(((int64_t)$cvR * ${ie[0]} + (int64_t)$cvG * ${ie[1]} + (int64_t)$cvB * ${ie[2]} + 32768) >> 16) + (max_value >> 1);',
  ];
  if (limited) {
    // 有限范围压缩：Y：offY + (y*219+127)/255；U/V 去零点后 224/255
    // 压缩（±127 偏置、截断除法）。出处同函数 limited 分支。
    s.addPrelude('const int ${id}_off_y = (max_value * 16 + 127) / 255;');
    lines.addAll([
      '$y = ${id}_off_y + ($y * 219 + 127) / 255;',
      '{ int d0_ = $u - (max_value >> 1); $u = (max_value >> 1) + (d0_ * 224 + (d0_ >= 0 ? 127 : -127)) / 255; }',
      '{ int d1_ = $v - (max_value >> 1); $v = (max_value >> 1) + (d1_ * 224 + (d1_ >= 0 ? 127 : -127)) / 255; }',
    ]);
  }
  final outs = <String>[];
  for (final e in [y, u, v]) {
    final o = s.freshVar();
    lines.add('const uint16_t $o = isp_clamp_u16($e, max_value);');
    outs.add(o);
  }
  // BT.601 全范围：登记整行行核（NEON/SSE2/标量双变体，随导出目标分叉；
  // 仅单节点独占阶段被调用，见 group_c_export_bb 阶段发射特判）。
  if (!bt709 && !limited) {
    s.addFileDecl('${id}_row', _cscRgb2YuvRowFn(id, ctx.target));
  }
  return (lines, {'out': outs});
}

// ---------------------------------------------------------------------------
// 整行 SIMD 行核共享发射工具（SSE2：解/重交织 + 32 位乘 + 钳位）
// ---------------------------------------------------------------------------

/// SSE2 三通道解交织语句（8 像素 3×16 位连续加载 → 三个 16 位通道向量）。
/// 输入 [i0]/[i1]/[i2] 为 3 个 `__m128i`（in+x*3 处 48 字节的连续 3 次
/// loadu）；输出语句声明 [o0]/[o1]/[o2]（通道 0/1/2 各 8 lane，与
/// 像素 0..7 一一对应）。复用固定掩码 `lm0..lm7`（调用方在循环外声明）。
List<String> _sse2Deinterleave3(
    String i0, String i1, String i2, String o0, String o1, String o2) {
  return [
    'const __m128i $o0 = _mm_or_si128(',
    '    _mm_or_si128(',
    '        _mm_or_si128(_mm_and_si128($i0, lm0),',
    '                     _mm_and_si128(_mm_srli_si128($i0, 4), lm1)),',
    '        _mm_or_si128(_mm_and_si128(_mm_srli_si128($i0, 8), lm2),',
    '                     _mm_and_si128(_mm_slli_si128($i1, 4), lm3))),',
    '    _mm_or_si128(',
    '        _mm_or_si128(_mm_and_si128($i1, lm4),',
    '                     _mm_and_si128(_mm_srli_si128($i1, 4), lm5)),',
    '        _mm_or_si128(_mm_and_si128(_mm_slli_si128($i2, 8), lm6),',
    '                     _mm_and_si128(_mm_slli_si128($i2, 4), lm7))));',
    'const __m128i $o1 = _mm_or_si128(',
    '    _mm_or_si128(',
    '        _mm_or_si128(_mm_and_si128(_mm_srli_si128($i0, 2), lm0),',
    '                     _mm_and_si128(_mm_srli_si128($i0, 6), lm1)),',
    '        _mm_or_si128(_mm_and_si128(_mm_srli_si128($i0, 10), lm2),',
    '                     _mm_and_si128(_mm_slli_si128($i1, 2), lm3))),',
    '    _mm_or_si128(',
    '        _mm_or_si128(_mm_and_si128(_mm_srli_si128($i1, 2), lm4),',
    '                     _mm_and_si128(_mm_slli_si128($i2, 10), lm5)),',
    '        _mm_or_si128(_mm_and_si128(_mm_slli_si128($i2, 6), lm6),',
    '                     _mm_and_si128(_mm_slli_si128($i2, 2), lm7))));',
    'const __m128i $o2 = _mm_or_si128(',
    '    _mm_or_si128(',
    '        _mm_or_si128(_mm_and_si128(_mm_srli_si128($i0, 4), lm0),',
    '                     _mm_and_si128(_mm_srli_si128($i0, 8), lm1)),',
    '        _mm_or_si128(_mm_and_si128(_mm_slli_si128($i1, 4), lm2),',
    '                     _mm_and_si128($i1, lm3))),',
    '    _mm_or_si128(',
    '        _mm_or_si128(_mm_and_si128(_mm_srli_si128($i1, 4), lm4),',
    '                     _mm_and_si128(_mm_slli_si128($i2, 8), lm5)),',
    '        _mm_or_si128(_mm_and_si128(_mm_slli_si128($i2, 4), lm6),',
    '                     _mm_and_si128($i2, lm7))));',
  ];
}

/// SSE2 三通道重交织语句（三个 16 位通道向量 → 48 字节连续写出的 3 个
/// `__m128i`）。输出语句声明 [o0]/[o1]/[o2]；复用固定掩码 `lm0..lm7`。
List<String> _sse2Reinterleave3(
    String i0, String i1, String i2, String o0, String o1, String o2) {
  return [
    'const __m128i $o0 = _mm_or_si128(',
    '    _mm_or_si128(',
    '        _mm_or_si128(_mm_and_si128($i0, lm0),',
    '                     _mm_and_si128(_mm_slli_si128($i1, 2), lm1)),',
    '        _mm_or_si128(_mm_and_si128(_mm_slli_si128($i2, 4), lm2),',
    '                     _mm_and_si128(_mm_slli_si128($i0, 4), lm3))),',
    '    _mm_or_si128(',
    '        _mm_or_si128(_mm_and_si128(_mm_slli_si128($i1, 6), lm4),',
    '                     _mm_and_si128(_mm_slli_si128($i2, 8), lm5)),',
    '        _mm_or_si128(_mm_and_si128(_mm_slli_si128($i0, 8), lm6),',
    '                     _mm_and_si128(_mm_slli_si128($i1, 10), lm7))));',
    'const __m128i $o1 = _mm_or_si128(',
    '    _mm_or_si128(',
    '        _mm_or_si128(_mm_and_si128(_mm_srli_si128($i2, 4), lm0),',
    '                     _mm_and_si128(_mm_srli_si128($i0, 4), lm1)),',
    '        _mm_or_si128(_mm_and_si128(_mm_srli_si128($i1, 2), lm2),',
    '                     _mm_and_si128($i2, lm3))),',
    '    _mm_or_si128(',
    '        _mm_or_si128(_mm_and_si128($i0, lm4),',
    '                     _mm_and_si128(_mm_slli_si128($i1, 2), lm5)),',
    '        _mm_or_si128(_mm_and_si128(_mm_slli_si128($i2, 4), lm6),',
    '                     _mm_and_si128(_mm_slli_si128($i0, 4), lm7))));',
    'const __m128i $o2 = _mm_or_si128(',
    '    _mm_or_si128(',
    '        _mm_or_si128(_mm_and_si128(_mm_srli_si128($i1, 10), lm0),',
    '                     _mm_and_si128(_mm_srli_si128($i2, 8), lm1)),',
    '        _mm_or_si128(_mm_and_si128(_mm_srli_si128($i0, 8), lm2),',
    '                     _mm_and_si128(_mm_srli_si128($i1, 6), lm3))),',
    '    _mm_or_si128(',
    '        _mm_or_si128(_mm_and_si128(_mm_srli_si128($i2, 4), lm4),',
    '                     _mm_and_si128(_mm_srli_si128($i0, 4), lm5)),',
    '        _mm_or_si128(_mm_and_si128(_mm_srli_si128($i1, 2), lm6),',
    '                     _mm_and_si128($i2, lm7))));',
  ];
}

/// SSE2 有符号 32 位低乘（无 `_mm_mullo_epi32`）：`mul_epu32` 偶/奇 lane
/// 双趟取积低 32 位重组，与 NEON `vmulq_s32` 低 32 位同、与标量 int32
/// 乘截断逐位一致。返回 C 表达式（输入 [a]/[b] 为 `__m128i` int32）。
String _sse2Mullo32(String a, String b) {
  return '_mm_unpacklo_epi32(\n'
      '        _mm_shuffle_epi32(_mm_mul_epu32(($a), ($b)),\n'
      '                          _MM_SHUFFLE(2, 0, 2, 0)),\n'
      '        _mm_shuffle_epi32(\n'
      '            _mm_mul_epu32(_mm_srli_epi64(($a), 32),\n'
      '                          _mm_srli_epi64(($b), 32)),\n'
      '            _MM_SHUFFLE(2, 0, 2, 0)))';
}

/// SSE2 int32 钳位 [0, max] 语句（无 `_mm_max_epi32`：比较 + 掩码选择）。
/// 返回修改 [v] 的两行语句。
List<String> _sse2Clamp032(String v, String vmax32, String vzero32) {
  return [
    '{ const __m128i gt_ = _mm_cmpgt_epi32($v, $vmax32);\n'
        '  $v = _mm_or_si128(_mm_and_si128(gt_, $vmax32),\n'
        '                    _mm_andnot_si128(gt_, $v)); }',
    '$v = _mm_andnot_si128(_mm_cmpgt_epi32($vzero32, $v), $v);',
  ];
}

/// csc_rgb2yuv（BT.601 全范围）整行函数源码（[id] 前缀）：NEON/SSE2 +
/// 标量双变体（随导出目标分叉），与融合行核逐位一致。
/// 域保证：输入在域内（≤ max_value）且 max_value ≤ 32767 时走 SIMD
/// （int16 通道 + int32 累加精确，|Σ系数|×max_value = 65536×32767 <
/// INT32_MAX）；其余（16 位域）走标量 int64（与融合行核同口径）。
String _cscRgb2YuvRowFn(String id, GroupCTarget target) {
  final scalarTail = '''
  for (; x < w; x++) {
    const int r = in[(size_t)x * 3u + 0u];
    const int g = in[(size_t)x * 3u + 1u];
    const int b = in[(size_t)x * 3u + 2u];
    const int y = (int)(((int64_t)19595 * r + (int64_t)38470 * g +
                         (int64_t)7471 * b + 32768) >> 16);
    const int u = (int)(((int64_t)-11058 * r + (int64_t)-21710 * g +
                         (int64_t)32768 * b + 32768) >> 16) +
                  (max_value >> 1);
    const int v = (int)(((int64_t)32768 * r + (int64_t)-27439 * g +
                         (int64_t)-5329 * b + 32768) >> 16) +
                  (max_value >> 1);
    out[(size_t)x * 3u + 0u] = isp_clamp_u16(y, max_value);
    out[(size_t)x * 3u + 1u] = isp_clamp_u16(u, max_value);
    out[(size_t)x * 3u + 2u] = isp_clamp_u16(v, max_value);
  }
}''';
  if (target.isX86) {
    final masks = '    const __m128i lm0 = _mm_setr_epi16(-1, 0, 0, 0, 0, 0, 0, 0);\n'
        '    const __m128i lm1 = _mm_setr_epi16(0, -1, 0, 0, 0, 0, 0, 0);\n'
        '    const __m128i lm2 = _mm_setr_epi16(0, 0, -1, 0, 0, 0, 0, 0);\n'
        '    const __m128i lm3 = _mm_setr_epi16(0, 0, 0, -1, 0, 0, 0, 0);\n'
        '    const __m128i lm4 = _mm_setr_epi16(0, 0, 0, 0, -1, 0, 0, 0);\n'
        '    const __m128i lm5 = _mm_setr_epi16(0, 0, 0, 0, 0, -1, 0, 0);\n'
        '    const __m128i lm6 = _mm_setr_epi16(0, 0, 0, 0, 0, 0, -1, 0);\n'
        '    const __m128i lm7 = _mm_setr_epi16(0, 0, 0, 0, 0, 0, 0, -1);\n';
    // 三通道各一次 mullo + 累加 + 舍入移位 + 钳位（lo/hi 各 4 lane）。
    final StringBuffer body = StringBuffer();
    for (final (label, half) in [
      ('Y', false),
      ('U', true),
      ('V', true),
    ]) {
      body.writeln('      /* $label：mullo×系数三通道累加 + 32768 → >>16'
          '${half ? ' → +half' : ''} → [0,max] 钳位。 */');
      body.writeln('      __m128i ${label.toLowerCase()}l, ${label.toLowerCase()}h;');
      body.writeln('      {');
      body.writeln('        const __m128i rl_ = _mm_unpacklo_epi16(rv, vzero16);');
      body.writeln('        const __m128i rh_ = _mm_unpackhi_epi16(rv, vzero16);');
      body.writeln('        const __m128i gl_ = _mm_unpacklo_epi16(gv, vzero16);');
      body.writeln('        const __m128i gh_ = _mm_unpackhi_epi16(gv, vzero16);');
      body.writeln('        const __m128i bl_ = _mm_unpacklo_epi16(bv, vzero16);');
      body.writeln('        const __m128i bh_ = _mm_unpackhi_epi16(bv, vzero16);');
      body.writeln(
          '        ${label.toLowerCase()}l = ${_sse2Mullo32('rl_', 'vc${label}r')};');
      body.writeln(
          '        ${label.toLowerCase()}l = _mm_add_epi32(${label.toLowerCase()}l, ${_sse2Mullo32('gl_', 'vc${label}g')});');
      body.writeln(
          '        ${label.toLowerCase()}l = _mm_add_epi32(${label.toLowerCase()}l, ${_sse2Mullo32('bl_', 'vc${label}b')});');
      body.writeln(
          '        ${label.toLowerCase()}h = ${_sse2Mullo32('rh_', 'vc${label}r')};');
      body.writeln(
          '        ${label.toLowerCase()}h = _mm_add_epi32(${label.toLowerCase()}h, ${_sse2Mullo32('gh_', 'vc${label}g')});');
      body.writeln(
          '        ${label.toLowerCase()}h = _mm_add_epi32(${label.toLowerCase()}h, ${_sse2Mullo32('bh_', 'vc${label}b')});');
      body.writeln(
          '        ${label.toLowerCase()}l = _mm_srai_epi32(_mm_add_epi32(${label.toLowerCase()}l, vhalf32), 16);');
      body.writeln(
          '        ${label.toLowerCase()}h = _mm_srai_epi32(_mm_add_epi32(${label.toLowerCase()}h, vhalf32), 16);');
      if (half) {
        body.writeln(
            '        ${label.toLowerCase()}l = _mm_add_epi32(${label.toLowerCase()}l, vh16v);');
        body.writeln(
            '        ${label.toLowerCase()}h = _mm_add_epi32(${label.toLowerCase()}h, vh16v);');
      }
      for (final l in ['l', 'h']) {
        for (final line in _sse2Clamp032('${label.toLowerCase()}$l', 'vmax32', 'vzero32')) {
          body.writeln('        ${line.replaceAll('\n', '\n        ')}');
        }
      }
      // lo/hi 两个 int32 半区打包为 8×int16 全通道（值 [0, max] ≤ 32767，
      // packs 有符号饱和不触发）。
      body.writeln(
          '        ${label.toLowerCase()}l = _mm_packs_epi32(${label.toLowerCase()}l, ${label.toLowerCase()}h);');
      body.writeln('      }');
    }
    final deint =
        _sse2Deinterleave3('i0', 'i1', 'i2', 'rv', 'gv', 'bv').join('\n');
    final reint =
        _sse2Reinterleave3('yl', 'ul', 'vl', 'o0', 'o1', 'o2').join('\n');
    return '''
/* csc_rgb2yuv 整行函数（BT.601 全范围；SSE2/标量双变体，逐位一致；
 * 仅单节点独占阶段被调用，见 top .c 阶段发射）。 */
#if defined(__SSE2__) || defined(_M_X64) || (defined(_M_IX86_FP) && _M_IX86_FP >= 2)
#include <emmintrin.h>
#endif
static void ${id}_row(const uint16_t *in, uint16_t *out, int w,
                      int max_value) {
  int x = 0;
#if defined(__SSE2__) || defined(_M_X64) || (defined(_M_IX86_FP) && _M_IX86_FP >= 2)
  if (max_value <= 32767) {
    const __m128i vcYr = _mm_set1_epi32(19595);
    const __m128i vcYg = _mm_set1_epi32(38470);
    const __m128i vcYb = _mm_set1_epi32(7471);
    const __m128i vcUr = _mm_set1_epi32(-11058);
    const __m128i vcUg = _mm_set1_epi32(-21710);
    const __m128i vcUb = _mm_set1_epi32(32768);
    const __m128i vcVr = _mm_set1_epi32(32768);
    const __m128i vcVg = _mm_set1_epi32(-27439);
    const __m128i vcVb = _mm_set1_epi32(-5329);
    const __m128i vhalf32 = _mm_set1_epi32(32768);
    const __m128i vh16v = _mm_set1_epi32(max_value >> 1);
    const __m128i vmax32 = _mm_set1_epi32(max_value);
    const __m128i vzero32 = _mm_setzero_si128();
    const __m128i vzero16 = _mm_setzero_si128();
$masks    for (; x + 8 <= w; x += 8) {
      const __m128i i0 =
          _mm_loadu_si128((const __m128i *)(in + (size_t)x * 3u));
      const __m128i i1 =
          _mm_loadu_si128((const __m128i *)(in + (size_t)x * 3u + 8u));
      const __m128i i2 =
          _mm_loadu_si128((const __m128i *)(in + (size_t)x * 3u + 16u));
$deint${body.toString()}      /* 重交织写回（Y/U/V → 连续 3 通道，与解交织互逆）。 */
$reint      _mm_storeu_si128((__m128i *)(out + (size_t)x * 3u), o0);
      _mm_storeu_si128((__m128i *)(out + (size_t)x * 3u + 8u), o1);
      _mm_storeu_si128((__m128i *)(out + (size_t)x * 3u + 16u), o2);
    }
  }
#endif
$scalarTail''';
  }
  return '''
/* csc_rgb2yuv 整行函数（BT.601 全范围；NEON/标量双变体，逐位一致；
 * 仅单节点独占阶段被调用，见 top .c 阶段发射）。 */
#if defined(__ARM_NEON) || defined(__ARM_NEON__)
#include <arm_neon.h>
#endif
static void ${id}_row(const uint16_t *in, uint16_t *out, int w,
                      int max_value) {
  int x = 0;
#if defined(__ARM_NEON) || defined(__ARM_NEON__)
  if (max_value <= 32767) {
    /* 系数 32768（cuB/cvR）超 int16，统一走 int32 系数 + vmulq/vmlaq：
     * 单个乘积 |c|×r ≤ 32768×32767 < INT32_MAX，三通道累加 |Σ| ≤
     * 65536×32767 < INT32_MAX，与标量 int64 逐位一致。 */
    const int32x4_t vcYr = vdupq_n_s32(19595);
    const int32x4_t vcYg = vdupq_n_s32(38470);
    const int32x4_t vcYb = vdupq_n_s32(7471);
    const int32x4_t vcUr = vdupq_n_s32(-11058);
    const int32x4_t vcUg = vdupq_n_s32(-21710);
    const int32x4_t vcUb = vdupq_n_s32(32768);
    const int32x4_t vcVr = vdupq_n_s32(32768);
    const int32x4_t vcVg = vdupq_n_s32(-27439);
    const int32x4_t vcVb = vdupq_n_s32(-5329);
    const int32x4_t vhalf32 = vdupq_n_s32(32768);
    const int32x4_t vh16 = vdupq_n_s32(max_value >> 1);
    const int32x4_t vmax32 = vdupq_n_s32(max_value);
    const int32x4_t vzero32 = vdupq_n_s32(0);
    for (; x + 8 <= w; x += 8) {
      /* 8 像素：VLD3 解交织 → uint16 零扩展 int32 → vmulq/vmlaq 有符号
       * 累加 → +32768 舍入 → >>16 →（U/V）+half → [0,max] 钳位 →
       * vmovn 窄化 → VST3 重交织。 */
      const uint16x8x3_t px = vld3q_u16(in + (size_t)x * 3u);
      const int32x4_t rl = vreinterpretq_s32_u32(vmovl_u16(vget_low_u16(px.val[0])));
      const int32x4_t rh = vreinterpretq_s32_u32(vmovl_u16(vget_high_u16(px.val[0])));
      const int32x4_t gl = vreinterpretq_s32_u32(vmovl_u16(vget_low_u16(px.val[1])));
      const int32x4_t gh = vreinterpretq_s32_u32(vmovl_u16(vget_high_u16(px.val[1])));
      const int32x4_t bl = vreinterpretq_s32_u32(vmovl_u16(vget_low_u16(px.val[2])));
      const int32x4_t bh = vreinterpretq_s32_u32(vmovl_u16(vget_high_u16(px.val[2])));
      int32x4_t yl = vmulq_s32(rl, vcYr);
      yl = vmlaq_s32(yl, gl, vcYg);
      yl = vmlaq_s32(yl, bl, vcYb);
      yl = vshrq_n_s32(vaddq_s32(yl, vhalf32), 16);
      yl = vmaxq_s32(vminq_s32(yl, vmax32), vzero32);
      int32x4_t yh = vmulq_s32(rh, vcYr);
      yh = vmlaq_s32(yh, gh, vcYg);
      yh = vmlaq_s32(yh, bh, vcYb);
      yh = vshrq_n_s32(vaddq_s32(yh, vhalf32), 16);
      yh = vmaxq_s32(vminq_s32(yh, vmax32), vzero32);
      int32x4_t ul = vmulq_s32(rl, vcUr);
      ul = vmlaq_s32(ul, gl, vcUg);
      ul = vmlaq_s32(ul, bl, vcUb);
      ul = vaddq_s32(vshrq_n_s32(vaddq_s32(ul, vhalf32), 16), vh16);
      ul = vmaxq_s32(vminq_s32(ul, vmax32), vzero32);
      int32x4_t uh = vmulq_s32(rh, vcUr);
      uh = vmlaq_s32(uh, gh, vcUg);
      uh = vmlaq_s32(uh, bh, vcUb);
      uh = vaddq_s32(vshrq_n_s32(vaddq_s32(uh, vhalf32), 16), vh16);
      uh = vmaxq_s32(vminq_s32(uh, vmax32), vzero32);
      int32x4_t vl = vmulq_s32(rl, vcVr);
      vl = vmlaq_s32(vl, gl, vcVg);
      vl = vmlaq_s32(vl, bl, vcVb);
      vl = vaddq_s32(vshrq_n_s32(vaddq_s32(vl, vhalf32), 16), vh16);
      vl = vmaxq_s32(vminq_s32(vl, vmax32), vzero32);
      int32x4_t vh = vmulq_s32(rh, vcVr);
      vh = vmlaq_s32(vh, gh, vcVg);
      vh = vmlaq_s32(vh, bh, vcVb);
      vh = vaddq_s32(vshrq_n_s32(vaddq_s32(vh, vhalf32), 16), vh16);
      vh = vmaxq_s32(vminq_s32(vh, vmax32), vzero32);
      uint16x8x3_t opx;
      opx.val[0] = vcombine_u16(vmovn_u32(vreinterpretq_u32_s32(yl)),
                                vmovn_u32(vreinterpretq_u32_s32(yh)));
      opx.val[1] = vcombine_u16(vmovn_u32(vreinterpretq_u32_s32(ul)),
                                vmovn_u32(vreinterpretq_u32_s32(uh)));
      opx.val[2] = vcombine_u16(vmovn_u32(vreinterpretq_u32_s32(vl)),
                                vmovn_u32(vreinterpretq_u32_s32(vh)));
      vst3q_u16(out + (size_t)x * 3u, opx);
    }
  }
#endif
$scalarTail''';
}

/// csc_yuv2rgb 整行函数源码（[id] 前缀）：NEON/SSE2 + 标量双变体（随导出
/// 目标分叉），与融合行核（bb_yuv_to_rgb_px）逐位一致。
/// 域保证同 [_cscRgb2YuvRowFn]：max_value ≤ 32767 走 SIMD（u'/v' =
/// 通道值 - half ∈ [-16384, 16384]，单乘积 ≤ 116130×16384 < INT32_MAX）；
/// 注意标量的结合序：各通道先 (Σ coeff×src + 32768)>>16 **再**加 y。
String _cscYuv2RgbRowFn(String id, GroupCTarget target) {
  final scalarTail = '''
  for (; x < w; x++) {
    /* 标量路径：与融合行核同一 helper（bb_yuv_to_rgb_px），逐位一致。 */
    int rgb_[3];
    bb_yuv_to_rgb_px(in[(size_t)x * 3u + 0u], in[(size_t)x * 3u + 1u],
                     in[(size_t)x * 3u + 2u], max_value >> 1, max_value,
                     rgb_, rgb_ + 1, rgb_ + 2);
    out[(size_t)x * 3u + 0u] = (uint16_t)rgb_[0];
    out[(size_t)x * 3u + 1u] = (uint16_t)rgb_[1];
    out[(size_t)x * 3u + 2u] = (uint16_t)rgb_[2];
  }
}''';
  if (target.isX86) {
    final masks = '    const __m128i lm0 = _mm_setr_epi16(-1, 0, 0, 0, 0, 0, 0, 0);\n'
        '    const __m128i lm1 = _mm_setr_epi16(0, -1, 0, 0, 0, 0, 0, 0);\n'
        '    const __m128i lm2 = _mm_setr_epi16(0, 0, -1, 0, 0, 0, 0, 0);\n'
        '    const __m128i lm3 = _mm_setr_epi16(0, 0, 0, -1, 0, 0, 0, 0);\n'
        '    const __m128i lm4 = _mm_setr_epi16(0, 0, 0, 0, -1, 0, 0, 0);\n'
        '    const __m128i lm5 = _mm_setr_epi16(0, 0, 0, 0, 0, -1, 0, 0);\n'
        '    const __m128i lm6 = _mm_setr_epi16(0, 0, 0, 0, 0, 0, -1, 0);\n'
        '    const __m128i lm7 = _mm_setr_epi16(0, 0, 0, 0, 0, 0, 0, -1);\n';
    final deint =
        _sse2Deinterleave3('i0', 'i1', 'i2', 'yv', 'uv', 'vv').join('\n');
    final reint =
        _sse2Reinterleave3('rl', 'gl', 'bl', 'o0', 'o1', 'o2').join('\n');
    return '''
/* csc_yuv2rgb 整行函数（SSE2/标量双变体，逐位一致；
 * 仅单节点独占阶段被调用，见 top .c 阶段发射）。 */
#if defined(__SSE2__) || defined(_M_X64) || (defined(_M_IX86_FP) && _M_IX86_FP >= 2)
#include <emmintrin.h>
#endif
static void ${id}_row(const uint16_t *in, uint16_t *out, int w,
                      int max_value) {
  int x = 0;
#if defined(__SSE2__) || defined(_M_X64) || (defined(_M_IX86_FP) && _M_IX86_FP >= 2)
  if (max_value <= 32767) {
    const __m128i vcRv = _mm_set1_epi32(91881);
    const __m128i vcGu = _mm_set1_epi32(-22553);
    const __m128i vcGv = _mm_set1_epi32(-46801);
    const __m128i vcBu = _mm_set1_epi32(116130);
    const __m128i vhalf32 = _mm_set1_epi32(32768);
    const __m128i vh16v = _mm_set1_epi32(max_value >> 1);
    const __m128i vmax32 = _mm_set1_epi32(max_value);
    const __m128i vzero32 = _mm_setzero_si128();
    const __m128i vzero16 = _mm_setzero_si128();
$masks    for (; x + 8 <= w; x += 8) {
      const __m128i i0 =
          _mm_loadu_si128((const __m128i *)(in + (size_t)x * 3u));
      const __m128i i1 =
          _mm_loadu_si128((const __m128i *)(in + (size_t)x * 3u + 8u));
      const __m128i i2 =
          _mm_loadu_si128((const __m128i *)(in + (size_t)x * 3u + 16u));
$deint      /* y/u/v → int32；u'/v' 减半程。 */
      const __m128i yl_ = _mm_unpacklo_epi16(yv, vzero16);
      const __m128i yh_ = _mm_unpackhi_epi16(yv, vzero16);
      const __m128i ul_ = _mm_sub_epi32(_mm_unpacklo_epi16(uv, vzero16), vh16v);
      const __m128i uh_ = _mm_sub_epi32(_mm_unpackhi_epi16(uv, vzero16), vh16v);
      const __m128i vl_ = _mm_sub_epi32(_mm_unpacklo_epi16(vv, vzero16), vh16v);
      const __m128i vh_ = _mm_sub_epi32(_mm_unpackhi_epi16(vv, vzero16), vh16v);
      /* 各通道：(Σ coeff×src + 32768)>>16 再加 y（结合序同标量），
       * [0,max] 钳位后打包为 8×int16。 */
      __m128i rl, rh, gl, gh, bl, bh;
      rl = _mm_srai_epi32(
          _mm_add_epi32(${_sse2Mullo32('vl_', 'vcRv')}, vhalf32), 16);
      rl = _mm_add_epi32(yl_, rl);
      rh = _mm_srai_epi32(
          _mm_add_epi32(${_sse2Mullo32('vh_', 'vcRv')}, vhalf32), 16);
      rh = _mm_add_epi32(yh_, rh);
      gl = _mm_add_epi32(${_sse2Mullo32('ul_', 'vcGu')},
                         ${_sse2Mullo32('vl_', 'vcGv')});
      gl = _mm_srai_epi32(_mm_add_epi32(gl, vhalf32), 16);
      gl = _mm_add_epi32(yl_, gl);
      gh = _mm_add_epi32(${_sse2Mullo32('uh_', 'vcGu')},
                         ${_sse2Mullo32('vh_', 'vcGv')});
      gh = _mm_srai_epi32(_mm_add_epi32(gh, vhalf32), 16);
      gh = _mm_add_epi32(yh_, gh);
      bl = _mm_srai_epi32(
          _mm_add_epi32(${_sse2Mullo32('ul_', 'vcBu')}, vhalf32), 16);
      bl = _mm_add_epi32(yl_, bl);
      bh = _mm_srai_epi32(
          _mm_add_epi32(${_sse2Mullo32('uh_', 'vcBu')}, vhalf32), 16);
      bh = _mm_add_epi32(yh_, bh);
${[
  for (final v in ['rl', 'rh', 'gl', 'gh', 'bl', 'bh'])
    ..._sse2Clamp032(v, 'vmax32', 'vzero32'),
].map((l) => '      $l').join('\n')}
      rl = _mm_packs_epi32(rl, rh);
      gl = _mm_packs_epi32(gl, gh);
      bl = _mm_packs_epi32(bl, bh);
      /* 重交织写回（R/G/B → 连续 3 通道）。 */
$reint      _mm_storeu_si128((__m128i *)(out + (size_t)x * 3u), o0);
      _mm_storeu_si128((__m128i *)(out + (size_t)x * 3u + 8u), o1);
      _mm_storeu_si128((__m128i *)(out + (size_t)x * 3u + 16u), o2);
    }
  }
#endif
$scalarTail''';
  }
  return '''
/* csc_yuv2rgb 整行函数（NEON/标量双变体，逐位一致；
 * 仅单节点独占阶段被调用，见 top .c 阶段发射）。 */
#if defined(__ARM_NEON) || defined(__ARM_NEON__)
#include <arm_neon.h>
#endif
static void ${id}_row(const uint16_t *in, uint16_t *out, int w,
                      int max_value) {
  int x = 0;
#if defined(__ARM_NEON) || defined(__ARM_NEON__)
  if (max_value <= 32767) {
    /* int32 系数（91881/116130 超 int16）+ vmulq/vmlaq；u'/v' = 通道值
     * - half ∈ [-16384, 16384]，单乘积 ≤ 116130×16384 < INT32_MAX。 */
    const int32x4_t vcRv = vdupq_n_s32(91881);
    const int32x4_t vcGu = vdupq_n_s32(-22553);
    const int32x4_t vcGv = vdupq_n_s32(-46801);
    const int32x4_t vcBu = vdupq_n_s32(116130);
    const int32x4_t vhalf32 = vdupq_n_s32(32768);
    const int32x4_t vh16 = vdupq_n_s32(max_value >> 1);
    const int32x4_t vmax32 = vdupq_n_s32(max_value);
    const int32x4_t vzero32 = vdupq_n_s32(0);
    for (; x + 8 <= w; x += 8) {
      /* 8 像素：VLD3 解交织 → u'/v' 减半程 → 逐项 vmulq/vmlaq → 单通道
       * (term+32768)>>16 后加 y → [0,max] 钳位 → vmovn 窄化 → VST3。 */
      const uint16x8x3_t px = vld3q_u16(in + (size_t)x * 3u);
      const int32x4_t yl = vreinterpretq_s32_u32(vmovl_u16(vget_low_u16(px.val[0])));
      const int32x4_t yh = vreinterpretq_s32_u32(vmovl_u16(vget_high_u16(px.val[0])));
      const int32x4_t ul = vsubq_s32(vreinterpretq_s32_u32(vmovl_u16(vget_low_u16(px.val[1]))), vh16);
      const int32x4_t uh = vsubq_s32(vreinterpretq_s32_u32(vmovl_u16(vget_high_u16(px.val[1]))), vh16);
      const int32x4_t vl = vsubq_s32(vreinterpretq_s32_u32(vmovl_u16(vget_low_u16(px.val[2]))), vh16);
      const int32x4_t vh = vsubq_s32(vreinterpretq_s32_u32(vmovl_u16(vget_high_u16(px.val[2]))), vh16);
      int32x4_t rl = vshrq_n_s32(vaddq_s32(vmulq_s32(vl, vcRv), vhalf32), 16);
      rl = vmaxq_s32(vminq_s32(vaddq_s32(yl, rl), vmax32), vzero32);
      int32x4_t rh = vshrq_n_s32(vaddq_s32(vmulq_s32(vh, vcRv), vhalf32), 16);
      rh = vmaxq_s32(vminq_s32(vaddq_s32(yh, rh), vmax32), vzero32);
      int32x4_t gl = vmulq_s32(ul, vcGu);
      gl = vmlaq_s32(gl, vl, vcGv);
      gl = vshrq_n_s32(vaddq_s32(gl, vhalf32), 16);
      gl = vmaxq_s32(vminq_s32(vaddq_s32(yl, gl), vmax32), vzero32);
      int32x4_t gh = vmulq_s32(uh, vcGu);
      gh = vmlaq_s32(gh, vh, vcGv);
      gh = vshrq_n_s32(vaddq_s32(gh, vhalf32), 16);
      gh = vmaxq_s32(vminq_s32(vaddq_s32(yh, gh), vmax32), vzero32);
      int32x4_t bl = vshrq_n_s32(vaddq_s32(vmulq_s32(ul, vcBu), vhalf32), 16);
      bl = vmaxq_s32(vminq_s32(vaddq_s32(yl, bl), vmax32), vzero32);
      int32x4_t bh = vshrq_n_s32(vaddq_s32(vmulq_s32(uh, vcBu), vhalf32), 16);
      bh = vmaxq_s32(vminq_s32(vaddq_s32(yh, bh), vmax32), vzero32);
      uint16x8x3_t opx;
      opx.val[0] = vcombine_u16(vmovn_u32(vreinterpretq_u32_s32(rl)),
                                vmovn_u32(vreinterpretq_u32_s32(rh)));
      opx.val[1] = vcombine_u16(vmovn_u32(vreinterpretq_u32_s32(gl)),
                                vmovn_u32(vreinterpretq_u32_s32(gh)));
      opx.val[2] = vcombine_u16(vmovn_u32(vreinterpretq_u32_s32(bl)),
                                vmovn_u32(vreinterpretq_u32_s32(bh)));
      vst3q_u16(out + (size_t)x * 3u, opx);
    }
  }
#endif
$scalarTail''';
}

/// x86 专属 FP64 HSL 整行函数源码（[id] 前缀，[variant] 为 'hsl2rgb' /
/// 'rgb2hsl'）：SSE2 双像素调用 isp_csc_sse.h 的逐位等价实现（与标量
/// bb_hsl_to_rgb_px / bb_rgb_to_hsl_px 同一出处，数据相关分支改为双分支
/// 都算 + 掩码选择、混合分母后单除法；全量 256^3 穷举对拍见
/// test/isp_csc_sse_test.dart 的 csc_sse_selfcheck）。标量尾与融合行核
/// 逐位一致。ARM 目标不登记（NEON 无 FP64 SIMD，融合行核标量即为最优）。
String _cscHslRgbRowFn(String id, String variant, GroupCTarget target) {
  assert(target.isX86);
  final scalarTail = variant == 'hsl2rgb'
      ? '''
  for (; x < w; x++) {
    int a[3];
    bb_hsl_to_rgb_px((int)in[(size_t)x * 3u + 0u], (int)in[(size_t)x * 3u + 1u],
                     (int)in[(size_t)x * 3u + 2u], max_value, 1.0 / max_value,
                     a, a + 1, a + 2);
    out[(size_t)x * 3u + 0u] = (uint16_t)a[0];
    out[(size_t)x * 3u + 1u] = (uint16_t)a[1];
    out[(size_t)x * 3u + 2u] = (uint16_t)a[2];
  }
}'''
      : '''
  for (; x < w; x++) {
    uint16_t a[3];
    bb_rgb_to_hsl_px((int)in[(size_t)x * 3u + 0u], (int)in[(size_t)x * 3u + 1u],
                     (int)in[(size_t)x * 3u + 2u], max_value, 1.0 / max_value, a);
    out[(size_t)x * 3u + 0u] = a[0];
    out[(size_t)x * 3u + 1u] = a[1];
    out[(size_t)x * 3u + 2u] = a[2];
  }
}''';
  final String simdBody;
  if (variant == 'hsl2rgb') {
    simdBody = '''
    for (; x + 2 <= w; x += 2) {
      int rgb[6];
      isp_csc_hsl2_to_rgb6((int)in[(size_t)x * 3u + 0u],
                           (int)in[(size_t)x * 3u + 1u],
                           (int)in[(size_t)x * 3u + 2u],
                           (int)in[(size_t)x * 3u + 3u],
                           (int)in[(size_t)x * 3u + 4u],
                           (int)in[(size_t)x * 3u + 5u], max_value, inv, rgb);
      out[(size_t)x * 3u + 0u] = (uint16_t)rgb[0];
      out[(size_t)x * 3u + 1u] = (uint16_t)rgb[1];
      out[(size_t)x * 3u + 2u] = (uint16_t)rgb[2];
      out[(size_t)x * 3u + 3u] = (uint16_t)rgb[3];
      out[(size_t)x * 3u + 4u] = (uint16_t)rgb[4];
      out[(size_t)x * 3u + 5u] = (uint16_t)rgb[5];
    }''';
  } else {
    simdBody = '''
    for (; x + 2 <= w; x += 2) {
      uint16_t hsl[6];
      isp_csc_rgb2_to_hsl6((int)in[(size_t)x * 3u + 0u],
                           (int)in[(size_t)x * 3u + 1u],
                           (int)in[(size_t)x * 3u + 2u],
                           (int)in[(size_t)x * 3u + 3u],
                           (int)in[(size_t)x * 3u + 4u],
                           (int)in[(size_t)x * 3u + 5u], max_value, inv, hsl);
      out[(size_t)x * 3u + 0u] = hsl[0];
      out[(size_t)x * 3u + 1u] = hsl[1];
      out[(size_t)x * 3u + 2u] = hsl[2];
      out[(size_t)x * 3u + 3u] = hsl[3];
      out[(size_t)x * 3u + 4u] = hsl[4];
      out[(size_t)x * 3u + 5u] = hsl[5];
    }''';
  }
  return '''
/* csc $variant 整行函数（x86 专属：FP64 SSE2 双像素快路径，与标量
 * 逐位一致；仅单节点独占阶段被调用，见 top .c 阶段发射）。 */
static void ${id}_row(const uint16_t *in, uint16_t *out, int w,
                      int max_value) {
  int x = 0;
#if defined(_M_X64) || defined(_M_AMD64) || defined(__x86_64__) ||           \\
    defined(__SSE2__) || (defined(_M_IX86_FP) && _M_IX86_FP >= 2)
  {
    const double inv = 1.0 / max_value;
$simdBody  }
#endif
$scalarTail''';
}
StreamKernelResult _kCscOne(StreamKernelCtx s, CNodeGenCtx ctx,
    Map<String, List<String>?> inputs, String variant) {
  final ie = _in(inputs, 'in');
  if (ctx.boolParam('bypass')) return _alias(ie, 'out');
  // yuv2rgb：登记整行行核（NEON/SSE2/标量双变体，随导出目标分叉；仅单
  // 节点独占阶段被调用，见 group_c_export_bb 阶段发射特判）。
  if (variant == 'yuv2rgb') {
    s.addFileDecl('${ctx.ident}_row', _cscYuv2RgbRowFn(ctx.ident, ctx.target));
  }
  // hsl2rgb/rgb2hsl：x86 专属整行行核（FP64 SSE2 双像素快路径，复用
  // isp_csc_sse.h 的逐位等价实现——与 bb_* 标量 helper 同一出处；ARM
  // 无 FP64 SIMD，保持融合行核标量）。
  if (ctx.target.isX86 && (variant == 'hsl2rgb' || variant == 'rgb2hsl')) {
    s.addFileDecl('${ctx.ident}_row',
        _cscHslRgbRowFn(ctx.ident, variant, ctx.target));
    s.cscSseUsed = true;
  }
  final lines = <String>[];
  final outs = _emitCscPx(s, variant, ie, lines);
  return (lines, {'out': outs});
}

// ---------------------------------------------------------------------------
// 调节器域
// ---------------------------------------------------------------------------

/// hsl_debugger：H 色环循环偏移 + S/L 增益。出处：isp_adjust.c
/// isp_adjust_hsl。shift = round(h_shift/360 × max_value) 依赖运行期
/// max_value，放前奏；恒等（全缺省）时 c_ref 直通不动数据。
StreamKernelResult _kHslDebugger(
    StreamKernelCtx s, CNodeGenCtx ctx, Map<String, List<String>?> inputs) {
  final ie = _in(inputs, 'in');
  if (ctx.boolParam('bypass')) return _alias(ie, 'out');
  final hs = ctx.doubleParam('h_shift');
  final sg = ctx.doubleParam('s_gain');
  final lg = ctx.doubleParam('l_gain');
  if (hs == 0.0 && sg == 1.0 && lg == 1.0) return _alias(ie, 'out');
  s.useHelper('bb_clamp_to');
  s.addPrelude(
      'const int64_t ${ctx.ident}_shift = (int64_t)round(${cNum(hs)} / 360.0 * max_value);');
  final hv = s.freshVar();
  final o0 = s.freshVar();
  final o1 = s.freshVar();
  final o2 = s.freshVar();
  return (
    [
      'const int64_t $hv = (int64_t)${ie[0]} + ${ctx.ident}_shift;',
      // 色环回绕：|shift| ≤ max/2（h_shift ≤ ±180°），单次条件加减与双重
      // 取模逐位一致，且消灭 int64 除法。
      'int64_t ${hv}w = $hv;',
      'if (${hv}w > max_value) ${hv}w -= (max_value + 1);',
      'else if (${hv}w < 0) ${hv}w += (max_value + 1);',
      'const uint16_t $o0 = (uint16_t)${hv}w;',
      'const uint16_t $o1 = bb_clamp_to((double)${ie[1]} * ${cNum(sg)}, max_value);',
      'const uint16_t $o2 = bb_clamp_to((double)${ie[2]} * ${cNum(lg)}, max_value);',
    ],
    {'out': [o0, o1, o2]},
  );
}

/// rgb_debugger：R/G/B 三通道增益。出处：isp_adjust.c isp_adjust_rgb。
StreamKernelResult _kRgbDebugger(
    StreamKernelCtx s, CNodeGenCtx ctx, Map<String, List<String>?> inputs) {
  final ie = _in(inputs, 'in');
  if (ctx.boolParam('bypass')) return _alias(ie, 'out');
  final gains = [
    ctx.doubleParam('r_gain'),
    ctx.doubleParam('g_gain'),
    ctx.doubleParam('b_gain'),
  ];
  if (gains.every((g) => g == 1.0)) return _alias(ie, 'out');
  s.useHelper('bb_clamp_to');
  final lines = <String>[];
  final outs = <String>[];
  for (var c = 0; c < 3; c++) {
    final o = s.freshVar();
    lines.add(
        'const uint16_t $o = bb_clamp_to((double)${ie[c]} * ${cNum(gains[c])}, max_value);');
    outs.add(o);
  }
  return (lines, {'out': outs});
}

/// yuv_debugger：Y 增益 + U/V 绕中点缩放。出处：isp_adjust.c
/// isp_adjust_yuv（half = max_value >> 1）。
StreamKernelResult _kYuvDebugger(
    StreamKernelCtx s, CNodeGenCtx ctx, Map<String, List<String>?> inputs) {
  final ie = _in(inputs, 'in');
  if (ctx.boolParam('bypass')) return _alias(ie, 'out');
  final gains = [
    ctx.doubleParam('y_gain'),
    ctx.doubleParam('u_gain'),
    ctx.doubleParam('v_gain'),
  ];
  if (gains.every((g) => g == 1.0)) return _alias(ie, 'out');
  s.useHelper('bb_clamp_to');
  const half = '(max_value >> 1)';
  final o0 = s.freshVar();
  final o1 = s.freshVar();
  final o2 = s.freshVar();
  return (
    [
      'const uint16_t $o0 = bb_clamp_to((double)${ie[0]} * ${cNum(gains[0])}, max_value);',
      'const uint16_t $o1 = bb_clamp_to($half + ((int)${ie[1]} - $half) * ${cNum(gains[1])}, max_value);',
      'const uint16_t $o2 = bb_clamp_to($half + ((int)${ie[2]} - $half) * ${cNum(gains[2])}, max_value);',
    ],
    {'out': [o0, o1, o2]},
  );
}

/// sat_bright_adjuster：RGB/YUV/HSL 三域饱和度/亮度。出处：isp_adjust.c
/// isp_adjust_sat_bright（RGB 域 BT.601 全范围亮度保亮度混合）。
/// sat_bright 整行行核可用性（与 [_kSatBright] 同口径）：非 bypass、非恒等
/// （sat/bright 全 1）、x86 目标（FP64 SSE2 双像素）。单节点组活动端口恒
/// 为首端口 'in'（rgb），yuv/hsl 形态不可达。可用返回 (sat, bright)。
(double, double)? satBrightRowOk(Map<String, dynamic> params, bool isX86) {
  if (params['bypass'] == true) return null;
  if (!isX86) return null;
  final type = IspNodeRegistry.byId('sat_bright_adjuster')!;
  double p(String key) {
    final v = params.containsKey(key)
        ? params[key]
        : type.params.firstWhere((s) => s.key == key).defaultValue;
    return (v as num?)?.toDouble() ?? 0.0;
  }

  final sat = p('sat_gain');
  final bright = p('bright_gain');
  if (sat == 1.0 && bright == 1.0) return null;
  return (sat, bright);
}

/// black_level 整行行核可用性（与 [_kBlackLevel] 同口径）：非 bypass、
/// x86 目标（FP64 SSE2 双像素）。单节点组活动端口恒为首端口 'in'
/// （bayer 1 通道），恒为四相位表形态。
bool blackLevelRowOk(Map<String, dynamic> params, bool isX86) {
  if (params['bypass'] == true) return false;
  return isX86;
}

/// sat_bright（rgb 形态）x86 专属 FP64 整行函数源码（[id] 前缀）：SSE2
/// 双像素（亮度加权插值 + 双增益，运算结合序同融合行核；钳位复用
/// isp_csc_sse.h 的 isp_csc_clamp2，与 bb_clamp_to 逐位一致）。标量尾与
/// 融合行核逐位一致。ARM 目标不登记（NEON 无 FP64 SIMD）。
String _satBrightRgbRowFn(String id, double sat, double bright,
    GroupCTarget target) {
  assert(target.isX86);
  final scalarTail = '''
  for (; x < w; x++) {
    const int r_ = in[(size_t)x * 3u + 0u];
    const int g_ = in[(size_t)x * 3u + 1u];
    const int b_ = in[(size_t)x * 3u + 2u];
    const double y_ = 0.299 * r_ + 0.587 * g_ + 0.114 * b_;
    out[(size_t)x * 3u + 0u] = bb_clamp_to((y_ + (r_ - y_) * ${cNum(sat)}) * ${cNum(bright)}, max_value);
    out[(size_t)x * 3u + 1u] = bb_clamp_to((y_ + (g_ - y_) * ${cNum(sat)}) * ${cNum(bright)}, max_value);
    out[(size_t)x * 3u + 2u] = bb_clamp_to((y_ + (b_ - y_) * ${cNum(sat)}) * ${cNum(bright)}, max_value);
  }
}''';
  return '''
/* sat_bright（rgb）整行函数（x86 专属：FP64 SSE2 双像素快路径，与标量
 * 逐位一致；仅单节点独占阶段被调用，见 top .c 阶段发射）。 */
static void ${id}_row(const uint16_t *in, uint16_t *out, int w,
                      int max_value) {
  int x = 0;
#if defined(_M_X64) || defined(_M_AMD64) || defined(__x86_64__) ||           \\
    defined(__SSE2__) || (defined(_M_IX86_FP) && _M_IX86_FP >= 2)
  {
    const __m128d c299 = _mm_set1_pd(0.299);
    const __m128d c587 = _mm_set1_pd(0.587);
    const __m128d c114 = _mm_set1_pd(0.114);
    const __m128d satv = _mm_set1_pd(${cNum(sat)});
    const __m128d briv = _mm_set1_pd(${cNum(bright)});
    const __m128d maxd = _mm_set1_pd((double)max_value);
    for (; x + 2 <= w; x += 2) {
      const __m128d rv = _mm_cvtepi32_pd(
          _mm_set_epi32(0, 0, (int)in[(size_t)x * 3u + 3u],
                        (int)in[(size_t)x * 3u + 0u]));
      const __m128d gv = _mm_cvtepi32_pd(
          _mm_set_epi32(0, 0, (int)in[(size_t)x * 3u + 4u],
                        (int)in[(size_t)x * 3u + 1u]));
      const __m128d bv = _mm_cvtepi32_pd(
          _mm_set_epi32(0, 0, (int)in[(size_t)x * 3u + 5u],
                        (int)in[(size_t)x * 3u + 2u]));
      const __m128d yv = _mm_add_pd(
          _mm_add_pd(_mm_mul_pd(c299, rv), _mm_mul_pd(c587, gv)),
          _mm_mul_pd(c114, bv));
      const __m128i ri = isp_csc_clamp2(
          _mm_mul_pd(_mm_add_pd(yv, _mm_mul_pd(_mm_sub_pd(rv, yv), satv)),
                     briv),
          maxd);
      const __m128i gi = isp_csc_clamp2(
          _mm_mul_pd(_mm_add_pd(yv, _mm_mul_pd(_mm_sub_pd(gv, yv), satv)),
                     briv),
          maxd);
      const __m128i bi = isp_csc_clamp2(
          _mm_mul_pd(_mm_add_pd(yv, _mm_mul_pd(_mm_sub_pd(bv, yv), satv)),
                     briv),
          maxd);
      out[(size_t)x * 3u + 0u] = (uint16_t)_mm_cvtsi128_si32(ri);
      out[(size_t)x * 3u + 1u] = (uint16_t)_mm_cvtsi128_si32(gi);
      out[(size_t)x * 3u + 2u] = (uint16_t)_mm_cvtsi128_si32(bi);
      out[(size_t)x * 3u + 3u] =
          (uint16_t)_mm_cvtsi128_si32(_mm_srli_si128(ri, 4));
      out[(size_t)x * 3u + 4u] =
          (uint16_t)_mm_cvtsi128_si32(_mm_srli_si128(gi, 4));
      out[(size_t)x * 3u + 5u] =
          (uint16_t)_mm_cvtsi128_si32(_mm_srli_si128(bi, 4));
    }
  }
#endif
$scalarTail''';
}

StreamKernelResult _kSatBright(
    StreamKernelCtx s, CNodeGenCtx ctx, Map<String, List<String>?> inputs) {
  final inPort = _activePort(ctx, const ['in', 'in_yuv', 'in_hsl']);
  final fmt = ctx.inputFormats[inPort] ?? 'rgb';
  final outPort = switch (fmt) {
    'yuv' => 'out_yuv',
    'hsl' => 'out_hsl',
    _ => 'out_rgb',
  };
  final ie = _in(inputs, inPort);
  if (ctx.boolParam('bypass')) return _alias(ie, outPort);
  final sat = ctx.doubleParam('sat_gain');
  final bright = ctx.doubleParam('bright_gain');
  if (sat == 1.0 && bright == 1.0) return _alias(ie, outPort);
  s.useHelper('bb_clamp_to');
  // rgb 形态 x86 专属整行行核（FP64 SSE2 双像素；yuv/hsl 形态单节点组
  // 不可达——活动端口恒为首端口 'in'，与 bright_contrast 同理）。复用
  // isp_csc_sse.h 的 isp_csc_clamp2（与 bb_clamp_to 逐位一致）。
  if (ctx.target.isX86 && fmt == 'rgb') {
    s.addFileDecl('${ctx.ident}_row',
        _satBrightRgbRowFn(ctx.ident, sat, bright, ctx.target));
    s.cscSseUsed = true;
  }
  final lines = <String>[];
  final outs = <String>[];
  switch (fmt) {
    case 'yuv':
      const half = '(max_value >> 1)';
      final o0 = s.freshVar();
      final o1 = s.freshVar();
      final o2 = s.freshVar();
      lines.addAll([
        'const uint16_t $o0 = bb_clamp_to((double)${ie[0]} * ${cNum(bright)}, max_value);',
        'const uint16_t $o1 = bb_clamp_to($half + ((int)${ie[1]} - $half) * ${cNum(sat)}, max_value);',
        'const uint16_t $o2 = bb_clamp_to($half + ((int)${ie[2]} - $half) * ${cNum(sat)}, max_value);',
      ]);
      outs.addAll([o0, o1, o2]);
    case 'hsl':
      // H 不变；S 乘 sat、L 乘 bright。
      final o1 = s.freshVar();
      final o2 = s.freshVar();
      lines.addAll([
        'const uint16_t $o1 = bb_clamp_to((double)${ie[1]} * ${cNum(sat)}, max_value);',
        'const uint16_t $o2 = bb_clamp_to((double)${ie[2]} * ${cNum(bright)}, max_value);',
      ]);
      outs.addAll([ie[0], o1, o2]);
    default: // rgb
      final r = s.freshVar();
      final g = s.freshVar();
      final b = s.freshVar();
      final y = s.freshVar();
      lines.addAll([
        'const int $r = ${ie[0]};',
        'const int $g = ${ie[1]};',
        'const int $b = ${ie[2]};',
        'const double $y = 0.299 * $r + 0.587 * $g + 0.114 * $b;',
      ]);
      for (final (c, ch) in [(0, r), (1, g), (2, b)]) {
        final o = s.freshVar();
        lines.add('const uint16_t $o = bb_clamp_to(($y + ($ch - $y) * ${cNum(sat)}) * ${cNum(bright)}, max_value);');
        outs.insert(c, o);
      }
  }
  return (lines, {outPort: outs});
}

/// bright_contrast_adjuster：RGB/YUV/HSL/Mono 四域亮度/对比度。
/// 出处：isp_adjust.c isp_adjust_bright_contrast（RGB 域亮度比例路径）+
/// isp_adjust_bc_map。LUT 模式（codegenMode=lut）：adjust 映射表生成期
/// 烘焙（Dart brightContrastAdjustLut），max_value 一致走查表（出处：
/// isp_adjust.c isp_adjust_bc_lut_apply），不一致回退直算（行内三元）。
StreamKernelResult _kBrightContrast(
    StreamKernelCtx s, CNodeGenCtx ctx, Map<String, List<String>?> inputs) {
  final inPort = _activePort(ctx, const ['in', 'in_yuv', 'in_hsl', 'in_mono']);
  final fmt = ctx.inputFormats[inPort] ?? 'rgb';
  final outPort = switch (fmt) {
    'yuv' => 'out_yuv',
    'hsl' => 'out_hsl',
    'mono' => 'out_mono',
    _ => 'out_rgb',
  };
  final ie = _in(inputs, inPort);
  if (ctx.boolParam('bypass')) return _alias(ie, outPort);
  final brightPct = ctx.doubleParam('bright');
  final baselinePct = ctx.doubleParam('baseline');
  final gainPct = ctx.doubleParam('gain');
  if (brightPct == 100 && gainPct == 100) {
    return _alias(ie, outPort); // c_ref 恒等（与基线无关）
  }
  s.useHelper('bb_bc_map');
  final lutMode = ctx.strParam('codegenMode') == 'lut';
  final bs = cNum(brightPct / 100.0);
  final gs = cNum(gainPct / 100.0);
  final base = '(${cNum(baselinePct)} / 100.0 * max_value)';
  if (lutMode) {
    final n = ctx.lutDomainMax;
    final lut = brightContrastAdjustLut(
        maxValue: n,
        brightPct: brightPct,
        baselinePct: baselinePct,
        gainPct: gainPct);
    s.addFileDecl('${ctx.ident}_adj_lut', '''
/* bright_contrast LUT 模式：adjust 映射表生成期烘焙（Dart
 * brightContrastAdjustLut，域 0..$n）；max_value 一致走查表，不一致
 * 回退直算（同公式）。 */
static const uint16_t ${ctx.ident}_adj_lut[${n + 1}] = {
${cU16Table(lut)}
};''');
  }

  String mapExpr(String vExpr) => lutMode
      ? '((max_value == ${ctx.lutDomainMax}) ? (int)${ctx.ident}_adj_lut[$vExpr] : bb_bc_map($vExpr, $bs, $base, $gs, max_value))'
      : 'bb_bc_map($vExpr, $bs, $base, $gs, max_value)';

  final lines = <String>[];
  final outs = <String>[];
  switch (fmt) {
    case 'yuv':
      final o = s.freshVar();
      lines.add('const uint16_t $o = (uint16_t)${mapExpr(ie[0])};');
      outs.addAll([o, ie[1], ie[2]]); // U/V 不变
    case 'hsl':
      final o = s.freshVar();
      lines.add('const uint16_t $o = (uint16_t)${mapExpr(ie[2])};');
      outs.addAll([ie[0], ie[1], o]); // H/S 不变
    case 'mono':
      final o = s.freshVar();
      lines.add('const uint16_t $o = (uint16_t)${mapExpr(ie[0])};');
      outs.add(o);
    default: // rgb：亮度比例路径（纯黑像素保持 0）
      final y = s.freshVar();
      final ratio = s.freshVar();
      lines.addAll([
        'const double $y = 0.299 * ${ie[0]} + 0.587 * ${ie[1]} + 0.114 * ${ie[2]};',
        'const double $ratio = $y <= 0 ? 1.0 : (double)${mapExpr('(int)round($y)')} / $y;',
      ]);
      for (var c = 0; c < 3; c++) {
        final o = s.freshVar();
        lines.add('const uint16_t $o = $y <= 0 ? ${ie[c]} : bb_clamp_to((double)${ie[c]} * $ratio, max_value);');
        outs.add(o);
      }
      s.useHelper('bb_clamp_to');
  }
  return (lines, {outPort: outs});
}

/// levels_curves 整行行核可用性（与 [_kLevelsCurves] 同口径）：非 bypass、
/// 非恒等曲线（恒等时直通不烘焙表）。
bool levelsRowOk(Map<String, dynamic> params) {
  if (params['bypass'] == true) return false;
  final points = levelsPointsFromParam(params['points']);
  final mode = levelsCurveModeFromParam(params['curveMode']?.toString() ?? '');
  final gamma = (params['gamma'] as num?)?.toDouble() ?? 0.0;
  final identity = mode == LevelsCurveMode.gamma
      ? gamma == 1.0
      : levelsCurveIsIdentity(points);
  return !identity;
}

/// levels_curves 整行函数源码（[id] 前缀）：NEON/SSE2 + 标量双变体（随导出
/// 目标分叉），与融合行核（bb_levels_apply）逐位一致。
/// 域匹配（max_value == 4095）走 SIMD gather（三通道同一 4096 级 LUT）；
/// 域失配标量回退（线性缩放往返，与融合行核同口径）。
String _levelsRowFn(String id, GroupCTarget target) {
  final scalarTail = '''
  for (; x < w; x++) {
    out[(size_t)x * 3u + 0u] = bb_levels_apply(${id}_lut, in[(size_t)x * 3u + 0u], max_value);
    out[(size_t)x * 3u + 1u] = bb_levels_apply(${id}_lut, in[(size_t)x * 3u + 1u], max_value);
    out[(size_t)x * 3u + 2u] = bb_levels_apply(${id}_lut, in[(size_t)x * 3u + 2u], max_value);
  }
}''';
  if (target.isX86) {
    final masks = '    const __m128i lm0 = _mm_setr_epi16(-1, 0, 0, 0, 0, 0, 0, 0);\n'
        '    const __m128i lm1 = _mm_setr_epi16(0, -1, 0, 0, 0, 0, 0, 0);\n'
        '    const __m128i lm2 = _mm_setr_epi16(0, 0, -1, 0, 0, 0, 0, 0);\n'
        '    const __m128i lm3 = _mm_setr_epi16(0, 0, 0, -1, 0, 0, 0, 0);\n'
        '    const __m128i lm4 = _mm_setr_epi16(0, 0, 0, 0, -1, 0, 0, 0);\n'
        '    const __m128i lm5 = _mm_setr_epi16(0, 0, 0, 0, 0, -1, 0, 0);\n'
        '    const __m128i lm6 = _mm_setr_epi16(0, 0, 0, 0, 0, 0, -1, 0);\n'
        '    const __m128i lm7 = _mm_setr_epi16(0, 0, 0, 0, 0, 0, 0, -1);\n';
    final deint =
        _sse2Deinterleave3('i0', 'i1', 'i2', 'rv', 'gv', 'bv').join('\n');
    final reint =
        _sse2Reinterleave3('lrv', 'lgv', 'lbv', 'o0', 'o1', 'o2').join('\n');
    return '''
/* levels_curves 整行函数（SSE2/标量双变体，逐位一致；
 * 仅单节点独占阶段被调用，见 top .c 阶段发射）。 */
#if defined(__SSE2__) || defined(_M_X64) || (defined(_M_IX86_FP) && _M_IX86_FP >= 2)
#include <emmintrin.h>
#endif
static void ${id}_row(const uint16_t *in, uint16_t *out, int w,
                      int max_value) {
  int x = 0;
#if defined(__SSE2__) || defined(_M_X64) || (defined(_M_IX86_FP) && _M_IX86_FP >= 2)
  if (max_value == 4095) {
$masks    for (; x + 8 <= w; x += 8) {
      const __m128i i0 =
          _mm_loadu_si128((const __m128i *)(in + (size_t)x * 3u));
      const __m128i i1 =
          _mm_loadu_si128((const __m128i *)(in + (size_t)x * 3u + 8u));
      const __m128i i2 =
          _mm_loadu_si128((const __m128i *)(in + (size_t)x * 3u + 16u));
$deint      uint16_t r_[8], g_[8], b_[8], lr_[8], lg_[8], lb_[8];
      int k;
      _mm_storeu_si128((__m128i *)r_, rv);
      _mm_storeu_si128((__m128i *)g_, gv);
      _mm_storeu_si128((__m128i *)b_, bv);
      for (k = 0; k < 8; k++) {
        lr_[k] = ${id}_lut[r_[k]];
        lg_[k] = ${id}_lut[g_[k]];
        lb_[k] = ${id}_lut[b_[k]];
      }
      const __m128i lrv = _mm_loadu_si128((const __m128i *)lr_);
      const __m128i lgv = _mm_loadu_si128((const __m128i *)lg_);
      const __m128i lbv = _mm_loadu_si128((const __m128i *)lb_);
$reint      _mm_storeu_si128((__m128i *)(out + (size_t)x * 3u), o0);
      _mm_storeu_si128((__m128i *)(out + (size_t)x * 3u + 8u), o1);
      _mm_storeu_si128((__m128i *)(out + (size_t)x * 3u + 16u), o2);
    }
  }
#endif
$scalarTail''';
  }
  return '''
/* levels_curves 整行函数（NEON/标量双变体，逐位一致；
 * 仅单节点独占阶段被调用，见 top .c 阶段发射）。 */
#if defined(__ARM_NEON) || defined(__ARM_NEON__)
#include <arm_neon.h>
#endif
static void ${id}_row(const uint16_t *in, uint16_t *out, int w,
                      int max_value) {
  int x = 0;
#if defined(__ARM_NEON) || defined(__ARM_NEON__)
  if (max_value == 4095) {
    for (; x + 8 <= w; x += 8) {
      /* 8 像素：VLD3 解交织 → 三通道标量 gather 查表 → VST3 重交织。 */
      const uint16x8x3_t px = vld3q_u16(in + (size_t)x * 3u);
      uint16_t r_[8], g_[8], b_[8], lr_[8], lg_[8], lb_[8];
      int k;
      vst1q_u16(r_, px.val[0]);
      vst1q_u16(g_, px.val[1]);
      vst1q_u16(b_, px.val[2]);
      for (k = 0; k < 8; k++) {
        lr_[k] = ${id}_lut[r_[k]];
        lg_[k] = ${id}_lut[g_[k]];
        lb_[k] = ${id}_lut[b_[k]];
      }
      uint16x8x3_t opx;
      opx.val[0] = vld1q_u16(lr_);
      opx.val[1] = vld1q_u16(lg_);
      opx.val[2] = vld1q_u16(lb_);
      vst3q_u16(out + (size_t)x * 3u, opx);
    }
  }
#endif
$scalarTail''';
}

/// levels_curves：RGB 域传递函数（4096 级 LUT 生成期烘焙，Dart
/// levelsCurveLut 与节点图表同一求值口径）。出处：isp_levels.c
/// isp_levels_apply_rgb（单点版见 bb_levels_apply）。恒等曲线生成期判定
/// （与 Dart 同口径），恒等时直通、不烘焙表。
StreamKernelResult _kLevelsCurves(
    StreamKernelCtx s, CNodeGenCtx ctx, Map<String, List<String>?> inputs) {
  final ie = _in(inputs, 'in');
  if (ctx.boolParam('bypass')) return _alias(ie, 'out');
  // 参数解析与整帧版（node_c_gen_adjust.dart _genLevelsCurves）同口径。
  final points = levelsPointsFromParam(ctx.param('points'));
  final mode = levelsCurveModeFromParam(ctx.strParam('curveMode'));
  final gamma = ctx.doubleParam('gamma');
  final identity = mode == LevelsCurveMode.gamma
      ? gamma == 1.0
      : levelsCurveIsIdentity(points);
  if (identity) return _alias(ie, 'out');
  final lut = levelsCurveLut(points, mode: mode, gamma: gamma);
  s.useHelper('bb_levels_apply');
  s.addFileDecl('${ctx.ident}_lut', '''
/* levels_curves 传递函数 LUT：生成期由 Dart levelsCurveLut 按节点参数
 * 烘焙（与节点图表中绘制的曲线同一求值口径），运行时纯查表。 */
static const uint16_t ${ctx.ident}_lut[4096] = {
${cU16Table(lut)}
};''');
  // 整行行核（NEON/SSE2/标量双变体，随导出目标分叉；仅单节点独占阶段
  // 被调用，见 group_c_export_bb 阶段发射特判）。登记在 LUT 表之后——
  // 行核函数体引用该表，须先声明。
  s.addFileDecl('${ctx.ident}_row', _levelsRowFn(ctx.ident, ctx.target));
  final lines = <String>[];
  final outs = <String>[];
  for (var c = 0; c < 3; c++) {
    final o = s.freshVar();
    lines.add('const uint16_t $o = bb_levels_apply(${ctx.ident}_lut, ${ie[c]}, max_value);');
    outs.add(o);
  }
  return (lines, {'out': outs});
}

/// color_balance：RGB/YUV/HSL 三域中间调加性偏移（非 Process 类，无
/// Bypass）。出处：isp_adjust.c isp_adjust_color_balance（HSL 域为逐像素
/// HSL→RGB→偏移→HSL 往返，中间 RGB 先量化为整数，与整帧往返逐位一致）。
StreamKernelResult _kColorBalance(
    StreamKernelCtx s, CNodeGenCtx ctx, Map<String, List<String>?> inputs) {
  final inPort = _activePort(ctx, const ['in', 'in_yuv', 'in_hsl']);
  final fmt = ctx.inputFormats[inPort] ?? 'rgb';
  final outPort = switch (fmt) {
    'yuv' => 'out_yuv',
    'hsl' => 'out_hsl',
    _ => 'out_rgb',
  };
  final ie = _in(inputs, inPort);
  final cr = ctx.doubleParam('cyan_red');
  final mg = ctx.doubleParam('magenta_green');
  final yb = ctx.doubleParam('yellow_blue');
  if (cr == 0.0 && mg == 0.0 && yb == 0.0) {
    return _alias(ie, outPort); // c_ref 三值全 0 直通
  }
  s.useHelper('bb_clamp_to');
  final lines = <String>[];
  final outs = <String>[];
  switch (fmt) {
    case 'yuv':
      // k = maxValue/2/100；青↔红 → V、黄↔蓝 → U、洋红↔绿 = −U−V。
      final du = '(${cNum(yb)} * ((double)max_value / 2 / 100))';
      final dv = '(${cNum(cr)} * ((double)max_value / 2 / 100))';
      final dg = '(${cNum(mg)} * ((double)max_value / 2 / 100))';
      final y = s.freshVar();
      final wt = s.freshVar();
      final o1 = s.freshVar();
      final o2 = s.freshVar();
      lines.addAll([
        'const int $y = ${ie[0]};',
        'const double $wt = 1 - fabs(2.0 * $y / max_value - 1);',
        'const uint16_t $o1 = bb_clamp_to((double)${ie[1]} + ($du - $dg) * $wt, max_value);',
        'const uint16_t $o2 = bb_clamp_to((double)${ie[2]} + ($dv - $dg) * $wt, max_value);',
      ]);
      outs.addAll([ie[0], o1, o2]); // Y 不变
    case 'hsl':
      final dr = '(${cNum(cr)} / 100.0 * max_value)';
      final dg = '(${cNum(mg)} / 100.0 * max_value)';
      final db = '(${cNum(yb)} / 100.0 * max_value)';
      final rgb = s.freshVar();
      final y = s.freshVar();
      final wt = s.freshVar();
      final out = s.freshVar();
      s.useHelper('bb_hsl_to_rgb_px');
      s.useHelper('bb_rgb_to_hsl_px');
      lines.addAll([
        'int $rgb[3];',
        'bb_hsl_to_rgb_px(${ie[0]}, ${ie[1]}, ${ie[2]}, max_value, 1.0 / max_value, $rgb, $rgb + 1, $rgb + 2);',
        'const double $y = (0.299 * $rgb[0] + 0.587 * $rgb[1] + 0.114 * $rgb[2]) / max_value;',
        'const double $wt = 1 - fabs(2 * $y - 1);',
        '$rgb[0] = bb_clamp_to($rgb[0] + $dr * $wt, max_value);',
        '$rgb[1] = bb_clamp_to($rgb[1] + $dg * $wt, max_value);',
        '$rgb[2] = bb_clamp_to($rgb[2] + $db * $wt, max_value);',
        'uint16_t $out[3];',
        'bb_rgb_to_hsl_px($rgb[0], $rgb[1], $rgb[2], max_value, 1.0 / max_value, $out);',
      ]);
      outs.addAll(['$out[0]', '$out[1]', '$out[2]']);
    default: // rgb
      final dr = '(${cNum(cr)} / 100.0 * max_value)';
      final dg = '(${cNum(mg)} / 100.0 * max_value)';
      final db = '(${cNum(yb)} / 100.0 * max_value)';
      final r = s.freshVar();
      final g = s.freshVar();
      final b = s.freshVar();
      final y = s.freshVar();
      final wt = s.freshVar();
      lines.addAll([
        'const int $r = ${ie[0]};',
        'const int $g = ${ie[1]};',
        'const int $b = ${ie[2]};',
        'const double $y = (0.299 * $r + 0.587 * $g + 0.114 * $b) / max_value;',
        'const double $wt = 1 - fabs(2 * $y - 1);',
      ]);
      for (final (c, ch, d) in [(0, r, dr), (1, g, dg), (2, b, db)]) {
        final o = s.freshVar();
        lines.add('const uint16_t $o = bb_clamp_to($ch + $d * $wt, max_value);');
        outs.insert(c, o);
      }
  }
  return (lines, {outPort: outs});
}

/// color_temp 整行行核可用性（与 [_kColorTemp] 同口径）：LUT 模式且增益
/// 非全 1（全 1 时 LUT 为恒等，无行核收益）。返回 gains 或 null。
List<double>? colorTempRowGains(Map<String, dynamic> params) {
  if (params['codegenMode'] != 'lut') return null;
  final gains = colorTempGains(
      (params['temperature'] as num?)?.toDouble() ?? 0.0,
      (params['measured_cct'] as num?)?.toInt() ?? 0);
  if (gains.every((g) => g == 1.0)) return null;
  return gains;
}

/// color_temp（LUT 模式）整行函数源码（[id] 前缀，烘焙域 [n]）：
/// NEON/SSE2 + 标量双变体（随导出目标分叉）。域匹配（max_value == n）
/// 走 SIMD gather（三通道各自 lut_r/lut_g/lut_b 查表）；域失配标量回退
/// bb_clamp_to(v×gain)，与融合行核逐位一致。
String _colorTempLutRowFn(
    String id, int n, List<double> gains, GroupCTarget target) {
  final scalarTail = '''
  for (; x < w; x++) {
    out[(size_t)x * 3u + 0u] = (max_value == $n)
        ? ${id}_lut_r[in[(size_t)x * 3u + 0u]]
        : bb_clamp_to((double)in[(size_t)x * 3u + 0u] * ${cNum(gains[0])}, max_value);
    out[(size_t)x * 3u + 1u] = (max_value == $n)
        ? ${id}_lut_g[in[(size_t)x * 3u + 1u]]
        : bb_clamp_to((double)in[(size_t)x * 3u + 1u] * ${cNum(gains[1])}, max_value);
    out[(size_t)x * 3u + 2u] = (max_value == $n)
        ? ${id}_lut_b[in[(size_t)x * 3u + 2u]]
        : bb_clamp_to((double)in[(size_t)x * 3u + 2u] * ${cNum(gains[2])}, max_value);
  }
}''';
  if (target.isX86) {
    final masks = '    const __m128i lm0 = _mm_setr_epi16(-1, 0, 0, 0, 0, 0, 0, 0);\n'
        '    const __m128i lm1 = _mm_setr_epi16(0, -1, 0, 0, 0, 0, 0, 0);\n'
        '    const __m128i lm2 = _mm_setr_epi16(0, 0, -1, 0, 0, 0, 0, 0);\n'
        '    const __m128i lm3 = _mm_setr_epi16(0, 0, 0, -1, 0, 0, 0, 0);\n'
        '    const __m128i lm4 = _mm_setr_epi16(0, 0, 0, 0, -1, 0, 0, 0);\n'
        '    const __m128i lm5 = _mm_setr_epi16(0, 0, 0, 0, 0, -1, 0, 0);\n'
        '    const __m128i lm6 = _mm_setr_epi16(0, 0, 0, 0, 0, 0, -1, 0);\n'
        '    const __m128i lm7 = _mm_setr_epi16(0, 0, 0, 0, 0, 0, 0, -1);\n';
    final deint =
        _sse2Deinterleave3('i0', 'i1', 'i2', 'rv', 'gv', 'bv').join('\n');
    final reint =
        _sse2Reinterleave3('lrv', 'lgv', 'lbv', 'o0', 'o1', 'o2').join('\n');
    return '''
/* color_temp LUT 模式整行函数（SSE2/标量双变体，逐位一致；
 * 仅单节点独占阶段被调用，见 top .c 阶段发射）。 */
#if defined(__SSE2__) || defined(_M_X64) || (defined(_M_IX86_FP) && _M_IX86_FP >= 2)
#include <emmintrin.h>
#endif
static void ${id}_row(const uint16_t *in, uint16_t *out, int w,
                      int max_value) {
  int x = 0;
#if defined(__SSE2__) || defined(_M_X64) || (defined(_M_IX86_FP) && _M_IX86_FP >= 2)
  if (max_value == $n) {
$masks    for (; x + 8 <= w; x += 8) {
      const __m128i i0 =
          _mm_loadu_si128((const __m128i *)(in + (size_t)x * 3u));
      const __m128i i1 =
          _mm_loadu_si128((const __m128i *)(in + (size_t)x * 3u + 8u));
      const __m128i i2 =
          _mm_loadu_si128((const __m128i *)(in + (size_t)x * 3u + 16u));
$deint      uint16_t r_[8], g_[8], b_[8], lr_[8], lg_[8], lb_[8];
      int k;
      _mm_storeu_si128((__m128i *)r_, rv);
      _mm_storeu_si128((__m128i *)g_, gv);
      _mm_storeu_si128((__m128i *)b_, bv);
      for (k = 0; k < 8; k++) {
        lr_[k] = ${id}_lut_r[r_[k]];
        lg_[k] = ${id}_lut_g[g_[k]];
        lb_[k] = ${id}_lut_b[b_[k]];
      }
      const __m128i lrv = _mm_loadu_si128((const __m128i *)lr_);
      const __m128i lgv = _mm_loadu_si128((const __m128i *)lg_);
      const __m128i lbv = _mm_loadu_si128((const __m128i *)lb_);
$reint      _mm_storeu_si128((__m128i *)(out + (size_t)x * 3u), o0);
      _mm_storeu_si128((__m128i *)(out + (size_t)x * 3u + 8u), o1);
      _mm_storeu_si128((__m128i *)(out + (size_t)x * 3u + 16u), o2);
    }
  }
#endif
$scalarTail''';
  }
  return '''
/* color_temp LUT 模式整行函数（NEON/标量双变体，逐位一致；
 * 仅单节点独占阶段被调用，见 top .c 阶段发射）。 */
#if defined(__ARM_NEON) || defined(__ARM_NEON__)
#include <arm_neon.h>
#endif
static void ${id}_row(const uint16_t *in, uint16_t *out, int w,
                      int max_value) {
  int x = 0;
#if defined(__ARM_NEON) || defined(__ARM_NEON__)
  if (max_value == $n) {
    for (; x + 8 <= w; x += 8) {
      /* 8 像素：VLD3 解交织 → 三通道标量 gather 查表 → VST3 重交织。 */
      const uint16x8x3_t px = vld3q_u16(in + (size_t)x * 3u);
      uint16_t r_[8], g_[8], b_[8], lr_[8], lg_[8], lb_[8];
      int k;
      vst1q_u16(r_, px.val[0]);
      vst1q_u16(g_, px.val[1]);
      vst1q_u16(b_, px.val[2]);
      for (k = 0; k < 8; k++) {
        lr_[k] = ${id}_lut_r[r_[k]];
        lg_[k] = ${id}_lut_g[g_[k]];
        lb_[k] = ${id}_lut_b[b_[k]];
      }
      uint16x8x3_t opx;
      opx.val[0] = vld1q_u16(lr_);
      opx.val[1] = vld1q_u16(lg_);
      opx.val[2] = vld1q_u16(lb_);
      vst3q_u16(out + (size_t)x * 3u, opx);
    }
  }
#endif
$scalarTail''';
}

/// color_temp_adjuster：von Kries 对角增益 + 三通道增益施加（非 Process
/// 类，无 Bypass）。增益在生成期经 Dart colorTempGains 算出烘焙（与 C
/// isp_color_temp_gains 有既有 tol=0 对拍，增益值一致；measured_cct 缺失
/// 时 0 → 参考 6500K）。出处：isp_adjust.c isp_adjust_rgb 的逐像素施加。
/// LUT 模式（codegenMode=lut）：三通道查找表生成期烘焙（Dart
/// adjustGainLut），max_value 一致走查表（isp_adjust_lut3_apply 语义），
/// 不一致回退直算。
StreamKernelResult _kColorTemp(
    StreamKernelCtx s, CNodeGenCtx ctx, Map<String, List<String>?> inputs) {
  final ie = _in(inputs, 'in');
  final gains = colorTempGains(
      ctx.doubleParam('temperature'), ctx.intParam('measured_cct'));
  final lutMode = ctx.strParam('codegenMode') == 'lut';
  if (!lutMode && gains.every((g) => g == 1.0)) {
    return _alias(ie, 'out_rgb'); // isp_adjust_rgb 恒等早退
  }
  s.useHelper('bb_clamp_to');
  if (lutMode) {
    final n = ctx.lutDomainMax;
    for (var c = 0; c < 3; c++) {
      final name = 'lut_${'rgb'[c]}';
      s.addFileDecl('${ctx.ident}_$name', '''
/* color_temp LUT 模式：三通道增益表生成期烘焙（Dart colorTempGains +
 * adjustGainLut，域 0..$n）；max_value 一致走查表，不一致回退直算。 */
static const uint16_t ${ctx.ident}_$name[${n + 1}] = {
${cU16Table(adjustGainLut(gains[c], n))}
};''');
    }
    // 整行行核（NEON/SSE2/标量双变体，随导出目标分叉；仅单节点独占阶段
    // 被调用，见 group_c_export_bb 阶段发射特判）。登记在三表之后——
    // 行核函数体引用这些表，须先声明。
    if (!gains.every((g) => g == 1.0)) {
      s.addFileDecl('${ctx.ident}_row',
          _colorTempLutRowFn(ctx.ident, n, gains, ctx.target));
    }
  }
  final lines = <String>[];
  final outs = <String>[];
  for (var c = 0; c < 3; c++) {
    final o = s.freshVar();
    lines.add(lutMode
        ? 'const uint16_t $o = (max_value == ${ctx.lutDomainMax}) ? ${ctx.ident}_lut_${'rgb'[c]}[${ie[c]}] : bb_clamp_to((double)${ie[c]} * ${cNum(gains[c])}, max_value);'
        : 'const uint16_t $o = bb_clamp_to((double)${ie[c]} * ${cNum(gains[c])}, max_value);');
    outs.add(o);
  }
  return (lines, {'out_rgb': outs});
}

/// color_controller：高斯色相带选择性调整（src/dst 分离语义，融合链内
/// 天然满足）。出处：isp_color_controller.c isp_color_controller_apply
/// （逐像素精确 exp 权重，与 Dart adjustHslBandRows 同一表达式）。
/// 恒等（h_shift=0 且 s/l 增益为 1）时直通；q <= 0 校验期拒绝。
/// LUT 模式（codegenMode=lut）：H 域三表生成期烘焙（Dart hslBandLuts），
/// max_value 一致走查表（isp_color_controller_lut_apply 语义），不一致
/// 回退直算（行内三元）。
/// color_controller 整行行核可用性（与 [_kColorController] 同口径）：非
/// bypass、非恒等（h_shift=0 且 s/l 增益为 1）、LUT 模式、x86 目标（H 域
/// int32 + S/L FP64 双像素 SIMD；ARM 无 FP64 SIMD，保持融合行核 + omp）。
bool colorControllerRowOk(Map<String, dynamic> params, bool isX86) {
  if (params['bypass'] == true) return false;
  if (!isX86) return false;
  if (params['codegenMode'] != 'lut') return false;
  final type = IspNodeRegistry.byId('color_controller')!;
  double p(String key) {
    final v = params.containsKey(key)
        ? params[key]
        : type.params.firstWhere((s) => s.key == key).defaultValue;
    return (v as num?)?.toDouble() ?? 0.0;
  }

  final hs = p('h_shift');
  final sg = p('s_gain');
  final lg = p('l_gain');
  if (hs == 0.0 && sg == 1.0 && lg == 1.0) return false;
  return true;
}

/// color_controller（LUT 模式）x86 专属整行函数源码（[id] 前缀，烘焙域
/// [n]）：SSE2 双像素。域匹配（max_value == n）走 SIMD——H 通道 int32
/// gather 偏移 + 条件回绕（|shift| ≤ max/2 至多一次，先后两条件与标量
/// else-if 逐位一致）；S/L 通道 FP64 gather 乘子 + isp_csc_clamp2（与
/// bb_clamp_to 逐位一致）。域失配标量回退直算（含 exp 高斯权重），与
/// 融合行核逐位一致。ARM 目标不登记（NEON 无 FP64 SIMD）。
String _colorControllerRowFn(String id, int n, double hc, double q, double hs,
    double sg, double lg, GroupCTarget target) {
  assert(target.isX86);
  final sigma = 45.0 / q;
  final scalarTail = '''
  for (; x < w; x++) {
    int hv_ = (int)in[(size_t)x * 3u + 0u];
    if (hv_ > max_value) hv_ = max_value;
    const double hd_ = (double)hv_ * 360.0 / (double)max_value;
    double d_ = fabs(hd_ - ${cNum(hc)});
    d_ = fmod(d_, 360.0);
    if (d_ > 180.0) d_ = 360.0 - d_;
    const double x_ = d_ / ${cNum(sigma)};
    const double w_ = exp(-0.5 * x_ * x_);
    const int shift_ = (max_value == $n)
        ? ${id}_shift_lut[hv_]
        : (int)lround(${cNum(hs)} * w_ / 360.0 * (double)max_value);
    int hnew_ = hv_ + shift_;
    if (hnew_ > max_value) hnew_ -= (max_value + 1);
    else if (hnew_ < 0) hnew_ += (max_value + 1);
    out[(size_t)x * 3u + 0u] = (uint16_t)hnew_;
    out[(size_t)x * 3u + 1u] = bb_clamp_to(
        (double)in[(size_t)x * 3u + 1u] *
            ((max_value == $n)
                ? ${id}_s_mul_lut[hv_]
                : (1.0 + (${cNum(sg)} - 1.0) * w_)),
        max_value);
    out[(size_t)x * 3u + 2u] = bb_clamp_to(
        (double)in[(size_t)x * 3u + 2u] *
            ((max_value == $n)
                ? ${id}_l_mul_lut[hv_]
                : (1.0 + (${cNum(lg)} - 1.0) * w_)),
        max_value);
  }
}''';
  return '''
/* color_controller LUT 模式整行函数（x86 专属：H 域 int32 + S/L FP64
 * SSE2 双像素快路径，与标量逐位一致；仅单节点独占阶段被调用，见
 * top .c 阶段发射）。 */
static void ${id}_row(const uint16_t *in, uint16_t *out, int w,
                      int max_value) {
  int x = 0;
#if defined(_M_X64) || defined(_M_AMD64) || defined(__x86_64__) ||           \\
    defined(__SSE2__) || (defined(_M_IX86_FP) && _M_IX86_FP >= 2)
  if (max_value == $n) {
    const __m128i vmax32 = _mm_set1_epi32(max_value);
    const __m128i vmp1 = _mm_set1_epi32(max_value + 1);
    const __m128i vzero32 = _mm_setzero_si128();
    const __m128d maxd = _mm_set1_pd((double)max_value);
    for (; x + 2 <= w; x += 2) {
      const int hv0 =
          (int)in[(size_t)x * 3u + 0u] > max_value ? max_value : (int)in[(size_t)x * 3u + 0u];
      const int hv1 =
          (int)in[(size_t)x * 3u + 3u] > max_value ? max_value : (int)in[(size_t)x * 3u + 3u];
      /* H：int32 双像素 gather 偏移 → 加法 → 条件回绕（先减后加，与标量
       * else-if 逐位一致——首条件命中后回绕值 ≥ 0，次条件恒不触发）。 */
      __m128i hnew = _mm_add_epi32(
          _mm_set_epi32(0, 0, hv1, hv0),
          _mm_set_epi32(0, 0, (int)${id}_shift_lut[hv1],
                        (int)${id}_shift_lut[hv0]));
      hnew = _mm_sub_epi32(
          hnew, _mm_and_si128(_mm_cmpgt_epi32(hnew, vmax32), vmp1));
      hnew = _mm_add_epi32(
          hnew, _mm_and_si128(_mm_cmpgt_epi32(vzero32, hnew), vmp1));
      /* S/L：FP64 双像素 gather 乘子 → 乘 → isp_csc_clamp2 钳位。 */
      const __m128d sv = _mm_cvtepi32_pd(
          _mm_set_epi32(0, 0, (int)in[(size_t)x * 3u + 4u],
                        (int)in[(size_t)x * 3u + 1u]));
      const __m128d lv = _mm_cvtepi32_pd(
          _mm_set_epi32(0, 0, (int)in[(size_t)x * 3u + 5u],
                        (int)in[(size_t)x * 3u + 2u]));
      const __m128i si = isp_csc_clamp2(
          _mm_mul_pd(sv,
                     _mm_set_pd(${id}_s_mul_lut[hv1], ${id}_s_mul_lut[hv0])),
          maxd);
      const __m128i li = isp_csc_clamp2(
          _mm_mul_pd(lv,
                     _mm_set_pd(${id}_l_mul_lut[hv1], ${id}_l_mul_lut[hv0])),
          maxd);
      out[(size_t)x * 3u + 0u] = (uint16_t)_mm_cvtsi128_si32(hnew);
      out[(size_t)x * 3u + 1u] = (uint16_t)_mm_cvtsi128_si32(si);
      out[(size_t)x * 3u + 2u] = (uint16_t)_mm_cvtsi128_si32(li);
      out[(size_t)x * 3u + 3u] =
          (uint16_t)_mm_cvtsi128_si32(_mm_srli_si128(hnew, 4));
      out[(size_t)x * 3u + 4u] =
          (uint16_t)_mm_cvtsi128_si32(_mm_srli_si128(si, 4));
      out[(size_t)x * 3u + 5u] =
          (uint16_t)_mm_cvtsi128_si32(_mm_srli_si128(li, 4));
    }
  }
#endif
$scalarTail''';
}

StreamKernelResult _kColorController(
    StreamKernelCtx s, CNodeGenCtx ctx, Map<String, List<String>?> inputs) {
  final ie = _in(inputs, 'in');
  if (ctx.boolParam('bypass')) return _alias(ie, 'out');
  final hc = ctx.doubleParam('h_center');
  final q = ctx.doubleParam('q');
  final hs = ctx.doubleParam('h_shift');
  final sg = ctx.doubleParam('s_gain');
  final lg = ctx.doubleParam('l_gain');
  if (hs == 0.0 && sg == 1.0 && lg == 1.0) return _alias(ie, 'out');
  final sigma = 45.0 / q;
  s.useHelper('bb_clamp_to');
  final lutMode = ctx.strParam('codegenMode') == 'lut';
  if (lutMode) {
    final n = ctx.lutDomainMax;
    final (shiftLut, sMulLut, lMulLut) = hslBandLuts(
        maxValue: n,
        hCenterDeg: hc,
        q: q,
        hShiftDeg: hs,
        sGain: sg,
        lGain: lg);
    s.addFileDecl('${ctx.ident}_shift_lut', '''
/* color_controller LUT 模式：H 域三表（H 偏移/S 乘子/L 乘子，含高斯
 * 权重）生成期烘焙（Dart hslBandLuts，域 0..$n）；max_value 一致走查
 * 表，不一致回退直算。 */
static const int32_t ${ctx.ident}_shift_lut[${n + 1}] = {
${cI32Table(shiftLut)}
};''');
    s.addFileDecl('${ctx.ident}_s_mul_lut', '''
static const double ${ctx.ident}_s_mul_lut[${n + 1}] = {
${cF64Table(sMulLut)}
};''');
    s.addFileDecl('${ctx.ident}_l_mul_lut', '''
static const double ${ctx.ident}_l_mul_lut[${n + 1}] = {
${cF64Table(lMulLut)}
};''');
    // 整行行核（x86 专属：H int32 + S/L FP64 SSE2 双像素，复用
    // isp_csc_sse.h 的 isp_csc_clamp2；仅单节点独占阶段被调用）。登记在
    // 三表之后——行核函数体引用这些表，须先声明。
    if (ctx.target.isX86) {
      s.addFileDecl(
          '${ctx.ident}_row',
          _colorControllerRowFn(ctx.ident, n, hc, q, hs, sg, lg, ctx.target));
      s.cscSseUsed = true;
    }
  }
  final n = ctx.lutDomainMax;
  final id = ctx.ident;
  final hv = s.freshVar();
  final hd = s.freshVar();
  final d = s.freshVar();
  final x = s.freshVar();
  final w = s.freshVar();
  final shift = s.freshVar();
  final hnew = s.freshVar();
  final o0 = s.freshVar();
  final o1 = s.freshVar();
  final o2 = s.freshVar();
  final shiftExpr = lutMode
      ? '((max_value == $n) ? ${id}_shift_lut[$hv] : (int)lround(${cNum(hs)} * $w / 360.0 * (double)max_value))'
      : '(int)lround(${cNum(hs)} * $w / 360.0 * (double)max_value)';
  final sMulExpr = lutMode
      ? '((max_value == $n) ? ${id}_s_mul_lut[$hv] : (1.0 + (${cNum(sg)} - 1.0) * $w))'
      : '(1.0 + (${cNum(sg)} - 1.0) * $w)';
  final lMulExpr = lutMode
      ? '((max_value == $n) ? ${id}_l_mul_lut[$hv] : (1.0 + (${cNum(lg)} - 1.0) * $w))'
      : '(1.0 + (${cNum(lg)} - 1.0) * $w)';
  return (
    [
      // 色环最短角距 Δ（0..180°）与高斯权重（出处同函数主循环）。
      'int $hv = ${ie[0]};',
      'if ($hv > max_value) $hv = max_value;',
      'const double $hd = (double)$hv * 360.0 / (double)max_value;',
      'double $d = fabs($hd - ${cNum(hc)});',
      '$d = fmod($d, 360.0);',
      'if ($d > 180.0) $d = 360.0 - $d;',
      'const double $x = $d / ${cNum(sigma)};',
      'const double $w = exp(-0.5 * $x * $x);',
      'const int $shift = $shiftExpr;',
      // 色环回绕：|shift| ≤ max/2（h_shift ≤ ±180°）、hv ∈ [0,max]，单次
      // 条件加减与 % (max+1) 逐位一致——max_value 是运行时参数，% 会退化
      // 为逐像素整数除法（实测占单帧耗时大头），模数 2 的幂也救不了。
      'int $hnew = $hv + $shift;',
      'if ($hnew > max_value) $hnew -= (max_value + 1);',
      'else if ($hnew < 0) $hnew += (max_value + 1);',
      'const uint16_t $o0 = (uint16_t)$hnew;',
      'const uint16_t $o1 = bb_clamp_to((double)${ie[1]} * $sMulExpr, max_value);',
      'const uint16_t $o2 = bb_clamp_to((double)${ie[2]} * $lMulExpr, max_value);',
    ],
    {'out': [o0, o1, o2]},
  );
}

/// multi_band_eq：多段高斯色相带并联/串联（逐像素，H 量化值整数 →
/// 合成结果与整帧 LUT 表项逐位一致）。出处：isp_kernels.dart
/// multiBandLuts + applyHslBandLuts（= isp_multi_band_eq.c mb_compose +
/// lut_apply 的同公式行核版）。段参数读取口径同 runner（band_count 缺省
/// 1 钳位 1..24，b{i}_* 缺键回退恒等默认）；全段恒等直通别名（同 runner
/// 判定）。段合成写为文件级 static helper `<id>_compose`（段参数生成期
/// 烘焙为字面常量，公式与 mb_compose 逐行一致）；LUT 模式
///（codegenMode=lut）另烘焙三表（Dart multiBandLuts，域 0..
/// lutDomainMax），max_value 一致走查表、不一致回退 _compose 直算。
/// LUT 定点模式（codegenMode=lut_fixed）：H 表同 lut（int16），S/L 乘子
/// 烘焙为 Q14 定点整数表（bb_clamp_q14 整数乘加，面向 A55 等无 FP64
/// SIMD 的嵌入式核；与 FP64 口径偏差 ≤1 LSB），回退路径同 lut。
StreamKernelResult _kMultiBandEq(
    StreamKernelCtx s, CNodeGenCtx ctx, Map<String, List<String>?> inputs) {
  final ie = _in(inputs, 'in');
  if (ctx.boolParam('bypass')) return _alias(ie, 'out');
  var bandCount = ctx.intParam('band_count');
  if (bandCount < 1) bandCount = 1;
  if (bandCount > 24) bandCount = 24;
  final serial = ctx.strParam('band_mode') == 'serial';
  double bandParam(int i, String suffix, double fallback) =>
      (ctx.param('b${i}_$suffix') as num?)?.toDouble() ?? fallback;
  final bands = [
    for (var i = 0; i < bandCount; i++)
      (
        h: bandParam(i, 'h', 0.0),
        q: bandParam(i, 'q', 2.0),
        dh: bandParam(i, 'dh', 0.0),
        s: bandParam(i, 's', 1.0),
        l: bandParam(i, 'l', 1.0),
      ),
  ];
  if (bands.every((b) => b.dh == 0.0 && b.s == 1.0 && b.l == 1.0)) {
    return _alias(ie, 'out');
  }
  s.useHelper('bb_clamp_to');
  final id = ctx.ident;

  // 段 i 在色相 hueExpr 上的高斯权重（行级展开，字面常量下标/参数）：
  // 与 mb_compose 的 mb_weight 逐行一致。
  String bandWeightLines(int i, String hueExpr) {
    final b = bands[i];
    return '''
  double d$i = fabs($hueExpr - ${cNum(b.h)});
  d$i = fmod(d$i, 360.0);
  if (d$i > 180.0) d$i = 360.0 - d$i;
  { const double x$i = d$i / (45.0 / ${cNum(b.q)});
    const double w$i = exp(-0.5 * x$i * x$i);''';
  }

  // 文件级逐 hv 合成 helper（func 模式与 LUT 回退共用）。
  final compose = StringBuffer()
    ..writeln('''/* multi_band_eq 逐 hv 合成（与 isp_multi_band_eq.c mb_compose 同公式，
 * 段参数生成期烘焙为字面常量）。 */''')
    ..writeln('static void ${id}_compose(int hv, int max_value, int32_t *shift,')
    ..writeln('                          double *s_mul, double *l_mul) {')
    ..writeln('  const double h_deg = (double)hv * 360.0 / (double)max_value;');
  if (bandCount == 1) {
    // 单段捷径：串联与并联语义相同，走色彩控制器同公式（无钳位路径）。
    compose
      ..writeln(bandWeightLines(0, 'h_deg'))
      ..writeln('    *shift ='
          ' (int32_t)lround(${cNum(bands[0].dh)} * w0 / 360.0 * (double)max_value);')
      ..writeln('    *s_mul = 1.0 + (${cNum(bands[0].s)} - 1.0) * w0;')
      ..writeln('    *l_mul = 1.0 + (${cNum(bands[0].l)} - 1.0) * w0;')
      ..writeln('  }');
  } else if (!serial) {
    // 并联：全部段在原 H 上各取权重，加权求和后钳位。
    compose.writeln('  double dh_sum = 0.0, s_sum = 0.0, l_sum = 0.0;');
    for (var i = 0; i < bandCount; i++) {
      compose
        ..writeln(bandWeightLines(i, 'h_deg'))
        ..writeln('    dh_sum += w$i * ${cNum(bands[i].dh)};')
        ..writeln('    s_sum += w$i * (${cNum(bands[i].s)} - 1.0);')
        ..writeln('    l_sum += w$i * (${cNum(bands[i].l)} - 1.0);')
        ..writeln('  }');
    }
    compose.writeln('''
  if (dh_sum < -180.0) dh_sum = -180.0;
  else if (dh_sum > 180.0) dh_sum = 180.0;
  *shift = (int32_t)lround(dh_sum / 360.0 * (double)max_value);
  { const double sm = 1.0 + s_sum;
    *s_mul = sm < 0.0 ? 0.0 : (sm > 5.0 ? 5.0 : sm); }
  { const double lm = 1.0 + l_sum;
    *l_mul = lm < 0.0 ? 0.0 : (lm > 5.0 ? 5.0 : lm); }''');
  } else {
    // 串联：按段序级联，后段在前段更新后的中间色相上取权重（fmod 归一
    // 等价 Dart 欧几里得 %），首尾偏移取色环最短路径。
    compose.writeln('  double h_cur = h_deg;');
    compose.writeln('  double s_acc = 1.0, l_acc = 1.0;');
    for (var i = 0; i < bandCount; i++) {
      compose
        ..writeln(bandWeightLines(i, 'h_cur'))
        ..writeln('    s_acc *= 1.0 + w$i * (${cNum(bands[i].s)} - 1.0);')
        ..writeln('    l_acc *= 1.0 + w$i * (${cNum(bands[i].l)} - 1.0);')
        ..writeln('    h_cur = fmod(h_cur + w$i * ${cNum(bands[i].dh)}, 360.0);')
        ..writeln('    if (h_cur < 0.0) h_cur += 360.0;')
        ..writeln('  }');
    }
    compose.writeln('''
  { double dd = fmod(h_cur - h_deg, 360.0);
    if (dd < 0.0) dd += 360.0;
    if (dd > 180.0) dd -= 360.0;
    if (dd < -180.0) dd += 360.0;
    *shift = (int32_t)lround(dd / 360.0 * (double)max_value); }
  *s_mul = s_acc < 0.0 ? 0.0 : (s_acc > 5.0 ? 5.0 : s_acc);
  *l_mul = l_acc < 0.0 ? 0.0 : (l_acc > 5.0 ? 5.0 : l_acc);''');
  }
  compose.writeln('}');
  s.addFileDecl('${id}_compose', compose.toString());

  // LUT 模式：多段合成三表生成期烘焙（与整帧版同一路径）。
  final lutMode = ctx.strParam('codegenMode') == 'lut';
  final n = ctx.lutDomainMax;
  // LUT 定点模式（lut_fixed）：H 表同 lut（int16），S/L 乘子烘焙为 Q14
  // 定点整数表（bb_clamp_q14 整数乘加，面向 A55 等无 FP64 SIMD 的嵌入
  // 式核；与 FP64 口径偏差 ≤1 LSB）。域失配时与 lut 同口径回退 compose。
  final fixedMode = ctx.strParam('codegenMode') == 'lut_fixed';
  if (lutMode || fixedMode) {
    final (shiftLut, sMulLut, lMulLut) =
        multiBandLuts(bands, serial: serial, maxValue: n);
    s.addFileDecl('${id}_shift_lut', '''
/* multi_band_eq LUT 模式：H 偏移表生成期烘焙（Dart multiBandLuts，域
 * 0..$n；|shift| ≤ 域半宽 ±180° 恒成立，int16 足够且表 footprint/带宽
 * 减半——A55 D-Cache 只有 32KB）；max_value 一致走查表，不一致回退
 * ${id}_compose 直算。 */
static const int16_t ${id}_shift_lut[${n + 1}] = {
${cI32Table(shiftLut)}
};''');
    if (lutMode) {
      s.addFileDecl('${id}_s_mul_lut', '''
static const double ${id}_s_mul_lut[${n + 1}] = {
${cF64Table(sMulLut)}
};''');
      s.addFileDecl('${id}_l_mul_lut', '''
static const double ${id}_l_mul_lut[${n + 1}] = {
${cF64Table(lMulLut)}
};''');
      // 整行函数（标量）：仅当本节点独占一个零延迟阶段时被 top .c 调用
      //（见 group_c_export_bb 阶段发射特判，含 omp 行域并行）；其余形态
      // 走融合行核，两者逐位一致。
      s.addFileDecl('${id}_row', _lutRowFn(ctx.ident, n));
    } else {
      s.useHelper('bb_clamp_q14');
      s.addFileDecl('${id}_s_mul_q14', '''
/* S 乘子 Q14 定点表（生成期 round(mul × 2^14) 烘焙，配 bb_clamp_q14
 * 整数乘加；与 FP64 口径偏差 ≤1 LSB）。 */
static const int32_t ${id}_s_mul_q14[${n + 1}] = {
${cI32Table(Int32List.fromList([for (final v in sMulLut) (v * 16384.0).round()]))}
};''');
      s.addFileDecl('${id}_l_mul_q14', '''
/* L 乘子 Q14 定点表。 */
static const int32_t ${id}_l_mul_q14[${n + 1}] = {
${cI32Table(Int32List.fromList([for (final v in lMulLut) (v * 16384.0).round()]))}
};''');
      // 整行函数（ARM NEON / x86 SSE2 + 标量双变体，随导出目标 CPU 分叉，
      // 逐位一致）：仅当本节点独占一个零延迟阶段时被 top .c 调用（见
      // group_c_export_bb 阶段发射特判）；其余形态走融合行核（逐像素标量），
      // 两者逐位一致。
      s.addFileDecl('${id}_row', _lutFixedRowFn(ctx.ident, n, ctx.target));
    }
  }

  final hv = s.freshVar();
  final shift = s.freshVar();
  final sMul = s.freshVar();
  final lMul = s.freshVar();
  final hnew = s.freshVar();
  final o0 = s.freshVar();
  final o1 = s.freshVar();
  final o2 = s.freshVar();
  return (
    [
      'int $hv = ${ie[0]};',
      'if ($hv > max_value) $hv = max_value;',
      'int32_t $shift;',
      'double $sMul = 1.0, $lMul = 1.0;',
      if (lutMode) ...[
        'if (max_value == $n) {',
        '  $shift = ${id}_shift_lut[$hv];',
        '  $sMul = ${id}_s_mul_lut[$hv];',
        '  $lMul = ${id}_l_mul_lut[$hv];',
        '} else {',
        '  ${id}_compose($hv, max_value, &$shift, &$sMul, &$lMul);',
        '}',
      ] else if (fixedMode) ...[
        'if (max_value == $n) {',
        '  $shift = ${id}_shift_lut[$hv];',
        '} else {',
        '  ${id}_compose($hv, max_value, &$shift, &$sMul, &$lMul);',
        '}',
      ] else
        '${id}_compose($hv, max_value, &$shift, &$sMul, &$lMul);',
      // 色环回绕：烘焙/合成 shift 恒满足 |shift| ≤ max/2（dh ≤ ±180°，
      // 并联/串联均钳位）、hv ∈ [0,max]，单次条件加减与 % (max+1) 逐位
      // 一致——max_value 为运行时参数，% 退化为逐像素整数除法（实测占
      // 单帧耗时大头）。
      'int $hnew = $hv + $shift;',
      'if ($hnew > max_value) $hnew -= (max_value + 1);',
      'else if ($hnew < 0) $hnew += (max_value + 1);',
      'const uint16_t $o0 = (uint16_t)$hnew;',
      // lut_fixed：Q14 整数乘加（域一致时），域失配与 lut 同口径回退
      // compose 的 FP64 路径（$sMul/$lMul 恒被 compose 或默认 1.0 初始化，
      // 三目未选中分支不读取）。
      if (fixedMode) ...[
        'const uint16_t $o1 = (max_value == $n) ? bb_clamp_q14(${ie[1]}, ${id}_s_mul_q14[$hv], max_value) : bb_clamp_to((double)${ie[1]} * $sMul, max_value);',
        'const uint16_t $o2 = (max_value == $n) ? bb_clamp_q14(${ie[2]}, ${id}_l_mul_q14[$hv], max_value) : bb_clamp_to((double)${ie[2]} * $lMul, max_value);',
      ] else ...[
        'const uint16_t $o1 = bb_clamp_to((double)${ie[1]} * $sMul, max_value);',
        'const uint16_t $o2 = bb_clamp_to((double)${ie[2]} * $lMul, max_value);',
      ],
    ],
    {'out': [o0, o1, o2]},
  );
}

// ---------------------------------------------------------------------------
// 荧光 mono 域（逐像素子集）
// ---------------------------------------------------------------------------

/// lut_fixed 整行函数源码（[id] 前缀，烘焙域 [n]）：按导出目标 [target]
/// 分叉 SIMD 变体——ARM 目标为 NEON（守卫 `__ARM_NEON || __ARM_NEON__`，
/// 后者覆盖 A32/34/35 的 AArch32 gcc），x86 目标为 SSE2（守卫
/// `__SSE2__ / _M_X64 / _M_IX86_FP>=2`）；两变体与标量逐位一致；量化域
/// 失配整行走标量 compose 回退（与融合行核同口径）。
String _lutFixedRowFn(String id, int n, GroupCTarget target) {
  // 标量路径（含量化域失配的 compose 回退）：两目标共用，与融合行核逐位
  // 一致。
  final scalarTail = '''
  for (; x < w; x++) {
    /* 标量路径（含量化域失配的 compose 回退），与融合行核逐位一致。 */
    int hv = in[(size_t)x * 3u + 0u];
    int32_t shift;
    double s_mul = 1.0, l_mul = 1.0;
    if (hv > max_value) hv = max_value;
    if (max_value == $n) {
      shift = ${id}_shift_lut[hv];
    } else {
      ${id}_compose(hv, max_value, &shift, &s_mul, &l_mul);
    }
    {
      int hnew = hv + shift;
      if (hnew > max_value) {
        hnew -= (max_value + 1);
      } else if (hnew < 0) {
        hnew += (max_value + 1);
      }
      out[(size_t)x * 3u + 0u] = (uint16_t)hnew;
    }
    out[(size_t)x * 3u + 1u] = (max_value == $n)
        ? bb_clamp_q14(in[(size_t)x * 3u + 1u], ${id}_s_mul_q14[hv],
                       max_value)
        : bb_clamp_to((double)in[(size_t)x * 3u + 1u] * s_mul, max_value);
    out[(size_t)x * 3u + 2u] = (max_value == $n)
        ? bb_clamp_q14(in[(size_t)x * 3u + 2u], ${id}_l_mul_q14[hv],
                       max_value)
        : bb_clamp_to((double)in[(size_t)x * 3u + 2u] * l_mul, max_value);
  }
}''';
  if (target.isX86) {
    return '''
/* multi_band_eq lut_fixed 整行函数（SSE2/标量双变体，逐位一致；
 * 仅单节点独占阶段被调用，见 top .c 阶段发射）。 */
#if defined(__SSE2__) || defined(_M_X64) || (defined(_M_IX86_FP) && _M_IX86_FP >= 2)
#include <emmintrin.h>
#endif
static void ${id}_row(const uint16_t *in, uint16_t *out, int w,
                      int max_value) {
  int x = 0;
#if defined(__SSE2__) || defined(_M_X64) || (defined(_M_IX86_FP) && _M_IX86_FP >= 2)
  if (max_value == $n) {
    const int m = max_value + 1;
    const __m128i vmax16 = _mm_set1_epi16((short)max_value);
    const __m128i vm16 = _mm_set1_epi16((short)m);
    const __m128i vzero16 = _mm_setzero_si128();
    const __m128i vmax32 = _mm_set1_epi32(max_value);
    const __m128i vhalf = _mm_set1_epi32(8192);
    /* q ≥ 2^14 判定：SSE2 无 cmpge，cmpgt(q, 16383) 等价。 */
    const __m128i vq14m1 = _mm_set1_epi32(16383);
    const __m128i vzero32 = _mm_setzero_si128();
    /* u32→u16 窄化打包偏置：packs_epi32 为带符号饱和（值域已钳 [0, max]
     * 可能超 32767），先移偏到 [-2^15, 2^15) 打包再加回，与 NEON vmovn
     * 截断逐位一致。 */
    const __m128i vbias32 = _mm_set1_epi32(0x8000);
    /* 0x8000 的 16 位形态（-32768，避免 MSVC C4310 常量截断警告）。 */
    const __m128i vbias16 = _mm_set1_epi16(-32768);
    /* 单 16 位 lane 掩码（解/重交织按位提取通道用）。 */
    const __m128i lm0 = _mm_setr_epi16(-1, 0, 0, 0, 0, 0, 0, 0);
    const __m128i lm1 = _mm_setr_epi16(0, -1, 0, 0, 0, 0, 0, 0);
    const __m128i lm2 = _mm_setr_epi16(0, 0, -1, 0, 0, 0, 0, 0);
    const __m128i lm3 = _mm_setr_epi16(0, 0, 0, -1, 0, 0, 0, 0);
    const __m128i lm4 = _mm_setr_epi16(0, 0, 0, 0, -1, 0, 0, 0);
    const __m128i lm5 = _mm_setr_epi16(0, 0, 0, 0, 0, -1, 0, 0);
    const __m128i lm6 = _mm_setr_epi16(0, 0, 0, 0, 0, 0, -1, 0);
    const __m128i lm7 = _mm_setr_epi16(0, 0, 0, 0, 0, 0, 0, -1);
    for (; x + 8 <= w; x += 8) {
      /* 8 像素：and/字节移位/or 解交织（SSE2 无 VLD3/pshufb）→ 通道标量
       * gather（SSE2 无 gather 指令）→ 向量回绕/乘加 → 重交织写回。 */
      const __m128i i0 =
          _mm_loadu_si128((const __m128i *)(in + (size_t)x * 3u));
      const __m128i i1 =
          _mm_loadu_si128((const __m128i *)(in + (size_t)x * 3u + 8u));
      const __m128i i2 =
          _mm_loadu_si128((const __m128i *)(in + (size_t)x * 3u + 16u));
      /* H：i0 lanes 0/3/6，i1 lanes 1/4/7，i2 lanes 2/5。 */
      const __m128i hvv = _mm_or_si128(
          _mm_or_si128(
              _mm_or_si128(_mm_and_si128(i0, lm0),
                           _mm_and_si128(_mm_srli_si128(i0, 4), lm1)),
              _mm_or_si128(_mm_and_si128(_mm_srli_si128(i0, 8), lm2),
                           _mm_and_si128(_mm_slli_si128(i1, 4), lm3))),
          _mm_or_si128(
              _mm_or_si128(_mm_and_si128(i1, lm4),
                           _mm_and_si128(_mm_srli_si128(i1, 4), lm5)),
              _mm_or_si128(_mm_and_si128(_mm_slli_si128(i2, 8), lm6),
                           _mm_and_si128(_mm_slli_si128(i2, 4), lm7))));
      /* S：i0 lanes 1/4/7，i1 lanes 2/5，i2 lanes 0/3/6。 */
      const __m128i sv = _mm_or_si128(
          _mm_or_si128(
              _mm_or_si128(_mm_and_si128(_mm_srli_si128(i0, 2), lm0),
                           _mm_and_si128(_mm_srli_si128(i0, 6), lm1)),
              _mm_or_si128(_mm_and_si128(_mm_srli_si128(i0, 10), lm2),
                           _mm_and_si128(_mm_slli_si128(i1, 2), lm3))),
          _mm_or_si128(
              _mm_or_si128(_mm_and_si128(_mm_srli_si128(i1, 2), lm4),
                           _mm_and_si128(_mm_slli_si128(i2, 10), lm5)),
              _mm_or_si128(_mm_and_si128(_mm_slli_si128(i2, 6), lm6),
                           _mm_and_si128(_mm_slli_si128(i2, 2), lm7))));
      /* L：i0 lanes 2/5，i1 lanes 0/3/6，i2 lanes 1/4/7。 */
      const __m128i lv = _mm_or_si128(
          _mm_or_si128(
              _mm_or_si128(_mm_and_si128(_mm_srli_si128(i0, 4), lm0),
                           _mm_and_si128(_mm_srli_si128(i0, 8), lm1)),
              _mm_or_si128(_mm_and_si128(_mm_slli_si128(i1, 4), lm2),
                           _mm_and_si128(i1, lm3))),
          _mm_or_si128(
              _mm_or_si128(_mm_and_si128(_mm_srli_si128(i1, 4), lm4),
                           _mm_and_si128(_mm_slli_si128(i2, 8), lm5)),
              _mm_or_si128(_mm_and_si128(_mm_slli_si128(i2, 4), lm6),
                           _mm_and_si128(i2, lm7))));
      uint16_t h[8];
      int16_t sh[8];
      int32_t qs[8], ql[8];
      int k;
      _mm_storeu_si128((__m128i *)h, hvv);
      for (k = 0; k < 8; k++) {
        int hvc = h[k];
        if (hvc > max_value) hvc = max_value;
        h[k] = (uint16_t)hvc;
        sh[k] = ${id}_shift_lut[hvc];
        qs[k] = ${id}_s_mul_q14[hvc];
        ql[k] = ${id}_l_mul_q14[hvc];
      }
      /* H：int16 通道单次条件回绕（|shift| ≤ max/2 恒成立）。 */
      __m128i hnew = _mm_add_epi16(_mm_loadu_si128((const __m128i *)h),
                                   _mm_loadu_si128((const __m128i *)sh));
      {
        const __m128i gt = _mm_cmpgt_epi16(hnew, vmax16);
        hnew = _mm_or_si128(_mm_and_si128(gt, _mm_sub_epi16(hnew, vm16)),
                            _mm_andnot_si128(gt, hnew));
      }
      {
        const __m128i lt = _mm_cmpgt_epi16(vzero16, hnew);
        hnew = _mm_or_si128(_mm_and_si128(lt, _mm_add_epi16(hnew, vm16)),
                            _mm_andnot_si128(lt, hnew));
      }
      /* S/L：bb_clamp_q14 同口径——q ≥ 2^14 且超域先钳输入（与先乘加
       * 后钳位结果一致），32 位乘加（SSE2 无 _mm_mullo_epi32：
       * _mm_mul_epu32 偶/奇 lane 双趟取积低 32 位重组，与 NEON
       * vmulq_s32 低 32 位同）、移位、[0, max] 钳位、窄化打包。 */
      __m128i so, lo;
      {
        const __m128i q0 = _mm_loadu_si128((const __m128i *)qs);
        const __m128i q1 = _mm_loadu_si128((const __m128i *)(qs + 4));
        __m128i a0 = _mm_unpacklo_epi16(sv, vzero16);
        __m128i a1 = _mm_unpackhi_epi16(sv, vzero16);
        __m128i r0, r1;
        {
          const __m128i mk0 = _mm_and_si128(_mm_cmpgt_epi32(a0, vmax32),
                                            _mm_cmpgt_epi32(q0, vq14m1));
          const __m128i mk1 = _mm_and_si128(_mm_cmpgt_epi32(a1, vmax32),
                                            _mm_cmpgt_epi32(q1, vq14m1));
          a0 = _mm_or_si128(_mm_and_si128(mk0, vmax32),
                            _mm_andnot_si128(mk0, a0));
          a1 = _mm_or_si128(_mm_and_si128(mk1, vmax32),
                            _mm_andnot_si128(mk1, a1));
        }
        r0 = _mm_srai_epi32(
            _mm_add_epi32(
                _mm_unpacklo_epi32(
                    _mm_shuffle_epi32(_mm_mul_epu32(a0, q0),
                                      _MM_SHUFFLE(2, 0, 2, 0)),
                    _mm_shuffle_epi32(
                        _mm_mul_epu32(_mm_srli_epi64(a0, 32),
                                      _mm_srli_epi64(q0, 32)),
                        _MM_SHUFFLE(2, 0, 2, 0))),
                vhalf),
            14);
        r1 = _mm_srai_epi32(
            _mm_add_epi32(
                _mm_unpacklo_epi32(
                    _mm_shuffle_epi32(_mm_mul_epu32(a1, q1),
                                      _MM_SHUFFLE(2, 0, 2, 0)),
                    _mm_shuffle_epi32(
                        _mm_mul_epu32(_mm_srli_epi64(a1, 32),
                                      _mm_srli_epi64(q1, 32)),
                        _MM_SHUFFLE(2, 0, 2, 0))),
                vhalf),
            14);
        {
          const __m128i gt0 = _mm_cmpgt_epi32(r0, vmax32);
          const __m128i gt1 = _mm_cmpgt_epi32(r1, vmax32);
          r0 = _mm_or_si128(_mm_and_si128(gt0, vmax32),
                            _mm_andnot_si128(gt0, r0));
          r1 = _mm_or_si128(_mm_and_si128(gt1, vmax32),
                            _mm_andnot_si128(gt1, r1));
          r0 = _mm_andnot_si128(_mm_cmpgt_epi32(vzero32, r0), r0);
          r1 = _mm_andnot_si128(_mm_cmpgt_epi32(vzero32, r1), r1);
        }
        so = _mm_add_epi16(
            _mm_packs_epi32(_mm_sub_epi32(r0, vbias32),
                            _mm_sub_epi32(r1, vbias32)),
            vbias16);
      }
      {
        const __m128i q0 = _mm_loadu_si128((const __m128i *)ql);
        const __m128i q1 = _mm_loadu_si128((const __m128i *)(ql + 4));
        __m128i a0 = _mm_unpacklo_epi16(lv, vzero16);
        __m128i a1 = _mm_unpackhi_epi16(lv, vzero16);
        __m128i r0, r1;
        {
          const __m128i mk0 = _mm_and_si128(_mm_cmpgt_epi32(a0, vmax32),
                                            _mm_cmpgt_epi32(q0, vq14m1));
          const __m128i mk1 = _mm_and_si128(_mm_cmpgt_epi32(a1, vmax32),
                                            _mm_cmpgt_epi32(q1, vq14m1));
          a0 = _mm_or_si128(_mm_and_si128(mk0, vmax32),
                            _mm_andnot_si128(mk0, a0));
          a1 = _mm_or_si128(_mm_and_si128(mk1, vmax32),
                            _mm_andnot_si128(mk1, a1));
        }
        r0 = _mm_srai_epi32(
            _mm_add_epi32(
                _mm_unpacklo_epi32(
                    _mm_shuffle_epi32(_mm_mul_epu32(a0, q0),
                                      _MM_SHUFFLE(2, 0, 2, 0)),
                    _mm_shuffle_epi32(
                        _mm_mul_epu32(_mm_srli_epi64(a0, 32),
                                      _mm_srli_epi64(q0, 32)),
                        _MM_SHUFFLE(2, 0, 2, 0))),
                vhalf),
            14);
        r1 = _mm_srai_epi32(
            _mm_add_epi32(
                _mm_unpacklo_epi32(
                    _mm_shuffle_epi32(_mm_mul_epu32(a1, q1),
                                      _MM_SHUFFLE(2, 0, 2, 0)),
                    _mm_shuffle_epi32(
                        _mm_mul_epu32(_mm_srli_epi64(a1, 32),
                                      _mm_srli_epi64(q1, 32)),
                        _MM_SHUFFLE(2, 0, 2, 0))),
                vhalf),
            14);
        {
          const __m128i gt0 = _mm_cmpgt_epi32(r0, vmax32);
          const __m128i gt1 = _mm_cmpgt_epi32(r1, vmax32);
          r0 = _mm_or_si128(_mm_and_si128(gt0, vmax32),
                            _mm_andnot_si128(gt0, r0));
          r1 = _mm_or_si128(_mm_and_si128(gt1, vmax32),
                            _mm_andnot_si128(gt1, r1));
          r0 = _mm_andnot_si128(_mm_cmpgt_epi32(vzero32, r0), r0);
          r1 = _mm_andnot_si128(_mm_cmpgt_epi32(vzero32, r1), r1);
        }
        lo = _mm_add_epi16(
            _mm_packs_epi32(_mm_sub_epi32(r0, vbias32),
                            _mm_sub_epi32(r1, vbias32)),
            vbias16);
      }
      {
        /* 重交织写回（H/S/L → 连续 3 通道，与解交织互逆）。 */
        const __m128i o0 = _mm_or_si128(
            _mm_or_si128(
                _mm_or_si128(_mm_and_si128(hnew, lm0),
                             _mm_and_si128(_mm_slli_si128(so, 2), lm1)),
                _mm_or_si128(_mm_and_si128(_mm_slli_si128(lo, 4), lm2),
                             _mm_and_si128(_mm_slli_si128(hnew, 4), lm3))),
            _mm_or_si128(
                _mm_or_si128(_mm_and_si128(_mm_slli_si128(so, 6), lm4),
                             _mm_and_si128(_mm_slli_si128(lo, 8), lm5)),
                _mm_or_si128(_mm_and_si128(_mm_slli_si128(hnew, 8), lm6),
                             _mm_and_si128(_mm_slli_si128(so, 10), lm7))));
        const __m128i o1 = _mm_or_si128(
            _mm_or_si128(
                _mm_or_si128(_mm_and_si128(_mm_srli_si128(lo, 4), lm0),
                             _mm_and_si128(_mm_srli_si128(hnew, 4), lm1)),
                _mm_or_si128(_mm_and_si128(_mm_srli_si128(so, 2), lm2),
                             _mm_and_si128(lo, lm3))),
            _mm_or_si128(
                _mm_or_si128(_mm_and_si128(hnew, lm4),
                             _mm_and_si128(_mm_slli_si128(so, 2), lm5)),
                _mm_or_si128(_mm_and_si128(_mm_slli_si128(lo, 4), lm6),
                             _mm_and_si128(_mm_slli_si128(hnew, 4), lm7))));
        const __m128i o2 = _mm_or_si128(
            _mm_or_si128(
                _mm_or_si128(_mm_and_si128(_mm_srli_si128(so, 10), lm0),
                             _mm_and_si128(_mm_srli_si128(lo, 8), lm1)),
                _mm_or_si128(_mm_and_si128(_mm_srli_si128(hnew, 8), lm2),
                             _mm_and_si128(_mm_srli_si128(so, 6), lm3))),
            _mm_or_si128(
                _mm_or_si128(_mm_and_si128(_mm_srli_si128(lo, 4), lm4),
                             _mm_and_si128(_mm_srli_si128(hnew, 4), lm5)),
                _mm_or_si128(_mm_and_si128(_mm_srli_si128(so, 2), lm6),
                             _mm_and_si128(lo, lm7))));
        _mm_storeu_si128((__m128i *)(out + (size_t)x * 3u), o0);
        _mm_storeu_si128((__m128i *)(out + (size_t)x * 3u + 8u), o1);
        _mm_storeu_si128((__m128i *)(out + (size_t)x * 3u + 16u), o2);
      }
    }
  }
#endif
$scalarTail''';
  }
  return '''
/* multi_band_eq lut_fixed 整行函数（NEON/标量双变体，逐位一致；
 * 仅单节点独占阶段被调用，见 top .c 阶段发射）。 */
#if defined(__ARM_NEON) || defined(__ARM_NEON__)
#include <arm_neon.h>
#endif
static void ${id}_row(const uint16_t *in, uint16_t *out, int w,
                      int max_value) {
  int x = 0;
#if defined(__ARM_NEON) || defined(__ARM_NEON__)
  if (max_value == $n) {
    const int m = max_value + 1;
    const int16x8_t vmax16 = vdupq_n_s16((int16_t)max_value);
    const int16x8_t vm16 = vdupq_n_s16((int16_t)m);
    const uint32x4_t vmax32 = vdupq_n_u32((uint32_t)max_value);
    const int32x4_t vhalf = vdupq_n_s32(8192);
    const int32x4_t vq14 = vdupq_n_s32(16384);
    const int32x4_t vzero32 = vdupq_n_s32(0);
    for (; x + 8 <= w; x += 8) {
      /* 8 像素：VLD3 解交织 → 通道标量 gather（NEON 无 gather 指令）→
       * 向量回绕/乘加 → VST3 重交织。 */
      const uint16x8x3_t px = vld3q_u16(in + (size_t)x * 3u);
      uint16_t h[8];
      int16_t sh[8];
      int32_t qs[8], ql[8];
      int k;
      vst1q_u16(h, px.val[0]);
      for (k = 0; k < 8; k++) {
        int hv = h[k];
        if (hv > max_value) hv = max_value;
        h[k] = (uint16_t)hv;
        sh[k] = ${id}_shift_lut[hv];
        qs[k] = ${id}_s_mul_q14[hv];
        ql[k] = ${id}_l_mul_q14[hv];
      }
      /* H：int16 通道单次条件回绕（|shift| ≤ max/2 恒成立）。 */
      int16x8_t hnew = vaddq_s16(vld1q_s16((const int16_t *)h), vld1q_s16(sh));
      {
        const int16x8_t sub = vsubq_s16(hnew, vm16);
        const int16x8_t add = vaddq_s16(hnew, vm16);
        hnew = vbslq_s16(vcgtq_s16(hnew, vmax16), sub, hnew);
        hnew = vbslq_s16(vcltq_s16(hnew, vdupq_n_s16(0)), add, hnew);
      }
      /* S/L：bb_clamp_q14 同口径——q ≥ 2^14 且超域先钳输入（与先乘加
       * 后钳位结果一致），32 位乘加、移位、[0, max] 钳位、窄化。 */
      uint16x8_t so, lo;
      {
        const int32x4_t q0 = vld1q_s32(qs), q1 = vld1q_s32(qs + 4);
        uint32x4_t a0 = vmovl_u16(vget_low_u16(px.val[1]));
        uint32x4_t a1 = vmovl_u16(vget_high_u16(px.val[1]));
        int32x4_t r0, r1;
        a0 = vbslq_u32(
            vandq_u32(vcgtq_u32(a0, vmax32), vcgeq_s32(q0, vq14)),
            vmax32, a0);
        a1 = vbslq_u32(
            vandq_u32(vcgtq_u32(a1, vmax32), vcgeq_s32(q1, vq14)),
            vmax32, a1);
        r0 = vshrq_n_s32(
            vaddq_s32(vmulq_s32(vreinterpretq_s32_u32(a0), q0), vhalf), 14);
        r1 = vshrq_n_s32(
            vaddq_s32(vmulq_s32(vreinterpretq_s32_u32(a1), q1), vhalf), 14);
        r0 = vminq_s32(vmaxq_s32(r0, vzero32),
                       vreinterpretq_s32_u32(vmax32));
        r1 = vminq_s32(vmaxq_s32(r1, vzero32),
                       vreinterpretq_s32_u32(vmax32));
        so = vcombine_u16(vmovn_u32(vreinterpretq_u32_s32(r0)),
                          vmovn_u32(vreinterpretq_u32_s32(r1)));
      }
      {
        const int32x4_t q0 = vld1q_s32(ql), q1 = vld1q_s32(ql + 4);
        uint32x4_t a0 = vmovl_u16(vget_low_u16(px.val[2]));
        uint32x4_t a1 = vmovl_u16(vget_high_u16(px.val[2]));
        int32x4_t r0, r1;
        a0 = vbslq_u32(
            vandq_u32(vcgtq_u32(a0, vmax32), vcgeq_s32(q0, vq14)),
            vmax32, a0);
        a1 = vbslq_u32(
            vandq_u32(vcgtq_u32(a1, vmax32), vcgeq_s32(q1, vq14)),
            vmax32, a1);
        r0 = vshrq_n_s32(
            vaddq_s32(vmulq_s32(vreinterpretq_s32_u32(a0), q0), vhalf), 14);
        r1 = vshrq_n_s32(
            vaddq_s32(vmulq_s32(vreinterpretq_s32_u32(a1), q1), vhalf), 14);
        r0 = vminq_s32(vmaxq_s32(r0, vzero32),
                       vreinterpretq_s32_u32(vmax32));
        r1 = vminq_s32(vmaxq_s32(r1, vzero32),
                       vreinterpretq_s32_u32(vmax32));
        lo = vcombine_u16(vmovn_u32(vreinterpretq_u32_s32(r0)),
                          vmovn_u32(vreinterpretq_u32_s32(r1)));
      }
      {
        uint16x8x3_t opx;
        opx.val[0] = vreinterpretq_u16_s16(hnew);
        opx.val[1] = so;
        opx.val[2] = lo;
        vst3q_u16(out + (size_t)x * 3u, opx);
      }
    }
  }
#endif
$scalarTail''';
}

/// lut 整行函数源码（[id] 前缀，烘焙域 [n]）：标量（FP64 三表查表 +
/// bb_clamp_to 乘加），与融合行核逐位一致；量化域失配整行走 compose
/// 回退（与融合行核同口径）。面向 PC/验证程序的多核行域并行（top 层
/// omp pragma）；嵌入式无 FP64 SIMD 的定点场景用 lut_fixed（Q14 +
/// NEON/SSE2 行核，随导出目标分叉）。
String _lutRowFn(String id, int n) {
  return '''
/* multi_band_eq lut 整行函数（标量，与融合行核逐位一致；
 * 仅单节点独占阶段被调用，见 top .c 阶段发射）。 */
static void ${id}_row(const uint16_t *in, uint16_t *out, int w,
                      int max_value) {
  int x;
  for (x = 0; x < w; x++) {
    /* 标量路径（含量化域失配的 compose 回退），与融合行核逐位一致。 */
    int hv = in[(size_t)x * 3u + 0u];
    int32_t shift;
    double s_mul = 1.0, l_mul = 1.0;
    if (hv > max_value) hv = max_value;
    if (max_value == $n) {
      shift = ${id}_shift_lut[hv];
      s_mul = ${id}_s_mul_lut[hv];
      l_mul = ${id}_l_mul_lut[hv];
    } else {
      ${id}_compose(hv, max_value, &shift, &s_mul, &l_mul);
    }
    {
      int hnew = hv + shift;
      if (hnew > max_value) {
        hnew -= (max_value + 1);
      } else if (hnew < 0) {
        hnew += (max_value + 1);
      }
      out[(size_t)x * 3u + 0u] = (uint16_t)hnew;
    }
    out[(size_t)x * 3u + 1u] =
        bb_clamp_to((double)in[(size_t)x * 3u + 1u] * s_mul, max_value);
    out[(size_t)x * 3u + 2u] =
        bb_clamp_to((double)in[(size_t)x * 3u + 2u] * l_mul, max_value);
  }
}''';
}

// ---------------------------------------------------------------------------
// 荧光 mono 域（逐像素子集）
// ---------------------------------------------------------------------------

/// fluoro_leak：激发泄漏统一电平扣除（sub = min(level, maxSub)，sub <= 0
/// 时 c_ref 直通——生成期判定同结果）。出处：isp_fluoro.c
/// isp_fluoro_leak_apply（v <= 0 写 0，否则 round，无上限钳位）。
StreamKernelResult _kFluoroLeak(
    StreamKernelCtx s, CNodeGenCtx ctx, Map<String, List<String>?> inputs) {
  final ie = _in(inputs, 'in_mono');
  if (ctx.boolParam('bypass')) return _alias(ie, 'out_mono');
  final level = ctx.doubleParam('level');
  final maxSub = ctx.doubleParam('maxSub');
  final sub = level < maxSub ? level : maxSub;
  if (sub <= 0.0) return _alias(ie, 'out_mono');
  s.useHelper('bb_round_pos');
  final v = s.freshVar();
  final o = s.freshVar();
  return (
    [
      'const double $v = (double)${ie[0]} - ${cNum(sub)};',
      'const uint16_t $o = ($v <= 0.0) ? (uint16_t)0 : bb_round_pos($v);',
    ],
    {'out_mono': [o]},
  );
}

/// pseudo_color：mono → 伪彩 RGB（链尾映射）。出处：isp_fluoro.c
/// isp_fluoro_pseudo_color_apply（t = mono × gain / max_value 钳位 [0,1]
/// 后查色表）与 isp_fluoro__colormap。Bypass 退化为灰度直通（mono 原值
/// 复制到三通道，与整帧版一致）。LUT 模式（codegenMode=lut）：三通道
/// 色表生成期烘焙（Dart pseudoColorLuts），max_value 一致走查表
/// （isp_fluoro_pseudo_color_lut_apply 语义），不一致回退直算。
/// pseudo_color 整行行核可用性（与 [_kPseudoColor] 同口径）：非 bypass、
/// LUT 模式。
bool pseudoColorRowOk(Map<String, dynamic> params) {
  if (params['bypass'] == true) return false;
  return params['codegenMode'] == 'lut';
}

/// pseudo_color（LUT 模式）整行函数源码（[id] 前缀，烘焙域 [n]）：
/// NEON/SSE2 + 标量双变体（随导出目标分叉）。mono 1 通道输入 → RGB 三
/// 通道输出；域匹配（max_value == n）走 SIMD gather（同一索引查三张色表）；
/// 域失配标量回退（t 钳位后按色表直算），与融合行核逐位一致。
String _pseudoColorRowFn(
    String id, int n, double gain, String colormap, GroupCTarget target) {
  final (re, ge, be) = switch (colormap) {
    'magenta' => ('t_', '0.0', 't_'),
    'hot' => (
        'ISP_MIN(3.0 * t_, 1.0)',
        'bb_clamp01(3.0 * t_ - 1.0)',
        'bb_clamp01(3.0 * t_ - 2.0)',
      ),
    _ => ('0.0', 't_', '0.0'), // green（ICG 荧光惯例；未知值同兜底）
  };
  final scalarTail = '''
  for (; x < w; x++) {
    const double t_ = bb_clamp01((double)in[x] * ${cNum(gain)} * (1.0 / max_value));
    out[(size_t)x * 3u + 0u] = (max_value == $n)
        ? ${id}_lut_r[in[x]] : bb_clamp_to($re * max_value, max_value);
    out[(size_t)x * 3u + 1u] = (max_value == $n)
        ? ${id}_lut_g[in[x]] : bb_clamp_to($ge * max_value, max_value);
    out[(size_t)x * 3u + 2u] = (max_value == $n)
        ? ${id}_lut_b[in[x]] : bb_clamp_to($be * max_value, max_value);
  }
}''';
  if (target.isX86) {
    final masks = '    const __m128i lm0 = _mm_setr_epi16(-1, 0, 0, 0, 0, 0, 0, 0);\n'
        '    const __m128i lm1 = _mm_setr_epi16(0, -1, 0, 0, 0, 0, 0, 0);\n'
        '    const __m128i lm2 = _mm_setr_epi16(0, 0, -1, 0, 0, 0, 0, 0);\n'
        '    const __m128i lm3 = _mm_setr_epi16(0, 0, 0, -1, 0, 0, 0, 0);\n'
        '    const __m128i lm4 = _mm_setr_epi16(0, 0, 0, 0, -1, 0, 0, 0);\n'
        '    const __m128i lm5 = _mm_setr_epi16(0, 0, 0, 0, 0, -1, 0, 0);\n'
        '    const __m128i lm6 = _mm_setr_epi16(0, 0, 0, 0, 0, 0, -1, 0);\n'
        '    const __m128i lm7 = _mm_setr_epi16(0, 0, 0, 0, 0, 0, 0, -1);\n';
    final reint =
        _sse2Reinterleave3('lrv', 'lgv', 'lbv', 'o0', 'o1', 'o2').join('\n');
    return '''
/* pseudo_color LUT 模式整行函数（SSE2/标量双变体，逐位一致；
 * 仅单节点独占阶段被调用，见 top .c 阶段发射）。 */
#if defined(__SSE2__) || defined(_M_X64) || (defined(_M_IX86_FP) && _M_IX86_FP >= 2)
#include <emmintrin.h>
#endif
static void ${id}_row(const uint16_t *in, uint16_t *out, int w,
                      int max_value) {
  int x = 0;
#if defined(__SSE2__) || defined(_M_X64) || (defined(_M_IX86_FP) && _M_IX86_FP >= 2)
  if (max_value == $n) {
$masks    for (; x + 8 <= w; x += 8) {
      const __m128i pv = _mm_loadu_si128((const __m128i *)(in + (size_t)x));
      uint16_t t_[8], lr_[8], lg_[8], lb_[8];
      int k;
      _mm_storeu_si128((__m128i *)t_, pv);
      for (k = 0; k < 8; k++) {
        lr_[k] = ${id}_lut_r[t_[k]];
        lg_[k] = ${id}_lut_g[t_[k]];
        lb_[k] = ${id}_lut_b[t_[k]];
      }
      const __m128i lrv = _mm_loadu_si128((const __m128i *)lr_);
      const __m128i lgv = _mm_loadu_si128((const __m128i *)lg_);
      const __m128i lbv = _mm_loadu_si128((const __m128i *)lb_);
$reint      _mm_storeu_si128((__m128i *)(out + (size_t)x * 3u), o0);
      _mm_storeu_si128((__m128i *)(out + (size_t)x * 3u + 8u), o1);
      _mm_storeu_si128((__m128i *)(out + (size_t)x * 3u + 16u), o2);
    }
  }
#endif
$scalarTail''';
  }
  return '''
/* pseudo_color LUT 模式整行函数（NEON/标量双变体，逐位一致；
 * 仅单节点独占阶段被调用，见 top .c 阶段发射）。 */
#if defined(__ARM_NEON) || defined(__ARM_NEON__)
#include <arm_neon.h>
#endif
static void ${id}_row(const uint16_t *in, uint16_t *out, int w,
                      int max_value) {
  int x = 0;
#if defined(__ARM_NEON) || defined(__ARM_NEON__)
  if (max_value == $n) {
    for (; x + 8 <= w; x += 8) {
      /* 8 像素：mono VLD1 → 标量 gather 查三张色表 → VST3 重交织。 */
      const uint16x8_t pv = vld1q_u16(in + (size_t)x);
      uint16_t t_[8], lr_[8], lg_[8], lb_[8];
      int k;
      vst1q_u16(t_, pv);
      for (k = 0; k < 8; k++) {
        lr_[k] = ${id}_lut_r[t_[k]];
        lg_[k] = ${id}_lut_g[t_[k]];
        lb_[k] = ${id}_lut_b[t_[k]];
      }
      uint16x8x3_t opx;
      opx.val[0] = vld1q_u16(lr_);
      opx.val[1] = vld1q_u16(lg_);
      opx.val[2] = vld1q_u16(lb_);
      vst3q_u16(out + (size_t)x * 3u, opx);
    }
  }
#endif
$scalarTail''';
}

StreamKernelResult _kPseudoColor(
    StreamKernelCtx s, CNodeGenCtx ctx, Map<String, List<String>?> inputs) {
  final ie = _in(inputs, 'in_mono');
  if (ctx.boolParam('bypass')) {
    return (const [], {
      'out': [ie[0], ie[0], ie[0]],
    });
  }
  final gain = ctx.doubleParam('gain');
  final lutMode = ctx.strParam('codegenMode') == 'lut';
  s.useHelper('bb_clamp_to');
  final lines = <String>[];
  if (lutMode) {
    final n = ctx.lutDomainMax;
    final (lutR, lutG, lutB) =
        pseudoColorLuts(ctx.strParam('colormap'), gain, n);
    for (final (name, lut) in [('lut_r', lutR), ('lut_g', lutG), ('lut_b', lutB)]) {
      s.addFileDecl('${ctx.ident}_$name', '''
/* pseudo_color LUT 模式：三通道色表生成期烘焙（Dart pseudoColorLuts，
 * 域 0..$n）；max_value 一致走查表，不一致回退直算（同公式）。 */
static const uint16_t ${ctx.ident}_$name[${n + 1}] = {
${cU16Table(lut)}
};''');
    }
    // 整行行核（NEON/SSE2/标量双变体，随导出目标分叉；仅单节点独占阶段
    // 被调用，见 group_c_export_bb 阶段发射特判）。登记在三表之后。
    s.addFileDecl('${ctx.ident}_row', _pseudoColorRowFn(
        ctx.ident, n, gain, ctx.strParam('colormap'), ctx.target));
  }
  // 直算路径（LUT 回退分支同用）：t 钳位 [0,1] 后按烘焙色表映射。
  final t = s.freshVar();
  lines.add('const double $t = bb_clamp01((double)${ie[0]} * ${cNum(gain)} * (1.0 / max_value));');
  s.useHelper('bb_clamp01');
  final (re, ge, be) = switch (ctx.strParam('colormap')) {
    'magenta' => (t, '0.0', t),
    'hot' => (
        'ISP_MIN(3.0 * $t, 1.0)',
        'bb_clamp01(3.0 * $t - 1.0)',
        'bb_clamp01(3.0 * $t - 2.0)',
      ),
    _ => ('0.0', t, '0.0'), // green（ICG 荧光惯例；未知值同兜底）
  };
  final outs = <String>[];
  for (var c = 0; c < 3; c++) {
    final o = s.freshVar();
    final lutExpr = '${ctx.ident}_lut_${'rgb'[c]}[${ie[0]}]';
    final directExpr = 'bb_clamp_to(${[re, ge, be][c]} * max_value, max_value)';
    lines.add(lutMode
        ? 'const uint16_t $o = (max_value == ${ctx.lutDomainMax}) ? $lutExpr : $directExpr;'
        : 'const uint16_t $o = $directExpr;');
    outs.add(o);
  }
  return (lines, {'out': outs});
}

// ---------------------------------------------------------------------------
// Datapath 域
// ---------------------------------------------------------------------------

/// 分路器：交织三通道 → 三个单通道平面（纯数据搬运，通道别名零语句）。
/// 输入格式非本域时按 pipeline_runner 兜底语义先转换再拆（出处：
/// isp_split.c isp_split3_impl + node_c_gen_datapath.dart 的转换分支）：
/// rgb_splitter 收 yuv/hsl（yuv2rgb / hsl2rgb），yuv/hsl_splitter 收 rgb
/// （rgb2yuv BT.601 全范围 / rgb2hsl）。
StreamKernelResult _kSplitter(StreamKernelCtx s, CNodeGenCtx ctx,
    Map<String, List<String>?> inputs, String domain) {
  final fmt = ctx.inputFormats['in'] ?? domain;
  final ie = _in(inputs, 'in');
  final outNames = switch (domain) {
    'yuv' => const ['out_y', 'out_u', 'out_v'],
    'hsl' => const ['out_h', 'out_s', 'out_l'],
    _ => const ['out_r', 'out_g', 'out_b'],
  };
  final variant = switch ((domain, fmt)) {
    ('rgb', 'yuv') => 'yuv2rgb',
    ('rgb', 'hsl') => 'hsl2rgb',
    ('yuv', 'rgb') => 'rgb2yuv601',
    ('hsl', 'rgb') => 'rgb2hsl',
    _ => null, // 本域直拆
  };
  if (variant == null) {
    return (
      const [],
      {for (var c = 0; c < 3; c++) outNames[c]: [ie[c]]},
    );
  }
  final lines = <String>[];
  final ch = _emitCscPx(s, variant, ie, lines);
  return (
    lines,
    {for (var c = 0; c < 3; c++) outNames[c]: [ch[c]]},
  );
}

/// 合路器：三个单通道平面 → 交织三通道帧（通道别名零语句）。未连接的
/// 通道输入直接发射缺省常量（整帧版传 NULL 由 c_ref 填缺省值，出处：
/// isp_split.c isp_combine3_impl / isp_combine_yuv 的 mid = max >> 1）：
/// YUV 的 U/V 缺省 max_value>>1，其余缺省 0。
StreamKernelResult _kCombiner(StreamKernelCtx s, CNodeGenCtx ctx,
    Map<String, List<String>?> inputs, String domain) {
  final inNames = switch (domain) {
    'yuv' => const ['in_y', 'in_u', 'in_v'],
    'hsl' => const ['in_h', 'in_s', 'in_l'],
    _ => const ['in_r', 'in_g', 'in_b'],
  };
  final defs = switch (domain) {
    'yuv' => const ['0', '((uint16_t)(max_value >> 1))', '((uint16_t)(max_value >> 1))'],
    _ => const ['0', '0', '0'],
  };
  return (
    const [],
    {
      'out': [
        for (var c = 0; c < 3; c++) inputs[inNames[c]]?[0] ?? defs[c],
      ],
    },
  );
}

/// multiplier：双 mono 归一化相乘 out=(a+offset1)×(b+offset2)/maxValue。
/// 出处：isp_blend.c isp_blend_multiply（全程双精度 + _clampTo 收尾）。
StreamKernelResult _kMultiplier(
    StreamKernelCtx s, CNodeGenCtx ctx, Map<String, List<String>?> inputs) {
  final a = _in(inputs, 'in_mono');
  final b = _in(inputs, 'in_mono2');
  s.useHelper('bb_clamp_to');
  final o = s.freshVar();
  return (
    [
      'const uint16_t $o = bb_clamp_to(((double)${a[0]} + ${cNum(ctx.doubleParam('offset1'))}) * ((double)${b[0]} + ${cNum(ctx.doubleParam('offset2'))}) / (double)max_value, max_value);',
    ],
    {'out_mono': [o]},
  );
}

/// adder：双 mono 平衡加权混合 out=a×balance+b×(1−balance)。
/// 出处：isp_blend.c isp_blend_add（两路增益总和恒为 1）。
StreamKernelResult _kAdder(
    StreamKernelCtx s, CNodeGenCtx ctx, Map<String, List<String>?> inputs) {
  final a = _in(inputs, 'in_mono');
  final b = _in(inputs, 'in_mono2');
  s.useHelper('bb_clamp_to');
  final o = s.freshVar();
  return (
    [
      'const uint16_t $o = bb_clamp_to((double)${a[0]} * ${cNum(ctx.doubleParam('balance'))} + (double)${b[0]} * ${cNum(1.0 - ctx.doubleParam('balance'))}, max_value);',
    ],
    {'out_mono': [o]},
  );
}

/// blender：基图（四域互斥）+ 蒙版 mono + 混叠图（四域互斥）叠加。
/// 出处：isp_blend.c isp_blend_mask_apply（k = strength/max_value 循环外
/// 一次；负 delta 不下压；int64 精确相乘再乘 double k）。strength == 0
/// 时 c_ref 早退基图不动（生成期判定同结果）。
StreamKernelResult _kBlender(
    StreamKernelCtx s, CNodeGenCtx ctx, Map<String, List<String>?> inputs) {
  final basePort = _activePort(ctx, const ['in', 'in_yuv', 'in_hsl', 'in_mono']);
  final baseFmt = ctx.inputFormats[basePort] ??
      (basePort == 'in_mono'
          ? 'mono'
          : basePort == 'in'
              ? 'rgb'
              : basePort.substring(4));
  final blendPort =
      _activePort(ctx, const ['in_blend', 'in_blend_yuv', 'in_blend_hsl', 'in_blend_mono']);
  final blendFmt = ctx.inputFormats[blendPort] ??
      (blendPort.endsWith('_mono') ? 'mono' : 'rgb');
  final blendChannels = blendFmt == 'mono' ? 1 : 3;
  final outPort = switch (baseFmt) {
    'yuv' => 'out_yuv',
    'hsl' => 'out_hsl',
    'mono' => 'out_mono',
    _ => 'out_rgb',
  };
  final base = _in(inputs, basePort);
  final strength = ctx.doubleParam('strength');
  if (strength == 0.0) return _alias(base, outPort);
  final mask = _in(inputs, 'in_mask');
  final blend = _in(inputs, blendPort);
  s.useHelper('bb_clamp_to');
  s.addPrelude('const double ${ctx.ident}_k = ${cNum(strength)} / (double)max_value;');
  final id = ctx.ident;
  final channels = baseFmt == 'mono' ? 1 : 3;
  final lines = <String>[];
  final outs = <String>[];
  if (blendChannels == 3) {
    // 三通道交织混叠图：逐通道对应叠加（mono 基图 channels=1，只取
    // blend 的 c=0，与 c_ref 循环一致）。
    for (var c = 0; c < channels; c++) {
      final d = s.freshVar();
      final o = s.freshVar();
      lines.addAll([
        'const double $d = (double)((int64_t)${blend[c]} * (int64_t)${mask[0]}) * ${id}_k;',
        'const uint16_t $o = $d <= 0 ? ${base[c]} : bb_clamp_to((double)${base[c]} + $d, max_value);',
      ]);
      outs.add(o);
    }
  } else {
    // mono 混叠图：单一增量按基图格式选目标通道（RGB 三通道同加 /
    // YUV 只加 Y / HSL 只加 L / MONO 加通道 0）。
    final d = s.freshVar();
    lines.add('const double $d = (double)((int64_t)${blend[0]} * (int64_t)${mask[0]}) * ${id}_k;');
    final targets = switch (baseFmt) {
      'yuv' => const [0],
      'hsl' => const [2],
      'mono' => const [0],
      _ => const [0, 1, 2], // rgb：三通道同加（等效亮度增量）
    };
    for (var c = 0; c < channels; c++) {
      if (!targets.contains(c)) {
        outs.add(base[c]); // 未目标通道直通
        continue;
      }
      final o = s.freshVar();
      lines.add('const uint16_t $o = $d <= 0 ? ${base[c]} : bb_clamp_to((double)${base[c]} + $d, max_value);');
      outs.add(o);
    }
  }
  return (lines, {outPort: outs});
}

/// mux4：select 烘焙后纯透传（零语句别名；未选中支路已被规划层裁剪）。
/// 出处：isp_blend.c isp_mux4_select + Dart 的透传零拷贝语义。
StreamKernelResult _kMux4(
    StreamKernelCtx s, CNodeGenCtx ctx, Map<String, List<String>?> inputs) {
  final inPort = ctx.type.inputs
      .firstWhere((p) => ctx.inputFormats.containsKey(p.name),
          orElse: () => ctx.type.inputs.first)
      .name;
  final ie = _in(inputs, inPort);
  final outPort = switch (ctx.inputFormats[inPort] ?? 'rgb') {
    'yuv' => 'out_yuv',
    'hsl' => 'out_hsl',
    'mono' => 'out_mono',
    _ => 'out_rgb',
  };
  return _alias(ie, outPort);
}

// ---------------------------------------------------------------------------
// 垂直窗口节点行核
//
// 窗口访问模型：发射层为每个窗口节点声明窗口行指针（k = 0..2r，对应行
// yo-r+k；环形缓冲取模寻址 / 外部输入整帧夹取寻址），行核按行指针 + 列
// 表达式采样，越界样本按 c_ref「裁剪」语义在坐标判断后跳过（指针恒合法，
// 越界行内容不被读取）。像素行号经 s.rowVar（窗口阶段恒为 yo = y - D）。
// ---------------------------------------------------------------------------

/// 窗口节点行核的窗口访问描述（行指针变量由发射层声明）。
class StreamWindowAccess {
  /// 输入窗口行指针变量名（k = 0..2r，对应行 yo-r+k）。
  final List<String> rowPtrs;

  /// 垂直半径 r。
  final int radius;

  /// 输入帧通道数（mono/bayer=1，rgb/yuv/hsl=3）。
  final int channels;

  /// 派生环窗口行指针（sharpen/edge_extract 的 ys 亮度环、rgb_dnr 的
  /// yuv 环；布局同 rowPtrs）。
  final List<String>? auxRowPtrs;

  /// dpc 原地语义：输出环行指针（k = 0..r，行 yo-r+k；当前行 k=r 已在
  /// 行循环前从输入行整行拷入——左侧为已处理值、右侧为未处理值，与
  /// c_ref 原地读写一致）。
  final List<String>? outRowPtrs;

  const StreamWindowAccess({
    required this.rowPtrs,
    required this.radius,
    required this.channels,
    this.auxRowPtrs,
    this.outRowPtrs,
  });

  /// 输入窗口 (dy, colExpr) 处的采样表达式（单通道帧）。
  String sample(int dy, String colExpr) => '${rowPtrs[radius + dy]}[$colExpr]';
}

/// 发射一个窗口节点（输出第 yo 行）的行核。不支持的类型抛
/// [ArgumentError]（highlight 仅 recover 模式；clip 走点对点行核）。
StreamKernelResult emitStreamWindowKernel(
    StreamKernelCtx s, CNodeGenCtx ctx, StreamWindowAccess access) {
  switch (ctx.node.typeId) {
    case 'dpc':
      return _wDpc(s, ctx, access);
    case 'sharpen':
      return _wSharpen(s, ctx, access);
    case 'edge_extract':
      return _wEdgeExtract(s, ctx, access);
    case 'rgb_dnr':
      return _wRgbDnr(s, ctx, access);
    case 'bayer_dnr':
      return _wBayerDnr(s, ctx, access);
    case 'demosaic':
      return _wDemosaicBilinear(s, ctx, access);
    case 'morphology':
      return _wMorphology(s, ctx, access);
    case 'gaussian_blur':
      return _wGaussianBlur(s, ctx, access);
    case 'highlight':
      return _wHighlightRecover(s, ctx, access);
  }
  throw ArgumentError('节点类型 ${ctx.node.typeId} 非窗口类型');
}

/// 列表达式（dx 为编译期常量）。
String _col(int dx) => dx == 0 ? 'x' : (dx > 0 ? '(x + $dx)' : '(x - ${-dx})');

/// 行号表达式（dy 为编译期常量；rv = s.rowVar）。
String _row(StreamKernelCtx s, int dy) =>
    dy == 0 ? s.rowVar : (dy > 0 ? '${s.rowVar} + $dy' : '${s.rowVar} - ${-dy}');

/// 发射同相位/mono 3x3 邻域枚举（复刻 isp_phase_neighbors 的顺序与裁剪：
/// dy 外层 dx 内层行优先、步进 step、去中心、越界丢弃——浮点累加次序与
/// c_ref 逐位一致）。[rowOf]：dy → 行指针变量（dpc 原地语义时 dy<=0 用
/// 输出环）。[stride]/[chan]：交织帧采样步进与通道（rgb_dnr 的 yuv 环
/// 取 Y 通道时 stride=3）。[emitSample]：对 (dy,dx) 处样本发射语句
/// （nb 为采样表达式）。
void _emitPhaseLoop(
  StreamKernelCtx s,
  List<String> lines,
  int step,
  String Function(int dy) rowOf,
  void Function(List<String> lines, String nb) emitSample, {
  int stride = 1,
  int chan = 0,
}) {
  for (var dy = -step; dy <= step; dy += step) {
    for (var dx = -step; dx <= step; dx += step) {
      if (dx == 0 && dy == 0) continue;
      lines.add('if (${_col(dx)} >= 0 && ${_col(dx)} < w && '
          '${_row(s, dy)} >= 0 && ${_row(s, dy)} < h) {');
      final idx = stride == 1 ? _col(dx) : '${_col(dx)} * $stride + $chan';
      emitSample(lines, '${rowOf(dy)}[$idx]');
      lines.add('}');
    }
  }
}

/// 窗口节点直通别名：输出 = 输入中心行。
StreamKernelResult _wAlias(StreamWindowAccess access, String outPort) =>
    (const [], {outPort: [access.sample(0, 'x')]});

/// RAW 域窗口节点双形态（端口/步进）：mono → (in_mono, out_mono, 1)，
/// bayer → (in, out, 2)。
(String, String, int) _rawWindowForm(CNodeGenCtx ctx) {
  final mono = _isMonoPath(ctx);
  return mono ? ('in_mono', 'out_mono', 1) : ('in', 'out', 2);
}

/// dpc：离群超阈值替换坏点（median / directional）。出处：isp_dpc.c
/// isp_dpc_apply。原地语义：dy<=0 窗口行读输出环（已处理行，当前行行
/// 循环前已拷入），dy>0 读输入环（未处理行）；邻域收集顺序与
/// isp_phase_neighbors 一致；median 取上中位（isp_median_u16，
/// isp_common.c）；directional 四方向（水平/垂直/主对角/副对角）选
/// |va−vb| 最小的一对写 (va+vb+1)>>1，全越界回退 med。
StreamKernelResult _wDpc(
    StreamKernelCtx s, CNodeGenCtx ctx, StreamWindowAccess access) {
  final (_, outPort, step) = _rawWindowForm(ctx);
  final center = access.sample(0, 'x');
  if (ctx.boolParam('bypass')) return _wAlias(access, outPort);
  final out = access.outRowPtrs!;
  String rowOf(int dy) =>
      dy <= 0 ? out[access.radius + dy] : access.rowPtrs[access.radius + dy];
  final vals = s.freshVar();
  final n = s.freshVar();
  final med = s.freshVar();
  final diff = s.freshVar();
  final o = s.freshVar();
  final thr = '(${cNum(ctx.doubleParam('threshold'))} / 100.0 * max_value)';
  final lines = <String>[
    'uint16_t $vals[8];',
    'int $n = 0;',
  ];
  _emitPhaseLoop(s, lines, step, rowOf,
      (lines, nb) => lines.add('$vals[$n++] = $nb;'));
  lines.addAll([
    // 默认保持原值（n==0 / 未离群 / directional 四方向全越界回退 med）。
    'uint16_t $o = $center;',
    'if ($n > 0) {',
    '  const uint16_t $med = isp_median_u16($vals, $n);',
    '  int $diff = (int)$center - (int)$med;',
    '  if ($diff < 0) $diff = -$diff;',
    '  if ((double)$diff > $thr) {',
  ]);
  if (ctx.strParam('mode') == 'directional') {
    lines.addAll([
      '{',
      '  int best_ = -1;',
      '  int best_diff_ = INT32_MAX;',
    ]);
    // 四方向按水平/垂直/主对角/副对角顺序（平局保留先出现者）。
    for (final (dx, dy) in const [(1, 0), (0, 1), (1, 1), (1, -1)]) {
      final ax = _col(-dx * step);
      final bx = _col(dx * step);
      final ray = _row(s, -dy * step);
      final rby = _row(s, dy * step);
      final va = '${rowOf(-dy * step)}[$ax]';
      final vb = '${rowOf(dy * step)}[$bx]';
      lines.addAll([
        '  if ($ax >= 0 && $ax < w && $bx >= 0 && $bx < w && '
            '$ray >= 0 && $ray < h && $rby >= 0 && $rby < h) {',
        '    const int va_ = (int)$va;',
        '    const int vb_ = (int)$vb;',
        '    int ddiff_ = va_ - vb_;',
        '    if (ddiff_ < 0) ddiff_ = -ddiff_;',
        '    if (ddiff_ < best_diff_) {',
        '      best_diff_ = ddiff_;',
        '      best_ = (va_ + vb_ + 1) >> 1;',
        '    }',
        '  }',
      ]);
    }
    lines.addAll([
      '  $o = (best_ >= 0) ? (uint16_t)best_ : $med;',
      '}',
    ]);
  } else {
    lines.add('  $o = $med;');
  }
  lines.addAll([
    '  }',
    '}',
  ]);
  return (lines, {outPort: [o]});
}

/// bayer_dnr：同相位 3x3 保边加权降噪（σ = strength×√(v+64)，
/// w = 1/(1+(Δ/σ)²)）。出处：isp_bayer_dnr.c isp_bayer_dnr_apply
///（c_ref 先整帧快照再处理；行流水读输入环写输出，天然快照语义）。
/// 加权平均为样本凸组合，结果必在样本范围内，与 c_ref 一样无钳位。
StreamKernelResult _wBayerDnr(
    StreamKernelCtx s, CNodeGenCtx ctx, StreamWindowAccess access) {
  final (_, outPort, step) = _rawWindowForm(ctx);
  final center = access.sample(0, 'x');
  if (ctx.boolParam('bypass')) return _wAlias(access, outPort);
  final strength = ctx.doubleParam('strength');
  if (strength <= 0.0) return _wAlias(access, outPort); // c_ref 早退
  final v = s.freshVar();
  final sigma = s.freshVar();
  final sum = s.freshVar();
  final wsum = s.freshVar();
  final o = s.freshVar();
  final lines = <String>[
    'const int $v = (int)$center;',
    'const double $sigma = ${cNum(strength)} * sqrt((double)$v + 64.0);',
    'double $sum = (double)$v;',
    'double $wsum = 1.0;',
  ];
  _emitPhaseLoop(s, lines, step, (dy) => access.rowPtrs[access.radius + dy],
      (lines, nb) {
    lines.addAll([
      '{',
      '  const double d_ = (double)((int)$nb - $v);',
      '  const double ds_ = d_ / $sigma;',
      '  const double wgt_ = 1.0 / (1.0 + ds_ * ds_);',
      '  $sum += wgt_ * (double)$nb;',
      '  $wsum += wgt_;',
      '}',
    ]);
  });
  lines.add('const uint16_t $o = (uint16_t)round($sum / $wsum);');
  return (lines, {outPort: [o]});
}

/// sharpen：亮度 unsharp mask（3x3 盒式含中心，裁剪；detail 为 double
/// 除法；Y'/Y 等比缩放三通道）。出处：isp_sharpen.c isp_sharpen_apply
///（c_ref 第一步全帧亮度平面——逐像素派生，行流水为 ys 派生环）。
StreamKernelResult _wSharpen(
    StreamKernelCtx s, CNodeGenCtx ctx, StreamWindowAccess access) {
  final ie = [
    for (var c = 0; c < 3; c++) access.sample(0, '(x) * 3 + $c'),
  ];
  if (ctx.boolParam('bypass')) return (const [], {'out': ie});
  final amount = ctx.doubleParam('amount');
  if (amount == 0.0) return (const [], {'out': ie}); // c_ref 早退
  final ys = access.auxRowPtrs!;
  s.useHelper('bb_clamp_to');
  final v = s.freshVar();
  final sum = s.freshVar();
  final count = s.freshVar();
  final detail = s.freshVar();
  final y2 = s.freshVar();
  final y2c = s.freshVar();
  final scale = s.freshVar();
  final lines = <String>[
    'const int $v = (int)${ys[access.radius]}[x];',
    'int $sum = 0;',
    'int $count = 0;',
  ];
  // 3x3 盒式（含中心），越界裁剪。
  for (var dy = -1; dy <= 1; dy++) {
    for (var dx = -1; dx <= 1; dx++) {
      lines.addAll([
        'if (${_col(dx)} >= 0 && ${_col(dx)} < w && '
            '${_row(s, dy)} >= 0 && ${_row(s, dy)} < h) {',
        '  $sum += (int)${ys[access.radius + dy]}[${_col(dx)}];',
        '  $count++;',
        '}',
      ]);
    }
  }
  lines.addAll([
    'double $detail = (double)$v - (double)$sum / (double)$count;',
    'if (fabs($detail) < ${cNum(ctx.doubleParam('threshold'))}) $detail = 0.0;',
    'const double $y2 = ($detail == 0.0 || $v <= 0) ? 0.0 : (double)$v + ${cNum(amount)} * $detail;',
    'const double $y2c = $y2 < 0.0 ? 0.0 : ($y2 > (double)max_value ? (double)max_value : $y2);',
    'const double $scale = ($detail == 0.0 || $v <= 0) ? 1.0 : $y2c / (double)$v;',
  ]);
  final outs = <String>[];
  for (var c = 0; c < 3; c++) {
    final o = s.freshVar();
    lines.add(
        'const uint16_t $o = ($detail == 0.0 || $v <= 0) ? ${ie[c]} : bb_clamp_to((double)${ie[c]} * $scale, max_value);');
    outs.add(o);
  }
  return (lines, {'out': outs});
}

/// edge_extract：亮度高通黑底白线边缘图（非原地）。出处：
/// isp_edge_extract.c isp_edge_extract_run 第二步（3x3 盒式含中心裁剪 +
/// 相对对比度归一化 + √rel 显示压缩；mean_floor = max/128 防近黑爆增益）。
/// 主输出保持输入格式（RGB：v/v/v；YUV：v/mid/mid；HSL：0/0/v），
/// out_mono 为边缘亮度图（与整帧版取通道语义一致：RGB/YUV 取 0、HSL 取
/// L=2——即同一 v）。
StreamKernelResult _wEdgeExtract(
    StreamKernelCtx s, CNodeGenCtx ctx, StreamWindowAccess access) {
  final inPort = _activePort(ctx, const ['in', 'in_yuv', 'in_hsl']);
  final fmt = ctx.inputFormats[inPort] ?? 'rgb';
  final outPort = switch (fmt) {
    'yuv' => 'out_yuv',
    'hsl' => 'out_hsl',
    _ => 'out_rgb',
  };
  final id = ctx.ident;
  s.addPreludeAll([
    'const double ${id}_mean_floor = (double)max_value / 128.0;',
    'const double ${id}_rel_thr = ${cNum(ctx.doubleParam('threshold'))} / (double)max_value;',
  ]);
  s.useHelper('bb_clamp_to');
  final ys = access.auxRowPtrs!;
  final sum = s.freshVar();
  final count = s.freshVar();
  final detail = s.freshVar();
  final mean = s.freshVar();
  final rel = s.freshVar();
  final o = s.freshVar();
  final lines = <String>[
    'int $sum = 0;',
    'int $count = 0;',
  ];
  for (var dy = -1; dy <= 1; dy++) {
    for (var dx = -1; dx <= 1; dx++) {
      lines.addAll([
        'if (${_col(dx)} >= 0 && ${_col(dx)} < w && '
            '${_row(s, dy)} >= 0 && ${_row(s, dy)} < h) {',
        '  $sum += (int)${ys[access.radius + dy]}[${_col(dx)}];',
        '  $count++;',
        '}',
      ]);
    }
  }
  lines.addAll([
    'const double $detail = (double)(int)${ys[access.radius]}[x] - (double)$sum / (double)$count;',
    'const double $mean = (double)$sum / (double)$count;',
    'double $rel = fabs($detail) / ($mean < ${id}_mean_floor ? ${id}_mean_floor : $mean);',
    'if ($rel < ${id}_rel_thr) $rel = 0.0;',
    'const uint16_t $o = bb_clamp_to(${cNum(ctx.doubleParam('gain'))} * sqrt($rel) * (double)max_value, max_value);',
  ]);
  const mid = '((uint16_t)(max_value >> 1))';
  return (
    lines,
    {
      outPort: switch (fmt) {
        'yuv' => [o, mid, mid],
        'hsl' => ['0', '0', o],
        _ => [o, o, o],
      },
      'out_mono': [o],
    },
  );
}

/// rgb_dnr：转 YUV 后亮度保边降噪 + 色度低通。出处：isp_rgb_dnr.c
/// isp_rgb_dnr_apply。c_ref 四步：全帧 rgbToYuv（逐像素，行流水为 yuv
/// 派生环）→ 亮度 3x3 保边（σ = luma×√(v+64)，w = 1/(1+(Δ/σ)²)，邻域
/// 顺序与 isp_phase_neighbors 一致）→ 色度 3x3 盒式按 blend 混合（读
/// 首遍 U/V——派生环恒为首遍值）→ yuvToRgb（bb_yuv_to_rgb_px）。
/// luma <= 0 / chroma <= 0 的分支跳过与 c_ref 一致（生成期判定）。
StreamKernelResult _wRgbDnr(
    StreamKernelCtx s, CNodeGenCtx ctx, StreamWindowAccess access) {
  final ie = [
    for (var c = 0; c < 3; c++) access.sample(0, '(x) * 3 + $c'),
  ];
  if (ctx.boolParam('bypass')) return (const [], {'out': ie});
  final luma = ctx.doubleParam('luma');
  final chroma = ctx.doubleParam('chroma');
  if (luma <= 0.0 && chroma <= 0.0) {
    return (const [], {'out': ie}); // c_ref 早退
  }
  final yuv = access.auxRowPtrs!;
  s.useHelper('bb_clamp_to');
  s.useHelper('bb_yuv_to_rgb_px');
  final lines = <String>[];
  // 亮度（Y = yuv 行通道 0）。
  String newY;
  if (luma > 0.0) {
    final v = s.freshVar();
    final sigma = s.freshVar();
    final sum = s.freshVar();
    final wsum = s.freshVar();
    final o = s.freshVar();
    lines.addAll([
      'const int $v = (int)${yuv[access.radius]}[(x) * 3];',
      'const double $sigma = ${cNum(luma)} * sqrt((double)($v + 64));',
      'double $sum = (double)$v;',
      'double $wsum = 1.0;',
    ]);
    _emitPhaseLoop(s, lines, 1, (dy) => yuv[access.radius + dy], (lines, nb) {
      lines.addAll([
        '{',
        '  const double d_ = (double)((int)$nb - $v);',
        '  const double ds_ = d_ / $sigma;',
        '  const double wgt_ = 1.0 / (1.0 + ds_ * ds_);',
        '  $sum += wgt_ * (double)$nb;',
        '  $wsum += wgt_;',
        '}',
      ]);
    }, stride: 3);
    lines.add('const uint16_t $o = bb_clamp_to($sum / $wsum, max_value);');
    newY = o;
  } else {
    newY = '${yuv[access.radius]}[(x) * 3]';
  }
  // 色度（U/V = yuv 行通道 1/2；3x3 盒式含中心裁剪 + blend 混合）。
  final newCs = <String>[];
  for (var c = 0; c < 2; c++) {
    if (chroma <= 0.0) {
      newCs.add('${yuv[access.radius]}[(x) * 3 + ${c + 1}]');
      continue;
    }
    final blend = chroma < 0.0 ? 0.0 : (chroma > 1.0 ? 1.0 : chroma);
    final sum = s.freshVar();
    final count = s.freshVar();
    final avg = s.freshVar();
    final o = s.freshVar();
    lines.addAll([
      'int $sum = 0;',
      'int $count = 0;',
    ]);
    for (var dy = -1; dy <= 1; dy++) {
      for (var dx = -1; dx <= 1; dx++) {
        lines.addAll([
          'if (${_col(dx)} >= 0 && ${_col(dx)} < w && '
              '${_row(s, dy)} >= 0 && ${_row(s, dy)} < h) {',
          '  $sum += (int)${yuv[access.radius + dy]}[${_col(dx)} * 3 + ${c + 1}];',
          '  $count++;',
          '}',
        ]);
      }
    }
    lines.addAll([
      'const double $avg = (double)$sum / (double)$count;',
      'const uint16_t $o = bb_clamp_to((double)${yuv[access.radius]}[(x) * 3 + ${c + 1}] * ${cNum(1.0 - blend)} + $avg * ${cNum(blend)}, max_value);',
    ]);
    newCs.add(o);
  }
  final rgb = s.freshVar();
  lines.addAll([
    'int $rgb[3];',
    'bb_yuv_to_rgb_px($newY, ${newCs[0]}, ${newCs[1]}, max_value >> 1, max_value, $rgb, $rgb + 1, $rgb + 2);',
  ]);
  return (lines, {
    'out': ['$rgb[0]', '$rgb[1]', '$rgb[2]'],
  });
}

/// demosaic（algorithm=bilinear，Bayer CFA）：3x3 裁剪邻域 + 通道筛选。
/// 出处：isp_demosaic.c isp_demosaic_pixel / isp_demosaic_avg_neighbors
///（通用路径，与 Dart 内部像素快速路径代数等价——见 c_ref 注释）。
/// 邻域平均 (sum + count/2) / count 整数四舍五入；count==0 回退自身。
/// Bypass 与整帧版一致：灰度直通（R=G=B=马赛克采样值）。
StreamKernelResult _wDemosaicBilinear(
    StreamKernelCtx s, CNodeGenCtx ctx, StreamWindowAccess access) {
  final selfExpr = access.sample(0, 'x');
  if (ctx.boolParam('bypass')) {
    return (const [], {
      'out': [selfExpr, selfExpr, selfExpr],
    });
  }
  var cfa = ctx.strParam('cfaPattern').trim();
  if (cfa.isEmpty) cfa = ctx.strParam('bayerPattern').trim();
  final pat = switch (cfa.toUpperCase()) {
    'BGGR' => 'ISP_BAYER_BGGR',
    'GRBG' => 'ISP_BAYER_GRBG',
    'GBRG' => 'ISP_BAYER_GBRG',
    _ => 'ISP_BAYER_RGGB',
  };
  final own = s.freshVar();
  final self = s.freshVar();
  final lines = <String>[
    'const int $own = isp_bayer_color_at($pat, x, ${s.rowVar});',
    'const int $self = (int)$selfExpr;',
  ];
  const axial = [(-1, 0), (1, 0), (0, -1), (0, 1)];
  const diagonal = [(-1, -1), (1, -1), (-1, 1), (1, 1)];

  // 邻域平均（越界/非该色跳过；count==0 回退自身）写入 dst。
  void emitAvg(String dst, int color, List<(int, int)> offsets) {
    lines.add('{');
    lines.add('  int sum_ = 0, count_ = 0;');
    for (final (dx, dy) in offsets) {
      final cond = '${_col(dx)} >= 0 && ${_col(dx)} < w && '
          '${_row(s, dy)} >= 0 && ${_row(s, dy)} < h && '
          'isp_bayer_color_at($pat, ${_col(dx)}, ${_row(s, dy)}) == $color';
      lines.addAll([
        '  if ($cond) {',
        '    sum_ += (int)${access.rowPtrs[access.radius + dy]}[${_col(dx)}];',
        '    count_++;',
        '  }',
      ]);
    }
    lines.add(
        '  $dst = count_ > 0 ? (uint16_t)((sum_ + count_ / 2) / count_) : (uint16_t)$self;');
    lines.add('}');
  }

  final outs = <String>[];
  for (var c = 0; c < 3; c++) {
    final o = s.freshVar();
    lines.add('uint16_t $o = 0;');
    if (c == 1) {
      // R/B 站点缺 G：轴向邻居。
      lines.add('if ($own == 1) {');
      lines.add('  $o = (uint16_t)$self;');
      lines.add('} else {');
      emitAvg(o, 1, axial);
      lines.add('}');
    } else {
      lines.add('if ($own == $c) {');
      lines.add('  $o = (uint16_t)$self;');
      lines.add('} else if ($own == 1) {');
      // G 站点缺 R/B：该颜色的轴向邻居。
      emitAvg(o, c, axial);
      lines.add('} else {');
      // R 站点缺 B（或反之）：对角邻居。
      emitAvg(o, c, diagonal);
      lines.add('}');
    }
    outs.add(o);
  }
  return (lines, {'out': outs});
}

/// highlight（mode=recover）：饱和像素用同相位未饱和邻域均值重建。
/// 出处：isp_highlight.c isp_highlight_apply 的 recover 分支（c_ref 先
/// 整帧快照；行流水读输入环写输出，天然快照语义）。膝点
/// kneePt = clamp01(knee) × max_value；未达膝点或邻域全饱和保持原值；
/// 整数平均 (sum + count/2) / count。
StreamKernelResult _wHighlightRecover(
    StreamKernelCtx s, CNodeGenCtx ctx, StreamWindowAccess access) {
  final (_, outPort, step) = _rawWindowForm(ctx);
  final center = access.sample(0, 'x');
  if (ctx.boolParam('bypass')) return _wAlias(access, outPort);
  final knee = ctx.doubleParam('knee').clamp(0.0, 1.0);
  final kp = '(${cNum(knee)} * (double)max_value)';
  final sum = s.freshVar();
  final count = s.freshVar();
  final o = s.freshVar();
  final lines = <String>[
    'int $sum = 0;',
    'int $count = 0;',
  ];
  _emitPhaseLoop(s, lines, step, (dy) => access.rowPtrs[access.radius + dy],
      (lines, nb) {
    // 只用未饱和邻居（< kneePt）。
    lines.addAll([
      'if ((double)$nb < $kp) {',
      '  $sum += (int)$nb;',
      '  $count++;',
      '}',
    ]);
  });
  lines.add(
      'const uint16_t $o = ((double)$center < $kp || $count == 0) ? $center : (uint16_t)(($sum + $count / 2) / $count);');
  return (lines, {outPort: [o]});
}

// ---------------------------------------------------------------------------
// 分离趟算子行核（水平趟在发射层作为派生行写入，见 group_c_export_bb.dart
// _emitWindowPreamble；此处为垂直趟 + 收尾）
// ---------------------------------------------------------------------------

/// morphology：方形结构元腐蚀/膨胀（分离趟：水平趟极值环 + 垂直滑窗
/// 极值）。出处：isp_morphology.c isp_morphology_apply 垂直趟——窗口
/// [y-r, y+r] 截断，严格比较取极值（极值为整数运算且与枚举顺序无关，
/// 中心 tap 恒在界内作初值；与 c_ref 的 y0..y1 循环逐位一致）；极值取自
/// 原数据，必然在有效范围内，无需钳位。
StreamKernelResult _wMorphology(
    StreamKernelCtx s, CNodeGenCtx ctx, StreamWindowAccess access) {
  final mono = _isMonoPath(ctx);
  final outPort = mono ? 'out_mono' : 'out';
  final ch = access.channels;
  if (ctx.boolParam('bypass')) {
    return (const [], {
      outPort: [for (var c = 0; c < ch; c++) access.sample(0, ch == 1 ? 'x' : '(x) * $ch + $c')],
    });
  }
  final erode = ctx.strParam('mode') != 'dilate';
  final aux = access.auxRowPtrs!;
  final r = access.radius;
  final lines = <String>[];
  final outs = <String>[];
  for (var c = 0; c < ch; c++) {
    final colC = ch == 1 ? 'x' : '(x) * $ch + $c';
    final o = s.freshVar();
    lines.add('uint16_t $o = ${aux[r]}[$colC];');
    for (var k = 0; k <= 2 * r; k++) {
      if (k == r) continue;
      lines.addAll([
        'if (${_row(s, k - r)} >= 0 && ${_row(s, k - r)} < h) {',
        '  const uint16_t u_ = ${aux[k]}[$colC];',
        '  if (${erode ? 'u_ < $o' : 'u_ > $o'}) $o = u_;',
        '}',
      ]);
    }
    outs.add(o);
  }
  return (lines, {outPort: outs});
}

/// gaussian_blur：可分离两趟高斯（分离趟：水平卷积 double 环 + 垂直
/// 卷积）。出处：isp_gaussian_blur.c isp_gaussian_blur_apply——半径
/// radius = ceil(3σ)（生成期烘焙）；权重核 v = exp(-(i²)/(2σ²)) 归一化
/// （运行期按 c_ref 同式构建，同 libm 逐位一致，prelude 注册）；垂直趟
/// tap 行号钳回 [0, h-1]（边界复制，行指针预备处夹取）；收尾强度混合
/// (orig + (acc − orig) × strength).round()，写回按 mod 2^16 截断
/// （(uint16_t)(int)round(...) 同义），无钳位。
StreamKernelResult _wGaussianBlur(
    StreamKernelCtx s, CNodeGenCtx ctx, StreamWindowAccess access) {
  final inPort = _activePort(ctx, const ['in', 'in_yuv', 'in_hsl', 'in_mono']);
  final fmt = ctx.inputFormats[inPort] ?? 'rgb';
  final outPort = switch (fmt) {
    'yuv' => 'out_yuv',
    'hsl' => 'out_hsl',
    'mono' => 'out_mono',
    _ => 'out_rgb',
  };
  final ch = access.channels;
  final r = access.radius;
  final kLen = 2 * r + 1;
  final sigma = ctx.doubleParam('sigma');
  final strength = ctx.doubleParam('strength');
  final ident = ctx.ident;
  // 权重核构建（单行 prelude；i 升序累加 ksum、随后逐项归一化，与
  // c_ref 完全同序）。
  s.addPrelude(
      '{ double ksum_ = 0.0; int i_; for (i_ = -$r; i_ <= $r; i_++) { const double kv_ = exp(-(double)(i_ * i_) / (2.0 * ${cNum(sigma)} * ${cNum(sigma)})); ${ident}_gk[i_ + $r] = kv_; ksum_ += kv_; } for (i_ = 0; i_ < $kLen; i_++) { ${ident}_gk[i_] /= ksum_; } }');
  final grow = access.auxRowPtrs!;
  final lines = <String>[];
  final outs = <String>[];
  for (var c = 0; c < ch; c++) {
    final colC = ch == 1 ? 'x' : '(x) * $ch + $c';
    final orig = access.sample(0, colC);
    final acc = s.freshVar();
    final o = s.freshVar();
    lines.add('double $acc = 0.0;');
    for (var k = 0; k < kLen; k++) {
      lines.add('$acc += ${grow[k]}[$colC] * ${ident}_gk[$k];');
    }
    lines.add(
        'const uint16_t $o = (uint16_t)(int)round((double)$orig + ($acc - (double)$orig) * ${cNum(strength)});');
    outs.add(o);
  }
  return (lines, {outPort: outs});
}
