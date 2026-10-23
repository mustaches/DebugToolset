/// ISP 编组「生成Verilog IP」的发射层与写盘：把 IpPlan 组装为 Verilog IP
/// 包文件集（核心/顶层/厂商封装/testbench/golden/tcl/README）。对应
/// group_c_export_bb.dart 的角色；plan → emit 两段式。
library;

import 'dart:io';
import 'dart:typed_data';

import '../models/isp_graph.dart';
import '../pipeline/isp_kernels.dart';
import 'ip_gen_plan.dart';
import 'ip_stimulus.dart';
import 'ip_target.dart';
import 'node_v_stream.dart';

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
/// 此处保留为默认值（`IpSimStimulus()` 默认构造同值：64×8×6 帧）。
const int kIpSimW = 64;
const int kIpSimH = 8;
const int kIpSimFrames = 6;

/// 内存生成 Verilog IP 包文件集：文件名 → 内容（键顺序即写盘顺序）。
/// [stimulus] 为一键仿真激励参数（帧尺寸/帧数/图案/种子/握手压力率），
/// 仅影响 tb/golden 生成物；null 取默认（与历史固定行为一致）。
Map<String, String> buildGroupIpFiles(
    IspGraph graph, IspNodeGroup group, IpGenOptions options,
    {IpSimStimulus? stimulus}) {
  final stim = stimulus ?? const IpSimStimulus();
  final plan = planGroupIp(graph, group, options);
  final top = plan.topName;
  final pb = plan.pixBits;
  final mv = plan.maxValue;

  // ---- 逐节点烘焙表与数据通路（v1 仅 multi_band_eq）----
  // 每节点片段收集到 roms / datapath；单节点形态直接拼进 core。
  final roms = StringBuffer();
  final datapath = StringBuffer();
  for (final id in plan.cPlan.topo) {
    final n = plan.cPlan.members[id]!;
    if (n.typeId == 'multi_band_eq') {
      final ident = plan.cPlan.idents[id]!;
      final parsed = multiBandEqBands(n);
      final (shiftLut, sMulLut, lMulLut) =
          multiBandLuts(parsed.bands, serial: parsed.serial, maxValue: mv);
      final sQ14 = [for (final v in sMulLut) (v * 16384.0).round()];
      final lQ14 = [for (final v in lMulLut) (v * 16384.0).round()];
      roms
        ..writeln(vRomSigned16('${ident}_shift_lut', shiftLut,
            comment: 'H 偏移表（16 位补码，|shift| ≤ MAXV/2）'))
        ..writeln(vRomU17('${ident}_s_mul_q14', sQ14,
            comment: 'S 乘子 Q14 定点表（0..81920）'))
        ..writeln(vRomU17('${ident}_l_mul_q14', lQ14,
            comment: 'L 乘子 Q14 定点表'));
      datapath.write(emitMultiBandEqDatapath(ident, pb));
    }
  }

  // ---- golden：输入激励帧 + 期望 FNV-1a（图案/尺寸/帧数由 stim 决定）----
  final (goldenIn, goldenHash) = _buildGolden(plan, graph, group, stim);

  final files = <String, String>{
    '${top}_core.v': _coreV(plan, roms.toString(), datapath.toString()),
    '${top}_top.v': _topV(plan),
    'tb_$top.v': _tbV(plan, goldenHash, stim),
    'golden_in.hex': goldenIn,
    'golden_hash.txt': '0x${goldenHash.toRadixString(16).padLeft(8, '0')}\n',
    'README.md': _readme(plan, stim),
  };
  if (options.vendor.isVivado) {
    files['${top}_axis.v'] = _axisV(plan);
    files['package_ip.tcl'] = _packageIpTcl(plan);
    // 定制界面（xgui）：打包时由 package_ip.tcl 拷入组件目录。
    files['xgui/${top}_v1_0.tcl'] = _xguiTcl(plan);
  } else if (options.vendor.isLibero) {
    files['${top}_libero.v'] = _liberoV(plan);
  }
  return files;
}

/// 写盘 IP 包到 [dir]（创建目录），返回已写文件路径列表。
/// 键可带子目录（如 xgui/xxx.tcl），父目录自动创建。
Future<List<String>> exportGroupIpPackage(
    Map<String, String> files, String dir) async {
  await Directory(dir).create(recursive: true);
  final out = <String>[];
  for (final e in files.entries) {
    final p = '$dir${Platform.pathSeparator}${e.key}';
    // 键含子目录（xgui/）：先建父目录。
    await File(p).parent.create(recursive: true);
    await File(p).writeAsString(e.value);
    out.add(p);
  }
  return out;
}

// ---------------------------------------------------------------------------
// 内部：各文件模板
// ---------------------------------------------------------------------------

String _headerComment(IpPlan plan) {
  final v = plan.options.vendor;
  return '''
// 本文件由 DebugToolSet ISP Studio 自动生成（编组 → FPGA Verilog IP 包）。
// 目标厂商：${v.displayName}
// 像素位宽 PIX_BITS=${plan.pixBits}（MAXV=${plan.maxValue}）、LUT 域 0..${plan.maxValue}
''';
}

String _coreV(IpPlan plan, String roms, String datapath) {
  final top = plan.topName;
  final pb = plan.pixBits;
  final bw = 3 * pb;
  // v1 单节点形态：输出 = {H,S,L}（各通道来自该节点的组合数据通路）。
  final ident = plan.cPlan.idents[plan.cPlan.topo.single]!;
  final resConcat = '${ident}_res_h, ${ident}_res_s, ${ident}_res_l';
  return '''
${_headerComment(plan)}// 核心模块：通用像素流 in→out（带 ready 握手），节点参数已烘焙；
// 厂商封装（AXI4-Stream / Libero）只转接口不含逻辑。
`timescale 1ns/1ps
module ${top}_core #(
    parameter integer PIX_BITS  = $pb,
    parameter integer MAX_WIDTH = ${plan.options.maxWidth},
    // 优化策略预留（0 面积 / 1 平衡 / 2 性能）：当前白名单为点操作
    //（II=1 恒等），窗口算子落地后经 generate-if 分档生效。
    parameter integer GSTRATEGY = ${plan.options.gstrategy},
    parameter integer FOLD      = ${plan.options.fold}
) (
    input  wire                   clk,
    input  wire                   rst_n,
    // 像素流输入（{H, S, L} 打包，H 在最高位段）
    input  wire                   in_valid,
    output wire                   in_ready,
    input  wire                   in_sof,
    input  wire                   in_eol,
    input  wire [$bw-1:0]         in_data,
    // 像素流输出（同打包）
    output reg                    out_valid,
    input  wire                   out_ready,
    output reg                    out_sof,
    output reg                    out_eol,
    output reg  [$bw-1:0]         out_data
);
  localparam [$pb-1:0] MAXV = (1 << PIX_BITS) - 1;

  wire [$pb-1:0] in_h = in_data[$bw-1 -: $pb];
  wire [$pb-1:0] in_s = in_data[${2 * pb}-1 -: $pb];
  wire [$pb-1:0] in_l = in_data[$pb-1:0];

$roms
$datapath
  // ---- 单级流水（II=1，1 拍延迟；advance = 本拍锁存新像素）----
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
      // 无新像素且输出已被接收：清空 valid（否则 valid 卡高，输出重复计数）。
      out_valid <= 1'b0;
    end
  end
endmodule
''';
}

String _topV(IpPlan plan) {
  final top = plan.topName;
  final pb = plan.pixBits;
  final bw = 3 * pb;
  return '''
${_headerComment(plan)}// 顶层装配：VIN_TYPE=none（直通）时直接透传核心像素流端口。
`timescale 1ns/1ps
module ${top}_top #(
    parameter integer PIX_BITS  = $pb,
    parameter integer MAX_WIDTH = ${plan.options.maxWidth},
    parameter integer GSTRATEGY = ${plan.options.gstrategy},
    parameter integer FOLD      = ${plan.options.fold}
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
    output wire [$bw-1:0]         out_data
);
  ${top}_core #(
      .PIX_BITS(PIX_BITS),
      .MAX_WIDTH(MAX_WIDTH),
      .GSTRATEGY(GSTRATEGY),
      .FOLD(FOLD)
  ) u_core (
      .clk(clk), .rst_n(rst_n),
      .in_valid(in_valid), .in_ready(in_ready),
      .in_sof(in_sof), .in_eol(in_eol), .in_data(in_data),
      .out_valid(out_valid), .out_ready(out_ready),
      .out_sof(out_sof), .out_eol(out_eol), .out_data(out_data)
  );
endmodule
''';
}

String _axisV(IpPlan plan) {
  final top = plan.topName;
  final pb = plan.pixBits;
  final bw = 3 * pb;
  return '''
${_headerComment(plan)}// Vivado AXI4-Stream 封装：像素流 → AXI4-Stream（tuser=sof、
// tlast=eol）。仅转接口不含逻辑。
`timescale 1ns/1ps
module ${top}_axis #(
    parameter integer PIX_BITS  = $pb,
    parameter integer MAX_WIDTH = ${plan.options.maxWidth},
    parameter integer GSTRATEGY = ${plan.options.gstrategy},
    parameter integer FOLD      = ${plan.options.fold}
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
    output wire                   m_axis_tlast
);
  ${top}_core #(
      .PIX_BITS(PIX_BITS),
      .MAX_WIDTH(MAX_WIDTH),
      .GSTRATEGY(GSTRATEGY),
      .FOLD(FOLD)
  ) u_core (
      .clk(aclk), .rst_n(aresetn),
      .in_valid(s_axis_tvalid), .in_ready(s_axis_tready),
      .in_sof(s_axis_tuser), .in_eol(s_axis_tlast), .in_data(s_axis_tdata),
      .out_valid(m_axis_tvalid), .out_ready(m_axis_tready),
      .out_sof(m_axis_tuser), .out_eol(m_axis_tlast), .out_data(m_axis_tdata)
  );
endmodule
''';
}

String _liberoV(IpPlan plan) {
  final top = plan.topName;
  final pb = plan.pixBits;
  final bw = 3 * pb;
  return '''
${_headerComment(plan)}// Libero 裸流封装：valid/ready + sof/eol 直通（SmartDesign 中改
// generics 面板的 PIX_BITS/MAX_WIDTH）。
`timescale 1ns/1ps
module ${top}_libero #(
    parameter integer PIX_BITS  = $pb,
    parameter integer MAX_WIDTH = ${plan.options.maxWidth},
    parameter integer GSTRATEGY = ${plan.options.gstrategy},
    parameter integer FOLD      = ${plan.options.fold}
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
    output wire [$bw-1:0]         out_data
);
  ${top}_core #(
      .PIX_BITS(PIX_BITS),
      .MAX_WIDTH(MAX_WIDTH),
      .GSTRATEGY(GSTRATEGY),
      .FOLD(FOLD)
  ) u_core (
      .clk(clk), .rst_n(rst_n),
      .in_valid(in_valid), .in_ready(in_ready),
      .in_sof(in_sof), .in_eol(in_eol), .in_data(in_data),
      .out_valid(out_valid), .out_ready(out_ready),
      .out_sof(out_sof), .out_eol(out_eol), .out_data(out_data)
  );
endmodule
''';
}

String _tbV(IpPlan plan, int goldenHash, IpSimStimulus stim) {
  final top = plan.topName;
  final pb = plan.pixBits;
  final bw = 3 * pb;
  final hashHex = goldenHash.toRadixString(16).padLeft(8, '0');
  final seedHex = (stim.seed & 0xFFFFFFFF).toRadixString(16).padLeft(8, '0');
  return '''
// 一键仿真 testbench：读 golden_in.hex 喂核心 → 收集输出 → FNV-1a 对拍
// golden_hash.txt（期望值内嵌为 EXPECTED_HASH，EXACT 模式逐位一致）。
// 激励参数（应用内「仿真激励参数」对话框指定，重新生成可改）：
//   帧 ${stim.width}×${stim.height} × ${stim.frames} 帧，帧间隔 ${stim.frameGapCycles} 拍，
//   图案=${stim.pattern.displayName}，
//   种子=0x$seedHex，输入气泡率=${stim.inGapPct}%，输出背压率=${stim.outStallPct}%。
`timescale 1ns/1ps
module tb_$top;
  localparam integer PIX_BITS = $pb;
  localparam integer W  = ${stim.width};
  localparam integer H  = ${stim.height};
  localparam integer FRAMES = ${stim.frames};
  // 帧间隔（时钟周期数）：帧与帧之间插入的 in_valid 空闲拍数（0=连续）。
  localparam integer FRAME_GAP = ${stim.frameGapCycles};
  localparam integer N  = W * H * FRAMES;
  localparam [31:0] EXPECTED_HASH = 32'h$hashHex;
  // 握手压力（%）：输入气泡（in_valid 随机空闲拍）/ 输出背压（out_ready
  // 随机拉低）；0 = 恒满流/恒接收。随机序列由 SEED 派生，仿真可复现。
  localparam integer GAP_PCT   = ${stim.inGapPct};
  localparam integer STALL_PCT = ${stim.outStallPct};
  localparam [31:0] SEED = 32'h$seedHex;

  reg clk = 1'b0, rst_n = 1'b0;
  reg in_valid = 1'b0, in_sof = 1'b0, in_eol = 1'b0;
  reg [$bw-1:0] in_data = {$bw{1'b0}};
  reg out_ready = 1'b1;
  wire in_ready, out_valid, out_sof, out_eol;
  wire [$bw-1:0] out_data;

  ${top}_top #(.PIX_BITS(PIX_BITS), .MAX_WIDTH(${plan.options.maxWidth})) dut (
      .clk(clk), .rst_n(rst_n),
      .in_valid(in_valid), .in_ready(in_ready),
      .in_sof(in_sof), .in_eol(in_eol), .in_data(in_data),
      .out_valid(out_valid), .out_ready(out_ready),
      .out_sof(out_sof), .out_eol(out_eol), .out_data(out_data)
  );

  reg [$bw-1:0] mem [0:N-1];
  initial \$readmemh("golden_in.hex", mem);

  // 仿真状态变量必须先声明（iverilog 要求声明在使用之前）。
  reg [31:0] fnv;
  reg [31:0] rng_gap, rng_stall;
  integer i, f, got;

  // LCG（Numerical Recipes，32 位）：与 Dart 侧激励生成同一种子口径。
  function [31:0] lcg_next;
    input [31:0] s;
    lcg_next = s * 32'd1664525 + 32'd1013904223;
  endfunction

  // FNV-1a：对单个通道值（零扩到 16 位）按小端 2 字节更新。
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

  // 波形转储：vvp 运行产出 wave.vcd，由内嵌「仿真波形」标签页展示。
  initial begin
    \$dumpfile("wave.vcd");
    \$dumpvars(0, tb_$top);
  end

  ${stim.clkMHz == 100 ? '' : '// CLK 频率 ${fmtClkMHz(stim.clkMHz)} MHz（半周期 ${ipClkHalfNs(stim.clkMHz)} ns，timescale 1ns/1ps）\n  '}always #${ipClkHalfNs(stim.clkMHz)} clk = ~clk;

  // 输出背压：负沿按 STALL_PCT 随机拉低 out_ready（负沿更新，与正沿
  // 采样错开半拍，无竞争）。
  always @(negedge clk) begin
    if (!rst_n || STALL_PCT == 0) begin
      out_ready <= 1'b1;
    end else begin
      rng_stall = lcg_next(rng_stall);
      out_ready <= (((rng_stall >> 16) % 100) >= STALL_PCT);
    end
  end

  // 输出监控：仅在真实传输拍（out_valid & out_ready）计一次哈希。
  // always 块在正沿读到的是沿前旧值（NBA 尚未生效），背压保持的输出
  // 不会被重复计数。
  always @(posedge clk) begin
    if (rst_n && out_valid && out_ready) begin
      hash_pixel(out_data);
      got = got + 1;
    end
  end

  // 驱动全部在负沿切换、正沿只读 in_ready 沿前值：输入信号的修改与
  // 核心的正沿采样错开半拍，彻底避开「正沿后 active 区改 in_valid 与
  // 核心采样竞争丢像素」的经典竞争。
  initial begin
    rng_gap = SEED;
    rng_stall = SEED ^ 32'h9E3779B9;
    // 复位 2 拍。
    repeat (2) @(posedge clk);
    rst_n = 1'b1;
    @(negedge clk);

    fnv = 32'h811c9dc5;
    got = 0;
    // 逐帧逐像素喂入：sof=帧首像素、eol=行尾像素；帧间连续不停流。
    // 像素在负沿驱动、下一正沿被采样；正沿后读 in_ready 沿前值判断
    // 是否被接收，未接收则保持信号再等一拍（背压下不重发不错序）。
    for (f = 0; f < FRAMES; f = f + 1) begin
      for (i = 0; i < W * H; i = i + 1) begin
        in_valid = 1'b1;
        in_data  = mem[f * W * H + i];
        in_sof   = (i == 0);
        in_eol   = (i % W == W - 1);
        @(posedge clk);
        while (!in_ready) @(posedge clk);
        @(negedge clk);
        // 输入气泡：按 GAP_PCT 概率插入 1 拍空闲。
        if (GAP_PCT > 0) begin
          rng_gap = lcg_next(rng_gap);
          if (((rng_gap >> 16) % 100) < GAP_PCT) begin
            in_valid = 1'b0; in_sof = 1'b0; in_eol = 1'b0;
            @(negedge clk);
          end
        end
      end
      // 帧间隔：帧末像素接收后插入 FRAME_GAP 拍空闲（负沿切换，无竞争）。
      if (FRAME_GAP > 0 && f + 1 < FRAMES) begin
        in_valid = 1'b0; in_sof = 1'b0; in_eol = 1'b0;
        repeat (FRAME_GAP) @(posedge clk);
        @(negedge clk);
      end
    end
    // 收尾：停流后等管道排空（点操作 1 拍延迟，4 拍余量充足）。
    in_valid = 1'b0; in_sof = 1'b0; in_eol = 1'b0;
    repeat (4) @(posedge clk);

    if (got == N && fnv == EXPECTED_HASH)
      \$display("PASS  frame=%0dx%0dx%0d  fnv=%08x", W, H, FRAMES, fnv);
    else
      \$display("FAIL  got=%0d/%0d  fnv=%08x  expected=%08x",
                 got, N, fnv, EXPECTED_HASH);
    \$finish;
  end
endmodule
''';
}

/// Vivado 定制界面（xgui tcl）：分页 + 控件化 + 参数联动，打包时由
/// package_ip.tcl 拷入组件 xgui/ 目录。标准 init_gui 结构。
String _xguiTcl(IpPlan plan) {
  return r'''
# Vivado Customize IP 定制界面（DebugToolSet ISP Studio 生成）：
# 分页 + 控件化 + 参数联动（FOLD 仅 GSTRATEGY=0 面积档可编辑，
# enablement 由打包脚本 package_ip.tcl 的 enablement_tcl_expr 实现）。
proc init_gui { IPINST } {
  ipgui::add_param $IPINST -name "Component_Name"
  set Page0 [ipgui::add_page $IPINST -name "Page0" -display_name {基本配置 General}]
  ipgui::add_param $IPINST -name "PIX_BITS" -parent $Page0 \
      -display_name {像素位宽 PIX_BITS} \
      -tooltip {像素位宽；决定数据通路宽度与 LUT ROM 深度（MAXV=2^PIX_BITS-1）。} \
      -widget comboBox
  ipgui::add_param $IPINST -name "MAX_WIDTH" -parent $Page0 \
      -display_name {最大行宽 MAX_WIDTH} \
      -tooltip {行缓冲最大行宽，直接决定 BRAM 用量。} \
      -widget comboBox
  set Page1 [ipgui::add_page $IPINST -name "Page1" -display_name {优化策略 Optimization}]
  ipgui::add_param $IPINST -name "GSTRATEGY" -parent $Page1 \
      -display_name {实现分档 GSTRATEGY} \
      -tooltip {0 面积优先 / 1 平衡 / 2 性能优先；当前白名单为点操作（II=1），窗口算子落地后分档生效。} \
      -widget comboBox
  ipgui::add_param $IPINST -name "FOLD" -parent $Page1 \
      -display_name {折叠因子 FOLD} \
      -tooltip {每像素 FOLD 拍、算子复用，吞吐 1/FOLD px/clk；仅 GSTRATEGY=0（面积优先）时可编辑。} \
      -widget comboBox
}
''';
}

String _packageIpTcl(IpPlan plan) {
  final top = plan.topName;
  final series = plan.options.series;
  return '''
# Vivado IP Packager：把 ${top}_axis 打包为可定制 IP（参数在 Customize IP
# 界面可改）。用法：vivado -mode batch -source package_ip.tcl
set ip_name $top
create_project -in_memory -part ${series.part}
add_files ${top}_core.v
add_files ${top}_top.v
add_files ${top}_axis.v
update_compile_order -fileset sources_1
ipx::package_project -root_dir ./ip_repo -vendor debugtoolset -library isp \\
    -taxonomy /UserIP
set_property name \$ip_name [ipx::current_core]
set_property display_name "$top (ISP Studio)" [ipx::current_core]
set_property vendor_display_name "DebugToolSet" [ipx::current_core]
# 参数组（Customize IP 界面）：
ipx::add_user_parameter PIX_BITS [ipx::current_core]
set_property value_resolve_type user [ipx::get_user_parameters PIX_BITS]
set_property value ${plan.pixBits} [ipx::get_user_parameters PIX_BITS]
ipx::add_user_parameter MAX_WIDTH [ipx::current_core]
set_property value ${plan.options.maxWidth} [ipx::get_user_parameters MAX_WIDTH]
# 优化策略（当前白名单为点操作，预留窗口算子分档；GUI 可改）。
ipx::add_user_parameter GSTRATEGY [ipx::current_core]
set_property value_resolve_type user [ipx::get_user_parameters GSTRATEGY]
set_property value ${plan.options.gstrategy} [ipx::get_user_parameters GSTRATEGY]
ipx::add_user_parameter FOLD [ipx::current_core]
set_property value_resolve_type user [ipx::get_user_parameters FOLD]
set_property value ${plan.options.fold} [ipx::get_user_parameters FOLD]
# 取值合法性（组合列表校验，与定制界面下拉同源）：
set_property value_validation_type list [ipx::get_user_parameters PIX_BITS]
set_property value_validation_list {8 10 12 14 16} [ipx::get_user_parameters PIX_BITS]
set_property value_validation_type list [ipx::get_user_parameters MAX_WIDTH]
set_property value_validation_list {640 1280 1920 2048 4096 8192} [ipx::get_user_parameters MAX_WIDTH]
set_property value_validation_type list [ipx::get_user_parameters GSTRATEGY]
set_property value_validation_list {0 1 2} [ipx::get_user_parameters GSTRATEGY]
set_property value_validation_type list [ipx::get_user_parameters FOLD]
set_property value_validation_list {1 2 4} [ipx::get_user_parameters FOLD]
# FOLD 仅面积档（GSTRATEGY=0）可编辑；旧版 Vivado 不支持该属性时静默跳过。
catch {
  set_property enablement_tcl_expr {\$GSTRATEGY == 0} \\
    [ipx::get_model_parameters FOLD -of_objects [ipx::current_core]]
}
set_property supported_families {${series.supportedFamilies}} [ipx::current_core]
ipx::save_core [ipx::current_core]
ipx::check_integrity [ipx::current_core]
# 定制界面（xgui tcl）拷入组件目录（Vivado 打开 Customize IP 时读取）：
set xguiDir "./ip_repo/\$ip_name/xgui"
file mkdir \$xguiDir
file copy -force -- "xgui/${top}_v1_0.tcl" \$xguiDir/
puts "IP 已打包到 ./ip_repo"
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
  return '''
# $top（FPGA Verilog IP，ISP Studio 自动生成）

## 接口（像素流）

核心模块 `${top}_core` 输入/输出均为通用像素流，通道打包 `{H,S,L}`
（H 在最高位段，每通道 `PIX_BITS` 位），全程带 ready 握手：

- `in_valid`/`in_ready`：输入握手，`advance = in_valid & in_ready`；
- `in_sof`/`in_eol`：帧起始/帧结束（与 `in_data` 同拍有效）；
- `out_valid`/`out_ready`/`out_sof`/`out_eol`/`out_data`：输出同形，1 拍流水
  延迟（II=1，每时钟 1 像素）。

## 参数（顶层 parameter，Customize IP / generics 面板可改）

| 参数 | 默认 | 说明 |
|---|---|---|
| `PIX_BITS` | ${plan.pixBits} | 像素位宽；决定数据通路宽度与 LUT ROM 深度（MAXV = 2^PIX_BITS-1） |
| `MAX_WIDTH` | ${plan.options.maxWidth} | 行缓冲最大行宽（本节点无窗口算子，参数保留） |
| `GSTRATEGY` | ${plan.options.gstrategy}（$strategyName） | 窗口算子实现分档：0 面积 / 1 平衡 / 2 性能（当前白名单为点操作，预留） |
| `FOLD` | ${plan.options.fold} | 窗口算子折叠因子（仅面积档生效，预留） |

Vivado 定制界面（双击 IP → Customize IP）为分页 + 控件化界面（基本配置 /
优化策略两页，`xgui/${top}_v1_0.tcl`），`FOLD` 仅面积档可编辑。

## 支持节点与定点口径

- `multi_band_eq`（codegenMode=lut_fixed）：H 偏移 16 位补码 ROM + S/L 乘子
  Q14 定点 ROM，逐像素 3 查表 + 色环回绕（单次条件加减）+ 2 次整数乘加
  `(in*q+8192)>>14` 后钳位；与 C 侧 `bb_clamp_q14` 逐位一致。

## 资源估算（粗估，随节点类型逐步细化）

| 项 | 估算 | 说明 |
|---|---|---|
| LUT ROM | ${est.romBits} bit（≈${est.bram36k} 块 36K BRAM） | 3 张烘焙表（shift 16bit + S/L Q14 各 17bit）× 深度 2^PIX_BITS |
| DSP | ≈${est.estDsps} | S/L 两个 Q14 定点乘法器；性能档推断 DSP48，平衡/面积档绑 LUT |
| 逻辑 LUT | ≈${est.estLuts} | 数据通路 + 握手 + 表取数（乘法器绑 LUT 时含其估算） |
| 延迟 | ${est.latencyCycles} 拍 | 点操作编组：1 拍流水（无行缓冲） |
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

## 节点参数已烘焙进生成代码（与 C 导出同口径）；运行时寄存器/AXI-Lite 留 v2。
''';
}

// ---------------------------------------------------------------------------
// golden 计算（Dart 侧，与 RTL 逐位一致）
// ---------------------------------------------------------------------------

/// 生成 golden 输入激励帧 + 期望输出 FNV-1a（EXACT 模式）。输入 3 通道
/// 打包 {H,S,L}，逐帧逐像素由 [IpStimulusGen] 按激励参数（图案/尺寸/
/// 帧数/种子）产出；默认参数下与历史 LCG 序列逐位一致。
(String, int) _buildGolden(
    IpPlan plan, IspGraph graph, IspNodeGroup group, IpSimStimulus stim) {
  final mv = plan.maxValue;
  final pb = plan.pixBits;

  // 烘焙三表（与 core 同一份）。
  // v1 仅 multi_band_eq。
  Int32List shiftLut = Int32List(0);
  Int32List sQ14 = Int32List(0);
  Int32List lQ14 = Int32List(0);
  for (final id in plan.cPlan.topo) {
    final n = plan.cPlan.members[id]!;
    if (n.typeId == 'multi_band_eq') {
      final parsed = multiBandEqBands(n);
      final (sl, sm, lm) =
          multiBandLuts(parsed.bands, serial: parsed.serial, maxValue: mv);
      shiftLut = sl;
      sQ14 = Int32List.fromList([for (final v in sm) (v * 16384.0).round()]);
      lQ14 = Int32List.fromList([for (final v in lm) (v * 16384.0).round()]);
    }
  }

  final gen = IpStimulusGen(stim, mv);
  final outBytes = <int>[];
  final hexDigits = ((3 * pb + 3) ~/ 4);
  final inLines = StringBuffer();
  for (var f = 0; f < stim.frames; f++) {
    for (var y = 0; y < stim.height; y++) {
      for (var x = 0; x < stim.width; x++) {
        final (h, s, l) = gen.next(x, y);
        final word = (h << (2 * pb)) | (s << pb) | l;
        inLines.writeln(word.toRadixString(16).padLeft(hexDigits, '0'));

        // 期望输出（与 core 组合逻辑同口径）。
        final hv = h > mv ? mv : h;
        final shift = shiftLut[hv];
        var hnew = hv + shift;
        if (hnew > mv) {
          hnew -= (mv + 1);
        } else if (hnew < 0) {
          hnew += (mv + 1);
        }
        final os = _clampQ14(s, sQ14[hv], mv);
        final ol = _clampQ14(l, lQ14[hv], mv);
        for (final c in [hnew, os, ol]) {
          outBytes.add(c & 0xFF);
          outBytes.add((c >> 8) & 0xFF);
        }
      }
    }
  }
  return (inLines.toString(), fnv1a32(outBytes));
}

int _clampQ14(int v, int q, int maxValue) {
  var r = (v * q + 8192) >> 14;
  if (r < 0) r = 0;
  if (r > maxValue) r = maxValue;
  return r;
}
