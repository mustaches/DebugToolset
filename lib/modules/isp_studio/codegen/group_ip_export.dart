/// ISP 编组「生成Verilog IP」的发射层与写盘：把 IpPlan 组装为 Verilog IP
/// 包文件集（核心/顶层/厂商封装/testbench/golden/tcl/README）。对应
/// group_c_export_bb.dart 的角色；plan → emit 两段式。
library;

import 'dart:io';
import 'dart:typed_data';

import '../models/isp_graph.dart';
import '../pipeline/isp_kernels.dart';
import 'ip_gen_plan.dart';
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

/// golden 测试帧尺寸（小图，仿真快；后续可参数化）。
const int kIpSimW = 64;
const int kIpSimH = 48;

/// 内存生成 Verilog IP 包文件集：文件名 → 内容（键顺序即写盘顺序）。
Map<String, String> buildGroupIpFiles(
    IspGraph graph, IspNodeGroup group, IpGenOptions options) {
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

  // ---- golden：输入帧（LCG）+ 期望 FNV-1a ----
  final (goldenIn, goldenHash) = _buildGolden(plan, graph, group);

  final files = <String, String>{
    '${top}_core.v': _coreV(plan, roms.toString(), datapath.toString()),
    '${top}_top.v': _topV(plan),
    'tb_$top.v': _tbV(plan, goldenHash),
    'golden_in.hex': goldenIn,
    'golden_hash.txt': '0x${goldenHash.toRadixString(16).padLeft(8, '0')}\n',
    'wave.gtkw': _gtkw(plan),
    'wave.sucl': _sucl(plan),
    'README.md': _readme(plan),
  };
  if (options.vendor.isVivado) {
    files['${top}_axis.v'] = _axisV(plan);
    files['package_ip.tcl'] = _packageIpTcl(plan);
  } else if (options.vendor.isLibero) {
    files['${top}_libero.v'] = _liberoV(plan);
  }
  return files;
}

/// 写盘 IP 包到 [dir]（创建目录），返回已写文件路径列表。
Future<List<String>> exportGroupIpPackage(
    Map<String, String> files, String dir) async {
  await Directory(dir).create(recursive: true);
  final out = <String>[];
  for (final e in files.entries) {
    final p = '$dir${Platform.pathSeparator}${e.key}';
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
    parameter integer MAX_WIDTH = ${plan.options.maxWidth}
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
    parameter integer MAX_WIDTH = ${plan.options.maxWidth}
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
      .MAX_WIDTH(MAX_WIDTH)
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
    parameter integer MAX_WIDTH = ${plan.options.maxWidth}
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
      .MAX_WIDTH(MAX_WIDTH)
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
    parameter integer MAX_WIDTH = ${plan.options.maxWidth}
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
      .MAX_WIDTH(MAX_WIDTH)
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

String _tbV(IpPlan plan, int goldenHash) {
  final top = plan.topName;
  final pb = plan.pixBits;
  final bw = 3 * pb;
  final hashHex = goldenHash.toRadixString(16).padLeft(8, '0');
  return '''
// 一键仿真 testbench：读 golden_in.hex 喂核心 → 收集输出 → FNV-1a 对拍
// golden_hash.txt（期望值内嵌为 EXPECTED_HASH，EXACT 模式逐位一致）。
`timescale 1ns/1ps
module tb_$top;
  localparam integer PIX_BITS = $pb;
  localparam integer W  = $kIpSimW;
  localparam integer H  = $kIpSimH;
  localparam integer N  = W * H;
  localparam [31:0] EXPECTED_HASH = 32'h$hashHex;

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
  integer i, got;

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

  // 波形转储：vvp 运行产出 wave.vcd，仿真结束后由 GTKWave 打开。
  initial begin
    \$dumpfile("wave.vcd");
    \$dumpvars(0, tb_$top);
  end

  always #5 clk = ~clk;

  initial begin
    // 复位 2 拍。
    repeat (2) @(posedge clk);
    rst_n = 1'b1;
    @(posedge clk); #1;

    fnv = 32'h811c9dc5;
    got = 0;
    // 逐像素喂入（ready 恒高、latency=1 拍），边喂边收。#1 后再采样
    // out_valid/out_data，避开 NBA 更新竞争（否则采到上一拍旧值）。
    for (i = 0; i < N; i = i + 1) begin
      in_data  <= mem[i];
      in_valid <= 1'b1;
      in_sof   <= (i == 0);
      in_eol   <= (i == N - 1);
      @(posedge clk); #1;
      if (out_valid) begin hash_pixel(out_data); got = got + 1; end
    end
    // 收尾：管道末尾 2 拍。
    in_valid <= 1'b0; in_sof <= 1'b0; in_eol <= 1'b0;
    repeat (2) begin
      @(posedge clk); #1;
      if (out_valid) begin hash_pixel(out_data); got = got + 1; end
    end

    if (got == N && fnv == EXPECTED_HASH)
      \$display("PASS  frame=%0dx%0d  fnv=%08x", W, H, fnv);
    else
      \$display("FAIL  got=%0d/%0d  fnv=%08x  expected=%08x",
                 got, N, fnv, EXPECTED_HASH);
    \$finish;
  end
endmodule
''';
}

/// GTKWave 保存文件：一键仿真打开 wave.vcd 时自动把时钟/复位与 IP 的
/// I/O 信号（valid/ready/sof/eol/data）加入波形视图，免去初学者手工
/// 从信号树逐个拖入。`@22` 段为十六进制显示（数据总线），标量信号
/// 任何进制显示效果相同。
String _gtkw(IpPlan plan) {
  final tb = 'tb_${plan.topName}';
  final bw = 3 * plan.pixBits;
  final b = StringBuffer()
    ..writeln('[timestart] 0')
    ..writeln('[size] 1280 800')
    ..writeln('[pos] -1 -1')
    // zoom=-1 即 Zoom Fit（全帧可见）；其余 26 列为标记位（无）。
    ..writeln(
        '*-1.000000 -1 -1 -1 -1 -1 -1 -1 -1 -1 -1 -1 -1 -1 -1 -1 -1 -1 -1 -1 -1 -1 -1 -1 -1 -1 -1 -1')
    ..writeln('@22');
  for (final s in const [
    'clk',
    'rst_n',
    'in_valid',
    'in_ready',
    'in_sof',
    'in_eol',
    'out_valid',
    'out_ready',
    'out_sof',
    'out_eol',
  ]) {
    b.writeln('$tb.$s');
  }
  b
    ..writeln('$tb.in_data[${bw - 1}:0]')
    ..writeln('$tb.out_data[${bw - 1}:0]');
  return b.toString();
}

/// Surfer 启动命令文件（`.sucl`，经 `surfer wave.vcd --command-file
/// wave.sucl` 生效）：与 [_gtkw] 同口径地把时钟/复位与 IP I/O 信号
/// 加入波形视图并 Zoom Fit。Surfer 的变量名不带位宽后缀。
String _sucl(IpPlan plan) {
  final tb = 'tb_${plan.topName}';
  final b = StringBuffer()
    ..writeln('# 一键仿真自动加载：时钟/复位 + IP I/O 信号')
    ..writeln('timeline_add');
  for (final s in const [
    'clk',
    'rst_n',
    'in_valid',
    'in_ready',
    'in_sof',
    'in_eol',
    'out_valid',
    'out_ready',
    'out_sof',
    'out_eol',
    'in_data',
    'out_data',
  ]) {
    b.writeln('variable_add $tb.$s');
  }
  b.writeln('zoom_fit');
  return b.toString();
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
set_property supported_families {${series.supportedFamilies}} [ipx::current_core]
ipx::save_core [ipx::current_core]
ipx::check_integrity [ipx::current_core]
puts "IP 已打包到 ./ip_repo"
''';
}

String _readme(IpPlan plan) {
  final top = plan.topName;
  final v = plan.options.vendor;
  final romBits = 50 * plan.lutDepth;
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

## 支持节点与定点口径

- `multi_band_eq`（codegenMode=lut_fixed）：H 偏移 16 位补码 ROM + S/L 乘子
  Q14 定点 ROM，逐像素 3 查表 + 色环回绕（单次条件加减）+ 2 次整数乘加
  `(in*q+8192)>>14` 后钳位；与 C 侧 `bb_clamp_q14` 逐位一致。

## 资源估算（单节点 multi_band_eq）

- 3 张 ROM：shift（16bit）+ S/L Q14（各 17bit），深度 `2^PIX_BITS`，合计
  $romBits bit（PIX_BITS=${plan.pixBits}）；
- 2 个 `17×PIX_BITS` 无符号乘法器（S/L 各一，可绑 DSP 或 LUT）。

## 一键仿真

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

/// 生成 golden 输入帧（LCG）+ 期望输出 FNV-1a（EXACT 模式）。输入 3 通道
/// 打包 {H,S,L}，各通道 LCG 采样到 [0,maxValue]。
(String, int) _buildGolden(
    IpPlan plan, IspGraph graph, IspNodeGroup group) {
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

  // LCG（Numerical Recipes，32 位）。
  var state = 0x1234_5678;
  int next() {
    state = (state * 1664525 + 1013904223) & 0xFFFFFFFF;
    return state;
  }

  final nPx = kIpSimW * kIpSimH;
  final outBytes = <int>[];
  final hexDigits = ((3 * pb + 3) ~/ 4);
  final inLines = StringBuffer();
  for (var i = 0; i < nPx; i++) {
    final h = (next() >> 16) & mv;
    final s = (next() >> 16) & mv;
    final l = (next() >> 16) & mv;
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
  return (inLines.toString(), fnv1a32(outBytes));
}

int _clampQ14(int v, int q, int maxValue) {
  var r = (v * q + 8192) >> 14;
  if (r < 0) r = 0;
  if (r > maxValue) r = maxValue;
  return r;
}
