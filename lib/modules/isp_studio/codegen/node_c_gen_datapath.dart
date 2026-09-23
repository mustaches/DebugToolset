/// ISP 编组导出 C 代码：Datapath 域模板（分路/合路/双源运算/多路选择）。
///
/// 覆盖 10 个类型：rgb_splitter / yuv_splitter / hsl_splitter、
/// rgb_combiner / yuv_combiner / hsl_combiner、multiplier / adder /
/// blender / mux4。c_ref 头：isp_split.h、isp_blend.h（格式兜底转换另
/// 需对应变体的 isp_csc_*.h，isp_csc 已按变体拆分）。Datapath 类无
/// BYPASS 宏（不在 processTypeIds 内）。
///
/// 格式推导要点（与 pipeline_runner 对齐）：
/// - splitter 收到非本域输入时先做色彩转换兜底（yuv/hsl→rgb、rgb→yuv、
///   rgb→hsl），封装用 scratch 暂存转换结果再拆路；本域输入直接拆。
/// - blender 基图四域互斥端口（in/in_yuv/in_hsl/in_mono）由
///   ctx.inputFormats 选路，输出端口与基图格式一致；混叠图四域互斥端口
///   （in_blend*）决定 blend_channels（mono→1，其余→3）。
/// - mux4 的 select 烘焙后只暴露选中源的活动端口，输出端口随其格式。
library;

import 'node_c_gen.dart';

/// Datapath 域模板入口：命中返回封装，未命中返回 null。
CNodeFiles? genDatapathCNode(CNodeGenCtx ctx) {
  switch (ctx.node.typeId) {
    case 'rgb_splitter':
      return _genSplitter(ctx, 'rgb');
    case 'yuv_splitter':
      return _genSplitter(ctx, 'yuv');
    case 'hsl_splitter':
      return _genSplitter(ctx, 'hsl');
    case 'rgb_combiner':
      return _genCombiner(ctx, 'rgb');
    case 'yuv_combiner':
      return _genCombiner(ctx, 'yuv');
    case 'hsl_combiner':
      return _genCombiner(ctx, 'hsl');
    case 'multiplier':
      return _genMultiplier(ctx);
    case 'adder':
      return _genAdder(ctx);
    case 'blender':
      return _genBlender(ctx);
    case 'mux4':
      return _genMux4(ctx);
  }
  return null;
}

/// 帧格式 → 通道数（bayer 不在本域出现，按 mono 计）。
int _fmtChannels(String fmt) => (fmt == 'rgb' || fmt == 'yuv' || fmt == 'hsl') ? 3 : 1;

/// 帧格式 → blender 基图格式枚举常量（isp_blend.h IspBlendFormat）。
String _blendFormatEnum(String fmt) => switch (fmt) {
      'yuv' => 'ISP_BLEND_FORMAT_YUV',
      'hsl' => 'ISP_BLEND_FORMAT_HSL',
      'mono' => 'ISP_BLEND_FORMAT_MONO',
      _ => 'ISP_BLEND_FORMAT_RGB',
    };

/// 帧格式 → mux4/blender 输出端口名。
String _fmtOutPort(String fmt) => switch (fmt) {
      'yuv' => 'out_yuv',
      'hsl' => 'out_hsl',
      'mono' => 'out_mono',
      _ => 'out_rgb',
    };

/// 分路器域名 → 三路输出端口名。
List<String> _splitOutPorts(String domain) => switch (domain) {
      'yuv' => const ['out_y', 'out_u', 'out_v'],
      'hsl' => const ['out_h', 'out_s', 'out_l'],
      _ => const ['out_r', 'out_g', 'out_b'],
    };

/// 合路器域名 → 三路输入端口名。
List<String> _combineInPorts(String domain) => switch (domain) {
      'yuv' => const ['in_y', 'in_u', 'in_v'],
      'hsl' => const ['in_h', 'in_s', 'in_l'],
      _ => const ['in_r', 'in_g', 'in_b'],
    };

/// 分路器：单进（交织三通道）三出（各单通道平面）。
///
/// 输入格式非本域时按 pipeline_runner 的兜底语义先转换再拆：
/// rgb_splitter 收 yuv/hsl（yuvToRgb/hslToRgb），yuv/hsl_splitter 收
/// rgb（rgbToYuv 等价 BT.601 全范围 / rgbToHsl）。转换需要 w*h*3 的
/// scratch 暂存；本域输入无 scratch。其余格式组合 Dart 侧直接抛错，
/// 端口类型约束下不会出现，封装按本域直拆处理。
CNodeFiles _genSplitter(CNodeGenCtx ctx, String domain) {
  final fmt = ctx.inputFormats['in'] ?? domain;
  final outNames = _splitOutPorts(domain);
  final outputs = [for (final n in outNames) CPort(n)];

  // 格式兜底转换（pipeline_runner 各 splitter case 的前置转换分支）。
  // isp_csc 全家桶已按变体拆分：按转换方向引用对应变体头。
  final (String, String)? conv = switch ((domain, fmt)) {
    ('rgb', 'yuv') => ('isp_csc_yuv_to_rgb(in, w, h, max_value, tmp)',
        'isp_csc_yuv2rgb.h'),
    ('rgb', 'hsl') => ('isp_csc_hsl_to_rgb(in, w, h, max_value, tmp)',
        'isp_csc_hsl2rgb.h'),
    // Dart 用 rgbToYuv（BT.601 全范围 Q16 定点），与 csc 全范围快路径一致。
    ('yuv', 'rgb') => ('isp_csc_rgb_to_yuv(in, w, h, max_value, '
        'ISP_CSC_BT601, ISP_CSC_RANGE_FULL, tmp)', 'isp_csc_rgb2yuv.h'),
    ('hsl', 'rgb') => ('isp_csc_rgb_to_hsl(in, w, h, max_value, tmp)',
        'isp_csc_rgb2hsl.h'),
    _ => null,
  };
  final convCall = conv?.$1;
  final convHeader = conv?.$2;

  final splitCall =
      'isp_split_$domain(${convCall == null ? 'in' : 'tmp'}, w, h, max_value, '
      '${outNames.join(', ')})';
  final body = convCall == null
      ? '  return $splitCall;'
      : '''
  /* 输入格式为 $fmt：按 pipeline_runner 兜底语义先转 $domain 再拆路。 */
  uint16_t *tmp = (uint16_t *)scratch;
  int rc = $convCall;
  if (rc != ISP_OK) return rc;
  return $splitCall;''';

  return assembleCNode(
    ctx: ctx,
    algoIncludes: [
      'isp_split.h',
      ?convHeader,
      if (convCall != null) 'isp_csc_common.h',
    ],
    inputs: const [CPort('in', channels: 3)],
    outputs: outputs,
    macroLines: const [],
    scratchExpr: convCall == null
        ? null
        : '((size_t)(w) * (size_t)(h) * 3u * sizeof(uint16_t))',
    body: body,
  );
}

/// 合路器：三个单通道平面 → 交织三通道帧。每路长度形参传 w*h（整帧
/// 连接；未连接的端口由 top 传 NULL，c_ref 内部填缺省值——YUV 的 U/V
/// 缺省为 max_value>>1，其余为 0，与 Dart 一致）。
CNodeFiles _genCombiner(CNodeGenCtx ctx, String domain) {
  final inNames = _combineInPorts(domain);
  return assembleCNode(
    ctx: ctx,
    algoIncludes: const ['isp_split.h'],
    inputs: [for (final n in inNames) CPort(n)],
    outputs: const [CPort('out', channels: 3)],
    macroLines: const [],
    body: '  return isp_combine_$domain('
        '${inNames[0]}, w * h, ${inNames[1]}, w * h, ${inNames[2]}, w * h, '
        'w, h, max_value, out);',
  );
}

/// 乘法器：双 mono 归一化相乘 out=(a+offset1)×(b+offset2)/maxValue。
CNodeFiles _genMultiplier(CNodeGenCtx ctx) {
  final m = ctx.macro;
  return assembleCNode(
    ctx: ctx,
    algoIncludes: const ['isp_blend.h'],
    inputs: const [CPort('in_mono'), CPort('in_mono2')],
    outputs: const [CPort('out_mono')],
    macroLines: [
      '#define ${m}_OFFSET1 ${cNum(ctx.doubleParam('offset1'))}',
      '#define ${m}_OFFSET2 ${cNum(ctx.doubleParam('offset2'))}',
    ],
    body: '  return isp_blend_multiply(in_mono, in_mono2, w * h, '
        '${m}_OFFSET1, ${m}_OFFSET2, max_value, out_mono);',
  );
}

/// 加法器：双 mono 平衡加权混合 out=a×balance+b×(1−balance)。
/// Dart 参数缺失回退 0.5，与类型默认值一致（ctx.param 已含该回退）。
CNodeFiles _genAdder(CNodeGenCtx ctx) {
  final m = ctx.macro;
  return assembleCNode(
    ctx: ctx,
    algoIncludes: const ['isp_blend.h'],
    inputs: const [CPort('in_mono'), CPort('in_mono2')],
    outputs: const [CPort('out_mono')],
    macroLines: [
      '#define ${m}_BALANCE ${cNum(ctx.doubleParam('balance'))}',
    ],
    body: '  return isp_blend_add(in_mono, in_mono2, w * h, '
        '${m}_BALANCE, max_value, out_mono);',
  );
}

/// 混叠器：基图（四域互斥）+ 蒙版 mono + 混叠图（四域互斥）原地叠加。
/// c_ref 为原地算子：封装先 copyInToOut 再在 out 上叠加（ABI 第 5 条）。
/// IspBlendFormat 由基图格式推导；blend_channels 由混叠端口格式推导
/// （mono→1，三通道交织→3；端口未在 inputFormats 中时按端口名后缀兜底）。
/// mode 仅 'normal' 一档，不烘焙。
CNodeFiles _genBlender(CNodeGenCtx ctx) {
  final m = ctx.macro;
  var basePort = 'in';
  for (final p in const ['in', 'in_yuv', 'in_hsl', 'in_mono']) {
    if (ctx.inputFormats.containsKey(p)) {
      basePort = p;
      break;
    }
  }
  final baseFmt = ctx.inputFormats[basePort] ??
      (basePort == 'in_mono'
          ? 'mono'
          : basePort == 'in'
              ? 'rgb'
              : basePort.substring(4));
  var blendPort = 'in_blend_mono';
  for (final p in const [
    'in_blend',
    'in_blend_yuv',
    'in_blend_hsl',
    'in_blend_mono',
  ]) {
    if (ctx.inputFormats.containsKey(p)) {
      blendPort = p;
      break;
    }
  }
  final blendFmt = ctx.inputFormats[blendPort] ??
      (blendPort.endsWith('_mono') ? 'mono' : 'rgb');
  final blendChannels = blendFmt == 'mono' ? 1 : 3;

  final base = CPort(basePort, channels: _fmtChannels(baseFmt));
  final output = CPort(_fmtOutPort(baseFmt), channels: _fmtChannels(baseFmt));
  return assembleCNode(
    ctx: ctx,
    algoIncludes: const ['isp_blend.h'],
    inputs: [base, const CPort('in_mask'), CPort(blendPort, channels: blendChannels)],
    outputs: [output],
    macroLines: [
      '#define ${m}_STRENGTH ${cNum(ctx.doubleParam('strength'))}',
      '#define ${m}_FORMAT ${_blendFormatEnum(baseFmt)}',
      '#define ${m}_BLEND_CHANNELS $blendChannels',
    ],
    body: '''
${copyInToOut(base, output, '  ')}
  return isp_blend_mask_apply(${output.name}, $blendPort, in_mask, w, h,
                              ${m}_FORMAT, ${m}_BLEND_CHANNELS,
                              ${m}_STRENGTH, max_value);''',
  );
}

/// 多路选择器（4 选 1）：select 烘焙（钳位 1..4，同 Dart），封装只暴露
/// 选中源的活动端口（四域互斥组按 ''/_yuv/_hsl/_mono 顺序取首个已连接
/// 者，与 pipeline_runner 一致）。isp_mux4_select 返回选中指针后 memcpy
/// 到 out（Dart 为透传零拷贝，嵌入式封装独立出帧故复制；通道数=输入
/// 格式通道数）。未连接时端口名回退 inN（rgb 型）。
CNodeFiles _genMux4(CNodeGenCtx ctx) {
  final m = ctx.macro;
  final sel = ctx.intParam('select').clamp(1, 4);
  final base = 'in$sel';
  var port = base;
  var fmt = 'rgb';
  for (final suffix in const ['', '_yuv', '_hsl', '_mono']) {
    final key = '$base$suffix';
    if (ctx.inputFormats.containsKey(key)) {
      port = key;
      fmt = ctx.inputFormats[key]!;
      break;
    }
  }
  final channels = _fmtChannels(fmt);
  final input = CPort(port, channels: channels);
  final output = CPort(_fmtOutPort(fmt), channels: channels);
  final slots = [for (var i = 1; i <= 4; i++) i == sel ? port : 'NULL'];
  return assembleCNode(
    ctx: ctx,
    algoIncludes: const ['isp_blend.h'],
    inputs: [input],
    outputs: [output],
    macroLines: [
      '#define ${m}_SELECT ${cNum(sel, asDouble: false)}',
    ],
    body: '''
  const uint16_t *sel = isp_mux4_select(${m}_SELECT, ${slots.join(', ')});
  if (sel == NULL) return ISP_ERR_ARG;
  memcpy(${output.name}, sel, ${output.bytesExpr});
  return ISP_OK;''',
  );
}
