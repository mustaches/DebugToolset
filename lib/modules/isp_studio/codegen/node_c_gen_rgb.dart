/// ISP 编组导出 C 代码：去马赛克 / RGB 域节点模板。
///
/// 覆盖类型：demosaic（去马赛克）、rgb_dnr、sharpen、gaussian_blur、
/// edge_extract、morphology、ahe。gamma/ccm/white_balance 见 node_c_gen.dart。
///
/// 多形态节点（gaussian_blur 四形态、morphology/ahe 双形态、edge_extract
/// 三形态）按 ctx.inputFormats 选活动输入端口，封装只含活动端口形参。
library;

import 'node_c_gen.dart';

/// 去马赛克 / RGB 域模板入口：命中返回 assembleCNode 结果，未命中返回 null。
CNodeFiles? genRgbDomainCNode(CNodeGenCtx ctx) {
  switch (ctx.node.typeId) {
    case 'demosaic':
      return _genDemosaic(ctx);
    case 'rgb_dnr':
      return _genRgbDnr(ctx);
    case 'sharpen':
      return _genSharpen(ctx);
    case 'gaussian_blur':
      return _genGaussianBlur(ctx);
    case 'edge_extract':
      return _genEdgeExtract(ctx);
    case 'morphology':
      return _genMorphology(ctx);
    case 'ahe':
      return _genAhe(ctx);
  }
  return null;
}

/// 多形态节点：选活动输入端口。[candidates] 按端口声明序给出
/// （端口名, 端口名推导的缺省格式）；已连接者优先，均未连接回退首个。
(String, CFrameFormat) _activeInput(
    CNodeGenCtx ctx, List<(String, CFrameFormat)> candidates) {
  for (final c in candidates) {
    final fmt = ctx.inputFormats[c.$1];
    if (fmt != null) return (c.$1, fmt);
  }
  return candidates.first;
}

/// demosaic：Bayer/非 Bayer CFA → 交织 RGB。按 algorithm + cfaPattern
/// 烘焙为 10 个候选函数之一（bilinear / mhc / aahd / amaze / lmmse / igv /
/// rccb(rccg) / rccc / ryycy / rgb_ir）。
///
/// CFA 种类与 Bayer 相位不在 demosaic 节点自身参数里，由顶层集成从上游
/// RAW 源节点注入：'cfaPattern'（RCCB/RCCG/RCCC/RYYCY/RGB_IR）或
/// 'bayerPattern'（RGGB/BGGR/GRBG/GBRG，缺省 RGGB）；rgb_ir 的红外扣除
/// 系数经 'irSubtraction' 注入（缺省 0.5）。
CNodeFiles _genDemosaic(CNodeGenCtx ctx) {
  final m = ctx.macro;
  var cfaRaw = ctx.strParam('cfaPattern').trim();
  if (cfaRaw.isEmpty) cfaRaw = ctx.strParam('bayerPattern').trim();
  final cfa = cfaRaw.toUpperCase();
  const input = CPort('in'); // bayer 单通道
  const output = CPort('out', channels: 3);

  // Bypass：输入 1ch / 输出 3ch 尺寸不同无法 memcpy，灰度直通
  // （R=G=B=原马赛克采样值，与链尾 RAW 直显按亮度出灰度图语义一致）。
  const bypass = '''
  /* Bypass：Bayer(1ch)→RGB(3ch) 尺寸不同无法 memcpy，灰度直通。 */
  if ({M}_BYPASS) {
    size_t i, j;
    for (i = 0, j = 0; i < (size_t)w * (size_t)h; i++, j += 3) {
      out[j] = out[j + 1] = out[j + 2] = in[i];
    }
    return ISP_OK;
  }''';

  switch (cfa) {
    case 'RCCB':
    case 'RCCG':
      return assembleCNode(
        ctx: ctx,
        algoIncludes: const ['isp_demosaic.h'],
        inputs: const [input],
        outputs: const [output],
        macroLines: const [],
        body: '''
${bypass.replaceAll('{M}', m)}
  return isp_demosaic_rccb(in, w, h, ${cfa == 'RCCG' ? 'true' : 'false'},
                           max_value, out);''',
      );
    case 'RCCC':
      return assembleCNode(
        ctx: ctx,
        algoIncludes: const ['isp_demosaic.h'],
        inputs: const [input],
        outputs: const [output],
        macroLines: const [],
        body: '''
${bypass.replaceAll('{M}', m)}
  return isp_demosaic_rccc(in, w, h, max_value, out);''',
      );
    case 'RYYCY':
      return assembleCNode(
        ctx: ctx,
        algoIncludes: const ['isp_demosaic.h'],
        inputs: const [input],
        outputs: const [output],
        macroLines: const [],
        body: '''
${bypass.replaceAll('{M}', m)}
  return isp_demosaic_ryycy(in, w, h, max_value, out);''',
      );
    case 'RGB_IR':
    case 'RGBIR':
      return assembleCNode(
        ctx: ctx,
        algoIncludes: const ['isp_demosaic.h'],
        inputs: const [input],
        outputs: const [output],
        macroLines: [
          // 缺省 0.5（cis_rgb_ir 源节点参数默认值；注入缺失时兜底）。
          '#define ${m}_IR_SUBTRACTION ${cNum(ctx.param('irSubtraction') == null ? 0.5 : ctx.doubleParam('irSubtraction'))}',
        ],
        body: '''
${bypass.replaceAll('{M}', m)}
  return isp_demosaic_rgb_ir(in, w, h, max_value, ${m}_IR_SUBTRACTION, out);''',
      );
  }

  // Bayer：cfa 为 RGGB/BGGR/GRBG/GBRG（空或未知回退 RGGB，与
  // BayerPattern.fromName 缺省语义不同——codegen 需要可编译常量，
  // 未知值静默回退 RGGB 并在导出报告中由集成层提示）。
  final patternEnum = switch (cfa) {
    'BGGR' => 'ISP_BAYER_BGGR',
    'GRBG' => 'ISP_BAYER_GRBG',
    'GBRG' => 'ISP_BAYER_GBRG',
    _ => 'ISP_BAYER_RGGB',
  };
  final algo = ctx.strParam('algorithm');
  final call = switch (algo) {
    '' || 'bilinear' => 'isp_demosaic_bilinear(in, w, h, ${m}_CFA_PATTERN, out)',
    'mhc' =>
      'isp_demosaic_adv_mhc(in, w, h, ${m}_CFA_PATTERN, max_value, out)',
    'aahd' =>
      'isp_demosaic_adv_aahd(in, w, h, ${m}_CFA_PATTERN, max_value, out, scratch)',
    'amaze' =>
      'isp_demosaic_adv_amaze(in, w, h, ${m}_CFA_PATTERN, max_value, out, scratch)',
    'lmmse' =>
      'isp_demosaic_adv_lmmse(in, w, h, ${m}_CFA_PATTERN, max_value, out, scratch)',
    'igv' =>
      'isp_demosaic_adv_igv(in, w, h, ${m}_CFA_PATTERN, max_value, out, scratch)',
    _ => throw ArgumentError('未知去马赛克算法: $algo'),
  };
  final advScratch = algo == 'aahd' || algo == 'amaze' || algo == 'lmmse' || algo == 'igv';
  return assembleCNode(
    ctx: ctx,
    algoIncludes: [advScratch || algo == 'mhc' ? 'isp_demosaic_adv.h' : 'isp_demosaic.h'],
    inputs: const [input],
    outputs: const [output],
    macroLines: ['#define ${m}_CFA_PATTERN $patternEnum'],
    // aahd/amaze/lmmse/igv 需 adv 统一 scratch；mhc 无中间平面不需要。
    scratchExpr: advScratch ? 'ISP_DEMOSAIC_ADV_SCRATCH_BYTES(w, h)' : null,
    body: '''
${bypass.replaceAll('{M}', m)}
  return $call;''',
  );
}

/// rgb_dnr：转 YUV 后亮度保边降噪 + 色度低通（c_ref 原地算子）。
CNodeFiles _genRgbDnr(CNodeGenCtx ctx) {
  final m = ctx.macro;
  const input = CPort('in', channels: 3);
  const output = CPort('out', channels: 3);
  return assembleCNode(
    ctx: ctx,
    algoIncludes: const ['isp_rgb_dnr.h'],
    inputs: const [input],
    outputs: const [output],
    macroLines: [
      '#define ${m}_LUMA ${cNum(ctx.doubleParam('luma'))}',
      '#define ${m}_CHROMA ${cNum(ctx.doubleParam('chroma'))}',
    ],
    scratchExpr: 'ISP_RGB_DNR_SCRATCH_BYTES(w, h)',
    body: '''
${copyInToOut(input, output, '  ')}
  if (${m}_BYPASS) return ISP_OK;
  return isp_rgb_dnr_apply(out, w, h, ${m}_LUMA, ${m}_CHROMA, max_value,
                           (uint16_t *)scratch);''',
  );
}

/// sharpen：亮度 unsharp mask（c_ref 原地算子）。
CNodeFiles _genSharpen(CNodeGenCtx ctx) {
  final m = ctx.macro;
  const input = CPort('in', channels: 3);
  const output = CPort('out', channels: 3);
  return assembleCNode(
    ctx: ctx,
    algoIncludes: const ['isp_sharpen.h'],
    inputs: const [input],
    outputs: const [output],
    macroLines: [
      '#define ${m}_AMOUNT ${cNum(ctx.doubleParam('amount'))}',
      '#define ${m}_THRESHOLD ${cNum(ctx.doubleParam('threshold'))}',
    ],
    scratchExpr: 'ISP_SHARPEN_SCRATCH_BYTES(w, h)',
    body: '''
${copyInToOut(input, output, '  ')}
  if (${m}_BYPASS) return ISP_OK;
  return isp_sharpen_apply(out, w, h, ${m}_AMOUNT, ${m}_THRESHOLD, max_value,
                           (uint16_t *)scratch);''',
  );
}

/// gaussian_blur：可分离两趟高斯（c_ref 原地算子）。四形态互斥输入
/// （in/in_yuv/in_hsl/in_mono），channels 由输入格式推导（mono=1，余=3）；
/// radius 由 inline isp_gaussian_blur_radius(sigma) 在 scratch 宏内求得。
CNodeFiles _genGaussianBlur(CNodeGenCtx ctx) {
  final m = ctx.macro;
  final (inName, fmt) = _activeInput(ctx, const [
    ('in', 'rgb'),
    ('in_yuv', 'yuv'),
    ('in_hsl', 'hsl'),
    ('in_mono', 'mono'),
  ]);
  final channels = fmt == 'mono' ? 1 : 3;
  final outName = switch (fmt) {
    'yuv' => 'out_yuv',
    'hsl' => 'out_hsl',
    'mono' => 'out_mono',
    _ => 'out_rgb',
  };
  final input = CPort(inName, channels: channels);
  final output = CPort(outName, channels: channels);
  return assembleCNode(
    ctx: ctx,
    algoIncludes: const ['isp_gaussian_blur.h'],
    inputs: [input],
    outputs: [output],
    macroLines: [
      '#define ${m}_SIGMA ${cNum(ctx.doubleParam('sigma'))}',
      '#define ${m}_STRENGTH ${cNum(ctx.doubleParam('strength'))}',
      '#define ${m}_CHANNELS $channels',
    ],
    scratchExpr:
        'ISP_GAUSSIAN_BLUR_SCRATCH_BYTES(w, ${m}_CHANNELS, isp_gaussian_blur_radius(${m}_SIGMA))',
    // gaussian_blur 非 Process 类（无 Bypass 参数），不做直通早退。
    body: '''
${copyInToOut(input, output, '  ')}
  return isp_gaussian_blur_apply(${output.name}, w, h, ${m}_CHANNELS,
                                 ${m}_SIGMA, ${m}_STRENGTH, scratch);''',
  );
}

/// edge_extract：亮度高通黑底白线边缘图（非原地，in 只读）。三形态互斥
/// 输入（in/in_yuv/in_hsl），主输出保持输入格式；out_mono 单通道边缘
/// 亮度图按 Dart 语义从主输出取通道（RGB/YUV 取 0，HSL 取 L=2）。
CNodeFiles _genEdgeExtract(CNodeGenCtx ctx) {
  final m = ctx.macro;
  final (inName, fmt) = _activeInput(ctx, const [
    ('in', 'rgb'),
    ('in_yuv', 'yuv'),
    ('in_hsl', 'hsl'),
  ]);
  final outName = switch (fmt) {
    'yuv' => 'out_yuv',
    'hsl' => 'out_hsl',
    _ => 'out_rgb',
  };
  final formatEnum = switch (fmt) {
    'yuv' => 'ISP_EDGE_EXTRACT_YUV',
    'hsl' => 'ISP_EDGE_EXTRACT_HSL',
    _ => 'ISP_EDGE_EXTRACT_RGB',
  };
  final monoCh = fmt == 'hsl' ? 2 : 0;
  final input = CPort(inName, channels: 3);
  final output = CPort(outName, channels: 3);
  const monoOutput = CPort('out_mono');
  return assembleCNode(
    ctx: ctx,
    algoIncludes: const ['isp_edge_extract.h'],
    inputs: [input],
    outputs: [output, monoOutput],
    macroLines: [
      '#define ${m}_FORMAT $formatEnum',
      '#define ${m}_GAIN ${cNum(ctx.doubleParam('gain'))}',
      '#define ${m}_THRESHOLD ${cNum(ctx.doubleParam('threshold'))}',
    ],
    scratchExpr: 'ISP_EDGE_EXTRACT_SCRATCH_BYTES(w, h)',
    // edge_extract 非 Process 类（无 Bypass 参数），主输出始终重算。
    body: '''
  {
    const int rc = isp_edge_extract_run(${input.name}, ${output.name}, w, h,
        ${m}_FORMAT, ${m}_GAIN, ${m}_THRESHOLD, max_value,
        (uint16_t *)scratch);
    if (rc != ISP_OK) return rc;
  }
  /* out_mono：RGB/YUV 取 0 通道、HSL 取 L（2 通道），与 Dart 一致。 */
  {
    size_t i, j;
    for (i = 0, j = $monoCh; i < (size_t)w * (size_t)h; i++, j += 3) {
      out_mono[i] = ${output.name}[j];
    }
  }
  return ISP_OK;''',
  );
}

/// morphology：方形结构元腐蚀/膨胀（c_ref 原地算子）。双形态互斥输入
/// （in / in_mono），channels 由输入格式推导；erode 为 mode 映射的布尔
/// （Dart：mode != 'dilate' 即腐蚀）。
CNodeFiles _genMorphology(CNodeGenCtx ctx) {
  final m = ctx.macro;
  final (inName, fmt) = _activeInput(ctx, const [
    ('in', 'rgb'),
    ('in_mono', 'mono'),
  ]);
  final channels = fmt == 'mono' ? 1 : 3;
  final outName = fmt == 'mono' ? 'out_mono' : 'out';
  final erode = ctx.strParam('mode') != 'dilate';
  final input = CPort(inName, channels: channels);
  final output = CPort(outName, channels: channels);
  return assembleCNode(
    ctx: ctx,
    algoIncludes: const ['isp_morphology.h'],
    inputs: [input],
    outputs: [output],
    macroLines: [
      '#define ${m}_ERODE ${erode ? 1 : 0}',
      '#define ${m}_RADIUS ${ctx.intParam('radius')}',
      '#define ${m}_CHANNELS $channels',
    ],
    scratchExpr: 'ISP_MORPHOLOGY_SCRATCH_BYTES(w, ${m}_CHANNELS, ${m}_RADIUS)',
    body: '''
${copyInToOut(input, output, '  ')}
  if (${m}_BYPASS) return ISP_OK;
  return isp_morphology_apply(${output.name}, w, h, ${m}_CHANNELS, ${m}_ERODE,
                              ${m}_RADIUS, (uint16_t *)scratch);''',
  );
}

/// ahe：CLAHE 自适应直方图均衡（c_ref 原地算子）。双形态互斥输入
/// （in=RGB 三通道 / in_mono=单通道）；blockSize<2→32、clipLimit<=0→1.0
/// 的兜底修正在 c_ref 内核内完成（与 Dart 一致），烘焙原值即可。
CNodeFiles _genAhe(CNodeGenCtx ctx) {
  final m = ctx.macro;
  final (inName, fmt) = _activeInput(ctx, const [
    ('in', 'rgb'),
    ('in_mono', 'mono'),
  ]);
  final channels = fmt == 'mono' ? 1 : 3;
  final outName = fmt == 'mono' ? 'out_mono' : 'out';
  final input = CPort(inName, channels: channels);
  final output = CPort(outName, channels: channels);
  return assembleCNode(
    ctx: ctx,
    algoIncludes: const ['isp_clahe.h'],
    inputs: [input],
    outputs: [output],
    macroLines: [
      '#define ${m}_BLOCK_SIZE ${ctx.intParam('blockSize')}',
      '#define ${m}_CLIP_LIMIT ${cNum(ctx.doubleParam('clipLimit'))}',
      '#define ${m}_STRENGTH ${cNum(ctx.doubleParam('strength'))}',
    ],
    scratchExpr: 'ISP_CLAHE_SCRATCH_BYTES(w, h, ${m}_BLOCK_SIZE)',
    body: '''
${copyInToOut(input, output, '  ')}
  if (${m}_BYPASS) return ISP_OK;
  return ${fmt == 'mono' ? 'isp_clahe_apply_mono' : 'isp_clahe_apply'}(
      ${output.name}, w, h, ${m}_BLOCK_SIZE, ${m}_CLIP_LIMIT, ${m}_STRENGTH,
      max_value, scratch);''',
  );
}
