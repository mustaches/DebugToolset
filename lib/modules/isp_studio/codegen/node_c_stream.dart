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

import '../models/isp_graph.dart';
import '../models/isp_node.dart';
import '../pipeline/color_temp.dart';
import '../pipeline/isp_kernels.dart';
import '../pipeline/levels_curve.dart';
import 'group_c_plan.dart';
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
CNodeGenCtx streamNodeCtx(IspGraph graph, GroupCPlan plan, String nodeId) {
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
 * isp_csc_common.h isp_csc_clamp_d（三处同语义）。 */
static uint16_t bb_clamp_to(double v, int max_value) {
  if (v < 0) return 0;
  if (v > (double)max_value) return (uint16_t)max_value;
  return (uint16_t)round(v);
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

/// ccm：3x3 色彩校正矩阵（Q20 定点乘加）。出处：isp_ccm.c
/// isp_ccm_apply。定点系数 m[i] = (matrix[i] * 2^20).round() 与单位矩阵
/// 判定在生成期完成（同一表达式，逐位一致）；单位矩阵时 c_ref 早退直通。
StreamKernelResult _kCcm(
    StreamKernelCtx s, CNodeGenCtx ctx, Map<String, List<String>?> inputs) {
  final ie = _in(inputs, 'in');
  if (ctx.boolParam('bypass')) return _alias(ie, 'out');
  final raw = ctx.param('matrix');
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
  if (isIdentity) return _alias(ie, 'out'); // c_ref 定点恒等早退
  s.useHelper('bb_clamp_i64');
  s.addFileDecl('${ctx.ident}_m', '''
/* ccm Q20 定点矩阵：m[i] = (matrix[i] * 2^20).round()，生成期烘焙
 * （与 isp_ccm.c isp_ccm_apply 的运行期换算同一表达式）。 */
static const int64_t ${ctx.ident}_m[9] = {
  ${m.join(', ')},
};''');
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
  return (lines, {'out': outs});
}

/// 其余 5 个 CSC 变体：单像素公式复刻（出处：isp_csc_<变体>.c 主循环 +
/// isp_csc_common.h 单像素工具；yuv2hsl/hsl2yuv 为单遍融合两段中转）。
StreamKernelResult _kCscOne(StreamKernelCtx s, CNodeGenCtx ctx,
    Map<String, List<String>?> inputs, String variant) {
  final ie = _in(inputs, 'in');
  if (ctx.boolParam('bypass')) return _alias(ie, 'out');
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
      'const uint16_t $o0 = (uint16_t)((($hv % (max_value + 1)) + (max_value + 1)) % (max_value + 1));',
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
      'int $hnew = ($hv + $shift) % (max_value + 1);',
      'if ($hnew < 0) $hnew += (max_value + 1);',
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
/// 1 钳位 1..8，b{i}_* 缺键回退恒等默认）；全段恒等直通别名（同 runner
/// 判定）。段合成写为文件级 static helper `<id>_compose`（段参数生成期
/// 烘焙为字面常量，公式与 mb_compose 逐行一致）；LUT 模式
///（codegenMode=lut）另烘焙三表（Dart multiBandLuts，域 0..
/// lutDomainMax），max_value 一致走查表、不一致回退 _compose 直算。
StreamKernelResult _kMultiBandEq(
    StreamKernelCtx s, CNodeGenCtx ctx, Map<String, List<String>?> inputs) {
  final ie = _in(inputs, 'in');
  if (ctx.boolParam('bypass')) return _alias(ie, 'out');
  var bandCount = ctx.intParam('band_count');
  if (bandCount < 1) bandCount = 1;
  if (bandCount > 8) bandCount = 8;
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
  if (lutMode) {
    final (shiftLut, sMulLut, lMulLut) =
        multiBandLuts(bands, serial: serial, maxValue: n);
    s.addFileDecl('${id}_shift_lut', '''
/* multi_band_eq LUT 模式：H 域三表（H 偏移/S 乘子/L 乘子）生成期烘焙
 *（Dart multiBandLuts，域 0..$n）；max_value 一致走查表，不一致回退
 * ${id}_compose 直算。 */
static const int32_t ${id}_shift_lut[${n + 1}] = {
${cI32Table(shiftLut)}
};''');
    s.addFileDecl('${id}_s_mul_lut', '''
static const double ${id}_s_mul_lut[${n + 1}] = {
${cF64Table(sMulLut)}
};''');
    s.addFileDecl('${id}_l_mul_lut', '''
static const double ${id}_l_mul_lut[${n + 1}] = {
${cF64Table(lMulLut)}
};''');
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
      'double $sMul, $lMul;',
      if (lutMode) ...[
        'if (max_value == $n) {',
        '  $shift = ${id}_shift_lut[$hv];',
        '  $sMul = ${id}_s_mul_lut[$hv];',
        '  $lMul = ${id}_l_mul_lut[$hv];',
        '} else {',
        '  ${id}_compose($hv, max_value, &$shift, &$sMul, &$lMul);',
        '}',
      ] else
        '${id}_compose($hv, max_value, &$shift, &$sMul, &$lMul);',
      'int $hnew = ($hv + $shift) % (max_value + 1);',
      'if ($hnew < 0) $hnew += (max_value + 1);',
      'const uint16_t $o0 = (uint16_t)$hnew;',
      'const uint16_t $o1 = bb_clamp_to((double)${ie[1]} * $sMul, max_value);',
      'const uint16_t $o2 = bb_clamp_to((double)${ie[2]} * $lMul, max_value);',
    ],
    {'out': [o0, o1, o2]},
  );
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
