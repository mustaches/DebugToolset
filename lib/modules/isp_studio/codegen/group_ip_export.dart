/// ISP 编组「生成Verilog IP」的发射层与写盘：把 IpPlan 组装为 Verilog IP
/// 包文件集（核心/顶层/厂商封装/testbench/golden/tcl/README/UserGuide）。对应
/// group_c_export_bb.dart 的角色；plan → emit 两段式。
library;

import 'dart:io';
import 'dart:typed_data';

import '../models/isp_graph.dart';
import '../models/isp_node.dart';
import '../pipeline/color_temp.dart';
import '../pipeline/color_temp_hw.dart';
import '../pipeline/csc_fixed.dart';
import '../pipeline/isp_kernels.dart';
import 'fixed_ip_verilog.dart';
import 'generated_text_io.dart';
import 'ip_gen_plan.dart';
import 'ip_stimulus.dart';
import 'ip_target.dart';
import 'node_v_full_stream.dart';
import 'node_v_stream.dart';
import 'verilog_format.dart';

/// FNV-1a 32 位（与 C 验证程序 `fnv1a_update` 同参数：offset basis
/// 2166136261、prime 16777619、32 位无符号回绕；对 uint16 数组按小端
/// 逐字节更新）。
int fnv1a32(List<int> bytes) {
  var h = 0x811c9dc5;
  for (final b in bytes) {
    h = (h ^ b) & 0xFFFFFFFF;
    h = (h * 0x01000193) & 0xFFFFFFFF; // 16777619
  }
  return h;
}

/// golden 测试帧默认尺寸（小图，仿真快）；现由 [IpSimStimulus] 参数化，
/// 此处保留为默认值（`IpSimStimulus()` 默认构造同值：64×8×1 帧）。
const int kIpSimW = 64;
const int kIpSimH = 8;
const int kIpSimFrames = 1;
const int kIpMaxBands = 16;

String defaultGroupDemoProjectName(
  IspGraph graph,
  IspNodeGroup group, {
  String? flowName,
}) {
  final trimmed = flowName?.trim() ?? '';
  if (trimmed.isNotEmpty && RegExp(r'^[\x20-\x7E]+$').hasMatch(trimmed)) {
    var name = trimmed.replaceAll(RegExp(r'[^A-Za-z0-9_]+'), '_');
    if (RegExp(r'^[0-9]').hasMatch(name)) name = '_$name';
    if (RegExp(r'^[A-Za-z_][A-Za-z0-9_]*$').hasMatch(name)) return name;
  }
  final types = group.nodeIds.map((id) => graph.nodes[id]?.typeId).toSet();
  if (types.contains('csc_yuv2hsl') || types.contains('csc_hsl2yuv')) {
    return 'YUV_Multi_Band_Color_EQ';
  }
  if (types.length == 1 && types.contains('multi_band_eq')) {
    return 'HSL_Multi_Band_Color_EQ';
  }
  return 'demo_prj';
}

String _v2ParamDecl(IpPlan plan) {
  if (plan.fxBandCount == 0) return '';
  return ',\n    parameter integer IMPL_MODE = ${plan.implMode},\n'
      '    parameter integer WORK_MODE = ${plan.fxSerial ? 1 : 0},\n'
      '    parameter integer NUM_BANDS = ${plan.fxBandCount}';
}

String _v2ParamConn(IpPlan plan) {
  if (plan.fxBandCount == 0) return '';
  return ',\n      .IMPL_MODE(IMPL_MODE),\n'
      '      .WORK_MODE(WORK_MODE),\n      .NUM_BANDS(NUM_BANDS)';
}

bool _hasYuv2Rgb(IpPlan plan) =>
    plan.cPlan.members.values.any((node) => node.typeId == 'csc_yuv2rgb');

bool _hasRgb2Yuv(IpPlan plan) =>
    plan.cPlan.members.values.any((node) => node.typeId == 'csc_rgb2yuv');

bool _hasRgb2Hsl(IpPlan plan) =>
    plan.cPlan.members.values.any((node) => node.typeId == 'csc_rgb2hsl');

bool _hasHsl2Rgb(IpPlan plan) =>
    plan.cPlan.members.values.any((node) => node.typeId == 'csc_hsl2rgb');

bool _hasHsl2Yuv(IpPlan plan) =>
    plan.cPlan.members.values.any((node) => node.typeId == 'csc_hsl2yuv');

bool _hasYuv2Hsl(IpPlan plan) =>
    plan.cPlan.members.values.any((node) => node.typeId == 'csc_yuv2hsl');

/// 涉及 YUV 矩阵（会用到 `YUV_STANDARD`）的 ColorTrans 类型。
const Set<String> _yuvMatrixTypes = {
  'csc_yuv2rgb',
  'csc_rgb2yuv',
  'csc_yuv2hsl',
  'csc_hsl2yuv',
};

bool _hasYuvMatrix(IpPlan plan) => plan.cPlan.members.values.any(
  (node) =>
      node.typeId == 'csc_yuv2rgb' ||
      node.typeId == 'csc_rgb2yuv' ||
      node.typeId == 'csc_yuv2hsl' ||
      node.typeId == 'csc_hsl2yuv',
);

/// 编组内是否存在 YUV↔RGB 转换节点——只有这类编组才需要「YUV 矩阵标准」
/// 配置项（RGB→HSL、纯色温等编组不显示该项，避免无中生有的配置）。
bool groupHasYuvMatrix(IspGraph graph, IspNodeGroup group) => group.nodeIds.any(
  (id) =>
      graph.nodes[id]?.typeId == 'csc_yuv2rgb' ||
      graph.nodes[id]?.typeId == 'csc_rgb2yuv' ||
      graph.nodes[id]?.typeId == 'csc_yuv2hsl' ||
      graph.nodes[id]?.typeId == 'csc_hsl2yuv',
);

String _effectiveYuvStandard(IpPlan plan) {
  for (final node in plan.cPlan.members.values) {
    if (_yuvMatrixTypes.contains(node.typeId)) {
      return effectiveYuvStandard(
        plan.options.yuvStandard,
        '${node.paramValues['standard'] ?? 'bt2020'}',
      );
    }
  }
  return 'bt2020';
}

String _yuvParamDecl(IpPlan plan) => _hasYuvMatrix(plan)
    ? ',\n    parameter integer YUV_STANDARD = '
          '${yuvStandardCode(_effectiveYuvStandard(plan))}'
    : '';

String _yuvParamConn(IpPlan plan) =>
    _hasYuvMatrix(plan) ? ',\n      .YUV_STANDARD(YUV_STANDARD)' : '';

String _chEnableConn(IpPlan plan) {
  if (plan.fxBandCount == 0) return '';
  return ',\n      .CH_Enable(CH_Enable)';
}

String _chEnableDecl(IpPlan plan) {
  if (plan.fxBandCount == 0) return '';
  return ',\n    input  wire [NUM_BANDS-1:0] CH_Enable';
}

String _v2TbOverrides(IpPlan plan, int? numBands, int bypassMask) {
  if (plan.fxBandCount == 0) return '';
  final count = numBands ?? plan.fxBandCount;
  return ', .IMPL_MODE(${plan.implMode}), '
      '.WORK_MODE(${plan.fxSerial ? 1 : 0}), .NUM_BANDS($count)';
}

String _v2PackageParams(IpPlan plan) {
  if (plan.fxBandCount == 0) return '';
  return '''
ipx::add_user_parameter IMPL_MODE [ipx::current_core]
set_property value_resolve_type user [ipx::get_user_parameters IMPL_MODE]
set_property value ${plan.implMode} [ipx::get_user_parameters IMPL_MODE]
ipx::add_user_parameter WORK_MODE [ipx::current_core]
set_property value_resolve_type user [ipx::get_user_parameters WORK_MODE]
set_property value ${plan.fxSerial ? 1 : 0} [ipx::get_user_parameters WORK_MODE]
ipx::add_user_parameter NUM_BANDS [ipx::current_core]
set_property value_resolve_type user [ipx::get_user_parameters NUM_BANDS]
set_property value ${plan.fxBandCount} [ipx::get_user_parameters NUM_BANDS]
''';
}

/// 内存生成 Verilog IP 包文件集：文件名 → 内容（键顺序即写盘顺序）。
/// [stimulus] 为一键仿真激励参数（帧尺寸/帧数/图案/种子/握手压力率），
/// 仅影响 tb/golden 生成物；null 取默认（与历史固定行为一致）。
typedef IpBuildProgress = void Function(String stage, double progress);

Map<String, String> buildGroupIpFiles(
  IspGraph graph,
  IspNodeGroup group,
  IpGenOptions options, {
  IpSimStimulus? stimulus,
  int? numBands,
  int bypassMask = 0,
  IpBuildProgress? onProgress,
  bool ctRuntimeEnabled = true,
}) {
  onProgress?.call('规划 IP 流水线', 0.02);
  if (group.nodeIds.length > 1) {
    return _buildMultiNodeIpFiles(
      graph,
      group,
      options,
      stimulus: stimulus,
      numBands: numBands,
      bypassMask: bypassMask,
      onProgress: onProgress,
    );
  }
  final stim = stimulus ?? const IpSimStimulus();
  final plan = planGroupIp(graph, group, options);
  onProgress?.call('生成 Verilog 核心与数据通路', 0.08);
  final top = plan.topName;
  final pb = plan.pixBits;
  final mv = plan.maxValue;

  // LUT 与函数两种实现同时生成，IMPL_MODE 在综合时选择。
  final roms = StringBuffer();
  final datapath = StringBuffer();
  var fxBands = <MbFxBand>[];
  for (final id in plan.cPlan.topo) {
    final n = plan.cPlan.members[id]!;
    if (n.typeId == 'multi_band_eq') {
      final ident = plan.cPlan.idents[id]!;
      final parsed = multiBandEqBands(n);
      fxBands = [
        for (final b in parsed.bands)
          multiBandFxBandConst(h: b.h, q: b.q, dh: b.dh, s: b.s, l: b.l),
      ];
      final (shiftLut, sMulLut, lMulLut) = multiBandLuts(
        parsed.bands,
        serial: parsed.serial,
        maxValue: mv,
      );
      final sQ14 = [for (final v in sMulLut) (v * 16384.0).round()];
      final lQ14 = [for (final v in lMulLut) (v * 16384.0).round()];
      final packedLut = [
        for (var i = 0; i < shiftLut.length; i++)
          (shiftLut[i] & 0xFFFF) | (sQ14[i] << 16) | (lQ14[i] << 33),
      ];
      roms.writeln(
        vRomU50(
          '${ident}_shift_lut',
          packedLut,
          comment: 'Packed H/S/L table: {L Q14, S Q14, H shift} = 50 bits',
        ),
      );
      datapath.write(emitMultiBandEqDatapath(ident, pb));
    }
  }
  final (parallelBody, parallelLat) = emitMultiBandEqFxPipeline(
    top,
    pb,
    fxBands.length,
    false,
  );
  final (serialBody, serialLat) = emitMultiBandEqFxPipeline(
    top,
    pb,
    fxBands.length,
    true,
  );
  final baseLatency = parallelLat > serialLat ? parallelLat : serialLat;
  final fxLatency = plan.implMode == 1
      ? (options.dspPipe == 3 ? mbFxFullLatency(true) : baseLatency)
      : 1;
  final coreFile = plan.fxBandCount == 0
      ? buildFixedIpCore(plan, ctRuntimeEnabled: ctRuntimeEnabled)
      : _coreUnifiedV(
          plan,
          roms.toString(),
          datapath.toString(),
          parallelBody,
          serialBody,
        );
  final fxDecl = plan.fxBandCount == 0 ? null : fxBandPortsDecl(kIpMaxBands);
  final fxConn = plan.fxBandCount == 0 ? null : fxBandPortsConn(kIpMaxBands);
  final FxTbBands? fxTb = plan.fxBandCount == 0
      ? null
      : (
          fx: fxBands,
          bands: multiBandEqBands(
            plan.cPlan.members[plan.cPlan.topo.firstWhere(
              (id) => plan.cPlan.members[id]!.typeId == 'multi_band_eq',
            )]!,
          ).bands,
        );

  onProgress?.call('生成 golden 激励与校验数据', 0.35);
  // ---- golden：输入激励帧 + 期望 FNV-1a（图案/尺寸/帧数由 stim 决定）----
  final (goldenIn, goldenHash, ctExpected) = _buildGolden(
    plan,
    graph,
    group,
    stim,
    numBands: numBands,
    bypassMask: bypassMask,
    ctRuntimeEnabled: ctRuntimeEnabled,
  );
  onProgress?.call('整理 IP 文件', 0.50);

  final files = <String, String>{
    '${top}_core.v': coreFile,
    '${top}_top.v': _topV(
      plan,
      fxDecl: fxDecl,
      fxConn: fxConn,
      fxDspPipe: options.dspPipe,
      ctPorts: _ctRuntimePlan(plan, enabled: ctRuntimeEnabled),
    ),
    'tb_$top.v': _tbV(
      plan,
      goldenHash,
      stim,
      drainCycles: fxLatency + 4,
      fxBands: fxTb,
      numBands: numBands,
      bypassMask: bypassMask,
      ctExpected: ctExpected,
    ),
    'golden_in.hex': goldenIn,
    'golden_hash.txt': '0x${goldenHash.toRadixString(16).padLeft(8, '0')}\n',
    'README.md': _readme(plan, stim),
    if (plan.fxBandCount != 0)
      '${top}_V2.0_UserGuide.md': File(
        'docs/ISP_IP_MBC_EQ_V2.0_UserGuide.md',
      ).readAsStringSync().replaceAll('ISP_IP_MBC_EQ', top)
    else if (_hasYuv2Rgb(plan))
      '${top}_V2.0_UserGuide.md': File(
        'docs/ISP_IP_YUV_to_RGB_V2.0_UserGuide.md',
      ).readAsStringSync().replaceAll('ISP_IP_YUV_to_RGB', top)
    else if (_hasRgb2Hsl(plan))
      '${top}_V2.0_UserGuide.md': File(
        'docs/ISP_IP_RGB_to_HSL_V2.0_UserGuide.md',
      ).readAsStringSync().replaceAll('ISP_IP_RGB_to_HSL', top)
    else if (_hasHsl2Rgb(plan))
      '${top}_V2.0_UserGuide.md': File(
        'docs/ISP_IP_HSL_to_RGB_V2.0_UserGuide.md',
      ).readAsStringSync().replaceAll('ISP_IP_HSL_to_RGB', top)
    else if (_hasHsl2Yuv(plan))
      '${top}_V2.0_UserGuide.md': File(
        'docs/ISP_IP_HSL_to_YUV_V2.0_UserGuide.md',
      ).readAsStringSync().replaceAll('ISP_IP_HSL_to_YUV', top)
    else if (_hasYuv2Hsl(plan))
      '${top}_V2.0_UserGuide.md': File(
        'docs/ISP_IP_YUV_to_HSL_V2.0_UserGuide.md',
      ).readAsStringSync().replaceAll('ISP_IP_YUV_to_HSL', top)
    else if (_hasRgb2Yuv(plan))
      '${top}_V2.0_UserGuide.md': File(
        'docs/ISP_IP_RGB_to_YUV_V2.0_UserGuide.md',
      ).readAsStringSync().replaceAll('ISP_IP_RGB_to_YUV', top),
  };
  if (options.vendor.isVivado) {
    files['${top}_axis.v'] = _axisV(
      plan,
      fxDecl: fxDecl,
      fxConn: fxConn,
      fxDspPipe: options.dspPipe,
      ctPorts: _ctRuntimePlan(plan, enabled: ctRuntimeEnabled),
    );
    files['package_ip.tcl'] = _packageIpTcl(plan);
    // 定制界面（xgui）：打包时由 package_ip.tcl 拷入组件目录。
    files['xgui/${top}_v2_0.tcl'] = _xguiTcl(plan);
    // 演示工程（demo/）：演示顶层（段参数烘焙为 ispflow 快照常量）+ golden
    // tb（打包容器 IP 实例）+ 一键建工程脚本（位置无关，可重复执行）。
    files['demo/demo_top.v'] = _demoTopV(
      plan,
      fxTb,
      ctPorts: _ctRuntimePlan(plan, enabled: ctRuntimeEnabled),
    );
    files['demo/tb_demo.v'] = _tbV(
      plan,
      goldenHash,
      stim,
      drainCycles: fxLatency + 4,
      fxBands: fxTb,
      dutName: top,
      numBands: numBands,
      bypassMask: bypassMask,
      ctExpected: ctExpected,
    );
    files['demo/timing.xdc'] = _timingXdc(plan);
    files['demo/clock_route.tcl'] = _clockRouteTcl();
    files['demo/create_demo_project.tcl'] = _demoProjectTcl(plan);
  } else if (options.vendor.isLibero) {
    files['${top}_libero.v'] = _liberoV(
      plan,
      fxDecl: fxDecl,
      fxConn: fxConn,
      fxDspPipe: options.dspPipe,
      ctPorts: _ctRuntimePlan(plan, enabled: ctRuntimeEnabled),
    );
  }
  final entries = files.entries.toList();
  for (var i = 0; i < entries.length; i++) {
    final entry = entries[i];
    if (entry.key.endsWith('.v')) {
      files[entry.key] = formatVerilogSource(entry.value);
    }
    onProgress?.call(
      '格式化 ${entry.key}',
      0.55 + 0.43 * (i + 1) / entries.length,
    );
  }
  onProgress?.call('IP 包生成完成', 1.0);
  return files;
}

/// 写盘 IP 包到 [dir]（创建目录），返回已写文件路径列表。
/// 键可带子目录（如 xgui/xxx.tcl），父目录自动创建。
Future<List<String>> exportGroupIpPackage(
  Map<String, String> files,
  String dir, {
  String? vivadoExecutable,
}) async {
  await Directory(dir).create(recursive: true);
  final out = <String>[];
  for (final e in files.entries) {
    final p = '$dir${Platform.pathSeparator}${e.key}';
    // 键含子目录（xgui/）：先建父目录。
    await File(p).parent.create(recursive: true);
    await writeGeneratedText(
      File(p),
      e.value,
      vivadoExecutable: vivadoExecutable,
    );
    out.add(p);
  }
  return out;
}

// ---------------------------------------------------------------------------
// 内部：各文件模板
// ---------------------------------------------------------------------------

/// tb 恒定驱动的目标色温：与 ispflow 里烘焙的 temperature 刻意不同，
/// 用来说明 CCM 真的由 14 位 `cct_in` 端口驱动（若端口被忽略，golden 哈希
/// 必然对不上）。
const int kCtTbTargetKelvin = 7000;

/// 该编组是否为「带运行期色温端口」的 IP：色温节点是编组首节点（本工程的
/// IP 生成规则是每节点独立 IP，首节点即唯一节点）且未 bypass、不含均衡器。
bool _ctRuntimePlan(IpPlan plan, {bool enabled = true}) {
  if (!enabled) return false;
  if (plan.cPlan.topo.isEmpty || plan.fxBandCount != 0) return false;
  final first = plan.cPlan.members[plan.cPlan.topo.first]!;
  return first.typeId == 'color_temp_adjuster' &&
      first.paramValues['bypass'] != true;
}

String _headerComment(IpPlan plan) {
  final v = plan.options.vendor;
  return '''
// Generated by DebugToolSet ISP Studio (group -> FPGA Verilog IP package).
// Target vendor: ${v.name}
// Pixel bits PIX_BITS=${plan.pixBits} (MAXV=${plan.maxValue}), LUT domain 0..${plan.maxValue}
''';
}

({String source, String data}) _fixedChain(
  IpPlan plan,
  Iterable<String> nodeIds,
  String input, {
  bool includeCommon = true,
}) {
  final ids = nodeIds.toList();
  if (ids.isEmpty) return (source: '', data: input);
  final source = StringBuffer(
    includeCommon
        ? fixedIpCommonFunctions(
            plan.pixBits,
            reciprocal: ids.any((id) {
              final type = plan.cPlan.members[id]!.typeId;
              return type == 'csc_rgb2hsl' || type == 'csc_yuv2hsl';
            }),
          )
        : '',
  );
  var data = input;
  for (final id in ids) {
    final node = plan.cPlan.members[id]!;
    final ident = plan.cPlan.idents[id]!;
    source.write(emitFixedIpNode(node, ident, plan.pixBits));
    source.writeln(
      '  wire [${3 * plan.pixBits - 1}:0] ${ident}_out = '
      '${ident}_convert($data);',
    );
    data = '${ident}_out';
  }
  return (source: source.toString(), data: data);
}

String _coreV(IpPlan plan, String roms, String datapath) {
  final top = plan.topName;
  final pb = plan.pixBits;
  final bw = 3 * pb;
  final eqIndex = plan.cPlan.topo.indexWhere(
    (id) => plan.cPlan.members[id]!.typeId == 'multi_band_eq',
  );
  final eqId = plan.cPlan.topo[eqIndex];
  final ident = plan.cPlan.idents[eqId]!;
  final pre = _fixedChain(plan, plan.cPlan.topo.take(eqIndex), 'in_data');
  final post = _fixedChain(
    plan,
    plan.cPlan.topo.skip(eqIndex + 1),
    '${ident}_packed_out',
    includeCommon: eqIndex == 0,
  );
  final resConcat = post.data;
  return '''
module ${top}_lut_core #(
    parameter integer PIX_BITS  = $pb,
    parameter integer MAX_WIDTH = ${plan.options.maxWidth},
    // Optimization strategy reserved (0 area / 1 balance / 2 performance):
    // the current whitelist is point operators (always II=1); window
    // operators will take effect per tier via generate-if once supported.
    parameter integer GSTRATEGY = ${plan.options.gstrategy},
    parameter integer FOLD      = ${plan.options.fold}
) (
    input  wire                   clk,
    input  wire                   rst_n,
    // pixel stream input ({H, S, L} packed, H in the MSBs)
    input  wire                   in_valid,
    output wire                   in_ready,
    input  wire                   in_sof,
    input  wire                   in_eol,
    input  wire [$bw-1:0]         in_data,
    // pixel stream output (same packing)
    output reg                    out_valid,
    input  wire                   out_ready,
    output reg                    out_sof,
    output reg                    out_eol,
    output reg  [$bw-1:0]         out_data
);
  localparam [$pb-1:0] MAXV = (1 << PIX_BITS) - 1;

${pre.source}  wire [$pb-1:0] in_h = ${pre.data}[$bw-1 -: $pb];
  wire [$pb-1:0] in_s = ${pre.data}[${2 * pb}-1 -: $pb];
  wire [$pb-1:0] in_l = ${pre.data}[$pb-1:0];
$roms
$datapath
  wire [$bw-1:0] ${ident}_packed_out =
      {${ident}_res_h, ${ident}_res_s, ${ident}_res_l};
${post.source}
  // ---- single pipeline stage (II=1, 1-cycle latency; advance = latch a
  // new pixel this cycle) ----
  wire advance = in_ready & in_valid;
  assign in_ready = ~out_valid | out_ready;

  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      out_valid <= 1'b0;
      out_sof   <= 1'b0;
      out_eol   <= 1'b0;
      out_data  <= {$bw{1'b0}};
    end else if (advance) begin
      out_valid <= in_valid;
      out_sof   <= in_sof;
      out_eol   <= in_eol;
      out_data  <= {$resConcat};
    end else if (out_ready) begin
      // No new pixel and the output was accepted: clear valid (otherwise
      // valid stays high and the output is counted twice).
      out_valid <= 1'b0;
    end
  end
endmodule
''';
}

/// func_fixed 核心：段运算单元模块定义（模块外）+ 流水核心模块。
/// 并联/串联两套结构由 WORK_MODE 在综合时选择，[bandCount] 个段的运行
/// 期参数端口追加在端口列表末尾。
String _coreFxV(
  IpPlan plan,
  String parallelBody,
  String serialBody,
  int bandCount,
) {
  final top = plan.topName;
  final pb = plan.pixBits;
  final bw = 3 * pb;
  final eqIndex = plan.cPlan.topo.indexWhere(
    (id) => plan.cPlan.members[id]!.typeId == 'multi_band_eq',
  );
  final pre = _fixedChain(plan, plan.cPlan.topo.take(eqIndex), 'in_data');
  final post = _fixedChain(
    plan,
    plan.cPlan.topo.skip(eqIndex + 1),
    'fx_raw_data',
    includeCommon: eqIndex == 0,
  );
  final parallel = parallelBody
      .replaceAll('in_data', pre.data)
      .replaceAll('out_data', 'fx_raw_data');
  final serial = serialBody
      .replaceAll('in_data', pre.data)
      .replaceAll('out_data', 'fx_raw_data');
  return '''
${mbFxUnitDefs(top, par: true, ser: true)}
${mbFxFullUnitDefs(top, par: true, ser: true, xilinx: plan.options.vendor.isVivado && plan.options.vivadoFamily == 'zynquplus')}
module ${top}_fx_core #(
    parameter integer PIX_BITS  = $pb,
    parameter integer MAX_WIDTH = ${plan.options.maxWidth},
    // Multiplier implementation: 0 = bind LUT (use_dsp=no) /
    // 1 = synthesizer's choice / 2 = bind DSP (use_dsp=yes).
    parameter integer GSTRATEGY = ${plan.options.gstrategy},
    parameter integer FOLD      = ${plan.options.fold},
    // Pipeline: 0 = combinational / 1 = pre / 2 = pre+mid /
    // 3 = full internal DSP pipeline (highest Fmax; GSTRATEGY != 0).
    parameter integer DSP_PIPE  = ${plan.options.dspPipe}${_v2ParamDecl(plan)}
) (
    input  wire                   clk,
    input  wire                   rst_n,
    // pixel stream input ({H, S, L} packed, H in the MSBs)
    input  wire                   in_valid,
    output wire                   in_ready,
    input  wire                   in_sof,
    input  wire                   in_eol,
    input  wire [$bw-1:0]         in_data,
    // pixel stream output (same packing)
    output reg                    out_valid,
    input  wire                   out_ready,
    output reg                    out_sof,
    output reg                    out_eol,
    output reg  [$bw-1:0]         out_data${fxBandPortsDecl(bandCount)}${_chEnableDecl(plan)}
);
  localparam [$pb-1:0] MAXV = (1 << PIX_BITS) - 1;
  reg [$bw-1:0] fx_raw_data;
${pre.source}${post.source}  always @* out_data = ${post.data};
generate
  if (WORK_MODE == 0) begin : g_parallel
$parallel
  end else begin : g_serial
$serial
  end
endgenerate
endmodule
''';
}

/// 双实现核心：LUT 查表与函数定点运算并存，IMPL_MODE=0 查表、1 函数。
String _coreUnifiedV(
  IpPlan plan,
  String roms,
  String datapath,
  String parallelBody,
  String serialBody,
) {
  final top = plan.topName;
  final pb = plan.pixBits;
  final bw = 3 * pb;
  return '''
${_headerComment(plan)}// Unified behavioral core: IMPL_MODE=0 remaps HSL through baked LUTs;
// IMPL_MODE=1 calls the runtime fixed-point band functions.
// LUT parameters are baked in; function band parameters are runtime ports.
// Vendor wrappers only adapt the interface and contain no logic.
`timescale 1ns/1ps
${_coreV(plan, roms, datapath)}
${_coreFxV(plan, parallelBody, serialBody, kIpMaxBands)}
module ${top}_core #(
    parameter integer PIX_BITS  = $pb,
    parameter integer MAX_WIDTH = ${plan.options.maxWidth},
    parameter integer GSTRATEGY = ${plan.options.gstrategy},
    parameter integer FOLD      = ${plan.options.fold},
    parameter integer DSP_PIPE  = ${plan.options.dspPipe}${_v2ParamDecl(plan)}
) (
    input  wire                   clk,
    input  wire                   rst_n,
    input  wire                   in_valid,
    output wire                   in_ready,
    input  wire                   in_sof,
    input  wire                   in_eol,
    input  wire [$bw-1:0]         in_data,
    output wire                   out_valid,
    input  wire                   out_ready,
    output wire                   out_sof,
    output wire                   out_eol,
    output wire [$bw-1:0]         out_data${fxBandPortsDecl(kIpMaxBands)}${_chEnableDecl(plan)}
);
  wire lut_in_ready, fx_in_ready;
  wire lut_out_valid, fx_out_valid;
  wire lut_out_sof, fx_out_sof;
  wire lut_out_eol, fx_out_eol;
  wire [$bw-1:0] lut_out_data, fx_out_data;

  ${top}_lut_core #(
      .PIX_BITS(PIX_BITS), .MAX_WIDTH(MAX_WIDTH),
      .GSTRATEGY(GSTRATEGY), .FOLD(FOLD)
  ) u_lut (
      .clk(clk), .rst_n(rst_n),
      .in_valid(in_valid & in_ready & (IMPL_MODE == 0)),
      .in_ready(lut_in_ready),
      .in_sof(in_sof), .in_eol(in_eol), .in_data(in_data),
      .out_valid(lut_out_valid), .out_ready(out_ready),
      .out_sof(lut_out_sof), .out_eol(lut_out_eol), .out_data(lut_out_data)
  );

  ${top}_fx_core #(
      .PIX_BITS(PIX_BITS), .MAX_WIDTH(MAX_WIDTH),
      .GSTRATEGY(GSTRATEGY), .FOLD(FOLD), .DSP_PIPE(DSP_PIPE)${_v2ParamConn(plan)}
  ) u_fx (
      .clk(clk), .rst_n(rst_n),
      .in_valid(in_valid & in_ready & (IMPL_MODE == 1)),
      .in_ready(fx_in_ready),
      .in_sof(in_sof), .in_eol(in_eol), .in_data(in_data),
      .out_valid(fx_out_valid), .out_ready(out_ready),
      .out_sof(fx_out_sof), .out_eol(fx_out_eol), .out_data(fx_out_data)${_chEnableConn(plan)},\n      ${fxBandPortsConn(kIpMaxBands)}
  );

  assign in_ready = (IMPL_MODE == 0) ? lut_in_ready : fx_in_ready;
  assign out_valid = (IMPL_MODE == 0) ? lut_out_valid : fx_out_valid;
  assign out_sof = (IMPL_MODE == 0) ? lut_out_sof : fx_out_sof;
  assign out_eol = (IMPL_MODE == 0) ? lut_out_eol : fx_out_eol;
  assign out_data = (IMPL_MODE == 0) ? lut_out_data : fx_out_data;
endmodule
''';
}

String _topV(IpPlan plan,
    {String? fxDecl, String? fxConn, int? fxDspPipe, bool ctPorts = false}) {
  final top = plan.topName;
  final pb = plan.pixBits;
  final bw = 3 * pb;
  return '''
${_headerComment(plan)}// Top-level assembly: with VIN_TYPE=none (pass-through) the core pixel
// stream ports are forwarded directly.
`timescale 1ns/1ps
module ${top}_top #(
    parameter integer PIX_BITS  = $pb,
    parameter integer MAX_WIDTH = ${plan.options.maxWidth},
    parameter integer GSTRATEGY = ${plan.options.gstrategy},
    parameter integer FOLD      = ${plan.options.fold}${fxDspPipe != null ? ', DSP_PIPE = $fxDspPipe' : ''}${_v2ParamDecl(plan)}${_yuvParamDecl(plan)}${ctPorts ? ', USE_BRAM = ${plan.options.useBram ? 1 : 0}' : ''}
) (
    input  wire                   clk,
    input  wire                   rst_n,
    input  wire                   in_valid,
    output wire                   in_ready,
    input  wire                   in_sof,
    input  wire                   in_eol,
    input  wire [$bw-1:0]         in_data,
    output wire                   out_valid,
    input  wire                   out_ready,
    output wire                   out_sof,
    output wire                   out_eol,
    output wire [$bw-1:0]         out_data${fxDecl ?? ''}${_chEnableDecl(plan)}${ctPorts ? ''',
    input  wire [13:0]            cct_in,
    output wire [13:0]            cct_out''' : ''}
);
  ${top}_core #(
      .PIX_BITS(PIX_BITS),
      .MAX_WIDTH(MAX_WIDTH),
      .GSTRATEGY(GSTRATEGY),
      .FOLD(FOLD)${fxDspPipe != null ? ', .DSP_PIPE(DSP_PIPE)' : ''}${_v2ParamConn(plan)}${_yuvParamConn(plan)}${ctPorts ? ', .USE_BRAM(USE_BRAM)' : ''}
  ) u_core (
      .clk(clk), .rst_n(rst_n),
      .in_valid(in_valid), .in_ready(in_ready),
      .in_sof(in_sof), .in_eol(in_eol), .in_data(in_data),
      .out_valid(out_valid), .out_ready(out_ready),
      .out_sof(out_sof), .out_eol(out_eol), .out_data(out_data)${_chEnableConn(plan)}${fxConn != null ? ',\n      $fxConn' : ''}${ctPorts ? ',\n      .cct_in(cct_in), .cct_out(cct_out)' : ''}
  );
endmodule
''';
}

String _axisV(IpPlan plan,
    {String? fxDecl, String? fxConn, int? fxDspPipe, bool ctPorts = false}) {
  final top = plan.topName;
  final pb = plan.pixBits;
  final bw = 3 * pb;
  return '''
${_headerComment(plan)}// Vivado AXI4-Stream wrapper: pixel stream -> AXI4-Stream (tuser=sof,
// tlast=eol). Interface adaptation only, no logic (func_fixed band
// parameter ports are passed through as-is, for runtime drivers such as
// AXI-Lite registers).
`timescale 1ns/1ps
module ${top}_axis #(
    parameter integer PIX_BITS  = $pb,
    parameter integer MAX_WIDTH = ${plan.options.maxWidth},
    parameter integer GSTRATEGY = ${plan.options.gstrategy},
    parameter integer FOLD      = ${plan.options.fold}${fxDspPipe != null ? ', DSP_PIPE = $fxDspPipe' : ''}${_v2ParamDecl(plan)}${_yuvParamDecl(plan)}${ctPorts ? ', USE_BRAM = ${plan.options.useBram ? 1 : 0}' : ''}
) (
    input  wire                   aclk,
    input  wire                   aresetn,
    input  wire [$bw-1:0]         s_axis_tdata,
    input  wire                   s_axis_tvalid,
    output wire                   s_axis_tready,
    input  wire                   s_axis_tuser,
    input  wire                   s_axis_tlast,
    output wire [$bw-1:0]         m_axis_tdata,
    output wire                   m_axis_tvalid,
    input  wire                   m_axis_tready,
    output wire                   m_axis_tuser,
    output wire                   m_axis_tlast${fxDecl ?? ''}${_chEnableDecl(plan)}${ctPorts ? ''',
    input  wire [13:0]            cct_in,
    output wire [13:0]            cct_out''' : ''}
);
  ${top}_core #(
      .PIX_BITS(PIX_BITS),
      .MAX_WIDTH(MAX_WIDTH),
      .GSTRATEGY(GSTRATEGY),
      .FOLD(FOLD)${fxDspPipe != null ? ', .DSP_PIPE(DSP_PIPE)' : ''}${_v2ParamConn(plan)}${_yuvParamConn(plan)}${ctPorts ? ', .USE_BRAM(USE_BRAM)' : ''}
  ) u_core (
      .clk(aclk), .rst_n(aresetn),
      .in_valid(s_axis_tvalid), .in_ready(s_axis_tready),
      .in_sof(s_axis_tuser), .in_eol(s_axis_tlast), .in_data(s_axis_tdata),
      .out_valid(m_axis_tvalid), .out_ready(m_axis_tready),
      .out_sof(m_axis_tuser), .out_eol(m_axis_tlast), .out_data(m_axis_tdata)${_chEnableConn(plan)}${fxConn != null ? ',\n      $fxConn' : ''}${ctPorts ? ',\n      .cct_in(cct_in), .cct_out(cct_out)' : ''}
  );
endmodule
''';
}

String _liberoV(IpPlan plan,
    {String? fxDecl, String? fxConn, int? fxDspPipe, bool ctPorts = false}) {
  final top = plan.topName;
  final pb = plan.pixBits;
  final bw = 3 * pb;
  return '''
${_headerComment(plan)}// Libero raw-stream wrapper: valid/ready + sof/eol pass-through (edit
// PIX_BITS/MAX_WIDTH in the SmartDesign generics panel; func_fixed band
// parameter ports are passed through as-is).
`timescale 1ns/1ps
module ${top}_libero #(
    parameter integer PIX_BITS  = $pb,
    parameter integer MAX_WIDTH = ${plan.options.maxWidth},
    parameter integer GSTRATEGY = ${plan.options.gstrategy},
    parameter integer FOLD      = ${plan.options.fold}${fxDspPipe != null ? ', DSP_PIPE = $fxDspPipe' : ''}${_v2ParamDecl(plan)}${_yuvParamDecl(plan)}${ctPorts ? ', USE_BRAM = ${plan.options.useBram ? 1 : 0}' : ''}
) (
    input  wire                   clk,
    input  wire                   rst_n,
    input  wire                   in_valid,
    output wire                   in_ready,
    input  wire                   in_sof,
    input  wire                   in_eol,
    input  wire [$bw-1:0]         in_data,
    output wire                   out_valid,
    input  wire                   out_ready,
    output wire                   out_sof,
    output wire                   out_eol,
    output wire [$bw-1:0]         out_data${fxDecl ?? ''}${_chEnableDecl(plan)}${ctPorts ? ''',
    input  wire [13:0]            cct_in,
    output wire [13:0]            cct_out''' : ''}
);
  ${top}_core #(
      .PIX_BITS(PIX_BITS),
      .MAX_WIDTH(MAX_WIDTH),
      .GSTRATEGY(GSTRATEGY),
      .FOLD(FOLD)${fxDspPipe != null ? ', .DSP_PIPE(DSP_PIPE)' : ''}${_v2ParamConn(plan)}${_yuvParamConn(plan)}${ctPorts ? ', .USE_BRAM(USE_BRAM)' : ''}
  ) u_core (
      .clk(clk), .rst_n(rst_n),
      .in_valid(in_valid), .in_ready(in_ready),
      .in_sof(in_sof), .in_eol(in_eol), .in_data(in_data),
      .out_valid(out_valid), .out_ready(out_ready),
      .out_sof(out_sof), .out_eol(out_eol), .out_data(out_data)${_chEnableConn(plan)}${fxConn != null ? ',\n      $fxConn' : ''}${ctPorts ? ',\n      .cct_in(cct_in), .cct_out(cct_out)' : ''}
  );
endmodule
''';
}

/// tb 段参数激励输入（func_fixed）：定点常量（端口初值）+ ispflow 原始
/// double 参数（注释展示）。
typedef FxTbBands = ({
  List<MbFxBand> fx,
  List<({double h, double q, double dh, double s, double l})> bands,
});

String _tbV(
  IpPlan plan,
  int goldenHash,
  IpSimStimulus stim, {
  int drainCycles = 4,
  FxTbBands? fxBands,
  String? dutName,
  int? numBands,
  int bypassMask = 0,
  List<int> ctExpected = const [],
}) {
  final top = plan.topName;
  final pb = plan.pixBits;
  final bw = 3 * pb;
  final ctRuntime = ctExpected.isNotEmpty;
  final hashHex = goldenHash.toRadixString(16).padLeft(8, '0');
  final seedHex = (stim.seed & 0xFFFFFFFF).toRadixString(16).padLeft(8, '0');
  final v2Overrides = _v2TbOverrides(plan, numBands, bypassMask);
  final activeCount = numBands ?? plan.fxBandCount;
  final chEnableValue = ((1 << activeCount) - 1) & ~bypassMask;
  final packagedDut = dutName == top;
  return '''
// One-shot simulation testbench: feed golden_in.hex to the core, collect
// the outputs, and compare FNV-1a against golden_hash.txt (expected value
// inlined as EXPECTED_HASH, EXACT bit-identical mode).
// Stimulus parameters (set in the in-app simulation stimulus dialog;
// regenerate to change):
//   frame ${stim.width}x${stim.height}, ${stim.frames} frames, frame gap ${stim.frameGapCycles} cycles,
//   pattern=${stim.pattern.name},
//   seed=0x$seedHex, input gap rate=${stim.inGapPct}%, output stall rate=${stim.outStallPct}%.
`timescale 1ns/1ps
module tb_$top;
  localparam integer PIX_BITS = $pb;
  localparam integer W  = ${stim.width};
  localparam integer H  = ${stim.height};
  localparam integer FRAMES = ${stim.frames};
  // Frame gap (clock cycles): in_valid idle cycles inserted between frames
  // (0 = continuous).
  localparam integer FRAME_GAP = ${stim.frameGapCycles};
  localparam integer N  = W * H * FRAMES;
  localparam [31:0] EXPECTED_HASH = 32'h$hashHex;
${packagedDut ? '''  // Set GOLDEN_CHECK=0 if the packaged IP configuration differs from the
  // exported golden configuration; then only the output frame count is checked.
  localparam integer GOLDEN_CHECK = 1;
''' : ''}  // Handshake stress (%): input gaps (random in_valid idle cycles) /
  // output backpressure (out_ready randomly pulled low); 0 = always full
  // stream / always accepting. Random sequences derive from SEED, so the
  // simulation is reproducible.
  localparam integer GAP_PCT   = ${stim.inGapPct};
  localparam integer STALL_PCT = ${stim.outStallPct};
  localparam [31:0] SEED = 32'h$seedHex;

  reg clk = 1'b0, rst_n = 1'b0;
  reg in_valid = 1'b0, in_sof = 1'b0, in_eol = 1'b0;
  reg [$bw-1:0] in_data = {$bw{1'b0}};
  reg out_ready = 1'b1;
  wire in_ready, out_valid, out_sof, out_eol;
  wire [$bw-1:0] out_data;
${ctRuntime ? '''  // 色温运行期端口：目标色温恒定驱动（与烘焙参数刻意不同，证明端口真的
  // 驱动了内部 CCM）；实测色温在每帧起始并入哈希（与 IP 的 cct_out 更新
  // 时点一致）。
  reg [13:0] cct_in = 14'd$kCtTbTargetKelvin;
  wire [13:0] cct_out;
''' : ''}${packagedDut ? '''  wire aclk = clk;
  wire aresetn = rst_n;
  wire [$bw-1:0] s_axis_tdata = in_data;
  wire s_axis_tvalid = in_valid;
  wire s_axis_tuser = in_sof;
  wire s_axis_tlast = in_eol;
  wire s_axis_tready;
  wire [$bw-1:0] m_axis_tdata;
  wire m_axis_tvalid;
  wire m_axis_tready = out_ready;
  wire m_axis_tuser;
  wire m_axis_tlast;
  assign in_ready = s_axis_tready;
  assign out_valid = m_axis_tvalid;
  assign out_sof = m_axis_tuser;
  assign out_eol = m_axis_tlast;
  assign out_data = m_axis_tdata;
''' : ''}${fxBands != null ? _tbFxDrivers(fxBands.fx, fxBands.bands) : ''}
${fxBands != null ? '''  localparam integer IMPL_MODE = ${plan.implMode};
  localparam integer NUM_BANDS = $activeCount;
  localparam [15:0] CH_ENABLE_VALUE = 16'h${chEnableValue.toRadixString(16).padLeft(4, '0')};
  reg [NUM_BANDS-1:0] CH_Enable = CH_ENABLE_VALUE[NUM_BANDS-1:0];
''' : ''}
${packagedDut ? '''  $top dut (
      .aclk(aclk), .aresetn(aresetn),
      .s_axis_tdata(s_axis_tdata), .s_axis_tvalid(s_axis_tvalid),
      .s_axis_tuser(s_axis_tuser), .s_axis_tlast(s_axis_tlast),
      .s_axis_tready(s_axis_tready),
      .m_axis_tdata(m_axis_tdata), .m_axis_tvalid(m_axis_tvalid),
      .m_axis_tready(m_axis_tready), .m_axis_tuser(m_axis_tuser),
      .m_axis_tlast(m_axis_tlast)${fxBands != null ? ',\n      .CH_Enable(CH_Enable),\n      ${fxBandPortsConn(activeCount)}' : ''}${ctRuntime ? ',\n      .cct_in(cct_in), .cct_out(cct_out)' : ''}
  );''' : '''  ${dutName ?? '${top}_top #(.PIX_BITS(PIX_BITS), .MAX_WIDTH(${plan.options.maxWidth})$v2Overrides)'} dut (
${dutName == null ? '''      .clk(clk), .rst_n(rst_n),
      .in_valid(in_valid), .in_ready(in_ready),
      .in_sof(in_sof), .in_eol(in_eol), .in_data(in_data),
      .out_valid(out_valid), .out_ready(out_ready),
      .out_sof(out_sof), .out_eol(out_eol), .out_data(out_data)''' : '''      // AXI4-Stream wrapper DUT (packaged IP top module): raw-stream signals
      // mapped onto AXI4-Stream.
      .aclk(clk), .aresetn(rst_n),
      .s_axis_tvalid(in_valid), .s_axis_tready(in_ready),
      .s_axis_tuser(in_sof), .s_axis_tlast(in_eol), .s_axis_tdata(in_data),
      .m_axis_tvalid(out_valid), .m_axis_tready(out_ready),
      .m_axis_tuser(out_sof), .m_axis_tlast(out_eol), .m_axis_tdata(out_data)'''}${fxBands != null ? ',\n      .CH_Enable(CH_Enable),\n      ${fxBandPortsConn(kIpMaxBands)}' : ''}${ctRuntime ? ',\n      .cct_in(cct_in), .cct_out(cct_out)' : ''}
  );'''}

  reg [$bw-1:0] mem [0:N-1];
  initial \$readmemh("golden_in.hex", mem);


  // Simulation state variables must be declared first (iverilog requires
  // declaration before use).
  reg [31:0] fnv;
  reg [31:0] rng_gap, rng_stall;
  integer i, f, got, drain_i;

  // LCG (Numerical Recipes, 32-bit): same seeding convention as the
  // Dart-side stimulus generator.
  function [31:0] lcg_next;
    input [31:0] s;
    lcg_next = s * 32'd1664525 + 32'd1013904223;
  endfunction

  // FNV-1a: update with a single channel value (zero-extended to 16 bits)
  // as 2 little-endian bytes.
  function [31:0] fnv_u16;
    input [31:0] h;
    input [15:0] v;
    reg [31:0] t;
    begin
      t = (h ^ {24'd0, v[7:0]}) * 32'd16777619;
      fnv_u16 = (t ^ {24'd0, v[15:8]}) * 32'd16777619;
    end
  endfunction

  task hash_pixel;
    input [$bw-1:0] px;
    reg [31:0] hh;
    begin
      hh = fnv;
      hh = fnv_u16(hh, {16'd0, px[$bw-1 -: $pb]});
      hh = fnv_u16(hh, {16'd0, px[${2 * pb}-1 -: $pb]});
      hh = fnv_u16(hh, {16'd0, px[$pb-1:0]});
      fnv = hh;
    end
  endtask

  // Waveform dump: vvp produces wave.vcd, shown in the built-in
  // "simulation waveform" tab. The demo project passes +NOVCD to Vivado:
  // its own wave window already records what is needed, while dumping the
  // flattened post-route timing netlist (tens of thousands of nets) makes
  // the run crawl.
  initial begin
    if (!\$test\$plusargs("NOVCD")) begin
      \$dumpfile("wave.vcd");
      \$dumpvars(0, tb_$top);
    end
  end

  // Banner so a long netlist simulation shows progress in the console
  // before the final PASS/FAIL line.
  initial \$display("SIM start  frame=%0dx%0dx%0d  pixels=%0d", W, H, FRAMES, N);

  ${stim.clkMHz == 25 ? '' : '// CLK frequency ${fmtClkMHz(stim.clkMHz)} MHz (half period ${ipClkHalfNs(stim.clkMHz)} ns, timescale 1ns/1ps)\n  '}always #${ipClkHalfNs(stim.clkMHz)} clk = ~clk;

  // Output backpressure: out_ready is randomly pulled low per STALL_PCT on
  // the negedge (updated on the negedge, half a cycle apart from posedge
  // sampling, no race).
  always @(negedge clk) begin
    if (!rst_n || STALL_PCT == 0) begin
      out_ready <= 1'b1;
    end else begin
      rng_stall = lcg_next(rng_stall);
      out_ready <= (((rng_stall >> 16) % 100) >= STALL_PCT);
    end
  end

  // Output monitor: hash once per real transfer cycle (out_valid &
  // out_ready). The always block reads pre-edge old values on the posedge
  // (NBA not yet applied), so outputs held under backpressure are never
  // counted twice.
  always @(posedge clk) begin
    if (rst_n && out_valid && out_ready) begin
      hash_pixel(out_data);
      got = got + 1;
    end
  end

  // All stimulus toggles on the negedge; the posedge only reads the pre-edge
  // value of in_ready: input-signal changes stay half a cycle away from the
  // core's posedge sampling, fully avoiding the classic race of "changing
  // in_valid in the active region right after the posedge while the core
  // samples it, losing pixels".
  initial begin
    rng_gap = SEED;
    rng_stall = SEED ^ 32'h9E3779B9;
    // Hold reset through the 100ns Xilinx GSR used by post-synthesis and
    // post-implementation netlists; release on a negedge to avoid races.
    repeat (12) @(posedge clk);
    @(negedge clk);
    rst_n = 1'b1;

    fnv = 32'h811c9dc5;
    got = 0;
    // Feed pixel by pixel, frame by frame: sof = first pixel of a frame,
    // eol = last pixel of a row; the stream runs continuously across frames.
    // Pixels are driven on the negedge and sampled on the next posedge;
    // after the posedge the pre-edge value of in_ready tells whether the
    // pixel was accepted; if not, hold the signals and wait one more cycle
    // (no resend and no reordering under backpressure).
    for (f = 0; f < FRAMES; f = f + 1) begin
${ctRuntime ? '''      // 实测色温（帧起始值 = 上上次测量的结果）并入哈希。
      fnv = fnv_u16(fnv, {2'b0, cct_out});
''' : ''}      for (i = 0; i < W * H; i = i + 1) begin
        in_valid = 1'b1;
        in_data  = mem[f * W * H + i];
        in_sof   = (i == 0);
        in_eol   = (i % W == W - 1);
        @(posedge clk);
        while (!in_ready) @(posedge clk);
        @(negedge clk);
        // Input gap: insert 1 idle cycle with GAP_PCT probability.
        if (GAP_PCT > 0) begin
          rng_gap = lcg_next(rng_gap);
          if (((rng_gap >> 16) % 100) < GAP_PCT) begin
            in_valid = 1'b0; in_sof = 1'b0; in_eol = 1'b0;
            @(negedge clk);
          end
        end
      end
      // Frame gap: after the last pixel of a frame is accepted, insert
      // FRAME_GAP idle cycles (negedge toggling, no race).
      if (FRAME_GAP > 0 && f + 1 < FRAMES) begin
        in_valid = 1'b0; in_sof = 1'b0; in_eol = 1'b0;
        repeat (FRAME_GAP) @(posedge clk);
        @(negedge clk);
      end
    end
    // Drain: after stopping the stream, wait for the pipeline to empty --
    // poll got == N (under output backpressure a fixed cycle count may not
    // suffice: func_fixed multi-stage pipeline + long stall tails), capped
    // at 40x the latency margin to avoid waiting forever.
    in_valid = 1'b0; in_sof = 1'b0; in_eol = 1'b0;
    drain_i = 0;
    while (got < N && drain_i < $drainCycles * 40) begin
      @(posedge clk);
      drain_i = drain_i + 1;
    end

${packagedDut ? '''    if (got == N && GOLDEN_CHECK == 0)
      \$display("PASS frame=%0dx%0dx%0d, frame-count check only", W, H, FRAMES);
    else if (got == N && fnv == EXPECTED_HASH)
      \$display("PASS  frame=%0dx%0dx%0d  fnv=%08x", W, H, FRAMES, fnv);
    else
      \$display("FAIL  got=%0d/%0d  fnv=%08x  expected=%08x",
                 got, N, fnv, EXPECTED_HASH);''' : '''    if (got == N && fnv == EXPECTED_HASH)
      \$display("PASS  frame=%0dx%0dx%0d  fnv=%08x", W, H, FRAMES, fnv);
    else
      \$display("FAIL  got=%0d/%0d  fnv=%08x  expected=%08x",
                 got, N, fnv, EXPECTED_HASH);'''}
    \$finish;
  end
endmodule
''';
}

/// 32 位有符号十进制字面量（负值写成 -32'sdN 合法形态）。
String _sd32(int v) => v < 0 ? "-32'sd${-v}" : "32'sd$v";

/// func_fixed tb 段参数激励驱动：[fx] 为定点常量（端口初值），[bands] 为
/// ispflow 原始 double 参数（注释展示）。初值即 ispflow 节点当前配置；用户
/// 仿真中动态调整时改写这些 reg（建议帧间隙修改，与硬件使用约定一致）。
String _tbFxDrivers(
  List<MbFxBand> fx,
  List<({double h, double q, double dh, double s, double l})> bands,
) {
  final b = StringBuffer()
    ..writeln('''
  // ---- band parameter stimulus (values from the ispflow node's current
  // configuration; func_fixed band parameters are runtime input ports --
  // in the FPGA they can be adjusted dynamically via AXI-Lite registers
  // etc.; in simulation, rewrite the regs below to verify tuning --
  // changing them during frame blanking is recommended) ----''');
  for (var i = 0; i < kIpMaxBands; i++) {
    final f = i < fx.length
        ? fx[i]
        : multiBandFxBandConst(h: 0, q: 2, dh: 0, s: 1, l: 1);
    final d = i < bands.length
        ? bands[i]
        : (h: 0.0, q: 2.0, dh: 0.0, s: 1.0, l: 1.0);
    final p = fxBandPorts(i);
    b.writeln('''
  // band $i: h=${d.h} deg q=${d.q} dh=${d.dh} deg s=${d.s} l=${d.l}
  reg [31:0] ${p.hc} = 32'd${f.hcQ16}; // h * 2^16 (Q16 degrees)
  reg [31:0] ${p.q} = 32'd${f.kQ20}; // q / 45 * 2^20
  reg signed [31:0] ${p.dh} = ${_sd32(f.dhQ16)}; // dh * 2^16
  reg signed [31:0] ${p.s1} = ${_sd32(f.s1Q14)}; // (s-1) * 2^14
  reg signed [31:0] ${p.l1} = ${_sd32(f.l1Q14)}; // (l-1) * 2^14''');
  }
  return b.toString();
}

/// Vivado 定制界面（xgui tcl）：分页 + 控件化 + 参数联动，打包时由
/// package_ip.tcl 拷入组件 xgui/ 目录。标准 init_gui 结构。
String _xguiTcl(IpPlan plan) {
  if (plan.fxBandCount == 0) {
    final yuvGui = _hasYuvMatrix(plan)
        ? r'''
  ipgui::add_param $IPINST -name "YUV_STANDARD" -parent $Page0 \
      -display_name "YUV Matrix Standard (YUV_STANDARD)" \
      -widget comboBox
  ipgui::add_static_text $IPINST -name "YUV_STANDARD_help" -parent $Page0 \
      -text "0=BT.601 (SD), 1=BT.709 (HD), 2=BT.2020 (UHD). Function implementation coefficients; LUT implementation is baked at generation."
'''
        : '';
    return r'''
# Vivado Customize IP: fixed-point ColorTrans/color-temperature core.
proc init_gui { IPINST } {
  ipgui::add_param $IPINST -name "Component_Name"
  set Page0 [ipgui::add_page $IPINST -name "Page0" -display_name "General"]
  ipgui::add_param $IPINST -name "PIX_BITS" -parent $Page0 -widget comboBox
  ipgui::add_param $IPINST -name "MAX_WIDTH" -parent $Page0 -widget comboBox
''' +
        yuvGui +
        r'''
  set Page1 [ipgui::add_page $IPINST -name "Page1" -display_name "Optimization"]
  ipgui::add_param $IPINST -name "GSTRATEGY" -parent $Page1 -widget comboBox
  ipgui::add_param $IPINST -name "FOLD" -parent $Page1 -widget comboBox
  ipgui::add_param $IPINST -name "DSP_PIPE" -parent $Page1 -widget comboBox
''' +
        (_ctRuntimePlan(plan)
            ? r'''  ipgui::add_param $IPINST -name "USE_BRAM" -parent $Page1 -display_name "Use Block RAM (USE_BRAM)" -widget comboBox
  ipgui::add_static_text $IPINST -name "USE_BRAM_help" -parent $Page1 -text "1 = white-point / reciprocal tables in Block RAM (default, saves CLB LUTs); 0 = distributed combinational ROM (previous build). Identical results."
'''
            : '') +
        r'''}

# 用户参数 -> 模型参数同步：**必须有这些 proc**，否则 Customize IP / 脚本里的
# `set_property CONFIG.X` 只改用户参数，生成的 wrapper 仍用打包时的默认值
#（表现在 IP 综合结果完全不随选项变化）。
proc update_MODELPARAM_VALUE.PIX_BITS { MODELPARAM_VALUE.PIX_BITS PARAM_VALUE.PIX_BITS } {
  set_property value [get_property value ${PARAM_VALUE.PIX_BITS}] ${MODELPARAM_VALUE.PIX_BITS}
}
proc update_MODELPARAM_VALUE.MAX_WIDTH { MODELPARAM_VALUE.MAX_WIDTH PARAM_VALUE.MAX_WIDTH } {
  set_property value [get_property value ${PARAM_VALUE.MAX_WIDTH}] ${MODELPARAM_VALUE.MAX_WIDTH}
}
proc update_MODELPARAM_VALUE.GSTRATEGY { MODELPARAM_VALUE.GSTRATEGY PARAM_VALUE.GSTRATEGY } {
  set_property value [get_property value ${PARAM_VALUE.GSTRATEGY}] ${MODELPARAM_VALUE.GSTRATEGY}
}
proc update_MODELPARAM_VALUE.FOLD { MODELPARAM_VALUE.FOLD PARAM_VALUE.FOLD } {
  set_property value [get_property value ${PARAM_VALUE.FOLD}] ${MODELPARAM_VALUE.FOLD}
}
proc update_MODELPARAM_VALUE.DSP_PIPE { MODELPARAM_VALUE.DSP_PIPE PARAM_VALUE.DSP_PIPE } {
  set_property value [get_property value ${PARAM_VALUE.DSP_PIPE}] ${MODELPARAM_VALUE.DSP_PIPE}
}
''' +
        (_hasYuvMatrix(plan)
            ? r'''proc update_MODELPARAM_VALUE.YUV_STANDARD { MODELPARAM_VALUE.YUV_STANDARD PARAM_VALUE.YUV_STANDARD } {
  set_property value [get_property value ${PARAM_VALUE.YUV_STANDARD}] ${MODELPARAM_VALUE.YUV_STANDARD}
}
'''
            : '') +
        (_ctRuntimePlan(plan)
            ? r'''proc update_MODELPARAM_VALUE.USE_BRAM { MODELPARAM_VALUE.USE_BRAM PARAM_VALUE.USE_BRAM } {
  set_property value [get_property value ${PARAM_VALUE.USE_BRAM}] ${MODELPARAM_VALUE.USE_BRAM}
}
'''
            : '') +
        r'''
''';
  }
  final b = StringBuffer(r'''
# Vivado Customize IP: all UI text is ASCII for cross-version compatibility.
proc init_gui { IPINST } {
  ipgui::add_param $IPINST -name "Component_Name"
  set Page0 [ipgui::add_page $IPINST -name "Page0" -display_name "General"]
  ipgui::add_param $IPINST -name "IMPL_MODE" -parent $Page0 \
      -display_name "Behavior Implementation (IMPL_MODE)" \
      -widget comboBox
  ipgui::add_static_text $IPINST -name "IMPL_MODE_help" -parent $Page0 \
      -text "0=Remap HSL color space using LUT file; 1=Call a function to modify HSL color space. Function-mode band ports are shown only when IMPL_MODE=1."
  ipgui::add_param $IPINST -name "PIX_BITS" -parent $Page0 \
      -display_name "Pixel Bits (PIX_BITS)" \
      -widget comboBox
  ipgui::add_static_text $IPINST -name "PIX_BITS_help" -parent $Page0 \
      -text "Pixel bit width; sets the datapath width and LUT ROM depth (MAXV=2^PIX_BITS-1)."
  ipgui::add_param $IPINST -name "MAX_WIDTH" -parent $Page0 \
      -display_name "Max Width (MAX_WIDTH)" \
      -widget comboBox
  ipgui::add_static_text $IPINST -name "MAX_WIDTH_help" -parent $Page0 \
      -text "Maximum line-buffer width; directly affects BRAM usage."
  set Page1 [ipgui::add_page $IPINST -name "Page1" -display_name "Optimization"]
  ipgui::add_param $IPINST -name "GSTRATEGY" -parent $Page1 \
      -display_name "Multiply Strategy (GSTRATEGY)" \
      -widget comboBox
  ipgui::add_static_text $IPINST -name "GSTRATEGY_help" -parent $Page1 \
      -text "0: force LUT (use_dsp=no); 1: synthesizer chooses; 2: force DSP (use_dsp=yes)."
  ipgui::add_param $IPINST -name "FOLD" -parent $Page1 \
      -display_name "Fold Factor (FOLD)" \
      -widget comboBox
  ipgui::add_static_text $IPINST -name "FOLD_help" -parent $Page1 \
      -text "FOLD cycles per pixel with operator reuse; throughput is 1/FOLD px/clk. Editable only when GSTRATEGY=0 (area)."
  ipgui::add_param $IPINST -name "DSP_PIPE" -parent $Page1 \
      -display_name "Band Pipeline (DSP_PIPE)" \
      -widget comboBox
  ipgui::add_static_text $IPINST -name "DSP_PIPE_help" -parent $Page1 \
      -text "func_fixed pipeline: 0=combinational, 1=band_pre, 2=band_pre+band_mid, 3=full internal DSP pipeline (highest Fmax). Only latency changes; pixel data is unchanged."
  ipgui::add_param $IPINST -name "NUM_BANDS" -parent $Page0 \
      -display_name "Number Of Color Picker Channels (NUM_BANDS)" \
      -widget comboBox
  ipgui::add_static_text $IPINST -name "NUM_BANDS_help" -parent $Page0 \
      -text "Active color picker channels from 1 to 16. CH_Enable is NUM_BANDS bits wide; unused channel parameters are hidden."
  ipgui::add_param $IPINST -name "WORK_MODE" -parent $Page0 \
      -display_name "Work Mode (WORK_MODE)" \
      -widget comboBox
  ipgui::add_static_text $IPINST -name "WORK_MODE_help" -parent $Page0 \
      -text "Select color picker parallel or cascade operation. The default follows the ispflow band mode."
}

# Keep model parameters synchronized while the Customize IP preview is open.
# CH_Enable's SIZE_LEFT dependency reads MODELPARAM_VALUE.NUM_BANDS.
proc update_MODELPARAM_VALUE.IMPL_MODE { MODELPARAM_VALUE.IMPL_MODE PARAM_VALUE.IMPL_MODE } {
  set_property value [get_property value ${PARAM_VALUE.IMPL_MODE}] ${MODELPARAM_VALUE.IMPL_MODE}
}
proc update_MODELPARAM_VALUE.PIX_BITS { MODELPARAM_VALUE.PIX_BITS PARAM_VALUE.PIX_BITS } {
  set_property value [get_property value ${PARAM_VALUE.PIX_BITS}] ${MODELPARAM_VALUE.PIX_BITS}
}
proc update_MODELPARAM_VALUE.MAX_WIDTH { MODELPARAM_VALUE.MAX_WIDTH PARAM_VALUE.MAX_WIDTH } {
  set_property value [get_property value ${PARAM_VALUE.MAX_WIDTH}] ${MODELPARAM_VALUE.MAX_WIDTH}
}
proc update_MODELPARAM_VALUE.GSTRATEGY { MODELPARAM_VALUE.GSTRATEGY PARAM_VALUE.GSTRATEGY } {
  set_property value [get_property value ${PARAM_VALUE.GSTRATEGY}] ${MODELPARAM_VALUE.GSTRATEGY}
}
proc update_MODELPARAM_VALUE.FOLD { MODELPARAM_VALUE.FOLD PARAM_VALUE.FOLD } {
  set_property value [get_property value ${PARAM_VALUE.FOLD}] ${MODELPARAM_VALUE.FOLD}
}
proc update_MODELPARAM_VALUE.DSP_PIPE { MODELPARAM_VALUE.DSP_PIPE PARAM_VALUE.DSP_PIPE } {
  set_property value [get_property value ${PARAM_VALUE.DSP_PIPE}] ${MODELPARAM_VALUE.DSP_PIPE}
}
proc update_MODELPARAM_VALUE.WORK_MODE { MODELPARAM_VALUE.WORK_MODE PARAM_VALUE.WORK_MODE } {
  set_property value [get_property value ${PARAM_VALUE.WORK_MODE}] ${MODELPARAM_VALUE.WORK_MODE}
}
proc update_MODELPARAM_VALUE.NUM_BANDS { MODELPARAM_VALUE.NUM_BANDS PARAM_VALUE.NUM_BANDS } {
  set_property value [get_property value ${PARAM_VALUE.NUM_BANDS}] ${MODELPARAM_VALUE.NUM_BANDS}
}
''');
  return b.toString();
}

/// demo_prj 时序约束：单时钟域 aclk=25MHz。I/O delay 是起始预算，
/// 用户应结合板卡、IOB 和接口时序进一步调整。
String _clockRouteTcl() {
  return '''
# Pinless demos let Vivado choose an arbitrary IOB, which need not have a
# dedicated route to the BUFG. This Tcl runs only before opt_design when no
# board-specific pins.xdc exists; real boards must use a clock-capable pin.
set clockNets [get_nets -quiet aclk_IBUF_inst/O]
if {[llength \$clockNets] > 0} {
  set_property CLOCK_DEDICATED_ROUTE FALSE \$clockNets
}

# Same reason: without a board pinout every port is unconstrained, so NSTD-1 /
# UCIO-1 would flag all of them as critical warnings. Declare them Advisory
# (still listed by report_drc); a real integration must supply pins.xdc.
foreach drc {NSTD-1 UCIO-1} {
  set checks [get_drc_checks -quiet \$drc]
  if {[llength \$checks] > 0} {
    set_property SEVERITY {Advisory} \$checks
  }
}
''';
}

String _timingXdc(IpPlan plan) {
  return '''
# Timing constraints for the demo project, organized by the Vivado
# Timing Constraints Wizard categories.

# ============================================================================
# 1. Clocks
# ============================================================================
# Primary clock: aclk = 25 MHz, 40 ns period, 50% duty cycle.
create_clock -period 40.000 -name aclk -waveform {0.000 20.000} [get_ports aclk]

# Generated clocks: none. The design has no MMCM/PLL or clock divider.
# Forwarded clocks: none. No clock is forwarded to an output port.
# External feedback delays: none. There is no external clock feedback path.

# ============================================================================
# 2. Input and output ports
# ============================================================================
# Default I/O timing budget (max=8 ns, min=2 ns). Adjust these values for
# the actual board, IOB placement and external source/sink timing.
# 色温运行期端口（cct_in 目标 / cct_out 实测，14 位）也要有 I/O 延迟约束，
# 否则 methodology DRC 会为每一位报 TIMING-18（Missing input or output delay）。
set_input_delay -clock aclk -max 8.000 [get_ports {s_axis_tdata s_axis_tvalid s_axis_tuser s_axis_tlast m_axis_tready aresetn${_ctRuntimePlan(plan) ? ' cct_in' : ''}}]
set_input_delay -clock aclk -min 2.000 [get_ports {s_axis_tdata s_axis_tvalid s_axis_tuser s_axis_tlast m_axis_tready aresetn${_ctRuntimePlan(plan) ? ' cct_in' : ''}}]
set_output_delay -clock aclk -max 8.000 [get_ports {s_axis_tready m_axis_tdata m_axis_tvalid m_axis_tuser m_axis_tlast${_ctRuntimePlan(plan) ? ' cct_out' : ''}}]
set_output_delay -clock aclk -min 2.000 [get_ports {s_axis_tready m_axis_tdata m_axis_tvalid m_axis_tuser m_axis_tlast${_ctRuntimePlan(plan) ? ' cct_out' : ''}}]
# CH_Enable and par_b* are tied to constants inside demo_top. They are not
# top-level ports or timing endpoints, so no I/O/path constraints apply.
# Combinational delays: bound any direct input-to-output path to one aclk
# period. Clocked paths are still analyzed against aclk as usual.
set_max_delay -from [all_inputs] -to [all_outputs] 40.000
set_min_delay -from [all_inputs] -to [all_outputs] 0.000

# ============================================================================
# 3. Clock domain crossings
# ============================================================================
# This design uses only the aclk domain. No generated or forwarded clock
# exists, so no physically exclusive or logically exclusive clock groups are
# required, and there are no asynchronous clock-domain crossing paths.
''';
}

String _clockBufferV() {
  return '''
  wire aclk_int;
`ifdef SYNTHESIS
  wire aclk_ibuf;
  IBUF u_ibuf (
      .I(aclk), .O(aclk_ibuf)
  );
  BUFGCE #(.CE_TYPE("SYNC")) u_bufgce (
      .I(aclk_ibuf), .CE(1'b1), .O(aclk_int)
  );
`else
  assign aclk_int = aclk;
`endif
''';
}

/// 演示顶层（demo/）：像素流直进直出；func_fixed 的段参数烘焙为 ispflow
/// 快照常量（运行时调参把这些端口改接 AXI-Lite 寄存器即可）。
String _demoTopV(IpPlan plan, FxTbBands? fx, {bool ctPorts = false}) {
  final top = plan.topName;
  final pb = plan.pixBits;
  final bw = 3 * pb;
  String ties = '';
  if (fx != null) {
    final blocks = <String>[
      for (var i = 0; i < kIpMaxBands; i++)
        () {
          final f = i < fx.fx.length
              ? fx.fx[i]
              : multiBandFxBandConst(h: 0, q: 2, dh: 0, s: 1, l: 1);
          final d = i < fx.bands.length
              ? fx.bands[i]
              : (h: 0.0, q: 2.0, dh: 0.0, s: 1.0, l: 1.0);
          return '  // band $i: h=${d.h} deg q=${d.q} '
              'dh=${d.dh} deg s=${d.s} l=${d.l}\n'
              '  wire [31:0] par_b${i}_hc = 32\'d${f.hcQ16};\n'
              '  wire [31:0] par_b${i}_q = 32\'d${f.kQ20};\n'
              '  wire signed [31:0] par_b${i}_dh = ${_sd32(f.dhQ16)};\n'
              '  wire signed [31:0] par_b${i}_s1 = ${_sd32(f.s1Q14)};\n'
              '  wire signed [31:0] par_b${i}_l1 = ${_sd32(f.l1Q14)};';
        }(),
    ];
    ties = '${blocks.join('\n')}\n';
  }
  return '''
// Demo top (demo_top): forwards the IP pixel stream straight to external
// ports; band parameters are baked as ispflow snapshot constants.
// Synthesis top; instantiates the IP instance $top (OOC synthesis produces
// $top.dcp, linked by the parent). Wildcard connections ignore local signals
// whose ports are hidden by the current NUM_BANDS configuration.
`timescale 1ns/1ps
module demo_top (
    input  wire           aclk,
    input  wire           aresetn,
    input  wire [$bw-1:0]         s_axis_tdata,
    input  wire                   s_axis_tvalid,
    output wire                   s_axis_tready,
    input  wire                   s_axis_tuser,
    input  wire                   s_axis_tlast,
    output wire [$bw-1:0]         m_axis_tdata,
    output wire                   m_axis_tvalid,
    input  wire                   m_axis_tready,
    output wire                   m_axis_tuser,
    output wire                   m_axis_tlast${ctPorts ? ''',
    input  wire [13:0]            cct_in,
    output wire [13:0]            cct_out''' : ''}
);
${_clockBufferV()}${fx != null ? '  localparam integer NUM_BANDS = ${plan.fxBandCount};\n  wire [NUM_BANDS-1:0] CH_Enable = {NUM_BANDS{1\'b1}};\n' : ''}$ties  $top u_dut ( .aclk(aclk_int), .* );
endmodule
''';
}

/// 一键生成 Vivado 演示工程（demo/ 目录）：打包 IP（幂等）→ 建工程 →
/// 例化 IP → 加演示顶层（综合）与 golden tb（行为仿真）。位置无关
///（以脚本所在目录为基准），可重复执行（-force 覆盖）。
String _demoProjectTcl(IpPlan plan) {
  final top = plan.topName;
  return '''
# One-shot Vivado demo project generation (select this file via
# Tools -> Run Tcl Script, or vivado -mode batch -source create_demo_project.tcl).
set demoDir [file dirname [file normalize [info script]]]
cd \$demoDir
set pkgDir [file dirname \$demoDir]
set ipName $top

# 1. IP packaging (skipped if already packaged and the script is not newer;
#    source leaks the sourced script's cd, so save/restore the current
#    directory). Re-exporting a different configuration refreshes ip_repo
#    automatically.
if {![file exists \$pkgDir/ip_repo/component.xml] ||
    [file mtime \$pkgDir/package_ip.tcl] > [file mtime \$pkgDir/ip_repo/component.xml]} {
  set _savedCwd [pwd]
  source \$pkgDir/package_ip.tcl
  cd \$_savedCwd
}

# 2. Create the demo project (same target part as the IP package export).
create_project -force ${plan.options.projectName} ./${plan.options.projectName} -part ${plan.options.vivadoPart}
# Avoid long-path IP-cache warnings; synthesis runs remain fully enabled.
config_ip_cache -disable
# Reviewed messages only: intentional DSP cascade plus pruning of inactive
# fixed-16-band variants. DRC, timing and all other warnings remain enabled.
set_msg_config -id {Synth 8-5409} -new_severity INFO
set_msg_config -id {Synth 8-3330} -new_severity INFO
set_msg_config -id {Synth 8-3332} -new_severity INFO
set_msg_config -id {Synth 8-3936} -new_severity INFO
set_msg_config -id {Synth 8-6014} -new_severity INFO
set_msg_config -id {Synth 8-7129} -new_severity INFO
set_property ip_repo_paths [list \$pkgDir/ip_repo] [current_project]
update_ip_catalog

# 3. Instantiate the IP and explicitly apply the configuration from the
#    export dialog.
create_ip -name \$ipName -vendor debugtoolset -library isp -module_name $top
set_property CONFIG.PIX_BITS {${plan.pixBits}} [get_ips $top]
set_property CONFIG.MAX_WIDTH {${plan.options.maxWidth}} [get_ips $top]
set_property CONFIG.GSTRATEGY {${plan.options.gstrategy}} [get_ips $top]
set_property CONFIG.FOLD {${plan.options.fold}} [get_ips $top]
set_property CONFIG.DSP_PIPE {${plan.options.dspPipe}} [get_ips $top]
${_ctRuntimePlan(plan) ? 'set_property CONFIG.USE_BRAM {${plan.options.useBram ? 1 : 0}} [get_ips $top]\n' : ''}${_hasYuvMatrix(plan) ? 'set_property CONFIG.YUV_STANDARD {${yuvStandardCode(_effectiveYuvStandard(plan))}} [get_ips $top]\n' : ''}${plan.fxBandCount > 0 ? 'set_property CONFIG.IMPL_MODE {${plan.implMode}} [get_ips $top]\nset_property CONFIG.WORK_MODE {${plan.fxSerial ? 1 : 0}} [get_ips $top]\nset_property CONFIG.NUM_BANDS {${plan.fxBandCount}} [get_ips $top]' : ''}
generate_target all [get_ips $top]
create_ip_run [get_ips $top]
# Use timing-oriented strategies for both the parent and the IP OOC run.
# The implementation strategy is explicit as well; do not rely on the
# Vivado-version-dependent runtime-optimized defaults.
set_property strategy Flow_PerfOptimized_high [get_runs synth_1]
set_property strategy Flow_PerfOptimized_high [get_runs ${top}_synth_1]
set_property strategy Performance_Explore [get_runs impl_1]

# 4. Demo top (synthesis top) and golden testbench, both using the packaged
#    $top instance. SystemVerilog wildcard port connections ignore local
#    signals whose IP ports are hidden by NUM_BANDS. golden_in.hex is copied
#    with sim_1 as simulation data.
# Note: create_project changes the current directory to the project directory,
# source files always use absolute paths.
add_files -norecurse [list \$demoDir/demo_top.v]
add_files -fileset constrs_1 -norecurse [list \$demoDir/timing.xdc]
# Optional board-specific pin constraints saved from Vivado I/O Planning.
if {[file exists \$demoDir/pins.xdc]} {
  add_files -fileset constrs_1 -norecurse [list \$demoDir/pins.xdc]
} else {
  add_files -fileset utils_1 -norecurse [list \$demoDir/clock_route.tcl]
  set clockRouteTcl [file normalize \$demoDir/clock_route.tcl]
  set_property STEPS.OPT_DESIGN.TCL.PRE \$clockRouteTcl [get_runs impl_1]
}
add_files -fileset sim_1 -norecurse [list     \$demoDir/tb_demo.v     \$pkgDir/golden_in.hex     [glob \$pkgDir/*_core.v]     [glob \$pkgDir/*_top.v]     [glob \$pkgDir/*_axis.v]]
set_property file_type SystemVerilog [get_files \$demoDir/demo_top.v]
set_property file_type SystemVerilog [get_files \$demoDir/tb_demo.v]
set_property top demo_top [current_fileset]
set_property top tb_$top [get_filesets sim_1]
# The tb finishes itself via \$finish; the default 1000ns simulation runtime
# is too short for all golden frames, so give it enough margin to run to
# completion.
set_property -name {xsim.simulate.runtime} -value {100us} -objects [get_filesets sim_1]
# Skip the testbench's own VCD dump under Vivado: the XSim wave window already
# records what is needed, and dumping a flattened post-route timing netlist
# (tens of thousands of nets) makes the run crawl.
set_property -name {xsim.simulate.xsim.more_options} -value {-testplusarg NOVCD} -objects [get_filesets sim_1]
update_compile_order -fileset sources_1
update_compile_order -fileset sim_1

puts "============================================================"
puts "Demo project generated: ./${plan.options.projectName}/${plan.options.projectName}.xpr"
puts "  Synthesis: Flow -> Run Synthesis (top: demo_top)"
puts "  Simulation: Flow -> Run Simulation -> Run Behavioral Simulation"
puts "       (top: tb_$top, golden hash by default; set GOLDEN_CHECK=0 for frame-count check)"
puts "============================================================"
''';
}

String _packageIpTcl(IpPlan plan) {
  final top = plan.topName;
  return '''
# Vivado IP Packager: packages ${top}_axis as a customizable IP (parameters
# editable in the Customize IP GUI). Usage: vivado -mode batch -source
# package_ip.tcl, or select this file via Tools -> Run Tcl Script in the
# Vivado GUI.
# Location-independent: first cd to the script's own directory (under Run
# Tcl Script Vivado's current directory is the project directory, not the
# script's -- relative paths would miss the source files and drop ip_repo
# in the wrong place).
cd [file dirname [file normalize [info script]]]
set ip_name $top
create_project -in_memory -part ${plan.options.vivadoPart}
add_files ${top}_core.v
add_files ${top}_top.v
add_files ${top}_axis.v
ipx::package_project -root_dir ./ip_repo -vendor debugtoolset -library isp \\
    -taxonomy /UserIP -import_files -force_update_compile_order
set_property name \$ip_name [ipx::current_core]
set_property display_name "$top (ISP Studio)" [ipx::current_core]
set_property vendor_display_name "DebugToolSet" [ipx::current_core]
set_property version 2.0 [ipx::current_core]
# Parameter group (Customize IP GUI):
ipx::add_user_parameter PIX_BITS [ipx::current_core]
set_property value_resolve_type user [ipx::get_user_parameters PIX_BITS]
set_property value ${plan.pixBits} [ipx::get_user_parameters PIX_BITS]
ipx::add_user_parameter MAX_WIDTH [ipx::current_core]
set_property value ${plan.options.maxWidth} [ipx::get_user_parameters MAX_WIDTH]
# Optimization strategy (current whitelist is point operators; tiers
# reserved for window operators; editable in the GUI).
ipx::add_user_parameter GSTRATEGY [ipx::current_core]
set_property value_resolve_type user [ipx::get_user_parameters GSTRATEGY]
set_property value ${plan.options.gstrategy} [ipx::get_user_parameters GSTRATEGY]
ipx::add_user_parameter FOLD [ipx::current_core]
set_property value_resolve_type user [ipx::get_user_parameters FOLD]
set_property value ${plan.options.fold} [ipx::get_user_parameters FOLD]
# func_fixed band-unit weight-chain pipeline depth (0/1/2; bypass structure
# folded by synthesis).
ipx::add_user_parameter DSP_PIPE [ipx::current_core]
set_property value_resolve_type user [ipx::get_user_parameters DSP_PIPE]
set_property value ${plan.options.dspPipe} [ipx::get_user_parameters DSP_PIPE]
${_ctRuntimePlan(plan) ? '''
# 色温表存储：1 = Block RAM（省 CLB LUT，默认）；0 = 分布式组合 ROM（上一版）。
ipx::add_user_parameter USE_BRAM [ipx::current_core]
set_property value_resolve_type user [ipx::get_user_parameters USE_BRAM]
set_property value ${plan.options.useBram ? 1 : 0} [ipx::get_user_parameters USE_BRAM]
''' : ''}${_hasYuvMatrix(plan) ? '''
# YUV matrix standard: 0=BT.601(SD), 1=BT.709(HD), 2=BT.2020(UHD).
ipx::add_user_parameter YUV_STANDARD [ipx::current_core]
set_property value_resolve_type user [ipx::get_user_parameters YUV_STANDARD]
set_property value ${yuvStandardCode(_effectiveYuvStandard(plan))} [ipx::get_user_parameters YUV_STANDARD]
''' : ''}${_v2PackageParams(plan)}
${plan.fxBandCount > 0 ? '''
catch {ipx::add_port CH_Enable [ipx::current_core]}
set_property direction in [ipx::get_ports CH_Enable]
set_property size_left ${plan.fxBandCount - 1} [ipx::get_ports CH_Enable]
set_property size_left_dependency {(spirit:decode(id('MODELPARAM_VALUE.NUM_BANDS')) - 1)} [ipx::get_ports CH_Enable]
set_property size_left_resolve_type dependent [ipx::get_ports CH_Enable]
set_property size_left_format_type long [ipx::get_ports CH_Enable]
set_property size_right 0 [ipx::get_ports CH_Enable]
set_property size_right_resolve_type immediate [ipx::get_ports CH_Enable]
set_property size_right_format_type long [ipx::get_ports CH_Enable]
set_property type_name std_logic_vector [ipx::get_ports CH_Enable]
set_property is_vector true [ipx::get_ports CH_Enable]
set_property driver_value 0 [ipx::get_ports CH_Enable]
set_property enablement_dependency {(spirit:decode(id('PARAM_VALUE.IMPL_MODE')) = 1)} [ipx::get_ports CH_Enable]
set_property enablement_resolve_type dependent [ipx::get_ports CH_Enable]
''' : ''}
# Value legality (combo-list validation, same source as the Customize IP
# dropdowns):
set_property value_validation_type list [ipx::get_user_parameters PIX_BITS]
set_property value_validation_list {8 10 12 14 16} [ipx::get_user_parameters PIX_BITS]
set_property value_validation_type list [ipx::get_user_parameters MAX_WIDTH]
set_property value_validation_list {${kIpMaxWidthOptions.join(' ')}} [ipx::get_user_parameters MAX_WIDTH]
set_property value_validation_type pairs [ipx::get_user_parameters GSTRATEGY]
set_property value_validation_pairs [list "Area (folded operators)" 0 "Balanced (synthesizer chooses)" 1 "Performance (use DSP)" 2] [ipx::get_user_parameters GSTRATEGY]
set_property value_validation_type pairs [ipx::get_user_parameters FOLD]
set_property value_validation_pairs [list "x1" 1 "x2" 2 "x4" 4] [ipx::get_user_parameters FOLD]
# FOLD is editable only in the area tier (GSTRATEGY=0).
set_property enablement_dependency {(spirit:decode(id('PARAM_VALUE.GSTRATEGY')) = 0)} [ipx::get_user_parameters FOLD]
set_property enablement_resolve_type dependent [ipx::get_user_parameters FOLD]
set_property value_validation_type pairs [ipx::get_user_parameters DSP_PIPE]
set_property value_validation_pairs [list "Combinational (lowest latency)" 0 "Pipeline band_pre" 1 "Pipeline band_pre+band_mid" 2 "Full internal DSP pipeline (highest Fmax)" 3] [ipx::get_user_parameters DSP_PIPE]
${_ctRuntimePlan(plan) ? '''
set_property value_validation_type pairs [ipx::get_user_parameters USE_BRAM]
set_property value_validation_pairs [list "Block RAM (saves CLB LUTs)" 1 "Distributed ROM (previous build)" 0] [ipx::get_user_parameters USE_BRAM]
''' : ''}${_hasYuvMatrix(plan) ? '''
set_property value_validation_type pairs [ipx::get_user_parameters YUV_STANDARD]
set_property value_validation_pairs [list "BT.601 (SD)" 0 "BT.709 (HD)" 1 "BT.2020 (UHD)" 2] [ipx::get_user_parameters YUV_STANDARD]
''' : ''}
${plan.fxBandCount > 0 ? '''
set_property enablement_dependency {(spirit:decode(id('PARAM_VALUE.IMPL_MODE')) = 1)} [ipx::get_user_parameters DSP_PIPE]
set_property enablement_resolve_type dependent [ipx::get_user_parameters DSP_PIPE]
''' : ''}
${plan.fxBandCount > 0 ? '''
set_property value_validation_type pairs [ipx::get_user_parameters IMPL_MODE]
set_property value_validation_pairs [list "Remap HSL color space using LUT file" 0 "Call a function to modify HSL color space" 1] [ipx::get_user_parameters IMPL_MODE]
set_property value_validation_type pairs [ipx::get_user_parameters WORK_MODE]
set_property value_validation_pairs [list "Color picker parallel operation" 0 "Color picker cascade operation" 1] [ipx::get_user_parameters WORK_MODE]
set_property enablement_dependency {(spirit:decode(id('PARAM_VALUE.IMPL_MODE')) = 1)} [ipx::get_user_parameters WORK_MODE]
set_property enablement_resolve_type dependent [ipx::get_user_parameters WORK_MODE]
set_property value_validation_type list [ipx::get_user_parameters NUM_BANDS]
set_property value_validation_list {${[for (var i = 1; i <= kIpMaxBands; i++) i].join(' ')}} [ipx::get_user_parameters NUM_BANDS]
set_property enablement_dependency {(spirit:decode(id('PARAM_VALUE.IMPL_MODE')) = 1)} [ipx::get_user_parameters NUM_BANDS]
set_property enablement_resolve_type dependent [ipx::get_user_parameters NUM_BANDS]
${[
          for (var i = 0; i < kIpMaxBands; i++)
            for (final p in ['hc', 'q', 'dh', 's1', 'l1']) '''
set_property type_name std_logic_vector [ipx::get_ports par_b${i}_$p]
set_property driver_value 0 [ipx::get_ports par_b${i}_$p]
set_property enablement_dependency {(spirit:decode(id('PARAM_VALUE.IMPL_MODE')) = 1) && (spirit:decode(id('PARAM_VALUE.NUM_BANDS')) > $i)} [ipx::get_ports par_b${i}_$p]
set_property enablement_resolve_type dependent [ipx::get_ports par_b${i}_$p]
''',
        ].join()}
''' : ''}
set_property supported_families {${plan.options.vivadoFamily} Production} [ipx::current_core]
ipx::save_core [ipx::current_core]
ipx::check_integrity [ipx::current_core]
# Copy the Customize IP page (xgui tcl) into the component directory. IP
# Packager keeps its auto-generated _axis_v1_0 reference after the core is
# renamed to v2.0, so overwrite that legacy file as well as the current names.
set xguiDir "./ip_repo/xgui"
file mkdir \$xguiDir
file copy -force -- "xgui/${top}_v2_0.tcl" "\$xguiDir/${top}_v2_0.tcl"
file copy -force -- "xgui/${top}_v2_0.tcl" "\$xguiDir/${top}_axis_v2_0.tcl"
file copy -force -- "xgui/${top}_v2_0.tcl" "\$xguiDir/${top}_axis_v1_0.tcl"
puts "IP packaged at ./ip_repo"
''';
}

String _readme(IpPlan plan, IpSimStimulus stim) {
  final top = plan.topName;
  final v = plan.options.vendor;
  final est = plan.resources;
  final strategyName = switch (plan.options.gstrategy) {
    0 => '面积优先',
    1 => '平衡',
    _ => '性能优先',
  };
  if (plan.fxBandCount == 0) {
    return '''
# $top（定点 FPGA Verilog IP，ISP Studio 自动生成）

支持 ColorTrans 与色温调节器的 func_fixed / lut_fixed 编组。
输入/输出为三通道像素流，每通道 PIX_BITS 位，带 ready/valid 握手、sof/eol。

- func_fixed：标量 Q14/Q16 整数运算，无 ROM。
- lut_fixed：生成期烘焙定点 ROM；色温使用三通道结果表，ColorTrans 使用乘积项与归一化表。
${_hasYuvMatrix(plan) ? '''- YUV2RGB 矩阵标准：`YUV_STANDARD` = 0 BT.601(SD) / 1 BT.709(HD) /
  2 BT.2020(UHD)；func_fixed 可在 Customize IP 切换，LUT 模式按生成选择烘焙。
''' : ''}- 当前实现为 II=1、${est.latencyCycles} 拍流水，支持背压。
${_hasRgb2Hsl(plan) ? '''- RGB→HSL（func_fixed，GSTRATEGY≠0 且 DSP_PIPE=3）为全流水分级数据通路：
  Q14 归一化 → 4 级定点除法乘法（牛顿迭代倒数 + 精确余数修正）→ 缩放。
  每级乘法用本文件内的 `${top}_hsl_mul`（DSP48E2 原语，AREG/BREG/MREG/PREG
  全 1，三个内部寄存器级各由所在流水级的 ready 驱动），因此既实际使用
  DSP（11 个乘法器）又零 DPIP/DPOP「DSP 未流水」建议，且仍支持输入气泡与
  输出背压；三段组合逻辑分成 `_hsl_m` / `_hsl_q` / `_hsl_corr` 子模块并保留
  层级（核心只留流水寄存器与 DSP 原语，便于 pblock/区域约束）；面积档
  （GSTRATEGY=0）仍为组合函数 + `use_dsp="no"`。
''' : ''}- 资源估算：${est.summary()}
${_ctRuntimePlan(plan) ? '''- 色温运行期接口：`cct_in[13:0]` = 目标色温（K，1800~12000，超范围钳位），
  `cct_out[13:0]` = 实测色温（每帧更新）。CCM（von Kries 对角增益 Q14）由内核
  按「目标白点 / 实测白点」自动算出，**不暴露 3×3 系数参数**；图像接口为
  RGB（每通道 PIX_BITS 位，打包成 3×PIX_BITS 的像素流）。
- 表存储（生成期选项「色温表存 Block RAM」）：勾选（默认）= 白点/倒数表放
  Block RAM，CLB LUT 约少 40%（实测 5786 LUT）；取消 = 组合 ROM（上一版实现，
  LUT 用量大、无读延迟）。两者表数据与插值写法相同，**结果逐位一致**；要切换
  需重新导出 IP 包（生成物里只有选中的那一套）。
- 测量口径：按帧累加输入 R/G/B，帧起始投入固定点 McCamy（sRGB→XYZ Q16 系数
  → 色度比 → 逐位长除法 → Q14 三次多项式），与 Dart 参考
  `pipeline/color_temp_hw.dart` 逐位一致；片上无帧缓存，**第 k 帧的增益用第
  k-2 帧的测量**（两帧后收敛），一帧像素数需 ≥96（测量 FSM 约 65 拍）。
''' : ''}- 仿真激励：${stim.width}×${stim.height}×${stim.frames} 帧。
${_simReadmeSection()}
''';
  }
  return '''
# $top（FPGA Verilog IP，ISP Studio 自动生成）

## 接口（像素流）

核心模块 `${top}_core` 输入/输出均为通用像素流，通道打包 `{H,S,L}`
（H 在最高位段，每通道 `PIX_BITS` 位），全程带 ready 握手：

- `in_valid`/`in_ready`：输入握手，`advance = in_valid & in_ready`；
- `in_sof`/`in_eol`：帧起始/帧结束（与 `in_data` 同拍有效）；
- `out_valid`/`out_ready`/`out_sof`/`out_eol`/`out_data`：输出同形，${plan.implMode == 1 ? '${est.latencyCycles} 拍流水' : '1 拍流水'}
  延迟（II=1，每时钟 1 像素）。

## 参数（顶层 parameter，Customize IP / generics 面板可改）

| 参数 | 默认 | 说明 |
|---|---|---|
| `IMPL_MODE` | ${plan.implMode} | 行为实现：0 = Remap HSL color space using LUT file；1 = Call a function to modify HSL color space；两种数据通路均包含在核心中，可在 Customize IP 中切换 |
| `PIX_BITS` | ${plan.pixBits} | 像素位宽；决定数据通路宽度与 LUT ROM 深度（MAXV = 2^PIX_BITS-1） |
| `MAX_WIDTH` | ${plan.options.maxWidth} | 行缓冲最大行宽（本节点无窗口算子，参数保留） |
| `GSTRATEGY` | ${plan.options.gstrategy}（$strategyName） | 乘法器实现：0 绑 LUT（`use_dsp=no`）/ 1 综合器自选 / 2 绑 DSP（`use_dsp=yes`） |
| `FOLD` | ${plan.options.fold} | 窗口算子折叠因子（仅面积档生效，预留） |
| `DSP_PIPE` | ${plan.options.dspPipe} | 0 纯组合 / 1 前段插一拍 / 2 前段+中段各插一拍 / 3 DSP 内部全流水（最高 Fmax；段参数随像素同拍延迟，II=1，数据不变） |
${plan.fxBandCount > 0 ? '''| `WORK_MODE` | ${plan.fxSerial ? '1（Color picker cascade operation）' : '0（Color picker parallel operation）'} | 取色器工作方式：0 并联 / 1 串联，默认与 ispflow 一致；综合时选择对应结构，数值语义不变 |
| `NUM_BANDS` | ${plan.fxBandCount} | 有效通道数 1..16，默认与 ispflow 取色器数量一致；超出的通道恒等直出 |
| `CH_Enable[NUM_BANDS-1:0]` | 输入端口 | 每 bit 对应通道 Enable：1 启用，0 原始像素直出；仅 IMPL_MODE=1 时显示，LUT 模式隐藏全部段参数端口 |
''' : ''}
Vivado 定制界面（双击 IP → Customize IP）为分页 + 控件化界面（General /
Optimization，`xgui/${top}_v2_0.tcl`），`FOLD` 仅面积档可编辑。

## 支持节点与定点口径

- `multi_band_eq`（codegenMode=lut_fixed）：H 偏移 16 位补码 ROM + S/L 乘子
  Q14 定点 ROM，逐像素 3 查表 + 色环回绕（单次条件加减）+ 2 次整数乘加
  `(in*q+8192)>>14` 后钳位；与 C 侧 `bb_clamp_q14` 逐位一致。
- `multi_band_eq`（codegenMode=func_fixed）：运行期直算定点（**无 ROM 表**）
  ——每个取色器段一个独立 DSP 段运算单元（角距条件回绕 → x² 整数乘 →
  2^(−u) 整数部移位 + [0,1) 五次多项式 Q16 Horner 求 Q14 高斯权重）；
  **并联**时全部段单元并行展开后求和收尾，**串联**时段单元按段序流水线
  展开（每段一级流水）。**段参数为运行期输入端口**（见下节「段参数端口」），
  FPGA 运行中可动态调整——这是与 LUT 烘焙形态的本质区别。
  无除法器：h_q16 用 Mersenne 折叠（MAXV=2^PIX_BITS−1）精确替代整数除法，
  shift 换算用「右移后 ×ceil(2^33/360) 倒数乘」精确替代。
  与 Dart 参考 `applyMultiBandEqFx` 逐位一致（iverilog EXACT 对拍），与
  FP64 口径偏差 ≤1 LSB。

## 段参数端口（func_fixed，运行期可调）

每个取色器段 5 个 32 位输入端口（`par_b{i}_*`，i = 0..15），可接
AXI-Lite 寄存器或外部逻辑，运行中动态调整（建议帧间隙修改）。Vivado 按
`NUM_BANDS` 隐藏未使用段的端口并为其提供零值默认驱动：

| 端口 | 含义 | 换算（double → 端口值） |
|---|---|---|
| `par_b{i}_hc` | H 中心（无符号） | `round(h_度 × 2^16) mod (360×2^16)` |
| `par_b{i}_q` | Q 值（带宽系数，无符号） | `round(q / 45 × 2^20)` |
| `par_b{i}_dh` | 色相偏移（带符号） | `round(dh_度 × 2^16)` |
| `par_b{i}_s1` | S 增益偏移（带符号） | `round((s−1) × 2^14)` |
| `par_b{i}_l1` | L 增益偏移（带符号） | `round((l−1) × 2^14)` |

testbench 中的段参数 reg 初值即 ispflow 节点当前配置（同口径换算），
仿真中改写这些 reg 即可验证动态调参。

## 资源估算（粗估，随节点类型逐步细化）

| 项 | 估算 | 说明 |
|---|---|---|
| LUT ROM | ${est.romBits} bit（≈${est.bram36k} 块 36K BRAM） | ${plan.implMode == 1 ? 'func_fixed 无 ROM 表（运行期直算）' : '3 张烘焙表（shift 16bit + S/L Q14 各 17bit）× 深度 2^PIX_BITS'} |
| DSP | ≈${est.estDsps} | ${plan.implMode == 1 ? '每段一个段运算单元（权重链 8 乘 + 段贡献 3 乘，串联另含乘性合成 2 乘）+ shift 倒数乘 + S/L 施加 2 乘' : 'S/L 两个 Q14 定点乘法器'}；性能档推断 DSP48，平衡/面积档绑 LUT |
| 逻辑 LUT | ≈${est.estLuts} | 数据通路 + 握手 + ${plan.implMode == 1 ? '段单元组合逻辑' : '表取数'}（乘法器绑 LUT 时含其估算） |
| 延迟 | ${est.latencyCycles} 拍 | ${plan.implMode == 1 ? (plan.fxSerial ? '串联：16×(1+DSP_PIPE)+4 拍流水；DSP_PIPE=3 时 889 拍（固定16段全流水）' : '并联/单段：5+DSP_PIPE 拍流水；DSP_PIPE=3 时 89 拍（全流水）') : '点操作编组：1 拍流水（无行缓冲）'} |
| 吞吐 | ${est.throughputPxPerClk} px/clk | II=1 |

## 一键仿真

激励参数（应用内「仿真激励参数」对话框指定，随 tb/golden 一并烘焙）：
帧 ${stim.width}×${stim.height} × ${stim.frames} 帧，帧间隔 ${stim.frameGapCycles} 拍，
图案 ${stim.pattern.displayName}，
种子 0x${(stim.seed & 0xFFFFFFFF).toRadixString(16).padLeft(8, '0')}，
输入气泡率 ${stim.inGapPct}%，输出背压率 ${stim.outStallPct}%。

```
iverilog -g2012 -o tb.vvp tb_$top.v ${top}_core.v ${top}_top.v
vvp tb.vvp
# 输出 PASS/FAIL（EXACT 逐位 FNV-1a 对拍）
```

## 导入说明（${v.displayName}）

${v.importNote}
${v.isVivado ? '''
### 演示工程（demo/，一键建完整 Vivado 工程）

```
# 在 demo/ 目录：Tools → Run Tcl Script 选 create_demo_project.tcl
#（或 vivado -mode batch -source create_demo_project.tcl）
```
自动完成：打包 IP（幂等）→ 建 `<project_name>/<project_name>.xpr` 工程（器件与导出
系列一致）→ 例化 IP（Component Name 为 `$top`）→ 综合顶层 `demo_top`（像素流直进直出，
段参数烘焙为 ispflow 快照常量）+ 行为仿真顶层 `tb_$top`（读
`golden_in.hex` 对拍 `golden_hash.txt`，输出 PASS/FAIL）。
板级引脚请直接在 Vivado 的 I/O Planning 中分配，可设置 PACKAGE_PIN、
IOSTANDARD、驱动、斜率、上下拉与端接等完整选项。若将约束保存为
`demo/pins.xdc`，建工程脚本会自动加入 `constrs_1`。未分配前的
NSTD-1 / UCIO-1 仅表示尚未做板级引脚配置。
''' : ''}
${_simReadmeSection()}
## v2.0：func_fixed 支持 NUM_BANDS(1..16) 与 CH_Enable[NUM_BANDS-1:0] 输入端口（1 启用、0 原始像素直出）；lut_fixed 保持 v1 查表通路。
''';
}

// ---------------------------------------------------------------------------
// golden 计算（Dart 侧，与 RTL 逐位一致）
// ---------------------------------------------------------------------------

List<int> _fixedGoldenNode(IspNode node, List<int> channels, int maxValue) {
  if (node.paramValues['bypass'] == true) return channels;
  if (node.typeId == 'color_temp_adjuster') {
    final gains = colorTempGains(
      (node.paramValues['temperature'] as num?)?.toDouble() ?? 6500,
      (node.paramValues['measured_cct'] as num?)?.toInt() ?? 0,
    );
    return [
      for (var c = 0; c < 3; c++)
        _clampQ14(channels[c], (gains[c] * 16384).round(), maxValue),
    ];
  }
  return cscFixedPixel(
    node.typeId,
    channels[0],
    channels[1],
    channels[2],
    maxValue,
    standard:
        '${node.paramValues['standard'] ??
            (_yuvMatrixTypes.contains(node.typeId) ? 'bt2020' : 'bt601')}',
    range: '${node.paramValues['range'] ?? 'full'}',
  );
}

/// 生成 golden 输入激励帧 + 期望输出 FNV-1a（EXACT 模式）。输入 3 通道
/// 打包 {H,S,L}，逐帧逐像素由 [IpStimulusGen] 按激励参数（图案/尺寸/
/// 帧数/种子）产出；默认参数下与历史 LCG 序列逐位一致。
(String, int, List<int>) _buildGolden(
  IpPlan plan,
  IspGraph graph,
  IspNodeGroup group,
  IpSimStimulus stim, {
  int? numBands,
  int bypassMask = 0,
  bool ctRuntimeEnabled = true,
}) {
  final mv = plan.maxValue;
  final pb = plan.pixBits;
  if (plan.fxBandCount == 0) {
    return _buildFixedGolden(plan, stim, ctRuntimeEnabled: ctRuntimeEnabled);
  }
  final activeCount = numBands ?? kIpMaxBands;
  var allBypass = plan.implMode == 1;

  // 烘焙三表（与 core 同一份）。
  // v1 仅 multi_band_eq。
  Int32List shiftLut = Int32List(0);
  Int32List sQ14 = Int32List(0);
  Int32List lQ14 = Int32List(0);
  var fxActive = false, fxSerial = false;
  List<MbFxBand> fxBands = const [];
  for (final id in plan.cPlan.topo) {
    final n = plan.cPlan.members[id]!;
    if (n.typeId == 'multi_band_eq') {
      final parsed = multiBandEqBands(n);
      final enabled = [
        for (var i = 0; i < parsed.bands.length; i++)
          if (i < activeCount && ((bypassMask >> i) & 1) == 0) parsed.bands[i],
      ];
      allBypass = allBypass && enabled.isEmpty;
      if (plan.implMode == 1) {
        // func_fixed：golden 直接走 Dart 定点参考（与 RTL 流水逐位一致）。
        fxActive = true;
        fxSerial = parsed.serial;
        fxBands = [
          for (final b in enabled)
            multiBandFxBandConst(h: b.h, q: b.q, dh: b.dh, s: b.s, l: b.l),
        ];
        continue;
      }
      final (sl, sm, lm) = multiBandLuts(
        enabled,
        serial: parsed.serial,
        maxValue: mv,
      );
      shiftLut = sl;
      sQ14 = Int32List.fromList([for (final v in sm) (v * 16384.0).round()]);
      lQ14 = Int32List.fromList([for (final v in lm) (v * 16384.0).round()]);
    }
  }

  final eqIndex = plan.cPlan.topo.indexWhere(
    (id) => plan.cPlan.members[id]!.typeId == 'multi_band_eq',
  );
  final gen = IpStimulusGen(stim, mv);
  final outBytes = <int>[];
  final hexDigits = ((3 * pb + 3) ~/ 4);
  final inLines = StringBuffer();
  for (var f = 0; f < stim.frames; f++) {
    for (var y = 0; y < stim.height; y++) {
      for (var x = 0; x < stim.width; x++) {
        var (h, s, l) = gen.next(x, y);
        final word = (h << (2 * pb)) | (s << pb) | l;
        for (final id in plan.cPlan.topo.take(eqIndex)) {
          final converted = _fixedGoldenNode(plan.cPlan.members[id]!, [
            h,
            s,
            l,
          ], mv);
          h = converted[0];
          s = converted[1];
          l = converted[2];
        }
        inLines.writeln(word.toRadixString(16).padLeft(hexDigits, '0'));

        // 期望输出（与 core 组合逻辑同口径）。
        final hv = h > mv ? mv : h;
        final int hnew, os, ol;
        if (allBypass) {
          hnew = hv;
          os = s;
          ol = l;
        } else if (fxActive) {
          final (shift, sq, lq) = multiBandComposeFx(
            hv,
            mv,
            fxBands,
            serial: fxSerial,
          );
          var hn = hv + shift;
          if (hn > mv) {
            hn -= (mv + 1);
          } else if (hn < 0) {
            hn += (mv + 1);
          }
          hnew = hn;
          os = _clampQ14(s, sq, mv);
          ol = _clampQ14(l, lq, mv);
        } else {
          final shift = shiftLut[hv];
          var hn = hv + shift;
          if (hn > mv) {
            hn -= (mv + 1);
          } else if (hn < 0) {
            hn += (mv + 1);
          }
          hnew = hn;
          os = _clampQ14(s, sQ14[hv], mv);
          ol = _clampQ14(l, lQ14[hv], mv);
        }
        var output = [hnew, os, ol];
        for (final id in plan.cPlan.topo.skip(eqIndex + 1)) {
          output = _fixedGoldenNode(plan.cPlan.members[id]!, output, mv);
        }
        for (final c in output) {
          outBytes.add(c & 0xFF);
          outBytes.add((c >> 8) & 0xFF);
        }
      }
    }
  }
  return (inLines.toString(), fnv1a32(outBytes), const <int>[]);
}

(String, int, List<int>) _buildFixedGolden(IpPlan plan, IpSimStimulus stim,
    {bool ctRuntimeEnabled = true}) {
  final mv = plan.maxValue;
  final pb = plan.pixBits;
  final gen = IpStimulusGen(stim, mv);
  final outBytes = <int>[];
  final hexDigits = (3 * pb + 3) ~/ 4;
  final inLines = StringBuffer();
  // 运行期色温控制（单色温节点 IP）：逐帧增益来自 14 位目标端口 +
  // 最近一次测量，测量又来自输入帧累加和——口径与 RTL 的时序一致：
  // 第 k 帧的增益用 measure(第 k-2 帧)（片上无帧缓存，测量滞后两帧收敛）。
  final ctRuntime = _ctRuntimePlan(plan, enabled: ctRuntimeEnabled);
  final ctTables = ctRuntime ? CtWhiteTables() : null;
  var ctMeasReg = 6500;
  final ctFrameMeas = <int?>[];
  final ctExpected = <int>[];
  for (var f = 0; f < stim.frames; f++) {
    var ctGains = const [16384, 16384, 16384];
    var ctSumR = 0, ctSumG = 0, ctSumB = 0;
    if (ctRuntime) {
      // 帧起始：cct_out（= 上一次有效测量）此刻仍是旧值，tb 会在同一时刻
      // 把它按 fnv_u16 的 2 字节小端并入哈希，golden 这里同步追加。
      ctExpected.add(ctMeasReg);
      outBytes.add(ctMeasReg & 0xFF);
      outBytes.add((ctMeasReg >> 8) & 0xFF);
      ctGains = ctGainsQ14(
        kCtTbTargetKelvin,
        ctMeasReg,
        tables: ctTables,
      );
    }
    for (var y = 0; y < stim.height; y++) {
      for (var x = 0; x < stim.width; x++) {
        final pixel = gen.next(x, y);
        final word = (pixel.$1 << (2 * pb)) | (pixel.$2 << pb) | pixel.$3;
        inLines.writeln(word.toRadixString(16).padLeft(hexDigits, '0'));
        var channels = [pixel.$1, pixel.$2, pixel.$3];
        if (ctRuntime) {
          // 测量口径：对**输入**像素累加（IP 的统计累加器挂在模块入口）。
          ctSumR += channels[0];
          ctSumG += channels[1];
          ctSumB += channels[2];
        }
        for (final id in plan.cPlan.topo) {
          final node = plan.cPlan.members[id]!;
          if (node.paramValues['bypass'] == true) continue;
          if (node.typeId == 'color_temp_adjuster') {
            final gains = ctRuntime
                ? ctGains
                : [
                    for (final g in colorTempGains(
                      (node.paramValues['temperature'] as num?)?.toDouble() ??
                          6500,
                      (node.paramValues['measured_cct'] as num?)?.toInt() ?? 0,
                    ))
                      (g * 16384).round(),
                  ];
            channels = [
              for (var c = 0; c < 3; c++)
                _clampQ14(channels[c], gains[c], mv),
            ];
          } else {
            channels = cscFixedPixel(
              node.typeId,
              channels[0],
              channels[1],
              channels[2],
              mv,
              standard: effectiveYuvStandard(
                plan.options.yuvStandard,
                '${node.paramValues['standard'] ??
                    (_yuvMatrixTypes.contains(node.typeId)
                        ? 'bt2020'
                        : 'bt601')}',
              ),
              range: '${node.paramValues['range'] ?? 'full'}',
            );
          }
        }
        for (final c in channels) {
          outBytes.add(c & 0xFF);
          outBytes.add((c >> 8) & 0xFF);
        }
      }
    }
    if (ctRuntime) {
      ctFrameMeas.add(ctMeasureCct(ctSumR, ctSumG, ctSumB));
      // RTL：帧 k 起始的 FSM 用第 k-1 帧累加和，结果在帧 k 内落地，
      // 供帧 k+1 起始时的增益使用。
      if (f >= 1) {
        final m = ctFrameMeas[f - 1];
        if (m != null) ctMeasReg = m;
      }
    }
  }
  return (inLines.toString(), fnv1a32(outBytes), ctExpected);
}

int _clampQ14(int v, int q, int maxValue) {
  var r = (v * q + 8192) >> 14;
  if (r < 0) r = 0;
  if (r > maxValue) r = maxValue;
  return r;
}

Map<String, String> _buildMultiNodeIpFiles(
  IspGraph graph,
  IspNodeGroup group,
  IpGenOptions options, {
  IpSimStimulus? stimulus,
  int? numBands,
  int bypassMask = 0,
  IpBuildProgress? onProgress,
}) {
  final stim = stimulus ?? const IpSimStimulus();
  final plan = planGroupIp(graph, group, options);
  final top = plan.topName;
  final files = <String, String>{};
  final nodePlans = <String, IpPlan>{};
  for (var index = 0; index < plan.cPlan.topo.length; index++) {
    final id = plan.cPlan.topo[index];
    final ident = plan.cPlan.idents[id]!;
    final nodeGroup = IspNodeGroup('ip_$ident', {id}, name: 'ip_$ident');
    final nodeFiles = buildGroupIpFiles(
      graph,
      nodeGroup,
      options,
      stimulus: stim,
      numBands: numBands,
      bypassMask: bypassMask,
      ctRuntimeEnabled: false,
      onProgress: (stage, progress) => onProgress?.call(
        '节点 $ident：$stage',
        (index + progress * 0.8) / plan.cPlan.topo.length,
      ),
    );
    nodePlans[id] = planGroupIp(graph, nodeGroup, options);
    for (final entry in nodeFiles.entries) {
      if (entry.key.startsWith('demo/')) continue;
      files['$ident/${entry.key}'] = entry.value;
    }
  }
  onProgress?.call('生成整链互连与 golden 数据', 0.85);
  final (goldenIn, goldenHash, ctExpected) = _buildGolden(
    plan,
    graph,
    group,
    stim,
    numBands: numBands,
    bypassMask: bypassMask,
    // 多节点编组的逐节点 IP 关闭了色温运行期端口（互连顶层没有唯一的
    // 14 位控制/测量端口），整链 golden 必须用同一口径（烘焙增益）。
    ctRuntimeEnabled: false,
  );
  files['${top}_top.v'] = _multiInterconnectV(plan, nodePlans, false);
  files['tb_$top.v'] = _tbV(
    plan,
    goldenHash,
    stim,
    drainCycles: plan.resources.latencyCycles + 8,
    dutName: '${top}_top',
  );
  files['golden_in.hex'] = goldenIn;
  files['golden_hash.txt'] =
      '0x${goldenHash.toRadixString(16).padLeft(8, '0')}\n';
  files['README.md'] = _multiReadme(plan, nodePlans);
  if (options.vendor.isVivado) {
    files['demo/demo_top.v'] = _multiInterconnectV(plan, nodePlans, true);
    files['demo/tb_demo.v'] = _tbV(
      plan,
      goldenHash,
      stim,
      drainCycles: plan.resources.latencyCycles + 8,
      dutName: 'demo_top',
    );
    files['demo/timing.xdc'] = _timingXdc(plan);
    files['demo/clock_route.tcl'] = _clockRouteTcl();
    files['demo/create_demo_project.tcl'] = _multiDemoProjectTcl(
      plan,
      nodePlans,
    );
  }
  final entries = files.entries.toList();
  for (var i = 0; i < entries.length; i++) {
    final entry = entries[i];
    if (entry.key.endsWith('.v')) {
      files[entry.key] = formatVerilogSource(entry.value);
    }
    onProgress?.call(
      '格式化 ${entry.key}',
      0.90 + 0.09 * (i + 1) / entries.length,
    );
  }
  onProgress?.call('IP 包生成完成', 1.0);
  return files;
}

Map<String, String> _multiComponentNames(
  IpPlan plan,
  Map<String, IpPlan> nodePlans,
) {
  final names = <String, String>{};
  final counts = <String, int>{};
  for (final id in plan.cPlan.topo) {
    final base = nodePlans[id]!.topName;
    final count = (counts[base] ?? 0) + 1;
    counts[base] = count;
    names[id] = count == 1 ? base : '${base}_$count';
  }
  return names;
}

String _multiInterconnectV(
  IpPlan plan,
  Map<String, IpPlan> nodePlans,
  bool packaged,
) {
  final componentNames = _multiComponentNames(plan, nodePlans);
  final pb = plan.pixBits;
  final bw = 3 * pb;
  final ids = plan.cPlan.topo;
  final b = StringBuffer();
  for (var i = 0; i + 1 < ids.length; i++) {
    b.writeln(
      '  wire link${i}_valid, link${i}_ready, link${i}_sof, link${i}_eol;',
    );
    b.writeln('  wire [$bw-1:0] link${i}_data;');
  }
  for (final id in ids) {
    final nodePlan = nodePlans[id]!;
    if (nodePlan.fxBandCount == 0) continue;
    final parsed = multiBandEqBands(plan.cPlan.members[id]!);
    final ident = plan.cPlan.idents[id]!;
    b.writeln(
      '  wire [${parsed.bands.length - 1}:0] ${ident}_ch_enable = '
      '{${parsed.bands.length}{1\'b1}};',
    );
    final exposedBands = packaged ? parsed.bands.length : kIpMaxBands;
    for (var i = 0; i < exposedBands; i++) {
      final band = i < parsed.bands.length
          ? parsed.bands[i]
          : (h: 0.0, q: 2.0, dh: 0.0, s: 1.0, l: 1.0);
      final fx = multiBandFxBandConst(
        h: band.h,
        q: band.q,
        dh: band.dh,
        s: band.s,
        l: band.l,
      );
      final ports = fxBandPorts(i);
      b.writeln('  wire [31:0] ${ident}_${ports.hc} = 32\'d${fx.hcQ16};');
      b.writeln('  wire [31:0] ${ident}_${ports.q} = 32\'d${fx.kQ20};');
      b.writeln(
        '  wire signed [31:0] ${ident}_${ports.dh} = ${_sd32(fx.dhQ16)};',
      );
      b.writeln(
        '  wire signed [31:0] ${ident}_${ports.s1} = ${_sd32(fx.s1Q14)};',
      );
      b.writeln(
        '  wire signed [31:0] ${ident}_${ports.l1} = ${_sd32(fx.l1Q14)};',
      );
    }
  }
  for (var i = 0; i < ids.length; i++) {
    final id = ids[i];
    final ident = plan.cPlan.idents[id]!;
    final nodePlan = nodePlans[id]!;
    final module = packaged ? componentNames[id]! : '${nodePlan.topName}_top';
    final inputData = i == 0 ? 's_axis_tdata' : 'link${i - 1}_data';
    final inputValid = i == 0 ? 's_axis_tvalid' : 'link${i - 1}_valid';
    final inputReady = i == 0 ? 's_axis_tready' : 'link${i - 1}_ready';
    final inputSof = i == 0 ? 's_axis_tuser' : 'link${i - 1}_sof';
    final inputEol = i == 0 ? 's_axis_tlast' : 'link${i - 1}_eol';
    final last = i + 1 == ids.length;
    final outputData = last ? 'm_axis_tdata' : 'link${i}_data';
    final outputValid = last ? 'm_axis_tvalid' : 'link${i}_valid';
    final outputReady = last ? 'm_axis_tready' : 'link${i}_ready';
    final outputSof = last ? 'm_axis_tuser' : 'link${i}_sof';
    final outputEol = last ? 'm_axis_tlast' : 'link${i}_eol';
    b.writeln('  $module u_$ident (');
    if (packaged) {
      b.writeln('      .aclk(aclk_int), .aresetn(aresetn),');
      b.writeln('      .s_axis_tdata($inputData),');
      b.writeln('      .s_axis_tvalid($inputValid),');
      b.writeln('      .s_axis_tready($inputReady),');
      b.writeln('      .s_axis_tuser($inputSof), .s_axis_tlast($inputEol),');
      b.writeln('      .m_axis_tdata($outputData),');
      b.writeln('      .m_axis_tvalid($outputValid),');
      b.writeln('      .m_axis_tready($outputReady),');
      b.writeln('      .m_axis_tuser($outputSof), .m_axis_tlast($outputEol)');
    } else {
      b.writeln('      .clk(aclk), .rst_n(aresetn),');
      b.writeln('      .in_data($inputData), .in_valid($inputValid),');
      b.writeln('      .in_ready($inputReady),');
      b.writeln('      .in_sof($inputSof), .in_eol($inputEol),');
      b.writeln('      .out_data($outputData), .out_valid($outputValid),');
      b.writeln('      .out_ready($outputReady),');
      b.writeln('      .out_sof($outputSof), .out_eol($outputEol)');
    }
    if (nodePlan.fxBandCount > 0) {
      b.writeln('      , .CH_Enable(${ident}_ch_enable)');
      final exposedBands = packaged ? nodePlan.fxBandCount : kIpMaxBands;
      for (var band = 0; band < exposedBands; band++) {
        final ports = fxBandPorts(band);
        for (final port in [ports.hc, ports.q, ports.dh, ports.s1, ports.l1]) {
          b.writeln('      , .$port(${ident}_$port)');
        }
      }
    }
    b.writeln('  );');
  }
  return '''
// Interconnect only: every graph node is an independent IP instance.
// No graph-level processing core is generated or packaged.
`timescale 1ns/1ps
module ${packaged ? 'demo_top' : '${plan.topName}_top'} (
    input wire aclk, input wire aresetn,
    input wire [$bw-1:0] s_axis_tdata,
    input wire s_axis_tvalid, output wire s_axis_tready,
    input wire s_axis_tuser, input wire s_axis_tlast,
    output wire [$bw-1:0] m_axis_tdata,
    output wire m_axis_tvalid, input wire m_axis_tready,
    output wire m_axis_tuser, output wire m_axis_tlast
);
${packaged ? _clockBufferV() : ''}$b
endmodule
''';
}

/// 各 README 共用的「仿真」章节：三种仿真模式的实测耗时，以及 post-route 时序
/// 仿真在这类网表上的已知问题（Vivado 2020.2 的 XSim 加载极慢且 Cancel 无效）。
String _simReadmeSection() => '''

## 仿真

`sim_1` 已配好 testbench：读 `golden_in.hex`，逐像素 FNV-1a 对拍并在控制台打印
`PASS/FAIL`（`xsim.simulate.runtime` 设为 100us，tb 用 `\$finish` 提前结束）。

| 仿真模式 | 验证对象 | 本机实测（xczu15eg，3 节点 demo） |
|---|---|---|
| Behavioral | RTL 源文件 | 约 15 s |
| Post-Synthesis Functional | 综合后网表（含原语） | 约 2.5 min |
| Post-Implementation Functional | 布线后网表 | 约 2.5 min |
| Post-Implementation Timing | 带 SDF 时序反标注 | 不可用，见下 |

**Post-Implementation Timing 的已知问题**：Vivado 2020.2 的 XSim 加载这份布线后
时序网表（约 1.5 万单元、158 个 DSP48E2、近 1 GB snapshot）时，实测 45 min 仍停在
`Vivado Simulator v2020.2.2` 之后没有任何输出，GUI 的 Cancel 也不生效——必须在任务
管理器结束 `xsimk.exe` 才能退出。功能/连接性验证请用上面三档 Functional 模式；
时序收敛由 `report_timing_summary` 保证（本 demo WNS 约 +15 ns）。

tb 自身用 `+NOVCD` 关闭 `wave.vcd` 转储（工程已通过
`XSIM.SIMULATE.XSIM.MORE_OPTIONS` 传入该参数），Vivado 波形窗口按需加信号即可；
需要 VCD（应用内「仿真波形」页）时去掉该参数。
''';

String _multiReadme(IpPlan plan, Map<String, IpPlan> nodePlans) {
  final lines = [
    for (final id in plan.cPlan.topo)
      '- `${plan.cPlan.idents[id]}/`：${plan.cPlan.members[id]!.name}，独立 IP（${nodePlans[id]!.topName}）。',
  ];
  return '''
# ${plan.topName} 多节点 IP 工程

每个节点生成独立 IP；根目录不再生成或打包图级合并 IP。

${lines.join('\n')}

- `demo/demo_top.v`：仅实例化并连接上述独立 IP。
- `demo/create_demo_project.tcl`：逐节点打包、加入 IP 仓库并创建互连工程。
- 根目录 testbench 使用同一连接关系执行整链 golden 对拍。
${_simReadmeSection()}
''';
}

String _multiDemoProjectTcl(IpPlan plan, Map<String, IpPlan> nodePlans) {
  final ids = plan.cPlan.topo;
  final componentNames = _multiComponentNames(plan, nodePlans);
  final b = StringBuffer();
  b.writeln('''
# Multi-node Vivado demo: package each node as an independent IP, then
# instantiate and connect those IPs in demo_top. No merged graph IP is used.
set demoDir [file dirname [file normalize [info script]]]
cd \$demoDir
set pkgDir [file dirname \$demoDir]
''');
  for (final id in ids) {
    final ident = plan.cPlan.idents[id]!;
    b.writeln('''
# Package $ident independently.
if {![file exists \$pkgDir/$ident/ip_repo/component.xml] ||
    [file mtime \$pkgDir/$ident/package_ip.tcl] > [file mtime \$pkgDir/$ident/ip_repo/component.xml]} {
  set _savedCwd [pwd]
  source \$pkgDir/$ident/package_ip.tcl
  cd \$_savedCwd
}
''');
  }
  b.writeln(
    'create_project -force ${plan.options.projectName} ./${plan.options.projectName} -part ${plan.options.vivadoPart}',
  );
  b.writeln('config_ip_cache -disable');
  b.writeln('set_msg_config -id {Synth 8-5409} -new_severity INFO');
  b.writeln('set_msg_config -id {Synth 8-3330} -new_severity INFO');
  b.writeln('set_msg_config -id {Synth 8-3332} -new_severity INFO');
  b.writeln('set_msg_config -id {Synth 8-3936} -new_severity INFO');
  b.writeln('set_msg_config -id {Synth 8-6014} -new_severity INFO');
  b.writeln('set_msg_config -id {Synth 8-7129} -new_severity INFO');
  b.writeln('set_property ip_repo_paths [list \\');
  for (final id in ids) {
    b.writeln('    \$pkgDir/${plan.cPlan.idents[id]!}/ip_repo \\');
  }
  b.writeln('] [current_project]');
  b.writeln('update_ip_catalog');
  for (final id in ids) {
    final nodePlan = nodePlans[id]!;
    final instance = componentNames[id]!;
    b.writeln('''
create_ip -name ${nodePlan.topName} -vendor debugtoolset -library isp -module_name $instance
set_property CONFIG.PIX_BITS {${nodePlan.pixBits}} [get_ips $instance]
set_property CONFIG.MAX_WIDTH {${nodePlan.options.maxWidth}} [get_ips $instance]
set_property CONFIG.GSTRATEGY {${nodePlan.options.gstrategy}} [get_ips $instance]
set_property CONFIG.FOLD {${nodePlan.options.fold}} [get_ips $instance]
set_property CONFIG.DSP_PIPE {${nodePlan.options.dspPipe}} [get_ips $instance]
${_hasYuvMatrix(nodePlan) ? 'set_property CONFIG.YUV_STANDARD {${yuvStandardCode(_effectiveYuvStandard(nodePlan))}} [get_ips $instance]\n' : ''}${nodePlan.fxBandCount > 0 ? 'set_property CONFIG.IMPL_MODE {${nodePlan.implMode}} [get_ips $instance]\nset_property CONFIG.WORK_MODE {${nodePlan.fxSerial ? 1 : 0}} [get_ips $instance]\nset_property CONFIG.NUM_BANDS {${nodePlan.fxBandCount}} [get_ips $instance]' : ''}
generate_target all [get_ips $instance]
create_ip_run [get_ips $instance]
catch {set_property strategy Flow_PerfOptimized_high [get_runs ${instance}_synth_1]}
''');
  }
  b.writeln('''
set_property strategy Flow_PerfOptimized_high [get_runs synth_1]
# Same impl strategy as the single-IP demo: the default flow requests
# place_design -ultrathreads, which Vivado only supports on multi-SLR parts and
# therefore reports [Vivado_Tcl 4-1400] here. Performance_Explore is clean.
set_property strategy Performance_Explore [get_runs impl_1]
add_files -norecurse [list \$demoDir/demo_top.v]
add_files -fileset constrs_1 -norecurse [list \$demoDir/timing.xdc]
if {[file exists \$demoDir/pins.xdc]} {
  add_files -fileset constrs_1 -norecurse [list \$demoDir/pins.xdc]
} else {
  add_files -fileset utils_1 -norecurse [list \$demoDir/clock_route.tcl]
  set clockRouteTcl [file normalize \$demoDir/clock_route.tcl]
  set_property STEPS.OPT_DESIGN.TCL.PRE \$clockRouteTcl [get_runs impl_1]
}
add_files -fileset sim_1 -norecurse [list \$demoDir/tb_demo.v \$pkgDir/golden_in.hex]
set_property file_type SystemVerilog [get_files \$demoDir/demo_top.v]
set_property file_type SystemVerilog [get_files \$demoDir/tb_demo.v]
set_property top demo_top [current_fileset]
set_property top tb_${plan.topName} [get_filesets sim_1]
set_property -name {xsim.simulate.runtime} -value {100us} -objects [get_filesets sim_1]
# Skip the testbench's own VCD dump under Vivado: the XSim wave window already
# records what is needed, and dumping a flattened post-route timing netlist
# (tens of thousands of nets) makes the run crawl.
set_property -name {xsim.simulate.xsim.more_options} -value {-testplusarg NOVCD} -objects [get_filesets sim_1]
update_compile_order -fileset sources_1
update_compile_order -fileset sim_1
puts "Demo project generated: ./${plan.options.projectName}/${plan.options.projectName}.xpr"
''');
  return b.toString();
}
