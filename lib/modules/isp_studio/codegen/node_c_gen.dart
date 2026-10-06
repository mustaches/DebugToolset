/// ISP 编组导出 C 代码：每节点实例的 C 封装生成框架。
///
/// 每个节点实例生成独立的 `<ident>.h` / `<ident>.c`（ident 为净化后的
/// 节点名，如 gamma_1），封装函数烘焙节点参数后调用 c_ref 参考实现。
///
/// 【封装 ABI 约定】（所有类型模板必须遵守，top 生成器依赖这些约定发调用）
/// 1. 运行函数命名与形参顺序固定：
///      int {ident}_run(const uint16_t *in..., int w, int h, int max_value,
///                      uint16_t|uint8_t *out...[, void *scratch]);
///    输入缓冲按端口声明序、然后 w/h/max_value、输出缓冲、scratch（无
///    scratch 的类型省略该形参）。gamma 链尾的 rgba 输出为 uint8_t*。
/// 2. 需要 scratch 的类型在 .h 定义统一三参宏（未用参数留空位）：
///      #define {MACRO}_SCRATCH_BYTES(w, h, max_value) (c_ref 宏或常量表达式)
///    top 层用它对全部成员取 MAX 聚合节点 scratch 区。
/// 3. 参数烘焙为 {MACRO}_{PARAM} 宏（数值/枚举）或 .c 内
///    `static const` 数组（ccm 矩阵、levels 控制点）。
/// 4. Process 类（IspNodeRegistry.isProcessType，含荧光）注入
///    {MACRO}_BYPASS 宏；封装内 Bypass 时直通（out != in 先 memcpy）。
/// 5. c_ref 原地算子（in-place）的封装仍收独立 in/out：out != in 时先
///    memcpy 再在 out 上原地处理，top 无需特判。
/// 6. .c 第一行 include 自己的 .h；memcpy 需要 string.h（统一包含）。
///
/// 本文件含框架与 gamma/ccm/white_balance 三个模板；其余类型按域分文件：
/// node_c_gen_raw.dart（RAW 域算子）、node_c_gen_rgb.dart（去马赛克/RGB
/// 域）、node_c_gen_adjust.dart（调节器）、node_c_gen_fluoro.dart（荧光
/// mono 域）、node_c_gen_datapath.dart（分路/合路/混合）。
library;

import 'dart:typed_data';

import '../models/isp_node.dart';
import '../pipeline/isp_kernels.dart';
import 'c_ident.dart';
import 'group_c_target.dart';
import 'node_c_gen_adjust.dart';
import 'node_c_gen_datapath.dart';
import 'node_c_gen_fluoro.dart';
import 'node_c_gen_raw.dart';
import 'node_c_gen_rgb.dart';

/// 当前支持导出的节点类型（Process 含 ColorTrans/Fluorescence 子分组 +
/// Datapath，共 49 个；Source 类暂不支持）。
const Set<String> cExportSupportedTypeIds = {
  // Process — RAW 域
  'black_level', 'dpc', 'fpn', 'lsc', 'grgb_balance', 'bayer_dnr', 'highlight',
  // Process — 去马赛克 / RGB 域（gamma/ccm/white_balance 模板在本文件）
  'demosaic', 'white_balance', 'ccm', 'rgb_dnr', 'sharpen', 'gaussian_blur',
  'edge_extract', 'morphology', 'gamma', 'ahe',
  // Process — ColorTrans（模板在本文件）
  'csc_rgb2yuv', 'csc_rgb2hsl', 'csc_yuv2rgb', 'csc_yuv2hsl', 'csc_hsl2rgb',
  'csc_hsl2yuv',
  // Process — 调节器
  'hsl_debugger', 'color_controller', 'multi_band_eq', 'rgb_debugger', 'yuv_debugger',
  'sat_bright_adjuster', 'bright_contrast_adjuster', 'levels_curves',
  'color_balance', 'color_temp_adjuster',
  // Process — Fluorescence
  'fluoro_leak', 'fluoro_background', 'fluoro_normalize', 'fluoro_temporal',
  'pseudo_color', 'fluoro_fusion',
  // Datapath
  'rgb_splitter', 'yuv_splitter', 'hsl_splitter',
  'rgb_combiner', 'yuv_combiner', 'hsl_combiner',
  'multiplier', 'adder', 'blender', 'mux4',
};

/// 帧格式（端口类型推导结果）：'bayer' | 'rgb' | 'yuv' | 'hsl' | 'mono'。
typedef CFrameFormat = String;

/// 封装端口：一个输入/输出缓冲形参。
class CPort {
  /// 形参名（如 in / in_r / out / out_rgba / history）。
  final String name;

  /// C 类型：'uint16_t'（16 位帧）或 'uint8_t'（gamma 的 rgba 输出）。
  final String cType;

  /// 帧通道数：mono/bayer=1，rgb/yuv/hsl=3，rgba8=4（cType 为 uint8_t）。
  final int channels;

  /// 持久缓冲（跨帧保留，如 fluoro_temporal 的 history）：top 从竞技场
  /// 持久区分配，且只有本节点写它。
  final bool isPersistent;

  const CPort(this.name,
      {this.cType = 'uint16_t', this.channels = 1, this.isPersistent = false});

  /// 缓冲字节数表达式（实参名 w/h 固定）。
  String get bytesExpr =>
      '(size_t)(w) * (size_t)(h) * ${channels}u * sizeof($cType)';
}

/// 一个节点实例的 C 封装生成结果。
class CNodeFiles {
  /// 文件名（净化标识符，不含扩展名）。
  final String fileName;
  final String header; // .h 内容
  final String source; // .c 内容
  final List<CPort> inputs;
  final List<CPort> outputs;

  /// scratch 宏名（如 ISP_GAMMA_1_SCRATCH_BYTES），无 scratch 为 null。
  /// 统一三参 (w, h, max_value)。
  final String? scratchMacro;

  /// 封装引用的 c_ref 算法头（如 isp_gamma.h；导出时连同对应 .c 一并拷出）。
  final List<String> algoIncludes;

  const CNodeFiles({
    required this.fileName,
    required this.header,
    required this.source,
    required this.inputs,
    required this.outputs,
    this.scratchMacro,
    this.algoIncludes = const [],
  });

  bool get hasScratch => scratchMacro != null;

  /// run() 原型（不含分号）。
  String get runProto {
    final params = <String>[
      for (final p in inputs) 'const ${p.cType} *${p.name}',
      'int w',
      'int h',
      'int max_value',
      for (final p in outputs) '${p.cType} *${p.name}',
      if (hasScratch) 'void *scratch',
    ];
    return 'int ${fileName}_run(${params.join(', ')})';
  }
}

/// 模板生成上下文。
class CNodeGenCtx {
  final IspNode node;
  final IspNodeType type;

  /// 净化标识符（文件名 / 函数名前缀），如 gamma_1。
  final String ident;

  /// 活动输入端口名 → 帧格式（由图连接推导；未连接的首要输入端口按
  /// 端口名自身推导）。双形态节点（如 RAW 算子的 in/in_mono）据此选路。
  final Map<String, CFrameFormat> inputFormats;

  /// LUT 模式（节点属性 codegenMode=lut）的烘焙域上限：由图上游源节点
  /// bitDepth 推导（group_c_export.dart lutDomainMaxOf），默认 1023。
  /// 表按 0..lutDomainMax 全量烘焙进 wrapper；运行时 max_value 与烘焙域
  /// 不一致时 wrapper 回退直算（同公式，数值一致）。
  final int lutDomainMax;

  /// 导出目标 CPU（仅影响 lut_fixed 行核的 SIMD 变体选择，见
  /// node_c_stream.dart 的 _lutFixedRowFn；默认与既有生成物一致）。
  final GroupCTarget target;

  CNodeGenCtx({
    required this.node,
    required this.type,
    required this.ident,
    required this.inputFormats,
    this.lutDomainMax = 1023,
    this.target = GroupCTarget.cortexA53_55,
  });

  /// 宏前缀（如 ISP_GAMMA_1）。
  String get macro => 'ISP_${cMacroPrefix(ident)}';

  /// 参数值：缺失回退类型默认值（旧 .ispflow 缺后加参数时与运行时一致）。
  Object? param(String key) {
    if (node.paramValues.containsKey(key)) return node.paramValues[key];
    for (final spec in type.params) {
      if (spec.key == key) return spec.defaultValue;
    }
    return null;
  }

  double doubleParam(String key) => (param(key) as num?)?.toDouble() ?? 0.0;
  int intParam(String key) => (param(key) as num?)?.toInt() ?? 0;
  bool boolParam(String key) => param(key) == true;
  String strParam(String key) => param(key)?.toString() ?? '';

  /// 是否为 Process 类（含荧光，有 Bypass 开关）。
  bool get isProcess => IspNodeRegistry.isProcessType(node.typeId);
}

/// uint16 表 → C 初始化文本（每行 8 项，缩进 4 空格，供 static const
/// uint16_t xxx[N] = {...} 使用）。
String cU16Table(Uint16List lut) {
  final b = StringBuffer();
  for (var i = 0; i < lut.length; i++) {
    if (i % 8 == 0) b.write('    ');
    b.write('${lut[i]}');
    if (i + 1 < lut.length) b.write(i % 8 == 7 ? ',\n' : ', ');
  }
  return b.toString();
}

/// int32 表 → C 初始化文本（每行 8 项，缩进 4 空格，供 static const
/// int32_t xxx[N] = {...} 使用；可含负值）。
String cI32Table(Int32List lut) {
  final b = StringBuffer();
  for (var i = 0; i < lut.length; i++) {
    if (i % 8 == 0) b.write('    ');
    b.write('${lut[i]}');
    if (i + 1 < lut.length) b.write(i % 8 == 7 ? ',\n' : ', ');
  }
  return b.toString();
}

/// double 表 → C 初始化文本（每行 4 项，缩进 4 空格，供 static const
/// double xxx[N] = {...} 使用）。
String cF64Table(Float64List lut) {
  final b = StringBuffer();
  for (var i = 0; i < lut.length; i++) {
    if (i % 4 == 0) b.write('    ');
    b.write(cNum(lut[i]));
    if (i + 1 < lut.length) b.write(i % 4 == 3 ? ',\n' : ', ');
  }
  return b.toString();
}

/// 数值 → C 字面量：double 保证带小数点（1 → 1.0），int 原样。
String cNum(Object? v, {bool asDouble = true}) {
  if (v is double) {
    var s = v.toString();
    if (!s.contains('.') && !s.contains('e') && !s.contains('E')) s += '.0';
    return s;
  }
  if (v is int) return asDouble ? '$v.0' : '$v';
  return asDouble ? '0.0' : '0';
}

/// 发射 .h：守卫 + includes + 参数宏 + scratch 宏 + run 原型。
/// 组装 CNodeFiles（模板统一入口）。
///
/// [algoIncludes] c_ref 算法头（如 isp_gamma.h，isp_common.h 自动前置）。
/// [macroLines] 参数烘焙宏行（已含 #define，BYPASS 宏自动追加）。
/// [scratchExpr] scratch 字节数表达式（可用 w/h/max_value），null 表示无。
/// [extraHeaderDecls] 额外 .h 声明（如静态数组 extern——一般用不到，
/// 数组放 .c 内部即可）。
/// [body] .c 函数体（不含函数签名与大括号）。
CNodeFiles assembleCNode({
  required CNodeGenCtx ctx,
  required List<String> algoIncludes,
  required List<CPort> inputs,
  required List<CPort> outputs,
  required List<String> macroLines,
  required String body,
  String? scratchExpr,
  String? docComment,
}) {
  final ident = ctx.ident;
  final macro = ctx.macro;
  final guard = 'ISP_NODE_${cMacroPrefix(ident)}_H';
  final scratchMacro = scratchExpr == null ? null : '${macro}_SCRATCH_BYTES';

  // Bypass 宏（Process 类）。
  final allMacros = [
    ...macroLines,
    if (ctx.isProcess)
      '#define ${macro}_BYPASS ${ctx.boolParam('bypass') ? 1 : 0}',
  ];

  final proto = CNodeFiles(
    fileName: ident,
    header: '',
    source: '',
    inputs: inputs,
    outputs: outputs,
    scratchMacro: scratchMacro,
  ).runProto;

  final h = '''
#ifndef $guard
#define $guard

#include "isp_common.h"
${algoIncludes.map((i) => '#include "$i"').join('\n')}

#ifdef __cplusplus
extern "C" {
#endif
${docComment == null ? '' : '\n$docComment\n'}
/* ---- 节点参数（导出时固化，来自 .ispflow） ---- */
${allMacros.join('\n')}
${scratchExpr == null ? '' : '''
/* scratch 所需字节数（统一三参；未用参数留空位）。 */
#define $scratchMacro(w, h, max_value) ($scratchExpr)
'''}
$proto;

#ifdef __cplusplus
} /* extern "C" */
#endif

#endif /* $guard */
''';

  final c = '''
#include "$ident.h"

#include <string.h>

$proto {
$body
}
''';

  return CNodeFiles(
    fileName: ident,
    header: h,
    source: c,
    inputs: inputs,
    outputs: outputs,
    scratchMacro: scratchMacro,
    algoIncludes: algoIncludes,
  );
}

/// out != in 时的拷贝语句（单帧缓冲）。
String copyInToOut(CPort input, CPort output, String indent) {
  return '${indent}if (${output.name} != ${input.name}) {\n'
      '$indent  memcpy(${output.name}, ${input.name}, ${input.bytesExpr});\n'
      '$indent}';
}

/// 生成一个节点实例的 C 封装。不支持的类型抛 [ArgumentError]。
CNodeFiles genCNodeWrapper(CNodeGenCtx ctx) {
  switch (ctx.node.typeId) {
    case 'gamma':
      return _genGamma(ctx);
    case 'ccm':
      return _genCcm(ctx);
    case 'white_balance':
      return _genWhiteBalance(ctx);
    case 'csc_rgb2yuv':
    case 'csc_rgb2hsl':
    case 'csc_yuv2rgb':
    case 'csc_yuv2hsl':
    case 'csc_hsl2rgb':
    case 'csc_hsl2yuv':
      return _genCsc(ctx);
  }
  return genRawDomainCNode(ctx) ??
      genRgbDomainCNode(ctx) ??
      genAdjusterCNode(ctx) ??
      genFluoroCNode(ctx) ??
      genDatapathCNode(ctx) ??
      (throw ArgumentError('节点类型 ${ctx.node.typeId} 暂不支持 C 代码导出'));
}

/// gamma：16 位交织 RGB → 8 位 RGBA 色调映射（链尾）。
/// Bypass 语义：Dart 侧跳过本节点后由链尾默认色调映射出图，封装对应
/// 退化为默认参数（gamma=2.2, brightness=0, contrast=1）。
CNodeFiles _genGamma(CNodeGenCtx ctx) {
  final m = ctx.macro;
  // 与 pipeline_runner 一致：gamma <= 0 回退 2.2，contrast <= 0 回退 1.0。
  final gamma = ctx.doubleParam('gamma') <= 0 ? 2.2 : ctx.doubleParam('gamma');
  final contrast =
      ctx.doubleParam('contrast') <= 0 ? 1.0 : ctx.doubleParam('contrast');
  return assembleCNode(
    ctx: ctx,
    algoIncludes: const ['isp_gamma.h'],
    inputs: const [CPort('in', channels: 3)],
    outputs: const [CPort('out_rgba', cType: 'uint8_t', channels: 4)],
    macroLines: [
      '#define ${m}_GAMMA ${cNum(gamma)}',
      '#define ${m}_BRIGHTNESS ${cNum(ctx.doubleParam('brightness'))}',
      '#define ${m}_CONTRAST ${cNum(contrast)}',
    ],
    scratchExpr: 'ISP_GAMMA_LUT_BYTES(max_value)',
    body: '''
  /* Bypass：退化为默认色调映射（见文件头注释）。 */
  const double g = ${m}_BYPASS ? 2.2 : ${m}_GAMMA;
  const double br = ${m}_BYPASS ? 0.0 : ${m}_BRIGHTNESS;
  const double ct = ${m}_BYPASS ? 1.0 : ${m}_CONTRAST;
  return isp_gamma_tonemap_to_rgba(in, w, h, max_value, g, br, ct,
                                   out_rgba, (uint8_t *)scratch);''',
  );
}

/// ccm：3x3 色彩校正矩阵（原地，烘焙为 static const double[9]）。
CNodeFiles _genCcm(CNodeGenCtx ctx) {
  final m = ctx.macro;
  final raw = ctx.param('matrix');
  final values = [
    for (var i = 0; i < 9; i++)
      cNum(raw is List && i < raw.length ? (raw[i] as num).toDouble() : (i % 4 == 0 ? 1.0 : 0.0)),
  ];
  const input = CPort('in', channels: 3);
  const output = CPort('out', channels: 3);
  return assembleCNode(
    ctx: ctx,
    algoIncludes: const ['isp_ccm.h'],
    inputs: const [input],
    outputs: const [output],
    macroLines: const [],
    body: '''
  static const double ${ctx.ident}_matrix[9] = {
    ${values.join(', ')},
  };
${copyInToOut(input, output, '  ')}
  if (${m}_BYPASS) return ISP_OK;
  return isp_ccm_apply(out, w, h, ${ctx.ident}_matrix, max_value);''',
  );
}

/// white_balance：auto=灰度世界增益估计+施加；manual=直接施加烘焙增益。
/// LUT 模式（codegenMode=lut）：manual 时按生成期参数烘焙双通道查找表
/// （域 0..ctx.lutDomainMax，源自上游位深），运行时 max_value 一致走纯
/// 查表、不一致回退直算；auto 时增益运行期才能确定，改为运行期在
/// scratch 建表后查表（消灭逐像素乘法，建表成本 max_value+1 次求值）。
CNodeFiles _genWhiteBalance(CNodeGenCtx ctx) {
  final m = ctx.macro;
  final auto = ctx.strParam('mode') == 'auto';
  final lutMode = ctx.strParam('codegenMode') == 'lut';
  const input = CPort('in', channels: 3);
  const output = CPort('out', channels: 3);
  final rGain = ctx.doubleParam('rGain') <= 0 ? 1.0 : ctx.doubleParam('rGain');
  final bGain = ctx.doubleParam('bGain') <= 0 ? 1.0 : ctx.doubleParam('bGain');
  final macroLines = auto
      ? const <String>[]
      : [
          '#define ${m}_RGAIN ${cNum(rGain)}',
          '#define ${m}_BGAIN ${cNum(bGain)}',
        ];
  if (lutMode && !auto) {
    // 烘焙表由 Dart 建表函数生成（与预览同函数，位级一致）。
    final lutR = whiteBalanceGainLut(rGain, ctx.lutDomainMax);
    final lutB = whiteBalanceGainLut(bGain, ctx.lutDomainMax);
    return assembleCNode(
      ctx: ctx,
      algoIncludes: const ['isp_white_balance.h'],
      inputs: const [input],
      outputs: const [output],
      macroLines: macroLines,
      body: '''
  /* LUT 模式：以下两表由生成期按节点参数烘焙（Dart whiteBalanceGainLut，
   * 域 0..${ctx.lutDomainMax}）；运行时 max_value 与烘焙域一致走纯查表，
   * 不一致回退直算（与函数方式同公式，数值一致）。 */
  static const uint16_t ${ctx.ident}_lut_r[${ctx.lutDomainMax + 1}] = {
${cU16Table(lutR)}
  };
  static const uint16_t ${ctx.ident}_lut_b[${ctx.lutDomainMax + 1}] = {
${cU16Table(lutB)}
  };
${copyInToOut(input, output, '  ')}
  if (${m}_BYPASS) return ISP_OK;
  if (max_value == ${ctx.lutDomainMax}) {
    return isp_white_balance_lut_apply(out, w, h, ${ctx.ident}_lut_r,
                                       ${ctx.ident}_lut_b, max_value);
  }
  return isp_white_balance_apply(out, w, h, ${m}_RGAIN, ${m}_BGAIN,
                                 max_value);''',
    );
  }
  final applyLines = lutMode
      ? '''
  /* auto + LUT：增益运行期估计，scratch 建表后查表。 */
  double r_gain = 1.0, b_gain = 1.0;
  uint16_t *lut_r = (uint16_t *)scratch;
  uint16_t *lut_b = lut_r + ((size_t)max_value + 1u);
  int rc = isp_white_balance_auto_gains(out, w, h, 16, &r_gain, &b_gain);
  if (rc != ISP_OK) return rc;
  isp_white_balance_build_lut(r_gain, max_value, lut_r);
  isp_white_balance_build_lut(b_gain, max_value, lut_b);'''
      : auto
          ? '''
  /* auto 模式：灰度世界增益估计（采样步长 16，与 Dart 缺省一致）。 */
  double r_gain = 1.0, b_gain = 1.0;
  int rc = isp_white_balance_auto_gains(out, w, h, 16, &r_gain, &b_gain);
  if (rc != ISP_OK) return rc;'''
          : '''
  const double r_gain = ${m}_RGAIN;
  const double b_gain = ${m}_BGAIN;''';
  return assembleCNode(
    ctx: ctx,
    algoIncludes: const ['isp_white_balance.h'],
    inputs: const [input],
    outputs: const [output],
    macroLines: macroLines,
    scratchExpr: lutMode && auto
        ? '(size_t)(max_value + 1) * 2u * sizeof(uint16_t)'
        : null,
    body: '''
${copyInToOut(input, output, '  ')}
  if (${m}_BYPASS) return ISP_OK;
$applyLines
  return ${lutMode && auto ? 'isp_white_balance_lut_apply(out, w, h, lut_r, lut_b, max_value)' : 'isp_white_balance_apply(out, w, h, r_gain, b_gain, max_value)'};''',
  );
}

/// ColorTrans：6 个色彩空间转换类型（单进单出 3 通道，非原地）。
/// 仅 csc_rgb2yuv 带 standard/range 枚举参数（BT.601/709、全/有限范围），
/// 其余为 BT.601 全范围定点无参转换。Bypass 直通为同布局 memcpy。
CNodeFiles _genCsc(CNodeGenCtx ctx) {
  final m = ctx.macro;
  // 变体头一一对应（isp_csc 全家桶已按变体拆分）：wrapper 只 #include
  // 实际用到的变体头 + 共享内部头 isp_csc_common.h。
  final (fn, header) = switch (ctx.node.typeId) {
    'csc_rgb2yuv' => ('isp_csc_rgb_to_yuv', 'isp_csc_rgb2yuv.h'),
    'csc_rgb2hsl' => ('isp_csc_rgb_to_hsl', 'isp_csc_rgb2hsl.h'),
    'csc_yuv2rgb' => ('isp_csc_yuv_to_rgb', 'isp_csc_yuv2rgb.h'),
    'csc_yuv2hsl' => ('isp_csc_yuv_to_hsl', 'isp_csc_yuv2hsl.h'),
    'csc_hsl2rgb' => ('isp_csc_hsl_to_rgb', 'isp_csc_hsl2rgb.h'),
    'csc_hsl2yuv' => ('isp_csc_hsl_to_yuv', 'isp_csc_hsl2yuv.h'),
    _ => throw ArgumentError('非 ColorTrans 类型: ${ctx.node.typeId}'),
  };
  final withStdRange = ctx.node.typeId == 'csc_rgb2yuv';
  const input = CPort('in', channels: 3);
  const output = CPort('out', channels: 3);
  return assembleCNode(
    ctx: ctx,
    algoIncludes: ['isp_csc_common.h', header],
    inputs: const [input],
    outputs: const [output],
    macroLines: withStdRange
        ? [
            '#define ${m}_STANDARD ${ctx.strParam('standard') == 'bt709' ? 'ISP_CSC_BT709' : 'ISP_CSC_BT601'}',
            '#define ${m}_RANGE ${ctx.strParam('range') == 'limited' ? 'ISP_CSC_RANGE_LIMITED' : 'ISP_CSC_RANGE_FULL'}',
          ]
        : const [],
    body: '''
  if (${m}_BYPASS) {
${copyInToOut(input, output, '    ')}
    return ISP_OK;
  }
  return $fn(in, w, h, max_value, ${withStdRange ? '${m}_STANDARD, ${m}_RANGE, ' : ''}out);''',
  );
}
