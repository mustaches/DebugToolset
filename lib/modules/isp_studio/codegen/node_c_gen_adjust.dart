/// ISP 编组导出 C 代码：调节器域节点模板（9 个类型）。
///
/// 覆盖：hsl_debugger / rgb_debugger / yuv_debugger / sat_bright_adjuster /
/// bright_contrast_adjuster / color_balance（以上共用 isp_adjust.h）、
/// color_controller（isp_color_controller.h，src/dst 分离）、
/// levels_curves（isp_levels.h，生成期按图表曲线烘焙 4096 级 LUT）、
/// color_temp_adjuster（isp_color_temp.h 增益计算 + isp_adjust.h 施加）。
///
/// 参数回退口径全部与 pipeline_runner.dart 各 case 一致（各 runner 回退值
/// 恰等于 isp_node.dart 的参数默认值，故直接经 ctx.doubleParam 等取值的
/// 结果与运行时语义相同）；多形态节点（互斥输入组）按 ctx.inputFormats 选
/// 活动端口，封装只含活动端口形参，IspAdjustFormat 由帧格式推导。
library;

import '../pipeline/color_temp.dart';
import '../pipeline/isp_kernels.dart';
import '../pipeline/levels_curve.dart';
import 'node_c_gen.dart';

/// 调节器域入口：命中返回封装，未命中返回 null。
CNodeFiles? genAdjusterCNode(CNodeGenCtx ctx) {
  switch (ctx.node.typeId) {
    case 'hsl_debugger':
      return _genHslDebugger(ctx);
    case 'rgb_debugger':
      return _genRgbDebugger(ctx);
    case 'yuv_debugger':
      return _genYuvDebugger(ctx);
    case 'sat_bright_adjuster':
      return _genSatBright(ctx);
    case 'bright_contrast_adjuster':
      return _genBrightContrast(ctx);
    case 'color_balance':
      return _genColorBalance(ctx);
    case 'color_controller':
      return _genColorController(ctx);
    case 'levels_curves':
      return _genLevelsCurves(ctx);
    case 'color_temp_adjuster':
      return _genColorTempAdjuster(ctx);
  }
  return null;
}

/// 帧格式 → IspAdjustFormat 枚举常量。
String _adjustFormatEnum(String fmt) => switch (fmt) {
      'yuv' => 'ISP_ADJ_FMT_YUV',
      'hsl' => 'ISP_ADJ_FMT_HSL',
      'mono' => 'ISP_ADJ_FMT_MONO',
      _ => 'ISP_ADJ_FMT_RGB',
    };

/// 多形态调节器公共骨架（sat_bright / bright_contrast / color_balance）：
/// [candidates] 为 (输入端口, 帧格式, 输出端口) 候选表，按端口声明序；
/// 按 ctx.inputFormats 选活动项（均未连接回退首项），mono 通道数为 1。
/// c_ref 核全部原地：先 copyInToOut 再在 out 上处理；Bypass 直通拷贝。
CNodeFiles _genMultiFormatAdjust(
  CNodeGenCtx ctx, {
  required List<(String, String, String)> candidates,
  required List<String> macroLines,
  required String Function(String outPort) makeCall,
}) {
  var (inPort, fmt, outPort) = candidates.first;
  for (final c in candidates) {
    if (ctx.inputFormats.containsKey(c.$1)) {
      (inPort, fmt, outPort) = c;
      break;
    }
  }
  final m = ctx.macro;
  final channels = fmt == 'mono' ? 1 : 3;
  final input = CPort(inPort, channels: channels);
  final output = CPort(outPort, channels: channels);
  // color_balance 不在 processTypeIds（无 Bypass 开关），BYPASS 宏只对
  // Process 类生成（assembleCNode 同样只对 Process 类注入该宏）。
  final bypassLine = ctx.isProcess ? '  if (${m}_BYPASS) return ISP_OK;\n' : '';
  return assembleCNode(
    ctx: ctx,
    algoIncludes: const ['isp_adjust.h'],
    inputs: [input],
    outputs: [output],
    macroLines: [
      '#define ${m}_FORMAT ${_adjustFormatEnum(fmt)}',
      ...macroLines,
    ],
    body: '''
${copyInToOut(input, output, '  ')}
$bypassLine  return ${makeCall(outPort)};''',
  );
}

/// hsl_debugger：H 色环循环偏移 + S/L 增益（isp_adjust_hsl，原地）。
CNodeFiles _genHslDebugger(CNodeGenCtx ctx) {
  final m = ctx.macro;
  const input = CPort('in', channels: 3);
  const output = CPort('out', channels: 3);
  return assembleCNode(
    ctx: ctx,
    algoIncludes: const ['isp_adjust.h'],
    inputs: const [input],
    outputs: const [output],
    macroLines: [
      '#define ${m}_H_SHIFT ${cNum(ctx.doubleParam('h_shift'))}',
      '#define ${m}_S_GAIN ${cNum(ctx.doubleParam('s_gain'))}',
      '#define ${m}_L_GAIN ${cNum(ctx.doubleParam('l_gain'))}',
    ],
    body: '''
${copyInToOut(input, output, '  ')}
  if (${m}_BYPASS) return ISP_OK;
  return isp_adjust_hsl(out, w, h, max_value,
                        ${m}_H_SHIFT, ${m}_S_GAIN, ${m}_L_GAIN);''',
  );
}

/// rgb_debugger：R/G/B 三通道增益（isp_adjust_rgb，原地）。
CNodeFiles _genRgbDebugger(CNodeGenCtx ctx) {
  final m = ctx.macro;
  const input = CPort('in', channels: 3);
  const output = CPort('out', channels: 3);
  return assembleCNode(
    ctx: ctx,
    algoIncludes: const ['isp_adjust.h'],
    inputs: const [input],
    outputs: const [output],
    macroLines: [
      '#define ${m}_R_GAIN ${cNum(ctx.doubleParam('r_gain'))}',
      '#define ${m}_G_GAIN ${cNum(ctx.doubleParam('g_gain'))}',
      '#define ${m}_B_GAIN ${cNum(ctx.doubleParam('b_gain'))}',
    ],
    body: '''
${copyInToOut(input, output, '  ')}
  if (${m}_BYPASS) return ISP_OK;
  return isp_adjust_rgb(out, w, h, max_value,
                        ${m}_R_GAIN, ${m}_G_GAIN, ${m}_B_GAIN);''',
  );
}

/// yuv_debugger：Y 增益 + U/V 绕中点缩放（isp_adjust_yuv，原地）。
CNodeFiles _genYuvDebugger(CNodeGenCtx ctx) {
  final m = ctx.macro;
  const input = CPort('in', channels: 3);
  const output = CPort('out', channels: 3);
  return assembleCNode(
    ctx: ctx,
    algoIncludes: const ['isp_adjust.h'],
    inputs: const [input],
    outputs: const [output],
    macroLines: [
      '#define ${m}_Y_GAIN ${cNum(ctx.doubleParam('y_gain'))}',
      '#define ${m}_U_GAIN ${cNum(ctx.doubleParam('u_gain'))}',
      '#define ${m}_V_GAIN ${cNum(ctx.doubleParam('v_gain'))}',
    ],
    body: '''
${copyInToOut(input, output, '  ')}
  if (${m}_BYPASS) return ISP_OK;
  return isp_adjust_yuv(out, w, h, max_value,
                        ${m}_Y_GAIN, ${m}_U_GAIN, ${m}_V_GAIN);''',
  );
}

/// sat_bright_adjuster：RGB/YUV/HSL 三域饱和度/亮度（isp_adjust_sat_bright）。
CNodeFiles _genSatBright(CNodeGenCtx ctx) {
  final m = ctx.macro;
  return _genMultiFormatAdjust(
    ctx,
    candidates: const [
      ('in', 'rgb', 'out_rgb'),
      ('in_yuv', 'yuv', 'out_yuv'),
      ('in_hsl', 'hsl', 'out_hsl'),
    ],
    macroLines: [
      '#define ${m}_SAT_GAIN ${cNum(ctx.doubleParam('sat_gain'))}',
      '#define ${m}_BRIGHT_GAIN ${cNum(ctx.doubleParam('bright_gain'))}',
    ],
    makeCall: (out) =>
        'isp_adjust_sat_bright($out, w, h, ${m}_FORMAT, max_value,\n'
        '                           ${m}_SAT_GAIN, ${m}_BRIGHT_GAIN)',
  );
}

/// bright_contrast_adjuster：RGB/YUV/HSL/Mono 四域亮度/对比度
/// （isp_adjust_bright_contrast；mono 形态通道数为 1）。
CNodeFiles _genBrightContrast(CNodeGenCtx ctx) {
  final m = ctx.macro;
  // LUT 模式（codegenMode=lut）：adjust 一维映射表与（RGB 域）亮度比例
  // 表按生成期参数烘焙（Dart brightContrastAdjustLut/RatioLut，域
  // 0..ctx.lutDomainMax）；运行时 max_value 一致走纯查表（RGB 域消灭逐
  // 像素除法），不一致回退直算（与函数方式同公式，数值一致）。
  if (ctx.strParam('codegenMode') == 'lut') {
    var (inPort, fmt, outPort) =
        const [('in', 'rgb', 'out_rgb'), ('in_yuv', 'yuv', 'out_yuv'),
               ('in_hsl', 'hsl', 'out_hsl'), ('in_mono', 'mono', 'out_mono')]
            .first;
    for (final c in const [
      ('in', 'rgb', 'out_rgb'),
      ('in_yuv', 'yuv', 'out_yuv'),
      ('in_hsl', 'hsl', 'out_hsl'),
      ('in_mono', 'mono', 'out_mono'),
    ]) {
      if (ctx.inputFormats.containsKey(c.$1)) {
        (inPort, fmt, outPort) = c;
        break;
      }
    }
    final channels = fmt == 'mono' ? 1 : 3;
    final input = CPort(inPort, channels: channels);
    final output = CPort(outPort, channels: channels);
    final n = ctx.lutDomainMax;
    final adjLut = brightContrastAdjustLut(
        maxValue: n,
        brightPct: ctx.doubleParam('bright'),
        baselinePct: ctx.doubleParam('baseline'),
        gainPct: ctx.doubleParam('gain'));

    final bypassLine = ctx.isProcess ? '  if (${m}_BYPASS) return ISP_OK;\n' : '';
    return assembleCNode(
      ctx: ctx,
      algoIncludes: const ['isp_adjust.h'],
      inputs: [input],
      outputs: [output],
      macroLines: [
        '#define ${m}_FORMAT ${_adjustFormatEnum(fmt)}',
        '#define ${m}_BRIGHT_PCT ${cNum(ctx.doubleParam('bright'))}',
        '#define ${m}_BASELINE_PCT ${cNum(ctx.doubleParam('baseline'))}',
        '#define ${m}_GAIN_PCT ${cNum(ctx.doubleParam('gain'))}',
      ],
      body: '''
  /* LUT 模式：adjust 映射表（与 RGB 域亮度比例表）由生成期按节点参数
   * 烘焙（Dart brightContrastAdjustLut/RatioLut，域 0..$n）。 */
  static const uint16_t ${ctx.ident}_adj_lut[${n + 1}] = {
${cU16Table(adjLut)}
  };
${copyInToOut(input, output, '  ')}
$bypassLine  if (max_value == $n) {
    return isp_adjust_bc_lut_apply($outPort, w, h, ${m}_FORMAT, max_value,
                                   ${ctx.ident}_adj_lut);
  }
  return isp_adjust_bright_contrast($outPort, w, h, ${m}_FORMAT, max_value,
                                    ${m}_BRIGHT_PCT, ${m}_BASELINE_PCT,
                                    ${m}_GAIN_PCT);''',
    );
  }
  return _genMultiFormatAdjust(
    ctx,
    candidates: const [
      ('in', 'rgb', 'out_rgb'),
      ('in_yuv', 'yuv', 'out_yuv'),
      ('in_hsl', 'hsl', 'out_hsl'),
      ('in_mono', 'mono', 'out_mono'),
    ],
    macroLines: [
      '#define ${m}_BRIGHT_PCT ${cNum(ctx.doubleParam('bright'))}',
      '#define ${m}_BASELINE_PCT ${cNum(ctx.doubleParam('baseline'))}',
      '#define ${m}_GAIN_PCT ${cNum(ctx.doubleParam('gain'))}',
    ],
    makeCall: (out) =>
        'isp_adjust_bright_contrast($out, w, h, ${m}_FORMAT, max_value,\n'
        '                                ${m}_BRIGHT_PCT, ${m}_BASELINE_PCT,\n'
        '                                ${m}_GAIN_PCT)',
  );
}

/// color_balance：RGB/YUV/HSL 三域中间调加性偏移（isp_adjust_color_balance）。
CNodeFiles _genColorBalance(CNodeGenCtx ctx) {
  final m = ctx.macro;
  return _genMultiFormatAdjust(
    ctx,
    candidates: const [
      ('in', 'rgb', 'out_rgb'),
      ('in_yuv', 'yuv', 'out_yuv'),
      ('in_hsl', 'hsl', 'out_hsl'),
    ],
    macroLines: [
      '#define ${m}_CYAN_RED ${cNum(ctx.doubleParam('cyan_red'))}',
      '#define ${m}_MAGENTA_GREEN ${cNum(ctx.doubleParam('magenta_green'))}',
      '#define ${m}_YELLOW_BLUE ${cNum(ctx.doubleParam('yellow_blue'))}',
    ],
    makeCall: (out) =>
        'isp_adjust_color_balance($out, w, h, ${m}_FORMAT, max_value,\n'
        '                              ${m}_CYAN_RED, ${m}_MAGENTA_GREEN,\n'
        '                              ${m}_YELLOW_BLUE)',
  );
}

/// color_controller：高斯色相带选择性调整（isp_color_controller_apply，
/// src/dst 分离故无需预拷贝；Bypass 时直通拷贝）。
CNodeFiles _genColorController(CNodeGenCtx ctx) {
  final m = ctx.macro;
  const input = CPort('in', channels: 3);
  const output = CPort('out', channels: 3);
  // LUT 模式（codegenMode=lut）：H 域三张表（H 偏移/S 乘子/L 乘子，含
  // 高斯权重 exp）按生成期参数烘焙（Dart hslBandLuts，域 0..
  // ctx.lutDomainMax）；运行时 max_value 一致走纯查表（逐像素只剩 3 次
  // 查表 + 2 次乘法 + 1 次取模，消灭 exp），不一致回退直算。
  if (ctx.strParam('codegenMode') == 'lut') {
    final n = ctx.lutDomainMax;
    final (shiftLut, sMulLut, lMulLut) = hslBandLuts(
        maxValue: n,
        hCenterDeg: ctx.doubleParam('h_center'),
        q: ctx.doubleParam('q'),
        hShiftDeg: ctx.doubleParam('h_shift'),
        sGain: ctx.doubleParam('s_gain'),
        lGain: ctx.doubleParam('l_gain'));
    return assembleCNode(
      ctx: ctx,
      algoIncludes: const ['isp_color_controller.h'],
      inputs: const [input],
      outputs: const [output],
      macroLines: [
        '#define ${m}_H_CENTER ${cNum(ctx.doubleParam('h_center'))}',
        '#define ${m}_Q ${cNum(ctx.doubleParam('q'))}',
        '#define ${m}_H_SHIFT ${cNum(ctx.doubleParam('h_shift'))}',
        '#define ${m}_S_GAIN ${cNum(ctx.doubleParam('s_gain'))}',
        '#define ${m}_L_GAIN ${cNum(ctx.doubleParam('l_gain'))}',
      ],
      body: '''
  /* LUT 模式：以下三张 H 域表由生成期按节点参数烘焙（Dart
   * hslBandLuts，域 0..$n）。 */
  static const int32_t ${ctx.ident}_shift_lut[${n + 1}] = {
${cI32Table(shiftLut)}
  };
  static const double ${ctx.ident}_s_mul_lut[${n + 1}] = {
${cF64Table(sMulLut)}
  };
  static const double ${ctx.ident}_l_mul_lut[${n + 1}] = {
${cF64Table(lMulLut)}
  };
  if (${m}_BYPASS) {
    if (out != in) {
      memcpy(out, in, ${input.bytesExpr});
    }
    return ISP_OK;
  }
  if (max_value == $n) {
    return isp_color_controller_lut_apply(in, out, w, h, max_value,
        ${ctx.ident}_shift_lut, ${ctx.ident}_s_mul_lut,
        ${ctx.ident}_l_mul_lut);
  }
  return isp_color_controller_apply(in, out, w, h, max_value,
                                    ${m}_H_CENTER, ${m}_Q, ${m}_H_SHIFT,
                                    ${m}_S_GAIN, ${m}_L_GAIN);''',
    );
  }
  return assembleCNode(
    ctx: ctx,
    algoIncludes: const ['isp_color_controller.h'],
    inputs: const [input],
    outputs: const [output],
    macroLines: [
      '#define ${m}_H_CENTER ${cNum(ctx.doubleParam('h_center'))}',
      '#define ${m}_Q ${cNum(ctx.doubleParam('q'))}',
      '#define ${m}_H_SHIFT ${cNum(ctx.doubleParam('h_shift'))}',
      '#define ${m}_S_GAIN ${cNum(ctx.doubleParam('s_gain'))}',
      '#define ${m}_L_GAIN ${cNum(ctx.doubleParam('l_gain'))}',
    ],
    body: '''
  if (${m}_BYPASS) {
    if (out != in) {
      memcpy(out, in, ${input.bytesExpr});
    }
    return ISP_OK;
  }
  return isp_color_controller_apply(in, out, w, h, max_value,
                                    ${m}_H_CENTER, ${m}_Q, ${m}_H_SHIFT,
                                    ${m}_S_GAIN, ${m}_L_GAIN);''',
  );
}

/// levels_curves：RGB 域传递函数。4096 级 LUT 在生成期由 Dart 侧
/// levelsCurveLut 按节点参数烘焙（与节点图表中绘制的曲线同一求值口径：
/// levelsPointsFromParam 规范化控制点 + curveMode 生成公式 + gamma），
/// 运行时只剩 isp_levels_apply_rgb 纯查表，无需 scratch。
/// 恒等曲线在生成期判定（gamma 模式看 γ==1，其余看规范化点共线，
/// 与 Dart 同口径），恒等时封装退化为纯拷贝、不烘焙表。
CNodeFiles _genLevelsCurves(CNodeGenCtx ctx) {
  final m = ctx.macro;
  // 参数解析与 pipeline_runner.dart levels_curves 分支同口径。
  final points = levelsPointsFromParam(ctx.param('points'));
  final mode = levelsCurveModeFromParam(ctx.strParam('curveMode'));
  final gamma = ctx.doubleParam('gamma');
  final identity = mode == LevelsCurveMode.gamma
      ? gamma == 1.0
      : levelsCurveIsIdentity(points);
  const input = CPort('in', channels: 3);
  const output = CPort('out', channels: 3);
  if (identity) {
    return assembleCNode(
      ctx: ctx,
      algoIncludes: const ['isp_levels.h'],
      inputs: const [input],
      outputs: const [output],
      macroLines: const [],
      body: '''
  /* 生成期判定为恒等曲线（与 Dart 同口径）：直通拷贝。 */
${copyInToOut(input, output, '  ')}
  return ISP_OK;''',
    );
  }
  final lut = levelsCurveLut(points, mode: mode, gamma: gamma);
  return assembleCNode(
    ctx: ctx,
    algoIncludes: const ['isp_levels.h'],
    inputs: const [input],
    outputs: const [output],
    macroLines: const [],
    body: '''
  /* 传递函数 LUT：生成期由 Dart levelsCurveLut 按节点参数烘焙（与节点
   * 图表中绘制的曲线同一求值口径），运行时纯查表。 */
  static const uint16_t ${ctx.ident}_lut[ISP_LEVELS_LUT_SIZE] = {
${cU16Table(lut)}
  };
  if (${m}_BYPASS) {
${copyInToOut(input, output, '    ')}
    return ISP_OK;
  }
  return isp_levels_apply_rgb(in, w, h, ${ctx.ident}_lut, max_value, out);''',
  );
}

/// color_temp_adjuster：isp_color_temp_gains（目标色温相对参考色温
/// measured_cct 求 von Kries 对角增益）+ isp_adjust_rgb 施加（原地）。
/// measured_cct 为隐式参数（运行时由测量按钮写入），缺失烘焙 0 ——
/// isp_color_temp_gains 对 reference <= 0 按 6500K 处理，与 Dart 一致。
/// 该类型不在 processTypeIds（无 Bypass 开关），故无 BYPASS 宏。
CNodeFiles _genColorTempAdjuster(CNodeGenCtx ctx) {
  final m = ctx.macro;
  const input = CPort('in', channels: 3);
  const output = CPort('out_rgb', channels: 3);
  final macroLines = [
    '#define ${m}_TEMPERATURE ${cNum(ctx.doubleParam('temperature'))}',
    '#define ${m}_MEASURED_CCT ${cNum(ctx.intParam('measured_cct'), asDouble: false)}',
  ];
  if (ctx.strParam('codegenMode') == 'lut') {
    // LUT 模式：色温/参考色温均烘焙参数，增益在生成期经 Dart
    // colorTempGains 算出后烘焙三通道查找表（与 C isp_color_temp_gains
    // 有既有 tol=0 对拍，增益值一致）；运行时 max_value 与烘焙域一致
    // 走纯查表，不一致回退运行期求增益+直算。
    final temperature = ctx.doubleParam('temperature');
    final measuredCct = ctx.intParam('measured_cct');
    final gains = colorTempGains(temperature, measuredCct);
    final luts = [
      for (final g in gains) adjustGainLut(g, ctx.lutDomainMax),
    ];
    return assembleCNode(
      ctx: ctx,
      algoIncludes: const ['isp_color_temp.h', 'isp_adjust.h'],
      inputs: const [input],
      outputs: const [output],
      macroLines: macroLines,
      body: '''
  double gains[3] = {0.0, 0.0, 0.0};
  int rc = 0;
  /* LUT 模式：以下三表由生成期按节点参数烘焙（Dart colorTempGains +
   * adjustGainLut，域 0..${ctx.lutDomainMax}）。 */
  static const uint16_t ${ctx.ident}_lut_r[${ctx.lutDomainMax + 1}] = {
${cU16Table(luts[0])}
  };
  static const uint16_t ${ctx.ident}_lut_g[${ctx.lutDomainMax + 1}] = {
${cU16Table(luts[1])}
  };
  static const uint16_t ${ctx.ident}_lut_b[${ctx.lutDomainMax + 1}] = {
${cU16Table(luts[2])}
  };
${copyInToOut(input, output, '  ')}
  if (max_value == ${ctx.lutDomainMax}) {
    return isp_adjust_lut3_apply(out_rgb, w, h, max_value, ${ctx.ident}_lut_r,
                                 ${ctx.ident}_lut_g, ${ctx.ident}_lut_b,
                                 out_rgb);
  }
  rc = isp_color_temp_gains(${m}_TEMPERATURE, ${m}_MEASURED_CCT, gains);
  if (rc != ISP_OK) return rc;
  return isp_adjust_rgb(out_rgb, w, h, max_value,
                        gains[0], gains[1], gains[2]);''',
    );
  }
  return assembleCNode(
    ctx: ctx,
    algoIncludes: const ['isp_color_temp.h', 'isp_adjust.h'],
    inputs: const [input],
    outputs: const [output],
    macroLines: macroLines,
    body: '''
  double gains[3] = {0.0, 0.0, 0.0};
  int rc = 0;
${copyInToOut(input, output, '  ')}
  rc = isp_color_temp_gains(${m}_TEMPERATURE, ${m}_MEASURED_CCT, gains);
  if (rc != ISP_OK) return rc;
  return isp_adjust_rgb(out_rgb, w, h, max_value,
                        gains[0], gains[1], gains[2]);''',
  );
}
