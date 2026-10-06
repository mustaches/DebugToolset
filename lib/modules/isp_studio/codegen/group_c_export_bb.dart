/// ISP 节点编组导出「黑盒子 C 代码」（行级流水）：校验 + bb top 生成 + 写盘。
///
/// 与整帧版（group_c_export.dart）并存的导出变体：生成单文件黑盒
/// `isp_pipe_<组名>_bb.h/.c`，只暴露编组外部输入/输出帧接口，内部为
/// 行级流水实现——中间结果不存整帧，连续点对点链融合进同一个
/// `for (x)` 行循环（中间值走局部变量）；扇出流/窗口输入流/延迟 FIFO
/// 物化为 scratch 环形缓冲（行号 ℓ 存于槽 ℓ % rows，同一行内先写后读）。
///
/// 结构为 plan → stream plan → emit 三段式：整帧版图推导
/// （group_c_plan.dart）→ 流式阶段组织（stream_plan.dart，含行延迟传播
/// 与环形/FIFO 物化规则）→ 本文件把行核（node_c_stream.dart，含窗口
/// 行核）拼成 bb.h/bb.c。驱动模型：主循环 `for (y = 0; y < h; y++)` 中
/// 延迟 D 的阶段计算第 y-D 行（y < D 跳过），主循环后尾部冲刷循环补齐
/// 底部 maxDelay 行。黑盒像素数学自含：只拷贝 isp_common.h/.c（基础
/// 内联工具/Bayer 相位/中位数），不拷贝其它 c_ref 算法文件；逐像素/
/// 窗口公式按 c_ref 循环体复刻内联（各行核注释标出处）。
///
/// 当前支持：点对点类型 + 垂直窗口类型（dpc/sharpen/edge_extract/
/// rgb_dnr/bayer_dnr/demosaic(bilinear)/highlight）+ 分离趟
///（morphology/gaussian_blur：c_ref 本即水平趟 + 垂直滑窗结构，水平趟
/// 作为派生环写入、垂直趟走窗口行核）+ 延迟均衡 FIFO；全帧统计/跨帧/
/// 跨行采样节点由 [validateGroupBlackBoxExport] 拒绝并列出节点名。
library;

import 'dart:io';

import '../models/isp_graph.dart';
import '../models/isp_node.dart';
import '../pipeline/node_c_code.dart';
import 'c_ident.dart';
import 'group_c_export.dart';
import 'group_c_target.dart';
import 'node_c_gen.dart';
import 'node_c_stream.dart';
import 'stream_plan.dart';

/// 黑盒 top 层名（`isp_pipe_<组名净化>_bb`，命名规则与整帧版一致）。
String groupBlackBoxTopName(IspNodeGroup group) => '${groupCTopName(group)
        .replaceFirst(RegExp('^isp_pipeline_'), 'isp_pipe_')}_bb';

/// 校验编组能否导出黑盒子（行级流水）C 代码；可导出返回 null，否则返回
/// 中文错误说明。先跑整帧版校验（validateGroupCExport），再查：成员类型
/// 全在流式支持集（不支持者按原因分类列出节点名）、demosaic 为 Bayer
/// CFA + bilinear 算法、无运行期全帧统计形态（white_balance auto）、
/// 无数据环。
String? validateGroupBlackBoxExport(IspGraph graph, IspNodeGroup group) {
  final base = validateGroupCExport(graph, group);
  if (base != null) return base;
  final members = [
    for (final id in group.nodeIds) ?graph.nodes[id],
  ];
  // 拒绝原因分类（核实结论见 stream_plan.dart 文件头）。
  String rejectReason(String typeId) => switch (typeId) {
        'fpn' => '需整帧多遍统计（全帧低通平面 + 行/列残差中位数），无法行级流水',
        'grgb_balance' || 'fluoro_normalize' || 'fluoro_background' || 'ahe' =>
          '需全帧统计，无法行级流水',
        'fluoro_temporal' => '跨帧持久帧，无法行级流水',
        'fluoro_fusion' => '偏移双线性采样/轮廓邻域需跨行访问',
        _ => '暂不支持行级流水导出',
      };
  final unsupported = <String>[];
  for (final n in members) {
    if (streamSupportedTypeIds.contains(n.typeId)) continue;
    final display = IspNodeRegistry.byId(n.typeId)?.displayName ?? n.typeId;
    unsupported.add('${n.name}（$display：${rejectReason(n.typeId)}）');
  }
  if (unsupported.isNotEmpty) {
    return '以下节点暂不支持黑盒子（行级流水）导出：${unsupported.join('、')}。';
  }
  // demosaic：仅 Bayer CFA + bilinear。
  for (final n in members) {
    if (n.typeId != 'demosaic') continue;
    var cfa = '${n.paramValues['cfaPattern'] ?? ''}'.trim();
    if (cfa.isEmpty) cfa = '${n.paramValues['bayerPattern'] ?? ''}'.trim();
    const nonBayer = {'RCCB', 'RCCG', 'RCCC', 'RYYCY', 'RGB_IR', 'RGBIR'};
    if (nonBayer.contains(cfa.toUpperCase())) {
      return '节点 ${n.name} 的 CFA 为 $cfa：行级流水暂仅支持 Bayer'
          '（RGGB/BGGR/GRBG/GBRG）+ bilinear 去马赛克。';
    }
    final algo = '${n.paramValues['algorithm'] ?? ''}'.trim();
    if (algo.isNotEmpty && algo != 'bilinear') {
      return '节点 ${n.name} 的去马赛克算法为 $algo：行级流水暂仅支持 '
          'bilinear（请在节点参数中切换算法）。';
    }
  }
  // white_balance auto：增益估计（灰度世界）需全帧统计。
  for (final n in members) {
    if (n.typeId == 'white_balance' && n.paramValues['mode'] == 'auto') {
      return '节点 ${n.name} 为 auto 白平衡模式：增益估计需全帧统计，'
          '无法行级流水（请改用 manual 模式）。';
    }
  }
  // color_controller：q 必须为正（c_ref 对 q <= 0 返回参数错误）。
  for (final n in members) {
    if (n.typeId != 'color_controller') continue;
    final q = (n.paramValues['q'] as num?)?.toDouble() ?? 2.0;
    if (!(q > 0.0)) return '节点 ${n.name} 的 q 参数必须为正数。';
  }
  // multi_band_eq：各段 q 必须为正（c_ref 同口径返回参数错误）。
  for (final n in members) {
    if (n.typeId != 'multi_band_eq') continue;
    final count =
        ((n.paramValues['band_count'] as num?)?.toInt() ?? 1).clamp(1, 24);
    for (var i = 0; i < count; i++) {
      final q = (n.paramValues['b${i}_q'] as num?)?.toDouble() ?? 2.0;
      if (!(q > 0.0)) return '节点 ${n.name} 第 ${i + 1} 段的 q 参数必须为正数。';
    }
  }
  // 数据环（splitter/combiner 回环）无法流水。
  return streamPlanDataCycleError(graph, group);
}

/// 内存生成编组黑盒 C 代码：文件名 → 内容（bb top .h/.c + isp_common
/// .h/.c）。键顺序与 [exportGroupBlackBoxCCode] 的写盘顺序一致。
/// [readFile] 测试注入用（isp_common 内容读取，默认 rootBundle 资产）；
/// [genTime] 文件头注释的生成时间（测试注入固定值保证比对稳定）。
Future<Map<String, String>> buildGroupBlackBoxCFiles(
  IspGraph graph,
  IspNodeGroup group, {
  Future<String> Function(String path)? readFile,
  DateTime? genTime,
  GroupCTarget target = GroupCTarget.cortexA53_55,
}) async {
  genTime ??= DateTime.now();
  final plan = planGroupC(graph, group);
  final stream = planGroupStream(plan);
  final topName = groupBlackBoxTopName(group);
  final macro = cMacroPrefix(topName);

  // ---- 阶段发射（行核登记 helper / 烘焙表 / 前奏 / gamma LUT）----
  final s = StreamKernelCtx();
  final stageCodes = <String>[
    for (var k = 0; k < stream.stages.length; k++)
      _emitStage(s, graph, stream, k, target),
  ];

  // ---- run() 形参 ----
  final runParams = <String>[
    for (final p in plan.extInputParams) 'const ${p.cType} *${p.name}',
    'int w',
    'int h',
    'int max_value',
    for (final p in plan.extOutputParams) '${p.cType} *${p.name}',
    if (stream.needsScratch) ...['void *scratch', 'size_t scratch_bytes'],
  ];

  // ---- scratch（物化环形缓冲 → 窗口派生环 → gamma LUT 区）----
  final scratchTotal = stream.scratchTerms
      .map((t) => 'ISP_PIPE_ALIGN8($t)')
      .join(' +\\\n    ');
  final carve = <String>[];
  if (stream.needsScratch) {
    carve.add('  uint8_t *isp_p = (uint8_t *)scratch;');
    for (final b in stream.lineBuffers) {
      carve.add('  uint16_t *${b.name} = (uint16_t *)isp_p;');
      carve.add('  isp_p += ISP_PIPE_ALIGN8(${b.bytesExpr});');
    }
    for (final wi in stream.windowInfos.values) {
      for (final b in wi.internalBuffers) {
        carve.add('  ${b.cType} *${b.name} = (${b.cType} *)isp_p;');
        carve.add('  isp_p += ISP_PIPE_ALIGN8(${b.bytesExpr});');
      }
    }
    for (final gid in stream.gammaLutNodeIds) {
      final ident = plan.idents[gid]!;
      carve.add('  uint8_t *${ident}_lut = (uint8_t *)isp_p;');
      carve.add(
          '  isp_p += ISP_PIPE_ALIGN8((size_t)(max_value + 1) * sizeof(uint8_t));');
    }
  }

  // ---- gamma 色调映射 LUT 构建（出处：isp_gamma.c _tonemapLut 循环）----
  final gammaBuild = <String>[
    for (final e in s.gammaLuts.entries)
      '''
  /* gamma 色调映射 LUT（${e.key}）：归一化 → 加亮度 → 绕 0.5 对比度 →
   * 钳位 [0,1] → pow(c, 1/gamma) → 钳位 → round(c*255)。 */
  {
    const double inv_gamma_ = 1.0 / ${cNum(e.value.$1)};
    int v_;
    for (v_ = 0; v_ <= max_value; v_++) {
      double c_ = (double)v_ / (double)max_value;
      c_ += ${cNum(e.value.$2)};
      c_ = (c_ - 0.5) * ${cNum(e.value.$3)} + 0.5;
      if (c_ < 0.0) c_ = 0.0;
      if (c_ > 1.0) c_ = 1.0;
      c_ = pow(c_, inv_gamma_);
      if (c_ < 0.0) c_ = 0.0;
      if (c_ > 1.0) c_ = 1.0;
      ${e.key}_lut[v_] = (uint8_t)llround(c_ * 255.0);
    }
  }''',
  ];

  // ---- y 循环顶的行指针（外部输入/输出帧按行访问；零延迟阶段使用）----
  final rowDecls = <String>[
    for (final p in plan.extInputParams)
      '    const uint16_t *row_${p.name} = ${p.name} + (size_t)y * (size_t)w${p.channels == 1 ? '' : ' * ${p.channels}u'};',
    for (final p in plan.extOutputParams)
      '    ${p.cType} *row_${p.name} = ${p.name} + (size_t)y * (size_t)w${p.channels == 1 ? '' : ' * ${p.channels}u'};',
  ];

  // ---- 尾部冲刷（窗口延迟致输出滞后，底部 maxDelay 行在此补齐）----
  final flushCodes = stream.maxDelay > 0
      ? [
          '  /* 尾部冲刷：窗口阶段输出滞后其延迟行数，底部延迟行在此补齐。 */',
          '  for (y = h; y < h + ${stream.maxDelay}; y++) {',
          for (var k = 0; k < stream.stages.length; k++)
            if (stream.stages[k].delay > 0) _emitStage(s, graph, stream, k, target),
          '  }',
        ]
      : <String>[];
  // 冲刷发射可能补登记 helper/前奏（与主循环同一 s；helper/表/prepend 在
  // 文件顶部统一去重发射，登记顺序不影响产物）。
  final helpers = s.helperDefs();

  // ---- top .h ----
  final topGuard = '${macro}_H';
  final topH = '''
#ifndef $topGuard
#define $topGuard

#include "isp_common.h"

#ifdef __cplusplus
extern "C" {
#endif
${stream.needsScratch ? '''
/* 8 字节对齐（scratch 各区分界）。 */
#define ISP_PIPE_ALIGN8(x) (((size_t)(x) + 7u) & ~(size_t)7u)

/* scratch 竞技场总大小 = 物化环形缓冲（扇出/窗口输入/延迟 FIFO，行号
 * 取模寻址） + 窗口派生环 + gamma 色调映射 LUT；无 h 因子（不存整帧）。 */
#define ${macro}_SCRATCH_BYTES(w, h, max_value) \\
    ($scratchTotal)
''' : ''}
/* 行级流水：连续点对点链融合进同一行循环（中间值走局部变量），物化流
 * 经 scratch 环形缓冲在同一行内先写后读。输入为组外部输入帧，输出为
 * 组外部输出帧。 */
int ${topName}_run(${runParams.join(', ')});

#ifdef __cplusplus
} /* extern "C" */
#endif

#endif /* $topGuard */
''';

  // ---- top .c ----
  // OpenMP 行域并行的安全条件：y 循环无跨迭代共享可写状态。scratch 行缓冲
  // （扇出/窗口输入/延迟 FIFO 物化流，含 rows=1 的扇出单行缓冲）在 y 循环
  // 外声明、被多行共享，并行会竞态，故仅当无任何行缓冲（单线性点操作链，
  // 无扇出/汇合/窗口）时并行；gamma LUT 只读、外部输入/输出按行偏移寻址，
  // 均无竞态。内层 for-x 的计数变量 x 在 top 声明，需 private(x)（整行
  // <id>_row 单节点独占阶段无 x 变量，则不加）。
  final rowParallel = stream.lineBuffers.isEmpty;
  final rowKernelParallel = rowParallel &&
      stream.stages.length == 1 &&
      _rowNodeId(graph, stream, stream.stages.single,
              stream.stages.single.delay, target) !=
          null;
  final topC = '''
#include "$topName.h"

#include <math.h>
#include <string.h>
${s.cscSseUsed ? '#include "isp_csc_sse.h" /* x86 FP64 HSL 行核双像素快路径（逐位一致） */\n' : ''}${helpers.isEmpty ? '' : '\n$helpers\n'}${s.fileDecls.isEmpty ? '' : '\n${s.fileDecls.join('\n\n')}\n'}
int ${topName}_run(${runParams.join(', ')}) {
  /* 单节点独占且类型有整行行核时阶段整行走 <id>_row，top 层无 x 循环——
   * 条件声明避免 GCC -Wunused-variable。 */
  int y${rowKernelParallel ? '' : ', x'};
${stream.needsScratch ? '''  if (scratch == NULL ||
      scratch_bytes < ${macro}_SCRATCH_BYTES(w, h, max_value)) {
    return ISP_ERR_SIZE;
  }
${carve.join('\n')}
''' : ''}${gammaBuild.isEmpty ? '' : '${gammaBuild.join('\n')}\n'}${s.prelude.isEmpty ? '' : '${s.prelude.map((l) => '  $l').join('\n')}\n'}${rowParallel ? '''#if defined(_OPENMP)
  /* 单线性点操作链（无行缓冲）：逐像素独立点运算、行间无依赖，行域并行
   * 与串行逐位一致（omp 开关随编译选项；不开 omp 自动串行）。x 计数变量
   * 在 top 声明，private(x) 令其线程私有；整行 <id>_row 变体无 x 变量。 */
#pragma omp parallel for${rowKernelParallel ? '' : ' private(x)'}
#endif
''' : ''}  for (y = 0; y < h; y++) {
${rowDecls.join('\n')}
${stageCodes.join('\n')}  }
${flushCodes.join('\n')}
  return ISP_OK;
}
''';

  // ---- 收集生成物 ----
  final files = <String, String>{
    '$topName.h': _bbDoc(group, genTime, target) + topH,
    '$topName.c': _bbDoc(group, genTime, target) + topC,
  };
  // isp_common.h/.c：基础内联工具与 Bayer 相位（黑盒像素数学自含，
  // 不拷贝其它 c_ref 算法文件）。读取失败静默跳过（与整帧版一致）。
  for (final f in const ['isp_common.h', 'isp_common.c']) {
    try {
      files[f] = await loadCRefFile(f, readFile: readFile);
    } catch (_) {
      // 与 exportCRefFiles 一致：单个文件失败不中断其余文件。
    }
  }
  // x86 FP64 HSL 行核依赖（仅当登记了 hsl2rgb/rgb2hsl 行核时附带）。
  if (s.cscSseUsed) {
    for (final f in const ['isp_csc_sse.h', 'isp_csc_common.h']) {
      try {
        files[f] = await loadCRefFile(f, readFile: readFile);
      } catch (_) {
        // 同上：单个文件失败不中断其余文件。
      }
    }
  }
  // 目标微架构说明（加速宏定义 + 实现方案），随代码一并导出。
  files[target.microDocName] = buildTargetCodeMicroDoc(target, blackBox: true);
  return files;
}

/// 有整行行核的单节点独占阶段的节点 id（不满足条件返回 null）：零延迟、
/// 单节点链、无窗口、外部输入、单一外部输出、类型+参数有整行 `<id>_row`
///（NEON/SSE2 + 标量双变体随导出目标分叉，或纯标量）。命中时阶段整行
/// 走 `<id>_row`，且 top 层 y 循环可加 OpenMP 行域并行（逐像素独立运算
/// 逐位一致）。
String? _rowNodeId(IspGraph graph, GroupStreamPlan stream,
    StreamStage stage, int delay, GroupCTarget target) {
  if (delay != 0 || stage.chain.length != 1) return null;
  final plan = stream.plan;
  final nid = stage.chain.single;
  final member = plan.members[nid]!;
  // 输入端口取 wrapper 实际端口名（mono 形态为 'in_mono' 而非 'in'）。
  final inPort = plan.wrappers[nid]!.inputs.single.name;
  final inSrc = stream.inputSrcs['$nid:$inPort'];
  if (stream.windowInfos[nid] != null ||
      inSrc == null ||
      inSrc.ext == null ||
      stage.targets.length != 1 ||
      stage.targets.single.extOutput == null) {
    return null;
  }
  // 类型 + 参数的行核可用性（与 node_c_stream 行核发射器的登记口径一致：
  // 发射器按同一组参数登记 `<id>_row` 文件级声明）。
  final mode = member.paramValues['codegenMode'];
  if (member.typeId == 'multi_band_eq') {
    return (mode == 'lut_fixed' || mode == 'lut') ? nid : null;
  }
  if (member.typeId == 'csc_rgb2yuv') {
    if (member.paramValues['bypass'] == true) return null;
    if ('${member.paramValues['standard'] ?? ''}' == 'bt709') return null;
    if ('${member.paramValues['range'] ?? ''}' == 'limited') return null;
    return nid;
  }
  if (member.typeId == 'csc_yuv2rgb') {
    if (member.paramValues['bypass'] == true) return null;
    return nid;
  }
  if (member.typeId == 'csc_hsl2rgb' || member.typeId == 'csc_rgb2hsl') {
    // x86 专属 FP64 SSE2 双像素行核（与行核发射器登记口径一致；ARM 无
    // FP64 SIMD 不登记）。
    if (member.paramValues['bypass'] == true) return null;
    if (!target.isX86) return null;
    return nid;
  }
  if (member.typeId == 'white_balance') {
    // LUT 模式 + 非恒等 + 非 bypass（与行核发射器登记口径一致）。
    if (whiteBalanceRowGains(member.paramValues) == null) return null;
    return nid;
  }
  if (member.typeId == 'ccm') {
    // 非 bypass、非恒等、全部 Q20 系数 |m| ≤ INT32_MAX（与行核发射器
    // 登记口径一致）。
    if (member.paramValues['bypass'] == true) return null;
    final (m, isIdentity) = ccmMatrixOf(member.paramValues);
    if (isIdentity) return null;
    if (!m.every((v) => v.abs() <= 2147483647)) return null;
    return nid;
  }
  if (member.typeId == 'levels_curves') {
    if (!levelsRowOk(member.paramValues)) return null;
    return nid;
  }
  if (member.typeId == 'color_temp_adjuster') {
    // LUT 模式 + 增益非全 1（与行核发射器登记口径一致）。
    if (colorTempRowGains(member.paramValues) == null) return null;
    return nid;
  }
  if (member.typeId == 'pseudo_color') {
    // LUT 模式 + 非 bypass（与行核发射器登记口径一致）。
    if (!pseudoColorRowOk(member.paramValues)) return null;
    return nid;
  }
  if (member.typeId == 'highlight') {
    // highlight(clip) LUT 模式 + 1 通道输入（RAW 'in' / 'in_mono'，与行核
    // 发射器登记口径一致）。
    if (!highlightClipRowOk(member.paramValues)) return null;
    if (member.paramValues['mode'] != 'clip') return null;
    if (inSrc.channels != 1) return null;
    return nid;
  }
  if (member.typeId == 'gamma') {
    // gamma 恒登记行核（16 位 RGB → 8 位 RGBA，LUT 运行期构建）；无参数
    // 条件，bypass 亦退化为默认参数。
    return nid;
  }
  if (member.typeId == 'sat_bright_adjuster') {
    // rgb 形态 x86 专属 FP64 双像素（与行核发射器登记口径一致）。
    if (satBrightRowOk(member.paramValues, target.isX86) == null) return null;
    return nid;
  }
  if (member.typeId == 'black_level') {
    // Bayer 形态 x86 专属 FP64 双像素（与行核发射器登记口径一致）。
    if (!blackLevelRowOk(member.paramValues, target.isX86)) return null;
    return nid;
  }
  if (member.typeId == 'color_controller') {
    // LUT 模式 x86 专属（H int32 + S/L FP64 双像素，与行核发射器登记
    // 口径一致）。
    if (!colorControllerRowOk(member.paramValues, target.isX86)) return null;
    return nid;
  }
  return null;
}

/// 发射一个行循环阶段：窗口预备（派生行/窗口行指针）→ 融合链逐节点
/// 行核 → 写物化目标（行 y-D，环形槽取模）。[target] 贯通导出目标 CPU
///（lut_fixed 行核 SIMD 变体选择）。
String _emitStage(StreamKernelCtx s, IspGraph graph, GroupStreamPlan stream,
    int k, GroupCTarget target) {
  final plan = stream.plan;
  final stage = stream.stages[k];
  final d = stage.delay;
  s.rowVar = d > 0 ? 'yo' : 'y';
  final ind = d > 0 ? '      ' : '    ';
  final values = <String, List<String>>{};
  final b = StringBuffer();
  final chainDesc =
      stage.chain.map((id) => plan.members[id]!.name).join(' → ');
  final targetDesc = [
    for (final t in stage.targets) ...[
      if (t.lineBuffer != null) stream.lineBuffers[t.lineBuffer!].name,
      if (t.extOutput != null) 'row_${t.extOutput!.name}',
    ],
  ].join(' + ');
  b.writeln(
      '    /* 阶段 $k：$chainDesc → $targetDesc${d > 0 ? '（延迟 $d 行）' : ''} */');
  if (d > 0) {
    b.writeln('    if (y >= $d) {');
    b.writeln('      const int yo = y - $d;');
  }

  // ---- 预备声明：环形读取行指针 / 目标行指针 / 窗口行指针 ----
  final declared = <String>{};
  // 点对点节点读取的环形缓冲（FIFO/窗口输入环/窗口输出环）：任何延迟的
  // 阶段都可能读到（D=0 阶段的生产者流也可被其它窗口/FIFO 消费者提为
  // 环形），按本阶段行变量取模。外部输入在延迟阶段按 yo 寻址。
  for (final id in stage.chain) {
    if (stream.windowInfos.containsKey(id)) continue;
    for (final cp in plan.wrappers[id]!.inputs) {
      final src = stream.inputSrcs['$id:${cp.name}']!;
      final nid = src.nodeId;
      if (nid != null) {
        final bufIdx = stream.streamBufferIndex['$nid:${src.port}'];
        if (bufIdx == null) continue;
        final buf = stream.lineBuffers[bufIdx];
        if (buf.rows > 1 && declared.add(buf.name)) {
          b.writeln(
              '$ind  const uint16_t *irow_${buf.name} = ${buf.name} + (size_t)(${s.rowVar} % ${buf.rows}) * (size_t)w${_chFactor(buf.channels)};');
        }
      } else if (d > 0 && src.ext != null && declared.add(src.ext!.name)) {
        b.writeln(
            '$ind  const uint16_t *irow_${src.ext!.name} = ${src.ext!.name} + (size_t)yo * (size_t)w${_chFactor(src.ext!.channels)};');
      }
    }
  }
  // 目标行指针（环形物化缓冲 / 延迟阶段的外部输出）。
  for (final t in stage.targets) {
    if (t.lineBuffer != null) {
      final buf = stream.lineBuffers[t.lineBuffer!];
      if (buf.rows > 1 && declared.add('trow_${buf.name}')) {
        b.writeln(
            '$ind  uint16_t *trow_${buf.name} = ${buf.name} + (size_t)(${s.rowVar} % ${buf.rows}) * (size_t)w${_chFactor(buf.channels)};');
      }
    }
    if (d > 0 && t.extOutput != null && declared.add('trow_${t.extOutput!.name}')) {
      b.writeln(
          '$ind  ${t.extOutput!.cType} *trow_${t.extOutput!.name} = ${t.extOutput!.name} + (size_t)yo * (size_t)w${_chFactor(t.extOutput!.channels)};');
    }
  }
  // 窗口节点预备（派生行写入 + 窗口行指针 + dpc 输出环/当前行拷贝）。
  for (final id in stage.chain) {
    final wi = stream.windowInfos[id];
    if (wi != null) _emitWindowPreamble(b, s, stream, id, wi, ind);
  }

  // ---- 有整行行核的单节点独占阶段：整行走 ${id}_row（NEON/SSE2 + 标量
  // 双变体随导出目标分叉），跳过逐像素融合循环（条件见 [_rowNodeId]）。----
  String? fixedRowCall;
  {
    final nid = _rowNodeId(graph, stream, stage, d, target);
    if (nid != null) {
      final ident = streamNodeCtx(graph, plan, nid).ident;
      final inPort = plan.wrappers[nid]!.inputs.single.name;
      final inExt = stream.inputSrcs['$nid:$inPort']!.ext!;
      final typeId = plan.members[nid]!.typeId;
      // 形参特判：gamma 行核带运行期 LUT 指针（top 层 scratch carve 声明，
      // 同作用域可直接传）；black_level 行核带 y（Bayer 相位随行奇偶交替）。
      final extra = typeId == 'gamma'
          ? ', ${ident}_lut'
          : typeId == 'black_level'
              ? ', y'
              : '';
      fixedRowCall =
          '${ident}_row(row_${inExt.name}, row_${stage.targets.single.extOutput!.name}, w, max_value$extra)';
    }
  }

  // ---- 主行循环：融合链逐节点行核 ----
  if (fixedRowCall != null) {
    // 触发表/行函数/helper 登记（行核行本身不内联）。
    final id = stage.chain.single;
    final wrapper = plan.wrappers[id]!;
    final inputs = <String, List<String>?>{};
    for (final cp in wrapper.inputs) {
      inputs[cp.name] =
          _srcExprs(stream, stream.inputSrcs['$id:${cp.name}']!, values, d);
    }
    emitStreamRowKernel(s, streamNodeCtx(graph, plan, id, target: target),
        inputs);
    b.writeln('$ind  $fixedRowCall;');
    if (d > 0) b.writeln('    }');
    return b.toString();
  }
  b.writeln('$ind  for (x = 0; x < w; x++) {');
  for (final id in stage.chain) {
    final wrapper = plan.wrappers[id]!;
    final wi = stream.windowInfos[id];
    if (wi != null) {
      final (lines, outs) = emitStreamWindowKernel(
          s, streamNodeCtx(graph, plan, id), _windowAccessOf(stream, id, wi));
      for (final line in lines) {
        b.writeln('$ind    $line');
      }
      for (final e in outs.entries) {
        values['$id:${e.key}'] = e.value;
      }
      continue;
    }
    final inputs = <String, List<String>?>{};
    for (final cp in wrapper.inputs) {
      inputs[cp.name] =
          _srcExprs(stream, stream.inputSrcs['$id:${cp.name}']!, values, d);
    }
    final (lines, outs) = emitStreamRowKernel(
        s, streamNodeCtx(graph, plan, id, target: target), inputs);
    for (final line in lines) {
      b.writeln('$ind    $line');
    }
    for (final e in outs.entries) {
      values['$id:${e.key}'] = e.value;
    }
  }

  // ---- 写物化目标（行 y-D；环形槽取模，单行缓冲直写）----
  for (final t in stage.targets) {
    final target = values['${stage.nodeId}:${t.wrapperPort}']!;
    final idx = [
      for (var c = 0; c < t.channels; c++)
        t.channels == 1 ? 'x' : '(x) * ${t.channels} + $c',
    ];
    if (t.lineBuffer != null) {
      final buf = stream.lineBuffers[t.lineBuffer!];
      final dst = buf.rows == 1 ? buf.name : 'trow_${buf.name}';
      for (var c = 0; c < t.channels; c++) {
        b.writeln('$ind    $dst[${idx[c]}] = ${target[c]};');
      }
    }
    if (t.extOutput != null) {
      final dst = d > 0 ? 'trow_${t.extOutput!.name}' : 'row_${t.extOutput!.name}';
      for (var c = 0; c < t.channels; c++) {
        b.writeln('$ind    $dst[${idx[c]}] = ${target[c]};');
      }
    }
  }
  b.writeln('$ind  }');
  if (d > 0) b.writeln('    }');
  return b.toString();
}

String _chFactor(int channels) => channels == 1 ? '' : ' * ${channels}u';

/// 窗口节点预备：派生环当前行（yo+r）写入 → 派生/输入窗口行指针 →
/// dpc 输出环行指针与当前行拷贝。
void _emitWindowPreamble(StringBuffer b, StreamKernelCtx s,
    GroupStreamPlan stream, String id, StreamWindowNodeInfo wi, String ind) {
  final plan = stream.plan;
  final r = wi.radius;
  final inSrc = stream.inputSrcs['$id:${wi.inputPort}']!;

  // 输入行 yo+k 的基址表达式（环形取模 / 外部输入夹取行号）。
  String inRowExpr(int k) {
    if (wi.inputBuffer >= 0) {
      final buf = stream.lineBuffers[wi.inputBuffer];
      return '${buf.name} + (size_t)((yo + ${buf.rows - r} + $k) % ${buf.rows}) * (size_t)w${_chFactor(buf.channels)}';
    }
    final ext = inSrc.ext!;
    return '${ext.name} + (size_t)((yo - ${r - k}) < 0 ? 0 : ((yo - ${r - k}) >= h ? h - 1 : (yo - ${r - k}))) * (size_t)w${_chFactor(ext.channels)}';
  }

  // ---- 派生环当前行（yo+r）写入（守卫：输入行存在）----
  if (wi.internalBuffers.isNotEmpty) {
    // 派生目标为行环形缓冲（gaussian 的权重核 rowWidth 为 null，不参与）。
    final aux = wi.internalBuffers.firstWhere((b) => b.rowWidth != null);
    final auxCh = aux.channels == 1 ? '' : ' * ${aux.channels}u';
    final typeId = plan.members[id]!.typeId;
    final fmt = streamNodeCtxInputFormat(plan, id);
    final ident = plan.idents[id]!;

    // 派生一行（读输入行基址 srcRow → 写派生环槽 dstRow）的 for-x 循环。
    void emitDeriveRow(String indent, String srcRow, String dstRow) {
      b.writeln('$indent' 'const uint16_t *iro_ = $srcRow;');
      b.writeln('$indent${aux.cType} *sro_ = $dstRow;');
      b.writeln('${indent}for (x = 0; x < w; x++) {');
      if (typeId == 'rgb_dnr') {
        // yuv 派生行：BT.601 全范围定点转换（bb_rgb_to_yuv_px）。
        s.useHelper('bb_rgb_to_yuv_px');
        b.writeln(
            '$indent  bb_rgb_to_yuv_px(iro_[(x) * 3], iro_[(x) * 3 + 1], iro_[(x) * 3 + 2], max_value >> 1, max_value, sro_ + (x) * 3);');
      } else if (typeId == 'morphology') {
        // 水平趟：窗口 [x-r, x+r] 截断取极值（严格比较；极值与枚举顺序
        // 无关，中心 tap 恒在界内作初值）。出处：isp_morphology.c
        // isp_morphology_apply 水平趟。
        final erode = plan.members[id]!.paramValues['mode'] != 'dilate';
        final ch = aux.channels;
        for (var c = 0; c < ch; c++) {
          final colC = ch == 1 ? 'x' : '(x) * $ch + $c';
          b.writeln('$indent  {');
          b.writeln('$indent    uint16_t hv_ = iro_[$colC];');
          for (var dx = -r; dx <= r; dx++) {
            if (dx == 0) continue;
            final col = dx > 0 ? '(x + $dx)' : '(x - ${-dx})';
            b.writeln('$indent    if ($col >= 0 && $col < w) {');
            b.writeln(
                '$indent      const uint16_t u_ = iro_[${ch == 1 ? col : '$col * $ch + $c'}];');
            b.writeln(
                '$indent      if (${erode ? 'u_ < hv_' : 'u_ > hv_'}) hv_ = u_;');
            b.writeln('$indent    }');
          }
          b.writeln('$indent    sro_[$colC] = hv_;');
          b.writeln('$indent  }');
        }
      } else if (typeId == 'gaussian_blur') {
        // 水平趟：k 升序卷积，tap 下标越界时钳回图内端点（边界复制）。
        // 出处：isp_gaussian_blur.c isp_gaussian_blur_apply 水平趟。
        final ch = aux.channels;
        for (var c = 0; c < ch; c++) {
          final colC = ch == 1 ? 'x' : '(x) * $ch + $c';
          b.writeln('$indent  {');
          b.writeln('$indent    double acc_ = 0.0;');
          for (var k = 0; k < 2 * r + 1; k++) {
            final off = k - r;
            final xx =
                off == 0 ? 'x' : (off > 0 ? '(x + $off)' : '(x - ${-off})');
            b.writeln(
                '$indent    acc_ += (double)iro_[($xx < 0 ? 0 : ($xx >= w ? w - 1 : $xx))${ch == 1 ? '' : ' * $ch + $c'}] * ${ident}_gk[$k];');
          }
          b.writeln('$indent    sro_[$colC] = acc_;');
          b.writeln('$indent  }');
        }
      } else if (typeId == 'edge_extract' && fmt == 'yuv') {
        b.writeln('$indent  sro_[x] = iro_[(x) * 3];');
      } else if (typeId == 'edge_extract' && fmt == 'hsl') {
        b.writeln('$indent  sro_[x] = iro_[(x) * 3 + 2];');
      } else {
        // sharpen / edge_extract(RGB)：BT.601 定点亮度（与 rgbToYuv 的 Y
        // 同一公式；系数和 65536 不超 uint16，无钳位）。
        b.writeln(
            '$indent  sro_[x] = (uint16_t)((19595 * (int64_t)iro_[(x) * 3] + 38470 * (int64_t)iro_[(x) * 3 + 1] + 7471 * (int64_t)iro_[(x) * 3 + 2] + 32768) >> 16);');
      }
      b.writeln('$indent}');
    }

    // 派生环预填：首个窗口迭代（yo == 0）时，此前迭代本阶段因 y < D 未
    // 执行，初始行 0..r-1 从未派生，在此补齐（行存在性逐行守卫）。
    b.writeln('$ind  if (yo == 0) {');
    for (var l = 0; l < r; l++) {
      b.writeln('$ind    if ($l < h) {');
      final srcRow = wi.inputBuffer >= 0
          ? '${stream.lineBuffers[wi.inputBuffer].name} + (size_t)(($l) % ${stream.lineBuffers[wi.inputBuffer].rows}) * (size_t)w${_chFactor(stream.lineBuffers[wi.inputBuffer].channels)}'
          : '${inSrc.ext!.name} + (size_t)($l) * (size_t)w${_chFactor(inSrc.ext!.channels)}';
      emitDeriveRow('$ind      ', srcRow,
          '${aux.name} + (size_t)(($l) % ${aux.rows}) * (size_t)w$auxCh');
      b.writeln('$ind    }');
    }
    b.writeln('$ind  }');
    b.writeln('$ind  if (yo + $r < h) {');
    emitDeriveRow('$ind    ', inRowExpr(2 * r),
        '${aux.name} + (size_t)((yo + $r) % ${aux.rows}) * (size_t)w$auxCh');
    b.writeln('$ind  }');
    // 派生环窗口行指针（k = 0..2r，行 yo-r+k）。
    if (typeId == 'gaussian_blur') {
      // gaussian 垂直趟为「夹取/边界复制」语义（出处：isp_gaussian_blur.c
      // 垂直趟 yy 钳回 [y0, y1]），行指针按夹取后的行号取模。
      for (var k = 0; k <= 2 * r; k++) {
        final yy = k == r ? 'yo' : (k < r ? 'yo - ${r - k}' : 'yo + ${k - r}');
        b.writeln(
            '$ind  const double *grow_${id}_$k = ${aux.name} + (size_t)(($yy < 0 ? 0 : ($yy >= h ? h - 1 : $yy)) % ${aux.rows}) * (size_t)w$auxCh;');
      }
    } else {
      for (var k = 0; k <= 2 * r; k++) {
        b.writeln(
            '$ind  const uint16_t *srow_${id}_$k = ${aux.name} + (size_t)((yo + ${aux.rows - r} + $k) % ${aux.rows}) * (size_t)w$auxCh;');
      }
    }
  }

  // ---- 输入窗口行指针（k = 0..2r，行 yo-r+k）----
  for (var k = 0; k <= 2 * r; k++) {
    b.writeln('$ind  const uint16_t *wrow_${id}_$k = ${inRowExpr(k)};');
  }

  // ---- dpc 原地语义：输出环行指针（k = 0..r，行 yo-r+k）+ 当前行拷贝 ----
  if (wi.inPlace) {
    final regPort = plan.wrappers[id]!.outputs.single.name;
    final outBuf =
        stream.lineBuffers[stream.streamBufferIndex['$id:$regPort']!];
    for (var k = 0; k < r; k++) {
      b.writeln(
          '$ind  const uint16_t *orow_${id}_$k = ${outBuf.name} + (size_t)((yo + ${outBuf.rows - r} + $k) % ${outBuf.rows}) * (size_t)w;');
    }
    b.writeln(
        '$ind  uint16_t *ow_$id = ${outBuf.name} + (size_t)(yo % ${outBuf.rows}) * (size_t)w;');
    // 当前行整行拷入输出环：处理过程中左侧读已处理值（本迭代写回）、
    // 右侧读未处理值（拷贝内容），与 c_ref 原地读写一致。
    b.writeln('$ind  for (x = 0; x < w; x++) {');
    b.writeln('$ind    ow_$id[x] = wrow_${id}_$r[x];');
    b.writeln('$ind  }');
  }
}

/// 窗口节点的访问描述（行指针变量名与预备声明一致）。
StreamWindowAccess _windowAccessOf(
    GroupStreamPlan stream, String id, StreamWindowNodeInfo wi) {
  final r = wi.radius;
  // gaussian 垂直趟为夹取语义，行指针用 grow_ 前缀（预备处夹取行号）。
  final auxPrefix =
      stream.plan.members[id]!.typeId == 'gaussian_blur' ? 'grow' : 'srow';
  return StreamWindowAccess(
    rowPtrs: [for (var k = 0; k <= 2 * r; k++) 'wrow_${id}_$k'],
    radius: r,
    channels: stream.plan.wrappers[id]!.inputs.single.channels,
    auxRowPtrs: wi.internalBuffers.isEmpty
        ? null
        : [for (var k = 0; k <= 2 * r; k++) '${auxPrefix}_${id}_$k'],
    outRowPtrs: wi.inPlace
        ? [
            for (var k = 0; k < r; k++) 'orow_${id}_$k',
            'ow_$id',
          ]
        : null,
  );
}

/// 节点的活动输入格式（edge_extract 派生行分派用；取首要活动输入端口）。
String streamNodeCtxInputFormat(GroupCPlan plan, String nodeId) {
  final wrapper = plan.wrappers[nodeId]!;
  final first = wrapper.inputs.first.name;
  return switch (first) {
    'in_yuv' => 'yuv',
    'in_hsl' => 'hsl',
    'in_mono' => 'mono',
    _ => 'rgb',
  };
}

/// 节点输入端口 → 通道 C 表达式（物化流元素 / 外部输入行元素 / 融合链
/// 上游局部变量；null = 未连接的次要输入，仅 combiner）。环形缓冲
/// （rows>1）在延迟阶段按 yo 取模读取（irow_ 行指针，预备处声明）。
List<String>? _srcExprs(GroupStreamPlan stream, StreamSrc src,
    Map<String, List<String>> values, int stageDelay) {
  if (src.isUnconnected) return null;
  final nid = src.nodeId;
  if (nid != null) {
    final bufIdx = stream.streamBufferIndex['$nid:${src.port}'];
    if (bufIdx != null) {
      final buf = stream.lineBuffers[bufIdx];
      final base = buf.rows == 1 ? buf.name : 'irow_${buf.name}';
      return [
        for (var c = 0; c < src.channels; c++)
          src.channels == 1 ? '$base[x]' : '$base[(x) * ${src.channels} + $c]',
      ];
    }
    // 非物化：融合链上游已发射的局部变量。
    final v = values['$nid:${src.wrapperPort}'];
    if (v == null) {
      throw StateError('融合链内部错误：$nid:${src.wrapperPort} 尚未发射');
    }
    return v;
  }
  final ext = src.ext!;
  final base = stageDelay > 0 ? 'irow_${ext.name}' : 'row_${ext.name}';
  return [
    for (var c = 0; c < ext.channels; c++)
      ext.channels == 1 ? '$base[x]' : '$base[(x) * ${ext.channels} + $c]',
  ];
}

/// 把编组导出为黑盒 C 代码并写入 [dir]（须已校验，见
/// [validateGroupBlackBoxExport]）。薄壳，仿 exportGroupCCode。
Future<GroupCExportResult> exportGroupBlackBoxCCode(
  IspGraph graph,
  IspNodeGroup group,
  String dir, {
  Future<String> Function(String path)? readFile,
  DateTime? genTime,
  GroupCTarget target = GroupCTarget.cortexA53_55,
}) async {
  final files = await buildGroupBlackBoxCFiles(graph, group,
      readFile: readFile, genTime: genTime, target: target);
  final written = <String>[];
  for (final e in files.entries) {
    await File('$dir/${e.key}').writeAsString(e.value);
    written.add(e.key);
  }
  return GroupCExportResult(written, groupBlackBoxTopName(group));
}

String _bbDoc(IspNodeGroup group, DateTime genTime, GroupCTarget target) => '''
/* 本文件由 DebugToolSet ISP Studio 自动生成：编组「${group.name}」的
 * 黑盒子（行级流水）ISP pipeline。语义说明：
 * - 行级流水：中间结果不存整帧；连续点对点链融合进同一行循环，
 *   中间值只在局部变量中传递；扇出/窗口输入/延迟 FIFO 物化为
 *   scratch 环形缓冲（行号取模寻址，同一行内先写后读）；
 * - 垂直窗口节点输出滞后输入 r 行，主循环后尾部冲刷补齐底部延迟行；
 *   窗口垂直边界按 c_ref 语义裁剪（越界样本丢弃）；
 * - gamma 节点的组内下游直接使用 gamma 的输入行（gamma 不改输入）；
 * - mux4 未选中支路为死路：与 Dart 预览一致裁剪，不生成其上游计算；
 * - combiner 未连接的通道输入填缺省常量（YUV 的 U/V 为 max_value>>1，
 *   其余 0，与 c_ref NULL 缺省语义一致）。
${target.headerBlock().join('\n')}
 * 生成时间：${_fmtGenTime(genTime)}
 */
''';

/// 文件头注释里的生成时间（本地时间，yyyy-MM-dd HH:mm:ss）。
String _fmtGenTime(DateTime t) {
  String two(int v) => v.toString().padLeft(2, '0');
  return '${t.year}-${two(t.month)}-${two(t.day)} '
      '${two(t.hour)}:${two(t.minute)}:${two(t.second)}';
}
