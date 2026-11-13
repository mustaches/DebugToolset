/// ISP 编组「生成Verilog IP」的节点行核发射器：逐类型 Verilog 片段（LUT
/// ROM 表 / 点操作组合数据通路）。对应 C 导出的 node_c_stream.dart 角色。
/// LUT 表烘焙复用 node_c_stream 各节点发射器调用的同一批 Dart 侧函数
/// （multiBandLuts / hslBandLuts 等），只换格式化器为 Verilog ROM 表。
library;

import 'node_v_full_stream.dart';

const int kMbMaxBands = 16;

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

String vRomU50(String name, List<int> values, {String? comment}) {
  final b = StringBuffer();
  if (comment != null) b.writeln('  // $comment');
  b.writeln('  reg [49:0] $name [0:${values.length - 1}];');
  b.writeln('  initial begin');
  for (var i = 0; i < values.length; i++) {
    if (i % 4 == 0) b.write('    ');
    b.write("$name[$i] = 50'd${values[i]};");
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
  // ---- multi_band_eq (lut_fixed Q14) combinational datapath ----
  // H: clamp to upper bound (same as C row kernel "if (hv > max) hv = max").
  wire [$hvW-1:0] ${ident}_hv = (in_h > MAXV) ? MAXV : in_h;
  // One packed lookup per pixel: {L Q14, S Q14, H shift} = 50 bits.
  wire [49:0] ${ident}_band = ${ident}_shift_lut[${ident}_hv];
  wire [15:0] ${ident}_shift = ${ident}_band[15:0];
  wire [16:0] ${ident}_s_mul_q14 = ${ident}_band[32:16];
  wire [16:0] ${ident}_l_mul_q14 = ${ident}_band[49:33];
  wire [16:0] ${ident}_sq   = ${ident}_s_mul_q14;
  wire [16:0] ${ident}_lq   = ${ident}_l_mul_q14;
  // Hue circle wrap: hv + shift (|shift| <= MAXV/2 always holds; a single
  // conditional add/sub is bit-identical to % (MAXV+1); 17-bit signed carries
  // the worst-case intermediate of hv+shift at MAXV=65535).
  wire signed [16:0] ${ident}_hv17   = {1'b0, ${ident}_hv};
  wire signed [16:0] ${ident}_shift17 = {{1{${ident}_shift[15]}}, ${ident}_shift};
  wire signed [16:0] ${ident}_mp1    = \$signed({1'b0, MAXV}) + 17'sd1;
  wire signed [16:0] ${ident}_hsum   = ${ident}_hv17 + ${ident}_shift17;
  wire signed [16:0] ${ident}_hwrap  =
      (${ident}_hsum > \$signed({1'b0, MAXV})) ? (${ident}_hsum - ${ident}_mp1)
    : (${ident}_hsum < 17'sd0)                   ? (${ident}_hsum + ${ident}_mp1)
    : ${ident}_hsum;
  wire [$hvW-1:0] ${ident}_res_h = ${ident}_hwrap[$hvW-1:0];
  // S/L: clamp after (in*q + 8192) >> 14 (in and q are both non-negative;
  // product width pixBits+17 exactly carries MAXV*81920, no unsigned
  // overflow).
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

// ---------------------------------------------------------------------------
// multi_band_eq func_fixed（运行期直算定点）：段运算单元 + 流水数据通路。
// 无 ROM 表、无除法器——全部乘加/移位/条件选择，乘法器由综合器推断 DSP。
// 与 Dart multiBandFxWeightQ14 / multiBandComposeFx 逐位一致（恒等式：
// h_q16 的 Mersenne 折叠除法、shift 的「>>(30|16) 后 ×ceil(2^33/360)」
// 精确等价，验证见 scratch/verify_fx_verilog_identities.dart 与
// test/isp_group_ip_export_test.dart 的恒等式用例）。段参数为运行期输入
// 端口（FPGA 中可动态调整，见 mbFxUnitDefs 注释）。
// ---------------------------------------------------------------------------

/// func_fixed 段运算单元模块定义（combinational；流水寄存器在 core 内）。
/// 每个取色器段实例化一组独立单元（DSP 乘法器）。**段参数为运行期输入端
/// 口**（hc_q16 = H 中心 × 2^16 Q16 度；q_q20 = q/45 × 2^20；dh_q16 =
/// ΔH × 2^16 带符号；s1/l1_q14 =（增益−1）× 2^14 带符号）——FPGA 运行
/// 中可动态调整（经 AXI-Lite 寄存器/外部逻辑驱动），与 LUT 烘焙形态本质
/// 区别。拆分为 pre（角距→x²→u）/ mid（多项式→Q14 权重）/ post（贡献/
/// 级联输出）三段，配合 core 内 `DSP_PIPE` 参数插拍（0 纯组合 / 1 pre 后
/// 一拍 / 2 pre、mid 后各一拍）。**GSTRATEGY 落地**：0=乘法器绑 LUT
/// （use_dsp=no）、2=绑 DSP（use_dsp=yes）、1=综合器自选。
/// [prefix] 为模块名前缀（IP top 名）；[par]/[ser] 按需发射形态。
String mbFxUnitDefs(String prefix, {required bool par, required bool ser}) {
  // 乘法线的 DSP 三重 generate（0 绑 LUT / 2 绑 DSP / 1 默认推断）。
  // 属性只挂在 wire 声明上（iverilog 不接受 assign 前的属性实例）。
  String dspTriple(List<String> lines) {
    String attr(String a) => [
      for (final l in lines)
        l.startsWith('wire ') ? '  (* use_dsp = "$a" *) $l' : '  $l',
    ].join('\n');
    return '''
  generate
  if (GSTRATEGY == 0) begin : g_area
${attr('no')}
  end else if (GSTRATEGY == 2) begin : g_perf
${attr('yes')}
  end else begin : g_auto
${lines.map((l) => '  $l').join('\n')}
  end
  endgenerate''';
  }

  // 角距回绕（无乘法，generate 外共享）。
  const wrap = '''
  // Conditional angular-distance wrap (|h-hc| -> [0,180 deg], Q16 degrees).
  wire signed [33:0] d0 = \$signed({2'b00, h_q16}) - \$signed({2'b00, hc_q16});
  wire [33:0] d1 = (d0 < 0) ? (34'd0 - d0) : d0;
  wire [33:0] d2 = (d1 >= 34'd23592960) ? (d1 - 34'd23592960) : d1;
  wire [33:0] dd = (d2 > 34'd11796480) ? (34'd23592960 - d2) : d2;''';

  final b = StringBuffer();
  b.writeln('''
// ---- band arithmetic units (pre/mid/post; staged by DSP_PIPE in core) ----
// pre: angular-distance wrap -> x = d*q/45 (Q20) -> u = 0.5*x^2*log2e (Q16).
module ${prefix}_band_pre #(
    parameter integer GSTRATEGY = 2
) (
    input  wire [31:0] h_q16,
    input  wire [31:0] hc_q16,
    input  wire [31:0] q_q20,
    output wire [63:0] u_q16
);
$wrap
${dspTriple(['wire [63:0] x_q20  = ({30\'d0, dd} * {32\'d0, q_q20}) >> 16;', 'wire [63:0] x2_q20 = (x_q20 * x_q20 + 64\'d524288) >> 20;', 'wire [63:0] u_q16_w = x2_q20 * 64\'d756405;', 'assign u_q16 = (u_q16_w + 64\'d8388608) >> 24;'])}
endmodule

// mid: 2^(-u) = integer-part shift * fractional 5th-order polynomial (Q16
// coefficients, Horner; coefficients are a weighted least-squares fit over
// [0,1), see scratch/fit_exp2_neg_poly.dart).
module ${prefix}_band_mid #(
    parameter integer GSTRATEGY = 2
) (
    input  wire [63:0] u_q16,
    output wire [14:0] w_q14
);
  wire [3:0]  nn = u_q16[19:16];
  wire [63:0] fr = {48'd0, u_q16[15:0]};
${dspTriple(['wire signed [63:0] p1 =   64\'sd603 + ((\$signed(fr) * (-64\'sd62)    + 64\'sd32768) >>> 16);', 'wire signed [63:0] p2 = -64\'sd3623  + ((\$signed(fr) * p1            + 64\'sd32768) >>> 16);', 'wire signed [63:0] p3 =  64\'sd15740 + ((\$signed(fr) * p2            + 64\'sd32768) >>> 16);', 'wire signed [63:0] p4 = -64\'sd45426 + ((\$signed(fr) * p3            + 64\'sd32768) >>> 16);', 'wire signed [63:0] p5 =  64\'sd65536 + ((\$signed(fr) * p4            + 64\'sd32768) >>> 16);', 'wire [63:0] wv = (|u_q16[63:20]) ? 64\'d0 : (\$unsigned(p5) + (64\'d1 << ({1\'b0, nn} + 5\'d1))) >> ({1\'b0, nn} + 5\'d2);', 'assign w_q14 = wv[14:0];'])}
endmodule''');

  if (par) {
    b.writeln('''
// par_post: three contribution terms of this band (dh_term = w*dh is Q30;
// s/l_term = w*(g-1) is Q28; summed in core).
module ${prefix}_band_par_post #(
    parameter integer GSTRATEGY = 2
) (
    input  wire [14:0] w_q14,
    input  wire signed [31:0] dh_q16,
    input  wire signed [31:0] s1_q14,
    input  wire signed [31:0] l1_q14,
    output wire signed [47:0] dh_term,
    output wire signed [47:0] s_term,
    output wire signed [47:0] l_term
);
${dspTriple(['wire signed [47:0] dh_term_w = \$signed({33\'d0, w_q14}) * dh_q16;', 'wire signed [47:0] s_term_w  = \$signed({33\'d0, w_q14}) * s1_q14;', 'wire signed [47:0] l_term_w  = \$signed({33\'d0, w_q14}) * l1_q14;', 'assign dh_term = dh_term_w;', 'assign s_term  = s_term_w;', 'assign l_term  = l_term_w;'])}
endmodule''');
  }
  if (ser) {
    b.writeln('''
// ser_post: intermediate hue cascade update (bit-identical to the serial
// branch of Dart multiBandComposeFx; S/L multiplicative compose, hue
// accumulation with conditional wrap, 48-bit signed datapath).
module ${prefix}_band_ser_post #(
    parameter integer GSTRATEGY = 2
) (
    input  wire [31:0] h_cur,
    input  wire signed [47:0] s_acc,
    input  wire signed [47:0] l_acc,
    input  wire [14:0] w_q14,
    input  wire signed [31:0] dh_q16,
    input  wire signed [31:0] s1_q14,
    input  wire signed [31:0] l1_q14,
    output wire [31:0] h_next,
    output wire signed [47:0] s_next,
    output wire signed [47:0] l_next
);
${dspTriple([
      'wire signed [47:0] mul_s = 48\'sd16384 + ((\$signed({33\'d0, w_q14}) * s1_q14 + 48\'sd8192) >>> 14);',
      'wire signed [47:0] mul_l = 48\'sd16384 + ((\$signed({33\'d0, w_q14}) * l1_q14 + 48\'sd8192) >>> 14);',
      'wire signed [47:0] inc = (\$signed({33\'d0, w_q14}) * dh_q16 + 48\'sd8192) >>> 14;',
      'wire signed [47:0] sn = (s_acc * mul_s + 48\'sd8192) >>> 14;',
      'wire signed [47:0] ln = (l_acc * mul_l + 48\'sd8192) >>> 14;',
      // h' = h + (w*dh + 8192)>>>14，单次条件回绕（|inc| ≤ 180<<16 恒成立）。
      'wire signed [47:0] h1 = \$signed({16\'d0, h_cur}) + inc;',
      'wire signed [47:0] h2 = (h1 >= 48\'sd23592960) ? (h1 - 48\'sd23592960) : ((h1 < 0) ? (h1 + 48\'sd23592960) : h1);',
      'assign h_next = h2[31:0];',
      'assign s_next = sn;',
      'assign l_next = ln;',
    ])}
endmodule''');
  }
  return b.toString();
}

/// 段运行期参数端口名（core/top/厂商封装/tb 五处共用）：段 [i] 的
/// （H 中心，Q，ΔH，S 增益，L 增益）定点常量。
({String hc, String q, String dh, String s1, String l1}) fxBandPorts(int i) => (
  hc: 'par_b${i}_hc',
  q: 'par_b${i}_q',
  dh: 'par_b${i}_dh',
  s1: 'par_b${i}_s1',
  l1: 'par_b${i}_l1',
);

/// 段参数端口声明片段（追加到模块端口列表末尾，含前导逗号行）。
String fxBandPortsDecl(int bandCount) {
  final b = StringBuffer();
  for (var i = 0; i < bandCount; i++) {
    final p = fxBandPorts(i);
    b.writeln('''
    ,
    // band $i runtime parameters (picker band $i: fixed-point constants of
    // H center / Q / dH / S gain / L gain; see README; change during frame
    // blanking recommended)
    input  wire [31:0] ${p.hc},
    input  wire [31:0] ${p.q},
    input  wire signed [31:0] ${p.dh},
    input  wire signed [31:0] ${p.s1},
    input  wire signed [31:0] ${p.l1}''');
  }
  return b.toString();
}

/// 段参数端口透传连接片段（实例化时逐层透传）。
String fxBandPortsConn(int bandCount) {
  final names = [
    for (var i = 0; i < bandCount; i++) ...[
      fxBandPorts(i).hc,
      fxBandPorts(i).q,
      fxBandPorts(i).dh,
      fxBandPorts(i).s1,
      fxBandPorts(i).l1,
    ],
  ];
  return names.map((n) => '.$n($n)').join(', ');
}

/// 一级流水寄存器（valid/sof/eol 声明由 [emitMultiBandEqFxPipeline] 头部
/// 统一前置——iverilog 要求声明先于引用，使能链与 always 块互相引用）。
/// [id] 为级名（寄存器 v{id}/sof{id}/eol{id}），[sofIn]/[eolIn] 为上一级
/// sof/eol 来源表达式。数据位无复位（由 valid 位守卫）。
String _fxStage(
  String id,
  String en,
  String vIn,
  String sofIn,
  String eolIn,
  List<String> regs,
  List<String> assigns,
) {
  final s = StringBuffer()
    ..write(regs.map((r) => '  $r\n').join())
    ..writeln('  always @(posedge clk or negedge rst_n) begin')
    ..writeln("    if (!rst_n) begin")
    ..writeln("      v$id <= 1'b0; sof$id <= 1'b0; eol$id <= 1'b0;")
    ..writeln('    end else if ($en) begin')
    ..writeln('      v$id <= $vIn;')
    ..writeln('      sof$id <= $sofIn;')
    ..writeln('      eol$id <= $eolIn;');
  for (final a in assigns) {
    s.writeln('      $a');
  }
  s.writeln('    end\n  end');
  return s.toString();
}

/// func_fixed 流水数据通路（core 模块体内从 MAXV localparam 到输出级的全
/// 部内容）：与 Dart applyMultiBandEqFx 逐位一致（无 ROM 表、任意
/// PIX_BITS 恒走定点直算）。**DSP_PIPE 选通**（参数多路选择，综合折叠）：
/// 0 = 全组合（并联 LAT=5 / 串联 段数+4）；1 = 权重前段插 1 拍（+1）；
/// 2 = 权重前段/中段各插 1 拍（+2）。旁路级寄存器在对应 k 以下不被使用，
/// 综合剪除。返回（文本, k=0 基准 LAT；k>0 的增量见 README 公式）。
/// 段参数全部来自运行期输入端口 `par_b{i}_hc/q/dh/s1/l1`（声明/连接片段
/// 由 [fxBandPortsDecl]/[fxBandPortsConn] 生成，各层模块共用）。
(String, int) emitMultiBandEqFxPipeline(
  String unitPrefix,
  int pixBits,
  int bandCount,
  bool serial,
) {
  final pb = pixBits;
  final bw = 3 * pb;
  const n = kMbMaxBands;
  final ser = serial && bandCount >= 2; // 单段：串联与并联语义相同，走并联结构
  final lat = ser ? n + 4 : 5; // k=0 基准（串联结构恒 16 段流水）
  final b = StringBuffer();
  b.write('''
  localparam [$pb-1:0] MAXV = (1 << PIX_BITS) - 1;
  localparam [63:0] CIRCLE_Q16 = 64'd23592960; // 360 << 16 (Q16 deg/circle)
  localparam [63:0] HALF_MV = MAXV >> 1;
  localparam signed [47:0] MAXV_S = MAXV;

  wire [$pb-1:0] in_h = in_data[$bw-1 -: $pb];
  wire [$pb-1:0] in_s = in_data[${2 * pb}-1 -: $pb];
  wire [$pb-1:0] in_l = in_data[$pb-1:0];
  // Zero-extend the configured enable input before fixed 16-band indexing.
  wire [15:0] ch_enable_ext = CH_Enable;

  // S0 input-stage valid/sof/eol and data bits (declared up front: the C01
  // fold logic references hv0 before stage S0; iverilog requires declaration
  // before use; other stages are declared in their own sections below).
  reg v0, sof0, eol0;
  reg [$pb-1:0] hv0, s0, l0;
''');

  // ---- C01：h_q16 = (hv*360*2^16 + MAXV/2) / MAXV 的 Mersenne 折叠
  //（MAXV = 2^PIX_BITS - 1，四次折叠 + 末位修正，与整数除法逐位一致）----
  b.write('''
  // ---- C01: h_q16 = (hv*360*2^16 + MAXV/2)/MAXV (Mersenne fold, exact) ----
  wire [$pb-1:0] hvc = (hv0 > MAXV) ? MAXV : hv0;
  wire [63:0] ht  = {{${64 - pb}{1'b0}}, hvc} * CIRCLE_Q16 + HALF_MV;
  wire [63:0] hf1 = (ht  >> PIX_BITS) + (ht  & MAXV);
  wire [63:0] hf2 = (hf1 >> PIX_BITS) + (hf1 & MAXV);
  wire [63:0] hf3 = (hf2 >> PIX_BITS) + (hf2 & MAXV);
  wire [63:0] hf4 = (hf3 >> PIX_BITS) + (hf3 & MAXV);
  wire [63:0] hq16_c = (ht >> PIX_BITS) + (hf1 >> PIX_BITS)
                     + (hf2 >> PIX_BITS) + (hf3 >> PIX_BITS)
                     + ((hf4 >= MAXV) ? 64'd1 : 64'd0);
''');
  b.write(
    emitMultiBandEqFxFullPipeline(unitPrefix, pixBits, bandCount, serial),
  );
  b.writeln('  end else begin : g_legacy_pipeline');

  String lastStage; // 施加级读取的寄存器前缀（hv/s/l）
  if (!ser) {
    // ===================== 并联 / 单段 =====================
    // 级序：S0 → S1(折叠) → P1(权重前段 k≥1) → P2(权重中段 k≥2) → S2(求和)
    // → S3(收尾) → OUT。
    b.write('''
  // ---- stage valid/sof/eol and DSP_PIPE gating (bypassed stages are unused
  // and pruned by synthesis) ----
  reg v1, sof1, eol1;
  reg vp1, sofp1, eolp1;
  reg vp2, sofp2, eolp2;
  reg v2, sof2, eol2;
  reg v3, sof3, eol3;
  wire vA = (DSP_PIPE >= 1) ? vp1 : v1;
  wire vB = (DSP_PIPE >= 2) ? vp2 : vA;
  wire sofB = (DSP_PIPE >= 2) ? sofp2 : ((DSP_PIPE >= 1) ? sofp1 : sof1);
  wire eolB = (DSP_PIPE >= 2) ? eolp2 : ((DSP_PIPE >= 1) ? eolp1 : eol1);
  // Enable propagates tail-to-head (II=1).
  wire en_out = ~out_valid | out_ready;
  wire en3 = ~v3 | en_out;
  wire en2 = ~v2 | en3;
  wire enp2 = ~vB | en2;
  wire enp1 = ~vA | enp2;
  wire en1 = ~v1 | enp1;
  wire en0 = ~v0 | en1;
  assign in_ready = en0;
''');
    // S0：输入锁存。
    b.write(
      _fxStage('0', 'en0', 'in_valid', 'in_sof', 'in_eol', const [], [
        'hv0 <= in_h; s0 <= in_s; l0 <= in_l;',
      ]),
    );
    // S1：折叠锁存。
    b.write(
      _fxStage(
        '1',
        'en1',
        'v0',
        'sof0',
        'eol0',
        ['reg [31:0] h1;', 'reg [$pb-1:0] hv1, s1, l1;'],
        ['h1 <= hq16_c[31:0]; hv1 <= hv0; s1 <= s0; l1 <= l0;'],
      ),
    );
    // 段 pre 单元（comb，h1 → u）。
    b.writeln(
      '  // ---- band units pre/mid/post (one set per band, parameters are runtime ports) ----',
    );
    for (var i = 0; i < n; i++) {
      final p = fxBandPorts(i);
      // 未启用段在 elaboration 期不实例化（与全流水路径同口径）：段单元是三路
      // 48 位宽乘加，2 段配置背着 16 份就是上千个 DSP。
      b.writeln('''
  wire [63:0] uc$i;
  if (NUM_BANDS > $i) begin : g_pre$i
    ${unitPrefix}_band_pre #(.GSTRATEGY(GSTRATEGY)) u_b${i}_pre (
        .h_q16(h1), .hc_q16(${p.hc}), .q_q20(${p.q}), .u_q16(uc$i));
  end else begin : g_pre${i}_off
    assign uc$i = 64'd0;
  end''');
    }
    // P1：u 寄存（k≥1 使用）+ 进位。
    final p1Regs = <String>[
      'reg [$pb-1:0] cp1_hv, cp1_s, cp1_l;',
      for (var i = 0; i < n; i++) 'reg [63:0] ur$i;',
    ];
    b.write(
      _fxStage('p1', 'enp1', 'v1', 'sof1', 'eol1', p1Regs, [
        for (var i = 0; i < n; i++) 'ur$i <= uc$i;',
        'cp1_hv <= hv1; cp1_s <= s1; cp1_l <= l1;',
      ]),
    );
    // u 选通 + mid 单元。
    for (var i = 0; i < n; i++) {
      b.writeln('''
  wire [63:0] usel$i = (DSP_PIPE >= 1) ? ur$i : uc$i;
  wire [14:0] wc$i;
  if (NUM_BANDS > $i) begin : g_mid$i
    ${unitPrefix}_band_mid #(.GSTRATEGY(GSTRATEGY)) u_b${i}_mid (
        .u_q16(usel$i), .w_q14(wc$i));
  end else begin : g_mid${i}_off
    assign wc$i = 15'd0;
  end''');
    }
    // P2：w 寄存（k≥2 使用）+ 进位。
    final p2Regs = <String>[
      'reg [$pb-1:0] cp2_hv, cp2_s, cp2_l;',
      for (var i = 0; i < n; i++) 'reg [14:0] wr$i;',
    ];
    b.write(
      _fxStage('p2', 'enp2', 'vp1', 'sofp1', 'eolp1', p2Regs, [
        for (var i = 0; i < n; i++) 'wr$i <= wc$i;',
        'cp2_hv <= cp1_hv; cp2_s <= cp1_s; cp2_l <= cp1_l;',
      ]),
    );
    // w 选通 + post 单元 + 进位选通 + S2 求和锁存。
    final sumTerms = <String, List<String>>{'dh': [], 's': [], 'l': []};
    for (var i = 0; i < n; i++) {
      final p = fxBandPorts(i);
      b.writeln('''
  // Inactive or bypassed band: zero weight (identity contribution).
  wire [14:0] wsel$i = (($i >= NUM_BANDS) || !ch_enable_ext[$i])
      ? 15'd0 : ((DSP_PIPE >= 2) ? wr$i : wc$i);
  wire signed [47:0] b${i}_dh, b${i}_s, b${i}_l;
  if (NUM_BANDS > $i) begin : g_post$i
    ${unitPrefix}_band_par_post #(.GSTRATEGY(GSTRATEGY)) u_b${i}_post (
        .w_q14(wsel$i), .dh_q16(${p.dh}), .s1_q14(${p.s1}), .l1_q14(${p.l1}),
        .dh_term(b${i}_dh), .s_term(b${i}_s), .l_term(b${i}_l));
  end else begin : g_post${i}_off
    assign b${i}_dh = 48'sd0;
    assign b${i}_s = 48'sd0;
    assign b${i}_l = 48'sd0;
  end''');
      sumTerms['dh']!.add('b${i}_dh');
      sumTerms['s']!.add('b${i}_s');
      sumTerms['l']!.add('b${i}_l');
    }
    b.writeln('''
  wire signed [47:0] dh_sum_c = ${sumTerms['dh']!.join(' + ')};
  wire signed [47:0] s_sum_c  = ${sumTerms['s']!.join(' + ')};
  wire signed [47:0] l_sum_c  = ${sumTerms['l']!.join(' + ')};
  wire [$pb-1:0] csel_hv = (DSP_PIPE >= 2) ? cp2_hv
                         : ((DSP_PIPE >= 1) ? cp1_hv : hv1);
  wire [$pb-1:0] csel_s = (DSP_PIPE >= 2) ? cp2_s
                        : ((DSP_PIPE >= 1) ? cp1_s : s1);
  wire [$pb-1:0] csel_l = (DSP_PIPE >= 2) ? cp2_l
                        : ((DSP_PIPE >= 1) ? cp1_l : l1);
''');
    b.write(
      _fxStage(
        '2',
        'en2',
        'vB',
        'sofB',
        'eolB',
        ['reg signed [47:0] dh2, s2, l2;', 'reg [$pb-1:0] hv2, s2v, l2v;'],
        [
          'dh2 <= dh_sum_c; s2 <= s_sum_c; l2 <= l_sum_c;',
          'hv2 <= csel_hv; s2v <= csel_s; l2v <= csel_l;',
        ],
      ),
    );
    // C23：并联合成收尾（钳位 + shift/s_mul/l_mul 换算，同原口径）。
    b.write('''
  // ---- C23: parallel-compose finalize (clamp + shift/s_mul/l_mul scaling) ----
  wire signed [47:0] dh_cl = (dh2 < -48'sd193273528320) ? -48'sd193273528320
                           : ((dh2 > 48'sd193273528320) ? 48'sd193273528320 : dh2);
  // shift = round(dh*MAXV/(360*2^30)): mag -> A=(mag+180*2^30)>>30 ->
  // (A*ceil(2^33/360))>>33, bit-identical to integer division (no divider).
  wire dh_neg = dh_cl[47];
  wire [47:0] dh_mag = dh_neg ? (~dh_cl + 48'd1) : dh_cl;
  wire [63:0] sh_a = ((dh_mag * {48'd0, MAXV}) + (64'd180 << 30)) >> 30;
  wire [63:0] sh_q = (sh_a * 64'd23860930) >> 33;
  wire signed [47:0] shift_c = dh_neg ? -\$signed(sh_q) : \$signed(sh_q);
  wire signed [47:0] sm_c0 = 48'sd16384 + ((s2 + 48'sd8192) >>> 14);
  wire signed [47:0] lm_c0 = 48'sd16384 + ((l2 + 48'sd8192) >>> 14);
  // NUM_BANDS selects the multi-band clamp or single-band shortcut at
  // elaboration time; the unused side is folded by synthesis.
  wire signed [47:0] sm_c = (NUM_BANDS > 1)
      ? ((sm_c0 < 0) ? 48'sd0 : ((sm_c0 > 48'sd81920) ? 48'sd81920 : sm_c0))
      : sm_c0;
  wire signed [47:0] lm_c = (NUM_BANDS > 1)
      ? ((lm_c0 < 0) ? 48'sd0 : ((lm_c0 > 48'sd81920) ? 48'sd81920 : lm_c0))
      : lm_c0;
''');
    b.write(
      _fxStage(
        '3',
        'en3',
        'v2',
        'sof2',
        'eol2',
        ['reg signed [31:0] shift3, sm3, lm3;', 'reg [$pb-1:0] hv3, s3, l3;'],
        [
          'shift3 <= shift_c[31:0]; sm3 <= sm_c[31:0]; lm3 <= lm_c[31:0];',
          'hv3 <= hv2; s3 <= s2v; l3 <= l2v;',
        ],
      ),
    );
    lastStage = '3';
  } else {
    // ===================== 串联（段数>=2） =====================
    // 级序：S0 → S1(折叠/初值) → 每段 A(u, k≥1) → B(w, k≥2) → C(级联输出)
    // → F(收尾) → OUT。
    b.write('''
  // ---- stage valid/sof/eol and DSP_PIPE gating ----
  reg v1, sof1, eol1;
''');
    for (var i = 0; i < n; i++) {
      b.writeln('  reg va$i, sofa$i, eola$i;');
      b.writeln('  reg vb$i, sofb$i, eolb$i;');
      b.writeln('  reg vc$i, sofc$i, eolc$i;');
    }
    b.writeln('  reg vF, sofF, eolF;');
    // 选通 valid。
    for (var i = 0; i < n; i++) {
      final prev = i == 0 ? 'v1' : 'vc${i - 1}';
      b.writeln('  wire vA$i = (DSP_PIPE >= 1) ? va$i : $prev;');
      b.writeln('  wire vB$i = (DSP_PIPE >= 2) ? vb$i : vA$i;');
    }
    for (var i = 0; i < n; i++) {
      final prevSof = i == 0 ? 'sof1' : 'sofc${i - 1}';
      final prevEol = i == 0 ? 'eol1' : 'eolc${i - 1}';
      b.writeln(
        '  wire sofB$i = (DSP_PIPE >= 2) ? sofb$i'
        ' : ((DSP_PIPE >= 1) ? sofa$i : $prevSof);',
      );
      b.writeln(
        '  wire eolB$i = (DSP_PIPE >= 2) ? eolb$i'
        ' : ((DSP_PIPE >= 1) ? eola$i : $prevEol);',
      );
    }
    // 使能链（尾→首）。
    b.writeln('''
  wire en_out = ~out_valid | out_ready;
  wire enF = ~vF | en_out;''');
    for (var i = n - 1; i >= 0; i--) {
      b.writeln(
        '  wire enc$i = ~vc$i | ${i == n - 1 ? 'enF' : 'ena${i + 1}'};',
      );
      b.writeln('  wire enb$i = ~vB$i | enc$i;');
      b.writeln('  wire ena$i = ~vA$i | enb$i;');
    }
    b.writeln('  wire en1 = ~v1 | ena0;');
    b.writeln('  wire en0 = ~v0 | en1;');
    b.writeln('  assign in_ready = en0;');
    b.writeln();

    // S0：输入锁存。
    b.write(
      _fxStage('0', 'en0', 'in_valid', 'in_sof', 'in_eol', const [], [
        'hv0 <= in_h; s0 <= in_s; l0 <= in_l;',
      ]),
    );
    // S1：折叠 + 初始 acc 锁存（命名后缀 0＝段 0 的输入态；段 i 的 C 级输出
    // 态后缀 i+1，F 级读后缀 n——全链下标单调无冲突）。
    b.write(
      _fxStage(
        '1',
        'en1',
        'v0',
        'sof0',
        'eol0',
        [
          'reg [31:0] hcur0, hqd0;',
          'reg signed [47:0] sacc0, lacc0;',
          'reg [$pb-1:0] hvp0, sp0, lp0;',
        ],
        [
          'hcur0 <= hq16_c[31:0]; hqd0 <= hq16_c[31:0];',
          "sacc0 <= 64'sd16384; lacc0 <= 64'sd16384;",
          'hvp0 <= hv0; sp0 <= s0; lp0 <= l0;',
        ],
      ),
    );
    b.writeln(
      '  // ---- band units (per-band A/B/C three-stage gated expansion) ----',
    );
    for (var i = 0; i < n; i++) {
      final p = fxBandPorts(i);
      final ph = 'hcur$i';
      final ps = 'sacc$i';
      final pl = 'lacc$i';
      final phqd = 'hqd$i';
      final phv = i == 0 ? 'hvp0' : 'hv$i';
      final pss = i == 0 ? 'sp0' : 's$i';
      final pll = i == 0 ? 'lp0' : 'l$i';
      final vprev = i == 0 ? 'v1' : 'vc${i - 1}';
      final sofPrev = i == 0 ? 'sof1' : 'sofc${i - 1}';
      final eolPrev = i == 0 ? 'eol1' : 'eolc${i - 1}';
      b.writeln('''
  wire [63:0] uc$i;
  if (NUM_BANDS > $i) begin : g_pre$i
    ${unitPrefix}_band_pre #(.GSTRATEGY(GSTRATEGY)) u_b${i}_pre (
        .h_q16($ph), .hc_q16(${p.hc}), .q_q20(${p.q}), .u_q16(uc$i));
  end else begin : g_pre${i}_off
    assign uc$i = 64'd0;
  end''');
      // A 级：u 寄存 + 进位。
      b.write(
        _fxStage(
          'a$i',
          'ena$i',
          vprev,
          sofPrev,
          eolPrev,
          [
            'reg [63:0] ua$i;',
            'reg [31:0] ca_h$i, ca_hqd$i;',
            'reg signed [47:0] ca_s$i, ca_l$i;',
            'reg [$pb-1:0] ca_hv$i, ca_ss$i, ca_ll$i;',
          ],
          [
            'ua$i <= uc$i;',
            'ca_h$i <= $ph; ca_s$i <= $ps; ca_l$i <= $pl;',
            'ca_hqd$i <= $phqd; ca_hv$i <= $phv; ca_ss$i <= $pss; ca_ll$i <= $pll;',
          ],
        ),
      );
      b.writeln('''
  wire [63:0] usel$i = (DSP_PIPE >= 1) ? ua$i : uc$i;
  wire [14:0] wc$i;
  if (NUM_BANDS > $i) begin : g_mid$i
    ${unitPrefix}_band_mid #(.GSTRATEGY(GSTRATEGY)) u_b${i}_mid (
        .u_q16(usel$i), .w_q14(wc$i));
  end else begin : g_mid${i}_off
    assign wc$i = 15'd0;
  end''');
      // B 级：w 寄存 + 进位。
      b.write(
        _fxStage(
          'b$i',
          'enb$i',
          'va$i',
          'sofa$i',
          'eola$i',
          [
            'reg [14:0] wb$i;',
            'reg [31:0] cb_h$i, cb_hqd$i;',
            'reg signed [47:0] cb_s$i, cb_l$i;',
            'reg [$pb-1:0] cb_hv$i, cb_ss$i, cb_ll$i;',
          ],
          [
            'wb$i <= wc$i;',
            'cb_h$i <= ca_h$i; cb_s$i <= ca_s$i; cb_l$i <= ca_l$i;',
            'cb_hqd$i <= ca_hqd$i; cb_hv$i <= ca_hv$i; cb_ss$i <= ca_ss$i; cb_ll$i <= ca_ll$i;',
          ],
        ),
      );
      // 选通 + post + C 级。
      b.writeln('''
  // Inactive or bypassed band: zero weight (identity cascade step).
  wire [14:0] wsel$i = (($i >= NUM_BANDS) || !ch_enable_ext[$i])
      ? 15'd0 : ((DSP_PIPE >= 2) ? wb$i : wc$i);
  wire [31:0] csel_h$i = (DSP_PIPE >= 2) ? cb_h$i
                       : ((DSP_PIPE >= 1) ? ca_h$i : $ph);
  wire [31:0] csel_hqd$i = (DSP_PIPE >= 2) ? cb_hqd$i
                       : ((DSP_PIPE >= 1) ? ca_hqd$i : $phqd);
  wire [$pb-1:0] csel_hv$i = (DSP_PIPE >= 2) ? cb_hv$i
                       : ((DSP_PIPE >= 1) ? ca_hv$i : $phv);
  wire [$pb-1:0] csel_ss$i = (DSP_PIPE >= 2) ? cb_ss$i
                       : ((DSP_PIPE >= 1) ? ca_ss$i : $pss);
  wire [$pb-1:0] csel_ll$i = (DSP_PIPE >= 2) ? cb_ll$i
                       : ((DSP_PIPE >= 1) ? ca_ll$i : $pll);
  wire signed [47:0] csel_s$i = (DSP_PIPE >= 2) ? cb_s$i
                       : ((DSP_PIPE >= 1) ? ca_s$i : $ps);
  wire signed [47:0] csel_l$i = (DSP_PIPE >= 2) ? cb_l$i
                       : ((DSP_PIPE >= 1) ? ca_l$i : $pl);
  wire [31:0] bw${i}_h;
  wire signed [47:0] bw${i}_s, bw${i}_l;
  if (NUM_BANDS > $i) begin : g_post$i
    ${unitPrefix}_band_ser_post #(.GSTRATEGY(GSTRATEGY)) u_b${i}_post (
        .h_cur(csel_h$i), .s_acc(csel_s$i), .l_acc(csel_l$i),
        .w_q14(wsel$i),
        .dh_q16(${p.dh}), .s1_q14(${p.s1}), .l1_q14(${p.l1}),
        .h_next(bw${i}_h), .s_next(bw${i}_s), .l_next(bw${i}_l));
  end else begin : g_post${i}_off
    // Unused band: ser_post is combinational here, so the C stage alone keeps
    // the cascade latency; pass the accumulators straight through.
    assign bw${i}_h = csel_h$i;
    assign bw${i}_s = csel_s$i;
    assign bw${i}_l = csel_l$i;
  end''');
      b.write(
        _fxStage(
          'c$i',
          'enc$i',
          'vB$i',
          'sofB$i',
          'eolB$i',
          [
            'reg [31:0] hcur${i + 1}, hqd${i + 1};',
            'reg signed [47:0] sacc${i + 1}, lacc${i + 1};',
            'reg [$pb-1:0] hv${i + 1}, s${i + 1}, l${i + 1};',
          ],
          [
            'hcur${i + 1} <= bw${i}_h; sacc${i + 1} <= bw${i}_s; lacc${i + 1} <= bw${i}_l;',
            'hqd${i + 1} <= csel_hqd$i; hv${i + 1} <= csel_hv$i; s${i + 1} <= csel_ss$i; l${i + 1} <= csel_ll$i;',
          ],
        ),
      );
    }
    // F 级：串联收尾（首尾色环最短路径 + shift/s_mul/l_mul）。
    final lf = n;
    b.write('''
  // ---- serial finalize: first/last hue shortest-path offset + multiplier
  // clamp (0..5*2^14) ----
  wire signed [63:0] dd0 = \$signed({32'd0, hcur$lf}) - \$signed({32'd0, hqd$lf});
  wire signed [63:0] dd1 = (dd0 < 0) ? (dd0 + 64'sd23592960) : dd0;
  wire signed [63:0] ddf = (dd1 > 64'sd11796480) ? (dd1 - 64'sd23592960) : dd1;
  // shift = round(dd*MAXV/(360*2^16)): same >>16 then reciprocal-multiply
  // scheme as the parallel path.
  wire dd_neg = ddf[63];
  wire [63:0] dd_mag = dd_neg ? (~ddf + 64'd1) : ddf;
  wire [63:0] sh_a = ((dd_mag * {48'd0, MAXV}) + (64'd180 << 16)) >> 16;
  wire [63:0] sh_q = (sh_a * 64'd23860930) >> 33;
  wire signed [47:0] shift_c = dd_neg ? -\$signed(sh_q) : \$signed(sh_q);
  wire signed [47:0] sm_c = (sacc$lf < 0) ? 48'sd0
      : ((sacc$lf > 48'sd81920) ? 48'sd81920 : sacc$lf);
  wire signed [47:0] lm_c = (lacc$lf < 0) ? 48'sd0
      : ((lacc$lf > 48'sd81920) ? 48'sd81920 : lacc$lf);
''');
    b.write(
      _fxStage(
        'F',
        'enF',
        'vc${n - 1}',
        'sofc${n - 1}',
        'eolc${n - 1}',
        ['reg signed [31:0] shift3, sm3, lm3;', 'reg [$pb-1:0] hvF, sF, lF;'],
        [
          'shift3 <= shift_c[31:0]; sm3 <= sm_c[31:0]; lm3 <= lm_c[31:0];',
          'hvF <= hv$lf; sF <= s$lf; lF <= l$lf;',
        ],
      ),
    );
    lastStage = 'F';
  }

  // ---- 末级：施加（H 单次条件回绕 + Q14 整数乘加钳位）→ 输出寄存器 ----
  final hvA = ser ? 'hvF' : 'hv3';
  final sA = ser ? 'sF' : 's3';
  final lA = ser ? 'lF' : 'l3';
  b.write('''
  // ---- apply (same as the lut_fixed datapath tail; Q14 multipliers are
  // signed and a single band may go negative, bb_clamp_q14 semantics always
  // clamp back to [0, MAXV]) ----
  wire signed [31:0] mp1 = \$signed({16'd0, MAXV}) + 32'sd1;
  wire signed [31:0] hsum = \$signed({16'd0, $hvA}) + shift3;
  wire signed [31:0] hwrap = (hsum > \$signed({16'd0, MAXV})) ? (hsum - mp1)
                           : ((hsum < 0) ? (hsum + mp1) : hsum);
  wire [$pb-1:0] res_h = hwrap[$pb-1:0];
  wire signed [47:0] sp = \$signed({32'd0, $sA}) * sm3;
  wire signed [47:0] lp = \$signed({32'd0, $lA}) * lm3;
  wire signed [47:0] sr = (sp + 48'sd8192) >>> 14;
  wire signed [47:0] lr = (lp + 48'sd8192) >>> 14;
  wire [$pb-1:0] res_s = (sr < 0) ? {$pb{1'b0}}
      : ((sr > MAXV_S) ? MAXV : sr[$pb-1:0]);
  wire [$pb-1:0] res_l = (lr < 0) ? {$pb{1'b0}}
      : ((lr > MAXV_S) ? MAXV : lr[$pb-1:0]);

  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      out_valid <= 1'b0; out_sof <= 1'b0; out_eol <= 1'b0;
      out_data <= {$bw{1'b0}};
    end else if (en_out) begin
      out_valid <= v$lastStage;
      out_sof   <= sof$lastStage;
      out_eol   <= eol$lastStage;
      out_data  <= {res_h, res_s, res_l};
    end
  end
  end
''');
  return (b.toString(), lat);
}
