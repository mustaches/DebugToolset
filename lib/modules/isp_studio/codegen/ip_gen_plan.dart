/// ISP 编组「生成Verilog IP」的规划层：在复用产物 `GroupStreamPlan` 之上
/// 补 IP 侧信息（位深推导、LUT 深度、总延迟、多段均衡器段参数解析）。纯
/// 推导，无字符串拼接；发射层见 group_ip_export.dart。
library;

import '../models/isp_graph.dart';
import '../models/isp_node.dart';
import 'c_ident.dart';
import 'group_c_plan.dart';
import 'hsl_pipe_verilog.dart';
import 'ip_target.dart';
import 'node_v_full_stream.dart';
import 'stream_plan.dart';

/// IP top 层名：单节点为 `ISP_IP_<节点英文名>`；多节点图的互连顶层保留
/// `isp_ip_<组名净化>`（该顶层不打包为合并 IP）。
String groupIpTopName(IspGraph graph, IspNodeGroup group) {
  if (group.nodeIds.length == 1) {
    final node = graph.nodes[group.nodeIds.first];
    final englishName = node == null
        ? null
        : IspNodeRegistry.byId(node.typeId)?.englishName;
    if (englishName != null &&
        RegExp(r'^[A-Za-z][A-Za-z0-9_]*$').hasMatch(englishName)) {
      return 'ISP_IP_$englishName';
    }
  }
  final base =
      sanitizeCIdent(group.name) ??
      group.id.replaceAll(RegExp(r'[^A-Za-z0-9_]'), '_');
  return 'isp_ip_$base';
}

/// 多段色彩均衡器的段参数解析（与 node_c_stream `_kMultiBandEq` 同口径：
/// band_count 缺省 1 钳位 1..24，b{i}_* 缺键回退恒等默认）。
({
  List<({double h, double q, double dh, double s, double l})> bands,
  bool serial,
})
multiBandEqBands(IspNode n) {
  final count = ((n.paramValues['band_count'] as num?)?.toInt() ?? 1).clamp(
    1,
    24,
  );
  final serial = '${n.paramValues['band_mode'] ?? ''}' == 'serial';
  double p(int i, String suffix, double fallback) =>
      (n.paramValues['b${i}_$suffix'] as num?)?.toDouble() ?? fallback;
  return (
    bands: [
      for (var i = 0; i < count; i++)
        (
          h: p(i, 'h', 0.0),
          q: p(i, 'q', 2.0),
          dh: p(i, 'dh', 0.0),
          s: p(i, 's', 1.0),
          l: p(i, 'l', 1.0),
        ),
    ],
    serial: serial,
  );
}

/// IP 资源/性能估算（v1 粗估口径：随节点类型逐步细化；写入 README 与
/// IP 页信息区，供选档参考）。
class IpResourceEstimate {
  /// LUT ROM 总位数（各烘焙表深度×位宽求和）。
  final int romBits;

  /// 折算 36Kb BRAM 块数（ROM 经 initial 块初始化，综合可推断为
  /// BRAM/分布式 ROM，此处仅作规模参考）。
  final int bram36k;

  /// 逻辑 LUT 粗估（数据通路 + 握手 + 表取数；乘法器绑 LUT 时另计）。
  final int estLuts;

  /// DSP 粗估（Q14 定点乘法器：性能档推断 DSP48，平衡/面积档绑 LUT）。
  final int estDsps;

  /// 总延迟（行缓冲行数 + 流水拍；一般点操作 = 1 拍，RGB→HSL = 3 拍）。
  final int latencyCycles;

  /// 吞吐（像素/时钟；点操作恒 II=1，窗口算子面积档为 1/FOLD）。
  final double throughputPxPerClk;

  const IpResourceEstimate({
    required this.romBits,
    required this.bram36k,
    required this.estLuts,
    required this.estDsps,
    required this.latencyCycles,
    required this.throughputPxPerClk,
  });

  /// 单行摘要（IP 页信息区/日志用）。
  String summary() =>
      'LUT ROM ${romBits / 1024}Kb（≈$bram36k 块 36K BRAM）'
      '  DSP≈$estDsps  LUT≈$estLuts  延迟 $latencyCycles 拍'
      '  吞吐 ${throughputPxPerClk}px/clk';
}

/// IP 生成规划产物（在 [GroupStreamPlan] 之上补 IP 侧信息）。
class IpPlan {
  /// 整帧版规划（复用）。
  final GroupCPlan cPlan;

  /// 行级流水规划（复用）。
  final GroupStreamPlan stream;

  /// IP top 名（`isp_ip_<组名净化>`）。
  final String topName;

  /// 像素位宽（参数/推导）。
  final int pixBits;

  /// 像素最大值 `(1 << pixBits) - 1`（LUT ROM 域 0..maxValue）。
  final int maxValue;

  /// LUT ROM 深度 = maxValue + 1。
  final int lutDepth;

  /// 总延迟（行；点操作编组为 0）。
  final int totalDelay;

  final IpGenOptions options;

  /// 资源/性能估算（随选项策略档联动：乘法器推断 DSP 或绑 LUT）。
  final IpResourceEstimate resources;

  /// 默认行为实现：0 = LUT 查表，1 = 函数运行期直算。
  final int implMode;

  /// 均衡器段数（LUT 与函数双实现共用）。
  final int fxBandCount;

  /// 取色器串联形态（按段序流水线展开）。
  final bool fxSerial;

  const IpPlan({
    required this.cPlan,
    required this.stream,
    required this.topName,
    required this.pixBits,
    required this.maxValue,
    required this.lutDepth,
    required this.totalDelay,
    required this.options,
    required this.resources,
    this.implMode = 0,
    this.fxBandCount = 0,
    this.fxSerial = false,
  });
}

/// 执行 IP 导出的全部规划（见 [IpPlan]）。纯推导，无 IO、无代码字符串；
/// 调用前应先经 [validateGroupIpExport] 校验。位深推导：取组内 LUT 节点
/// [lutDomainMaxOf] 的最大值所需最小位宽（下限 8）；选项 pixBits>0 时用
/// 选项值（LUT 表随之按新域重烘焙）。
IpPlan planGroupIp(IspGraph graph, IspNodeGroup group, IpGenOptions options) {
  final cPlan = planGroupC(graph, group);
  final stream = planGroupStream(cPlan);
  final topName = groupIpTopName(graph, group);

  var derivedMax = 0;
  for (final id in cPlan.topo) {
    final n = cPlan.members[id]!;
    final m = lutDomainMaxOf(graph, n);
    if (m > derivedMax) derivedMax = m;
  }

  final int pixBits;
  if (options.pixBits > 0) {
    pixBits = options.pixBits;
  } else {
    var bits = 8;
    while ((1 << bits) - 1 < derivedMax && bits < 16) {
      bits++;
    }
    pixBits = bits;
  }
  final maxValue = (1 << pixBits) - 1;
  final lutDepth = maxValue + 1;

  // ---- 资源估算（v1：multi_band_eq lut_fixed——三张烘焙表 + 每像素
  // S/L 两个 Q14 乘法；func_fixed——无 ROM，每段一个 DSP 运算单元：
  // 权重链 8 乘（x·k / x² / x²·C2 / 五次多项式）+ 段贡献 3 乘（串联另
  // 含乘性合成 2 乘），共享 h 折叠（无乘）+ shift 倒数乘 + S/L 施加
  // 2 乘；乘法器性能档推断 DSP48，平衡/面积档绑 LUT）----
  var romBits = 0;
  var eqNodes = 0;
  var fixedNodes = 0;
  var fixedDsp = 0;
  var implMode = 0;
  var fxBandCount = 0;
  var fxSerial = false;
  bool hslPipeEnabled(IspNode node) =>
      (node.typeId == 'csc_rgb2hsl' ||
          node.typeId == 'csc_hsl2rgb' ||
          node.typeId == 'csc_hsl2yuv' ||
          node.typeId == 'csc_yuv2hsl') &&
      node.paramValues['codegenMode'] != 'lut_fixed' &&
      node.paramValues['bypass'] != true &&
      options.gstrategy != 0 &&
      options.dspPipe == 3;
  bool pipelinedHslNode(IspNode node) =>
      node.typeId == 'csc_rgb2hsl' && hslPipeEnabled(node);
  bool pipelinedHsl2RgbNode(IspNode node) =>
      node.typeId == 'csc_hsl2rgb' && hslPipeEnabled(node);
  bool pipelinedHsl2YuvNode(IspNode node) =>
      node.typeId == 'csc_hsl2yuv' && hslPipeEnabled(node);
  bool pipelinedYuv2HslNode(IspNode node) =>
      node.typeId == 'csc_yuv2hsl' && hslPipeEnabled(node);
  for (final id in cPlan.topo) {
    final n = cPlan.members[id]!;
    if (n.typeId == 'multi_band_eq') {
      eqNodes++;
      final parsed = multiBandEqBands(n);
      fxBandCount = parsed.bands.length;
      fxSerial = parsed.serial && fxBandCount >= 2;
      implMode =
          '${n.paramValues['codegenMode'] ?? 'func_fixed'}' == 'func_fixed'
          ? 1
          : 0;
      if (implMode == 0) {
        romBits += lutDepth * 50; // h int16 + s/l u17（16+17+17 位）
      }
    } else {
      fixedNodes++;
      // HSL 全流水通路 11 个乘法器（各落 1 个 DSP48E2），其余 12。
      // 色温调节器带运行期控制/测量时多一组乘法（增益比 + 三次多项式 +
      // 逐位长除法不含 DSP），按 6 个 DSP48 估。
      final fixed = n.typeId == 'color_temp_adjuster'
          ? 6
          : (pipelinedHslNode(n)
                ? 11
                : (pipelinedHsl2RgbNode(n)
                      ? 7
                      : (pipelinedHsl2YuvNode(n)
                            ? 16
                            : (pipelinedYuv2HslNode(n) ? 15 : 12))));
      fixedDsp += fixed;
      if (n.paramValues['codegenMode'] == 'lut_fixed') {
        if (n.typeId == 'color_temp_adjuster') {
          romBits += lutDepth * 48;
        } else {
          final products = switch (n.typeId) {
            'csc_rgb2yuv' || 'csc_hsl2yuv' => 9,
            'csc_yuv2rgb' || 'csc_yuv2hsl' => 4,
            _ => 0,
          };
          final norms = switch (n.typeId) {
            'csc_rgb2hsl' || 'csc_yuv2hsl' || 'csc_hsl2rgb' => 3,
            _ => 0,
          };
          romBits += lutDepth * 32 * (products + norms);
        }
      }
    }
  }
  final perf = options.gstrategy == 2;
  final dsp = options.dspPipe.clamp(0, 3);
  final fxDspPerBand = fxSerial ? 13 : 11;
  // HSL↔RGB 走全流水 DSP 通路时占各自的拍数（组合函数版 3 拍）。
  final hslNodes = cPlan.members.values
      .where(
        (node) =>
            node.typeId == 'csc_rgb2hsl' ||
            node.typeId == 'csc_yuv2hsl' ||
            node.typeId == 'csc_hsl2rgb' ||
            node.typeId == 'csc_hsl2yuv' ||
            node.typeId == 'csc_yuv2hsl',
      )
      .toList();
  final cscPipelineExtra =
      hslNodes.where(pipelinedHslNode).length * (kHslPipeLatency - 1) +
      hslNodes.where(pipelinedHsl2RgbNode).length *
          (kHsl2RgbPipeLatency - 1) +
      hslNodes.where(pipelinedHsl2YuvNode).length *
          (kHsl2YuvPipeLatency - 1) +
      hslNodes.where(pipelinedYuv2HslNode).length *
          (kYuv2HslPipeLatency - 1) +
      hslNodes
              .where(
                (n) =>
                    !pipelinedHslNode(n) &&
                    !pipelinedHsl2RgbNode(n) &&
                    !pipelinedHsl2YuvNode(n) &&
                    !pipelinedYuv2HslNode(n) &&
                    n.typeId != 'csc_hsl2rgb' &&
                    n.typeId != 'csc_hsl2yuv',
              )
              .length *
          2 +
      (options.gstrategy == 0 || options.dspPipe != 3
          ? 0
          : cPlan.members.values
                    .where(
                      (node) =>
                          (node.typeId == 'csc_yuv2rgb' ||
                              node.typeId == 'csc_rgb2yuv') &&
                          node.paramValues['codegenMode'] != 'lut_fixed' &&
                          node.paramValues['bypass'] != true,
                    )
                    .length *
                3);
  final hslPipeNodes = cPlan.members.values.where(pipelinedHslNode).length;
  final est = IpResourceEstimate(
    romBits: romBits,
    bram36k: (romBits / 36864).ceil(),
    estDsps: eqNodes == 0
        ? (perf ? fixedDsp : 0)
        : (perf
              ? (implMode == 1 ? fxDspPerBand * fxBandCount + 3 : eqNodes * 2)
              : 0),
    estLuts: eqNodes == 0
        ? hslPipeNodes * 1600 + (fixedNodes - hslPipeNodes) * 800
        : (implMode == 1
              ? (perf ? 900 + fxBandCount * 900 : 900 + fxBandCount * 3200)
              : 600 + (perf ? 0 : eqNodes * 700)),
    latencyCycles: implMode == 1
        ? mbFxLatency(fxSerial, dsp, gstrategy: options.gstrategy) +
              cscPipelineExtra
        : stream.maxDelay + 1 + cscPipelineExtra,
    throughputPxPerClk: 1.0,
  );

  return IpPlan(
    cPlan: cPlan,
    stream: stream,
    topName: topName,
    pixBits: pixBits,
    maxValue: maxValue,
    lutDepth: lutDepth,
    totalDelay: stream.maxDelay,
    options: options,
    resources: est,
    implMode: implMode,
    fxBandCount: fxBandCount,
    fxSerial: fxSerial,
  );
}
