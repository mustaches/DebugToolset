/// ISP 编组导出 C 代码：RAW 域算子模板（black_level / dpc / fpn / lsc /
/// grgb_balance / bayer_dnr / highlight）。
///
/// 本批 7 个类型均为双形态端口（in(bayer)/in_mono(mono) 互斥输入，
/// out/out_mono 互斥输出，通道数恒为 1），按 ctx.inputFormats 选路：
/// - bayer 路径：pattern 烘焙为 ISP_BAYER_* 枚举（按值传参的类型直接传
///   枚举；const IspBayerPattern* 类型在函数体内取局部常量地址）；
/// - mono 路径：调 _mono 变体（black_level）或 pattern 传 NULL
///   （dpc / bayer_dnr / highlight）；grgb_balance 的 mono 路径在 Dart 侧
///   本就直通（无 Gr/Gb 相位概念），封装同样退化为纯拷贝。
///
/// Bypass（{MACRO}_BYPASS，框架自动注入）：out != in 先 memcpy 直通，
/// 随后早退 ISP_OK。
library;

import '../pipeline/isp_kernels.dart';
import 'node_c_gen.dart';

/// RAW 域双形态选路：活动输入为 in_mono（mono）时返回 true。
/// 两端口都不在 inputFormats 时按首要端口 in（bayer）处理。
bool _isMonoPath(CNodeGenCtx ctx) {
  final f = ctx.inputFormats;
  if (f.containsKey('in')) return false;
  return f.containsKey('in_mono');
}

/// BayerPattern 烘焙：节点带 cfaPattern 参数时取其值；本批 7 个类型均无
/// 该参数（pattern 运行时来自上游帧），按 Dart 侧
/// `frame.bayerPattern ?? BayerPattern.rggb` 的回退语义烘焙 RGGB。
String _bayerPatternEnum(CNodeGenCtx ctx) {
  switch (ctx.strParam('cfaPattern').toUpperCase()) {
    case 'BGGR':
      return 'ISP_BAYER_BGGR';
    case 'GRBG':
      return 'ISP_BAYER_GRBG';
    case 'GBRG':
      return 'ISP_BAYER_GBRG';
    default:
      return 'ISP_BAYER_RGGB';
  }
}

/// 按选路结果取输入/输出端口（mono 路径用 in_mono/out_mono）。
CPort _rawInPort(bool mono) => CPort(mono ? 'in_mono' : 'in');
CPort _rawOutPort(bool mono) => CPort(mono ? 'out_mono' : 'out');

/// 原地算子公共前奏：out != in 先 memcpy，Bypass 早退直通。
String _copyAndBypass(CPort input, CPort output, String macro) => '''
${copyInToOut(input, output, '  ')}
  if (${macro}_BYPASS) return ISP_OK;''';

/// RAW 域算子 C 封装生成入口。命中本文件负责的 7 个类型返回封装，
/// 否则返回 null（交由其他域模板处理）。
CNodeFiles? genRawDomainCNode(CNodeGenCtx ctx) {
  switch (ctx.node.typeId) {
    case 'black_level':
      return _genBlackLevel(ctx);
    case 'dpc':
      return _genDpc(ctx);
    case 'fpn':
      return _genFpn(ctx);
    case 'lsc':
      return _genLsc(ctx);
    case 'grgb_balance':
      return _genGrgbBalance(ctx);
    case 'bayer_dnr':
      return _genBayerDnr(ctx);
    case 'highlight':
      return _genHighlight(ctx);
  }
  return null;
}

/// black_level：bayer 按 2x2 四相位分别扣偏移；mono 用 r 作统一偏移。
CNodeFiles _genBlackLevel(CNodeGenCtx ctx) {
  final m = ctx.macro;
  final mono = _isMonoPath(ctx);
  final input = _rawInPort(mono);
  final output = _rawOutPort(mono);
  final macroLines = [
    '#define ${m}_R ${cNum(ctx.doubleParam('r'))}',
    if (!mono) ...[
      '#define ${m}_GR ${cNum(ctx.doubleParam('gr'))}',
      '#define ${m}_GB ${cNum(ctx.doubleParam('gb'))}',
      '#define ${m}_B ${cNum(ctx.doubleParam('b'))}',
      '#define ${m}_PATTERN ${_bayerPatternEnum(ctx)}',
    ],
  ];
  final applyLine = mono
      // mono 路径：Dart 在 off == 0 时整体跳过，c_ref 统一逐像素处理，
      // 结果逐位一致（见 isp_black_level.h 注释）。
      ? 'return isp_black_level_apply_mono(out_mono, w, h, ${m}_R);'
      : 'return isp_black_level_apply(out, w, h, ${m}_PATTERN,\n'
          '                                   ${m}_R, ${m}_GR, ${m}_GB, ${m}_B);';
  return assembleCNode(
    ctx: ctx,
    algoIncludes: const ['isp_black_level.h'],
    inputs: [input],
    outputs: [output],
    macroLines: macroLines,
    body: '''
${_copyAndBypass(input, output, m)}
  $applyLine''',
  );
}

/// dpc：离群超阈值替换坏点；median/directional 映射 IspDpcMode。
/// Dart 侧 mode 为空串回退 'median'；未知串同 median 语义（非 directional
/// 一律按 median 处理）。
CNodeFiles _genDpc(CNodeGenCtx ctx) {
  final m = ctx.macro;
  final mono = _isMonoPath(ctx);
  final input = _rawInPort(mono);
  final output = _rawOutPort(mono);
  final outName = output.name;
  final modeEnum = ctx.strParam('mode') == 'directional'
      ? 'ISP_DPC_DIRECTIONAL'
      : 'ISP_DPC_MEDIAN';
  final patternArg = mono ? 'NULL' : '&pattern';
  return assembleCNode(
    ctx: ctx,
    algoIncludes: const ['isp_dpc.h'],
    inputs: [input],
    outputs: [output],
    macroLines: [
      '#define ${m}_THRESHOLD ${cNum(ctx.doubleParam('threshold'))}',
      '#define ${m}_MODE $modeEnum',
      if (!mono) '#define ${m}_PATTERN ${_bayerPatternEnum(ctx)}',
    ],
    body: '''
${_copyAndBypass(input, output, m)}
${mono ? '' : '  const IspBayerPattern pattern = ${m}_PATTERN;\n'}  return isp_dpc_apply($outName, w, h, $patternArg, ${m}_THRESHOLD,
                         ${m}_MODE, max_value);''',
  );
}

/// fpn：行/列固定图案噪声校正（估计与施加分离 + 边缘掩膜）。
/// bool 参数直译为 int（c_ref 签名为 int row_enable / int col_enable）。
/// radius 节点无参数，烘焙 Dart 默认值 8。
CNodeFiles _genFpn(CNodeGenCtx ctx) {
  final m = ctx.macro;
  final mono = _isMonoPath(ctx);
  final input = _rawInPort(mono);
  final output = _rawOutPort(mono);
  final outName = output.name;
  return assembleCNode(
    ctx: ctx,
    algoIncludes: const ['isp_fpn.h'],
    inputs: [input],
    outputs: [output],
    macroLines: [
      '#define ${m}_ROW ${ctx.boolParam('row') ? 1 : 0}',
      '#define ${m}_COL ${ctx.boolParam('col') ? 1 : 0}',
      '#define ${m}_MAXCORR ${cNum(ctx.doubleParam('maxCorr'))}',
      '#define ${m}_RADIUS 8',
    ],
    scratchExpr: 'ISP_FPN_SCRATCH_BYTES(w, h)',
    body: '''
${_copyAndBypass(input, output, m)}
  return isp_fpn_apply($outName, w, h, ${m}_ROW, ${m}_COL, ${m}_MAXCORR,
                       ${m}_RADIUS, scratch,
                       ${m}_SCRATCH_BYTES(w, h, max_value));''',
  );
}

/// lsc：径向二次增益曲面校正。增益与相位无关，bayer/mono 同一路径
/// （c_ref 接口无 pattern 参数）。
CNodeFiles _genLsc(CNodeGenCtx ctx) {
  final m = ctx.macro;
  final mono = _isMonoPath(ctx);
  final input = _rawInPort(mono);
  final output = _rawOutPort(mono);
  final outName = output.name;
  return assembleCNode(
    ctx: ctx,
    algoIncludes: const ['isp_lsc.h'],
    inputs: [input],
    outputs: [output],
    macroLines: [
      '#define ${m}_STRENGTH ${cNum(ctx.doubleParam('strength'))}',
      '#define ${m}_CENTERX ${cNum(ctx.doubleParam('centerX'))}',
      '#define ${m}_CENTERY ${cNum(ctx.doubleParam('centerY'))}',
    ],
    body: '''
${_copyAndBypass(input, output, m)}
  return isp_lsc_apply($outName, w, h, ${m}_STRENGTH, ${m}_CENTERX,
                       ${m}_CENTERY, max_value);''',
  );
}

/// grgb_balance：Gr/Gb 相位均衡，仅 Bayer 有意义；mono 路径 Dart 侧
/// 直通（pattern 为 null 不处理），封装退化为纯拷贝。
CNodeFiles _genGrgbBalance(CNodeGenCtx ctx) {
  final m = ctx.macro;
  final mono = _isMonoPath(ctx);
  final input = _rawInPort(mono);
  final output = _rawOutPort(mono);
  return assembleCNode(
    ctx: ctx,
    algoIncludes: const ['isp_grgb_balance.h'],
    inputs: [input],
    outputs: [output],
    macroLines: mono
        ? const []
        : [
            '#define ${m}_STRENGTH ${cNum(ctx.doubleParam('strength'))}',
            '#define ${m}_PATTERN ${_bayerPatternEnum(ctx)}',
          ],
    body: mono
        ? '''
${copyInToOut(input, output, '  ')}
  /* mono 无 Gr/Gb 相位概念，直通（与 Dart 运行时一致）。 */
  return ISP_OK;'''
        : '''
${_copyAndBypass(input, output, m)}
  return isp_grgb_balance_apply(out, w, h, ${m}_PATTERN, ${m}_STRENGTH);''',
  );
}

/// bayer_dnr：同相位 3x3 保边加权降噪；scratch 为整帧 uint16 快照。
CNodeFiles _genBayerDnr(CNodeGenCtx ctx) {
  final m = ctx.macro;
  final mono = _isMonoPath(ctx);
  final input = _rawInPort(mono);
  final output = _rawOutPort(mono);
  final outName = output.name;
  final patternArg = mono ? 'NULL' : '&pattern';
  return assembleCNode(
    ctx: ctx,
    algoIncludes: const ['isp_bayer_dnr.h'],
    inputs: [input],
    outputs: [output],
    macroLines: [
      '#define ${m}_STRENGTH ${cNum(ctx.doubleParam('strength'))}',
      if (!mono) '#define ${m}_PATTERN ${_bayerPatternEnum(ctx)}',
    ],
    scratchExpr: 'ISP_BAYER_DNR_SCRATCH_BYTES(w, h)',
    body: '''
${_copyAndBypass(input, output, m)}
${mono ? '' : '  const IspBayerPattern pattern = ${m}_PATTERN;\n'}  return isp_bayer_dnr_apply($outName, w, h, $patternArg, ${m}_STRENGTH,
                               (uint16_t *)scratch);''',
  );
}

/// highlight：recover 模式同相位邻域重建 / clip 模式膝点软压缩。
/// scratch 为整帧快照（clip 模式不用，但仍统一分配，top 无需特判）。
/// Dart 侧 mode 为空串回退 'recover'，非 'clip' 一律走 recover 分支。
CNodeFiles _genHighlight(CNodeGenCtx ctx) {
  final m = ctx.macro;
  final mono = _isMonoPath(ctx);
  final input = _rawInPort(mono);
  final output = _rawOutPort(mono);
  final outName = output.name;
  final modeEnum = ctx.strParam('mode') == 'clip'
      ? 'ISP_HIGHLIGHT_CLIP'
      : 'ISP_HIGHLIGHT_RECOVER';
  final patternArg = mono ? 'NULL' : '&pattern';
  // LUT 模式（codegenMode=lut）仅 clip 分支：膝点压缩表按生成期参数
  // 烘焙（Dart highlightClipLut，膝点/满量程按烘焙域 ctx.lutDomainMax
  // 计算），运行时 max_value 一致走纯查表，不一致回退直算；recover
  // 分支邻域均值不可表化，仍走原实现。
  final lutMode = ctx.strParam('codegenMode') == 'lut' &&
      ctx.strParam('mode') == 'clip';
  if (lutMode) {
    final lut = highlightClipLut(ctx.doubleParam('knee'), ctx.lutDomainMax);
    return assembleCNode(
      ctx: ctx,
      algoIncludes: const ['isp_highlight.h'],
      inputs: [input],
      outputs: [output],
      macroLines: [
        '#define ${m}_MODE $modeEnum',
        '#define ${m}_KNEE ${cNum(ctx.doubleParam('knee'))}',
        if (!mono) '#define ${m}_PATTERN ${_bayerPatternEnum(ctx)}',
      ],
      scratchExpr: 'ISP_HIGHLIGHT_SCRATCH_BYTES(w, h)',
      body: '''
  /* LUT 模式：膝点压缩表由生成期按 knee 参数烘焙（Dart
   * highlightClipLut，域 0..${ctx.lutDomainMax}）。 */
  static const uint16_t ${ctx.ident}_clip_lut[${ctx.lutDomainMax + 1}] = {
${cU16Table(lut)}
  };
${_copyAndBypass(input, output, m)}
  if (max_value == ${ctx.lutDomainMax}) {
    return isp_highlight_clip_lut_apply($outName, w, h, ${ctx.ident}_clip_lut);
  }
${mono ? '' : '  const IspBayerPattern pattern = ${m}_PATTERN;\n'}  return isp_highlight_apply($outName, w, h, $patternArg, max_value,
                               ${m}_MODE, ${m}_KNEE, (uint16_t *)scratch);''',
    );
  }
  return assembleCNode(
    ctx: ctx,
    algoIncludes: const ['isp_highlight.h'],
    inputs: [input],
    outputs: [output],
    macroLines: [
      '#define ${m}_MODE $modeEnum',
      '#define ${m}_KNEE ${cNum(ctx.doubleParam('knee'))}',
      if (!mono) '#define ${m}_PATTERN ${_bayerPatternEnum(ctx)}',
    ],
    scratchExpr: 'ISP_HIGHLIGHT_SCRATCH_BYTES(w, h)',
    body: '''
${_copyAndBypass(input, output, m)}
${mono ? '' : '  const IspBayerPattern pattern = ${m}_PATTERN;\n'}  return isp_highlight_apply($outName, w, h, $patternArg, max_value,
                               ${m}_MODE, ${m}_KNEE, (uint16_t *)scratch);''',
  );
}
