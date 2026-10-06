/// ISP 编组「生成Verilog IP」的节点行核发射器：逐类型 Verilog 片段（LUT
/// ROM 表 / 点操作组合数据通路）。对应 C 导出的 node_c_stream.dart 角色。
/// LUT 表烘焙复用 node_c_stream 各节点发射器调用的同一批 Dart 侧函数
/// （multiBandLuts / hslBandLuts 等），只换格式化器为 Verilog ROM 表。
library;

/// 16 位补码十六进制字面量（用于带符号 ROM 表项，位模式无歧义）。
String vHex16(int v) {
  final u = v & 0xFFFF;
  return "16'h${u.toRadixString(16).padLeft(4, '0')}";
}

/// 17 位无符号十进制字面量（Q14 乘子 0..81920）。
String vDec17(int v) => "17'd$v";

/// 把带符号整数值列表格式化为 `reg [15:0] 名 [0:N-1]` + `initial` 赋值块
/// ROM 表（16 位补码位模式）。不用 SystemVerilog unpacked array
/// localparam——Icarus Verilog 不支持（"sorry: unpacked array parameters
/// are not supported yet"）；reg 数组 + initial 初始化在 iverilog 仿真与
/// Vivado/Libero FPGA 综合（ROM 初值）中均可用。[name] 为表名。
String vRomSigned16(String name, List<int> values, {String? comment}) {
  final b = StringBuffer();
  if (comment != null) b.writeln('  // $comment');
  b.writeln('  reg [15:0] $name [0:${values.length - 1}];');
  b.writeln('  initial begin');
  // 每行 4 项，紧凑但不超长。
  for (var i = 0; i < values.length; i++) {
    if (i % 4 == 0) b.write('    ');
    b.write('$name[$i] = ${vHex16(values[i])};');
    if (i % 4 == 3 || i == values.length - 1) {
      b.writeln();
    } else {
      b.write(' ');
    }
  }
  b.writeln('  end');
  return b.toString();
}

/// 17 位无符号 ROM 表（Q14 乘子），同 [vRomSigned16] 的 iverilog 兼容形态。
String vRomU17(String name, List<int> values, {String? comment}) {
  final b = StringBuffer();
  if (comment != null) b.writeln('  // $comment');
  b.writeln('  reg [16:0] $name [0:${values.length - 1}];');
  b.writeln('  initial begin');
  for (var i = 0; i < values.length; i++) {
    if (i % 4 == 0) b.write('    ');
    b.write('$name[$i] = ${vDec17(values[i])};');
    if (i % 4 == 3 || i == values.length - 1) {
      b.writeln();
    } else {
      b.write(' ');
    }
  }
  b.writeln('  end');
  return b.toString();
}

/// multi_band_eq（lut_fixed Q14）的组合数据通路：H 钳上界 → 查 shift 表 →
/// 色环回绕；S/L 查 Q14 乘子表 → 整数乘加 >>14 → 钳位。与 C 侧
/// bb_clamp_q14 + 单次条件加减回绕逐位一致。输入通道打包 {H,S,L}（H 在
/// 最高位段）。返回声明在模块内的 `wire`/`reg` 组合块文本（含 6 空格缩进
/// 由调用方统一加）。
///
/// [ident] 为节点净化标识符（表名 `<ident>_shift_lut` 等）；[pixBits] 决定
/// 数据通路宽度。
String emitMultiBandEqDatapath(String ident, int pixBits) {
  final hvW = pixBits; // 输入 H 位宽
  return '''
  // ---- multi_band_eq（lut_fixed Q14）组合数据通路 ----
  // H：钳上界（与 C 行核 "if (hv > max) hv = max" 同口径）。
  wire [$hvW-1:0] ${ident}_hv = (in_h > MAXV) ? MAXV : in_h;
  // 查表：shift 为 16 位补码；S/L 乘子为 17 位无符号 Q14。
  wire [15:0] ${ident}_shift = ${ident}_shift_lut[${ident}_hv];
  wire [16:0] ${ident}_sq   = ${ident}_s_mul_q14[${ident}_hv];
  wire [16:0] ${ident}_lq   = ${ident}_l_mul_q14[${ident}_hv];
  // 色环回绕：hv + shift（|shift| <= MAXV/2 恒成立，单次条件加减与
  // % (MAXV+1) 逐位一致；17 位带符号承载 MAXV=65535 时 hv+shift 的
  // 最大中间值）。
  wire signed [16:0] ${ident}_hv17   = {1'b0, ${ident}_hv};
  wire signed [16:0] ${ident}_shift17 = {{1{${ident}_shift[15]}}, ${ident}_shift};
  wire signed [16:0] ${ident}_mp1    = \$signed({1'b0, MAXV}) + 17'sd1;
  wire signed [16:0] ${ident}_hsum   = ${ident}_hv17 + ${ident}_shift17;
  wire signed [16:0] ${ident}_hwrap  =
      (${ident}_hsum > \$signed({1'b0, MAXV})) ? (${ident}_hsum - ${ident}_mp1)
    : (${ident}_hsum < 17'sd0)                   ? (${ident}_hsum + ${ident}_mp1)
    : ${ident}_hsum;
  wire [$hvW-1:0] ${ident}_res_h = ${ident}_hwrap[$hvW-1:0];
  // S/L：in*s_q+8192 >> 14 后钳位（in 与 q 均非负，乘积宽度
  // pixBits+17 恰好承载 MAXV*81920，无符号溢出）。
  wire [$hvW+16:0] ${ident}_s_prod = in_s * ${ident}_sq;
  wire [$hvW+16:0] ${ident}_l_prod = in_l * ${ident}_lq;
  wire [$hvW+16:0] ${ident}_s_sum  = ${ident}_s_prod + 18'd8192;
  wire [$hvW+16:0] ${ident}_l_sum  = ${ident}_l_prod + 18'd8192;
  wire [$hvW+16:0] ${ident}_s_scl  = ${ident}_s_sum >> 14;
  wire [$hvW+16:0] ${ident}_l_scl  = ${ident}_l_sum >> 14;
  wire [$hvW-1:0] ${ident}_res_s =
      (${ident}_s_scl > MAXV) ? MAXV : ${ident}_s_scl[$hvW-1:0];
  wire [$hvW-1:0] ${ident}_res_l =
      (${ident}_l_scl > MAXV) ? MAXV : ${ident}_l_scl[$hvW-1:0];
''';
}
