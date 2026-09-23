/// ISP 编组导出 C 代码：荧光 mono 域节点模板。
///
/// 覆盖类型：fluoro_leak / fluoro_background / fluoro_normalize /
/// fluoro_temporal / pseudo_color / fluoro_fusion。
/// c_ref 头：isp_fluoro.h（多为原地 mono 算子；pseudo_color 为
/// mono→rgb；fluoro_fusion 为 rgb 白光 + mono 荧光 → rgb）。
library;

import '../pipeline/isp_kernels.dart';
import 'node_c_gen.dart';

/// 生成荧光 mono 域节点实例的 C 封装。未命中返回 null。
CNodeFiles? genFluoroCNode(CNodeGenCtx ctx) {
  switch (ctx.node.typeId) {
    case 'fluoro_leak':
      return _genFluoroLeak(ctx);
    case 'fluoro_background':
      return _genFluoroBackground(ctx);
    case 'fluoro_normalize':
      return _genFluoroNormalize(ctx);
    case 'fluoro_temporal':
      return _genFluoroTemporal(ctx);
    case 'pseudo_color':
      return _genPseudoColor(ctx);
    case 'fluoro_fusion':
      return _genFluoroFusion(ctx);
  }
  return null;
}

/// 色表字符串 → c_ref 枚举常量（Dart 空串回退 'green'，未知值同兜底）。
String _fluoroColormapEnum(String v) => switch (v) {
      'magenta' => 'ISP_FLUORO_CMAP_MAGENTA',
      'hot' => 'ISP_FLUORO_CMAP_HOT',
      _ => 'ISP_FLUORO_CMAP_GREEN',
    };

/// 融合模式字符串 → c_ref 枚举常量（Dart 空串回退 'alpha'）。
String _fluoroFusionModeEnum(String v) =>
    v == 'contour' ? 'ISP_FLUORO_FUSION_CONTOUR' : 'ISP_FLUORO_FUSION_ALPHA';

/// fluoro_leak：激发泄漏统一电平扣除（原地，扣除量限幅 maxSub）。
CNodeFiles _genFluoroLeak(CNodeGenCtx ctx) {
  final m = ctx.macro;
  // 端口名与注册表一致（in_mono/out_mono）：top 层按注册表端口名解析
  // 边缓冲/外部端口，错名会导致「既不是组内边也不是组输出」。
  const input = CPort('in_mono');
  const output = CPort('out_mono');
  return assembleCNode(
    ctx: ctx,
    algoIncludes: const ['isp_fluoro.h'],
    inputs: const [input],
    outputs: const [output],
    macroLines: [
      '#define ${m}_LEVEL ${cNum(ctx.doubleParam('level'))}',
      '#define ${m}_MAX_SUB ${cNum(ctx.doubleParam('maxSub'))}',
    ],
    body: '''
${copyInToOut(input, output, '  ')}
  if (${m}_BYPASS) return ISP_OK;
  return isp_fluoro_leak_apply(out_mono, w, h, ${m}_LEVEL, ${m}_MAX_SUB);''',
  );
}

/// fluoro_background：块均值低频背景估计 + 按比例扣除（原地，需 scratch）。
CNodeFiles _genFluoroBackground(CNodeGenCtx ctx) {
  final m = ctx.macro;
  const input = CPort('in_mono');
  const output = CPort('out_mono');
  return assembleCNode(
    ctx: ctx,
    algoIncludes: const ['isp_fluoro.h'],
    inputs: const [input],
    outputs: const [output],
    macroLines: [
      '#define ${m}_BLOCK_SIZE ${cNum(ctx.intParam('blockSize'), asDouble: false)}',
      '#define ${m}_STRENGTH ${cNum(ctx.doubleParam('strength'))}',
    ],
    scratchExpr: 'ISP_FLUORO_BACKGROUND_SCRATCH_BYTES(w, h, ${m}_BLOCK_SIZE)',
    body: '''
${copyInToOut(input, output, '  ')}
  if (${m}_BYPASS) return ISP_OK;
  return isp_fluoro_background_apply(out_mono, w, h, ${m}_BLOCK_SIZE,
                                     ${m}_STRENGTH, scratch);''',
  );
}

/// fluoro_normalize：全帧均值归一化到参考电平（原地）。
CNodeFiles _genFluoroNormalize(CNodeGenCtx ctx) {
  final m = ctx.macro;
  const input = CPort('in_mono');
  const output = CPort('out_mono');
  return assembleCNode(
    ctx: ctx,
    algoIncludes: const ['isp_fluoro.h'],
    inputs: const [input],
    outputs: const [output],
    macroLines: [
      '#define ${m}_REFERENCE ${cNum(ctx.doubleParam('reference'))}',
      '#define ${m}_EPSILON ${cNum(ctx.doubleParam('epsilon'))}',
    ],
    body: '''
${copyInToOut(input, output, '  ')}
  if (${m}_BYPASS) return ISP_OK;
  return isp_fluoro_normalize_apply(out_mono, w, h, ${m}_REFERENCE,
                                    ${m}_EPSILON, max_value);''',
  );
}

/// fluoro_temporal：时域 IIR 降噪 Y = αF + (1−α)Yprev（跨帧 history）。
/// history 为持久缓冲（top 从竞技场持久区分配）；wrapper 内 static
/// `s_<ident>_has_history` 记录首帧（变量名含 ident，多实例不冲突）。
/// Bypass 时直通且不触碰 history（与 Dart 跳过节点一致）。
CNodeFiles _genFluoroTemporal(CNodeGenCtx ctx) {
  final m = ctx.macro;
  const input = CPort('in_mono');
  const output = CPort('out_mono');
  const history = CPort('history', isPersistent: true);
  return assembleCNode(
    ctx: ctx,
    algoIncludes: const ['isp_fluoro.h'],
    inputs: const [input],
    outputs: const [output, history],
    macroLines: [
      '#define ${m}_ALPHA ${cNum(ctx.doubleParam('alpha'))}',
      '#define ${m}_MOTION_ADAPT ${ctx.boolParam('motionAdapt') ? 1 : 0}',
    ],
    body: '''
  static bool s_${ctx.ident}_has_history = false;
  if (${m}_BYPASS) {
${copyInToOut(input, output, '    ')}
    return ISP_OK;
  }
  {
    const int rc = isp_fluoro_temporal_iir_apply(
        in_mono, history, s_${ctx.ident}_has_history, out_mono, w, h,
        ${m}_ALPHA, ${m}_MOTION_ADAPT, max_value);
    if (rc == ISP_OK) s_${ctx.ident}_has_history = true;
    return rc;
  }''',
  );
}

/// pseudo_color：mono → 伪彩 RGB（链尾映射）。
/// Bypass 语义：Dart 跳过本节点后 mono 帧原样下行，封装对应退化为
/// 灰度直通（mono 原值复制到三个通道，视觉上不变）。
CNodeFiles _genPseudoColor(CNodeGenCtx ctx) {
  final m = ctx.macro;
  if (ctx.strParam('codegenMode') == 'lut') {
    // LUT 模式：色表三通道按生成期参数烘焙（Dart pseudoColorLuts，域
    // 0..ctx.lutDomainMax）；运行时 max_value 一致走纯查表，不一致回退
    // 直算（与函数方式同公式，数值一致）。
    final (lutR, lutG, lutB) = pseudoColorLuts(
        ctx.strParam('colormap'), ctx.doubleParam('gain'), ctx.lutDomainMax);
    const input = CPort('in_mono');
    const output = CPort('out', channels: 3);
    return assembleCNode(
      ctx: ctx,
      algoIncludes: const ['isp_fluoro.h'],
      inputs: const [input],
      outputs: const [output],
      macroLines: const [],
      body: '''
  /* LUT 模式：以下三张色表由生成期按节点参数烘焙（Dart
   * pseudoColorLuts，域 0..${ctx.lutDomainMax}）。 */
  static const uint16_t ${ctx.ident}_lut_r[${ctx.lutDomainMax + 1}] = {
${cU16Table(lutR)}
  };
  static const uint16_t ${ctx.ident}_lut_g[${ctx.lutDomainMax + 1}] = {
${cU16Table(lutG)}
  };
  static const uint16_t ${ctx.ident}_lut_b[${ctx.lutDomainMax + 1}] = {
${cU16Table(lutB)}
  };
  if (${m}_BYPASS) {
    /* Bypass：灰度直通（mono 原值复制到三个通道，见文件头注释）。 */
    int i = 0;
    const int n = w * h;
    for (i = 0; i < n; i++) {
      out[i * 3] = in_mono[i];
      out[i * 3 + 1] = in_mono[i];
      out[i * 3 + 2] = in_mono[i];
    }
    return ISP_OK;
  }
  if (max_value == ${ctx.lutDomainMax}) {
    return isp_fluoro_pseudo_color_lut_apply(in_mono, out, w, h,
        ${ctx.ident}_lut_r, ${ctx.ident}_lut_g, ${ctx.ident}_lut_b,
        max_value);
  }
  /* 回退直算（与函数方式同公式）。 */
  return isp_fluoro_pseudo_color_apply(in_mono, out, w, h,
                                       (IspFluoroColormap)${m}_COLORMAP,
                                       ${m}_GAIN, max_value);''',
    );
  }
  return assembleCNode(
    ctx: ctx,
    algoIncludes: const ['isp_fluoro.h'],
    inputs: const [CPort('in_mono')],
    outputs: const [CPort('out', channels: 3)],
    macroLines: [
      '#define ${m}_COLORMAP ${_fluoroColormapEnum(ctx.strParam('colormap'))}',
      '#define ${m}_GAIN ${cNum(ctx.doubleParam('gain'))}',
    ],
    body: '''
  if (${m}_BYPASS) {
    /* Bypass：灰度直通（mono 原值复制到三个通道，见文件头注释）。 */
    int i = 0;
    const int n = w * h;
    for (i = 0; i < n; i++) {
      out[i * 3] = in_mono[i];
      out[i * 3 + 1] = in_mono[i];
      out[i * 3 + 2] = in_mono[i];
    }
    return ISP_OK;
  }
  return isp_fluoro_pseudo_color_apply(in_mono, out, w, h,
                                       (IspFluoroColormap)${m}_COLORMAP,
                                       ${m}_GAIN, max_value);''',
  );
}

/// fluoro_fusion：白光 RGB + 荧光 mono 融合出图（alpha/contour 两模式）。
/// in_fluoro 未连接时（inputFormats 无此项）与 Dart 一致：白光直通，
/// 封装退化为单输入拷贝。
CNodeFiles _genFluoroFusion(CNodeGenCtx ctx) {
  final m = ctx.macro;
  const input = CPort('in', channels: 3);
  const fluoro = CPort('in_fluoro');
  const output = CPort('out', channels: 3);
  final hasFluoro = ctx.inputFormats.containsKey('in_fluoro');
  if (!hasFluoro) {
    return assembleCNode(
      ctx: ctx,
      algoIncludes: const ['isp_fluoro.h'],
      inputs: const [input],
      outputs: const [output],
      macroLines: const [],
      body: '''
  /* 荧光输入未连接：白光直通（与 Dart 运行时语义一致）。 */
${copyInToOut(input, output, '  ')}
  return ISP_OK;''',
    );
  }
  return assembleCNode(
    ctx: ctx,
    algoIncludes: const ['isp_fluoro.h'],
    inputs: const [input, fluoro],
    outputs: const [output],
    macroLines: [
      '#define ${m}_MODE ${_fluoroFusionModeEnum(ctx.strParam('mode'))}',
      '#define ${m}_THRESHOLD ${cNum(ctx.doubleParam('threshold'))}',
      '#define ${m}_ALPHA_MAX ${cNum(ctx.doubleParam('alphaMax'))}',
      '#define ${m}_COLORMAP ${_fluoroColormapEnum(ctx.strParam('colormap'))}',
      '#define ${m}_OFFSET_X ${cNum(ctx.doubleParam('offsetX'))}',
      '#define ${m}_OFFSET_Y ${cNum(ctx.doubleParam('offsetY'))}',
    ],
    body: '''
  if (${m}_BYPASS) {
    /* Bypass：白光直通（与 Dart 跳过节点一致）。 */
${copyInToOut(input, output, '    ')}
    return ISP_OK;
  }
  return isp_fluoro_fuse_apply(in, in_fluoro, out, w, h,
                               (IspFluoroFusionMode)${m}_MODE,
                               ${m}_THRESHOLD, ${m}_ALPHA_MAX,
                               (IspFluoroColormap)${m}_COLORMAP,
                               ${m}_OFFSET_X, ${m}_OFFSET_Y, max_value);''',
  );
}
