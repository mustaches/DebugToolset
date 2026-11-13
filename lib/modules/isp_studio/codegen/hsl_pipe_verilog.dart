/// RGB→HSL 的全流水 DSP 数据通路（func_fixed 编组，GSTRATEGY≠0 且
/// DSP_PIPE=3 时替代原来的组合函数数据通路）。
///
/// 与组合函数版数值口径**逐位一致**（Dart 参考 `pipeline/csc_fixed.dart`
/// 的 `_rgbToHslQ14`：256³ 全组合 + 多档 PIX_BITS 抽样对拍 0 失配）。
///
/// 结构要点：
/// - 每级乘法用**显式 DSP48E2 原语**（`AREG/BREG/MREG/PREG` 全 1），寄存器在
///   核内，因此不会有 DPIP/DPOP「DSP 未流水」建议；乘积不再回综合器推断。
/// - 原语的三个内部寄存级（AREG→MREG→PREG）分别由**所在框架级的 ready**
///   驱动（`stage_ready[k+1]/[k+2]/[k+3]`），侧数据走同级框架寄存器，因此
///   整条通路仍是标准弹性流水：输入气泡、输出背压都不会让乘积与同像素侧
///   数据错拍（早期用单一使能的写法在 gap/stall 下会错拍，已废弃）。
///
/// 定点除法（`f_div_round` 的等价实现，单次牛顿迭代 + 精确余数修正）：
///
/// ```text
/// k    = 规格化移位，dn = den << k ∈ [2^16, 2^17)
/// A0   = floor(2^33 / dn 桶上界)         // 8 位索引 ROM（f_hsl_seed）
/// X    = (dn * A0) >> 17                 // 乘法级 1
/// nf   = 2^17 - X                        // 牛顿因子
/// R    = (A0 * nf) >> 16                 // 乘法级 2，R ≈ 2^33/dn
/// q0   = (nv * R) >> (19 - k)             // 乘法级 3，商估计（误差 < 1）
/// p4   = q0 * den                        // 乘法级 4，用于精确余数修正
/// rem  = (nv<<14) - p4 → ±1 修正 → 四舍五入
/// ```
///
/// 单节点 23 拍。
library;

import '../pipeline/isp_kernels.dart';

/// 一级流水：`wire [width-1:0] id = expr`，其寄存器由 core 的 valid/ready
/// 机制统一控制；`source` 写在该 wire 之前的辅助声明（DSP 原语等）。
class HslPipeStage {
  const HslPipeStage(this.id, this.width, this.source, this.expr);

  final String id;
  final int width;
  final String source;
  final String expr;
}

/// 单节点总拍数（含入口与输出寄存）。
const int kHslPipeLatency = 23;

const int _lW = 16; // l（Q14 ≤ 16384）
const int _denW = 17; // den / dn / A0（≤ 131071）
const int _nvW = 15; // nv（≤ 16384）
const int _slotW = 17; // R / q0 / nf 载体
const int _shW = 5; // 移位量 [3,17]
const int _p1W = 34; // 整数乘积宽度（≤ 2^33）
const int _p5W = 32; // 缩放乘积宽度（≤ 2^31）

/// 16 位零扩展（`width == 16` 时不产生 `{0{1'b0}}` 这种 0 次复制 ——
/// Vivado 会报 `[Synth 8-693] zero replication count`）。
String zeroPad16(String expr, int width) =>
    width >= 16 ? expr : '{{${16 - width}{1\'b0}}, $expr}';

class _Rec {
  final List<String> order = [];
  final Map<String, int> offs = {};
  final Map<String, int> widths = {};
  int _cursor = 0;

  void add(String key, int width) {
    order.add(key);
    offs[key] = _cursor;
    widths[key] = width;
    _cursor += width;
  }

  int get width => _cursor;
  int off(String key) => offs[key]!;
  int w(String key) => widths[key]!;
  String get_(String reg, String key) => '$reg[${off(key)} +: ${w(key)}]';
}

final _recM = _Rec()
  ..add('l', _lW)
  ..add('sel', 2)
  ..add('d', _nvW)
  ..add('den', _denW)
  ..add('dfa', _nvW)
  ..add('dfn', 1)
  // 规格化结果与种子 ROM 索引：在 m 级算好、随 rec M 同拍寄存，好让种子表
  // 的**读取**放进 m→q 这一个时钟沿（BRAM 同步读 / case 函数走同一组寄存
  // 器），整链 LAT 不变。
  ..add('shs', _shW)
  ..add('sht', _shW)
  ..add('sid', 8)
  ..add('tid', 8);

final _recQ = _Rec()
  ..add('l', _lW)
  ..add('sel', 2)
  ..add('nvs', _nvW)
  ..add('nvt', _nvW)
  ..add('dns', _denW)
  ..add('dnt', _denW)
  ..add('dens', _denW)
  ..add('dent', _denW)
  ..add('shs', _shW)
  ..add('sht', _shW)
  ..add('nzs', 1)
  ..add('nzt', 1)
  ..add('a0s', _denW)
  ..add('a0t', _denW)
  ..add('slots', _slotW)
  ..add('slott', _slotW)
  ..add('dfn', 1);

final _recOut = _Rec()
  ..add('h', _lW)
  ..add('s', _lW)
  ..add('l', _lW);

/// `h = round(tv/6)` 的折叠实现（tv 为 18 位有符号，可达域 [16384, 98304]）。
/// 先 +3 得 y，再 floor(y/3)（Mersenne 折叠：3 = 2^2−1，按 2 位切段）后 >>1
/// 即 floor(y/6)；与原常数乘 43691 取高位逐位一致（[0, 131071] 穷举对拍）。
/// 不用 DSP 推断那版：虽然同样省 LUT（171→111），但会引入 DPOP-3/DPOP-4
///（DSP 未流水）警告，本工程要求 DRC 只留 I/O 两条 Advisory。
String _div6FoldBlock() {
  const w = 20; // y 位宽（含余量）
  const k = 10; // 2 位一段
  const q = "'"; // Verilog 位宽基数字面量的撇号
  final b = StringBuffer();
  b.writeln("  wire [${w - 1}:0] hy = {2${q}b00, tv} + $w${q}d3;");
  for (var i = 0; i < k; i++) {
    b.writeln('  wire [1:0] hy_d$i = hy[${2 * i + 1}:${2 * i}];');
  }
  // S = Σ dᵢ（≤ 3k）
  final sTerms = [for (var i = 0; i < k; i++) "{3${q}d0, hy_d$i}"];
  b.writeln('  wire [4:0] hy_s = ${sTerms.join(' + ')};');
  // floor(S/3)：k−1 个比较器
  final cTerms = [
    for (var j = 1; j < k; j++) "(hy_s >= 5${q}d${3 * j} ? 4${q}d1 : 4${q}d0)",
  ];
  b.writeln('  wire [3:0] hy_c = ${cTerms.join(' + ')};');
  // q = Σ_{i≥1} dᵢ·Gᵢ + carry，Gᵢ = 1 + 4 + … + 4^{i−1}
  final terms = <String>[];
  for (var i = 1; i < k; i++) {
    for (var j = 0; j < i; j++) {
      final shift = 2 * j;
      final pad = w - 2 - shift;
      final padLit = "$pad${q}d0";
      final shiftLit = "$shift${q}d0";
      terms.add(pad > 0
          ? "{$padLit, hy_d$i${shift > 0 ? ", $shiftLit" : ''}}"
          : "{hy_d$i, $shiftLit}");
    }
  }
  terms.add("{${w - 4}${q}d0, hy_c}");
  b.writeln('  wire [${w - 1}:0] hy_q = ${terms.join(' + ')};');
  b.writeln('  wire [14:0] h_q14 = hy_q[15:1];');
  return b.toString();
}

/// `f_hsl_normk`：`<top>_hsl_m` 里算规格化移位量用（种子索引也在那一级算）。
String _hslNormkFunction() => '''
  function [4:0] f_hsl_normk;
    input [16:0] den;
    integer i;
    begin
      f_hsl_normk = 5'd16;
      for (i = 1; i <= 16; i = i + 1)
        if (den >= (1 << i)) f_hsl_normk = 16 - i;
    end
  endfunction''';

/// `floor(x / MAXV)`（MAXV = 2^PIX_BITS − 1）的 **Mersenne 折叠** Verilog
/// 函数，替代常量除法的「乘倒数 + 截取」LUT 写法（单除法实测 218 → 72 LUT，
/// 纯加/移位，不占 DSP、不加拍；`PIX_BITS` 仍是 IP 参数，循环次数/常数随它
/// 展开）。
///
/// 恒等式（x 按 pb 位切段 d₀..d_{k−1}）：
///   x − Σdᵢ = MAXV · Σ_{i≥1} dᵢ·Gᵢ,  Gᵢ = 1 + 2^pb + … + 2^{pb(i−1)}
/// 故 floor(x/MAXV) = Σ_{i≥1} dᵢ·Gᵢ + floor(Σdᵢ / MAXV)；后者只需 k−1 个
/// 比较器（Σdᵢ ≤ k·MAXV）。`DV_W` 为输入位宽（= PIX_BITS + 15），返回值同宽，
/// 调用方取 `[14:0]`（商 ≤ 16384）。
String divMaxvFunction() => r"""
  localparam integer DV_W = PIX_BITS + 15;
  localparam integer DV_N = (DV_W + PIX_BITS - 1) / PIX_BITS;
  // floor(x / (2^PIX_BITS - 1)) via Mersenne folding: split x into PIX_BITS-bit
  // limbs d<i>, then x - sum(d<i>) = MAXV * sum(d<i> * G<i>) with
  // G<i> = 1 + 2^PIX_BITS + ... + 2^(PIX_BITS*(i-1)), hence
  // floor(x/MAXV) = sum(d<i>*G<i>) + floor(sum(d<i>)/MAXV); the last term needs
  // only DV_N-1 comparators (sum <= DV_N*MAXV). No divider, no DSP, no extra
  // pipeline stage; bit-exact against integer division.
  function [14:0] f_div_maxv;
    input [DV_W-1:0] x;
    integer i, j;
    reg [DV_W-1:0] sum, g, d;
    reg [14:0] acc;
    begin
      sum = 0;
      for (i = 0; i < DV_N; i = i + 1)
        sum = sum + ((x >> (PIX_BITS * i)) & MAXV);
      acc = 0;
      for (i = 1; i < DV_N; i = i + 1) begin
        d = (x >> (PIX_BITS * i)) & MAXV;
        g = 0;
        for (j = 0; j < i; j = j + 1) g = g + (d << (PIX_BITS * j));
        acc = acc + g;
      end
      for (i = 1; i < DV_N; i = i + 1)
        if (sum >= (MAXV * i)) acc = acc + 1;
      f_div_maxv = acc[14:0];
    end
  endfunction
""";

/// `f_hsl_seed`：种子表（256 项 × 17 位）。`USE_BRAM=0` 时以 case 函数形式
/// 放在 core 里（综合成 LUT 逻辑）；`USE_BRAM=1` 时同一组数值放到 BRAM ROM，
/// 两者的**读取口径一致**（都在 m→q 的时钟沿取样），因此结果逐位相同。
/// [asRom] 为 true 时返回 ROM 初始化串（供 core 的 `initial` 使用）。
/// 种子表 `f_hsl_seed` 的 case 函数版（`USE_BRAM=0` 时放在 core 模块里）。
String hslSeedFunction() {
  final b = StringBuffer('''
  function [16:0] f_hsl_seed;
    input [8:0] idx;
    begin
      case (idx)''');
  for (var i = 256; i < 512; i++) {
    final up = (i << 8) + 255;
    final v = (1 << 33) ~/ up;
    b.writeln('        9\'d$i: f_hsl_seed = 17\'d$v;');
  }
  b.writeln('''
        default: f_hsl_seed = 17'd130563;
      endcase
    end
  endfunction''');
  return b.toString();
}

/// 种子 ROM 的 `initial` 初始化串（256 项，索引 0 对应归一化值 0x100）。
/// 种子 ROM 的 `initial` 初始化串（`USE_BRAM=1` 时用）。
String hslSeedRomInit(String romName) {
  final b = StringBuffer('    $romName[0] = 17\'d130563;\n');
  for (var i = 0; i < 256; i++) {
    final up = ((i + 256) << 8) + 255;
    final v = (1 << 33) ~/ up;
    b.writeln('    $romName[$i] = 17\'d$v;');
  }
  return b.toString();
}

/// 三段组合逻辑各自成一级子模块并保留层级（`keep_hierarchy`）：核心模块只留
/// 流水寄存器与 DSP 原语，避免综合后单一 cellview 摊成数千个原语
/// （`[Netlist 29-101] not ideal for floorplanning` 的来源，也不利于
/// pblock/区域约束）。
String hslBlockDefs(String top) {
  final wm = _recM.width;
  final wq = _recQ.width;
  final wo = _recOut.width;
  String mf(String key) => 'rec[${_recM.off(key)} +: ${_recM.w(key)}]';
  String qf(String key) => 'rec[${_recQ.off(key)} +: ${_recQ.w(key)}]';
  final m = '''
(* keep_hierarchy = "yes" *)
module ${top}_hsl_m #(
    parameter integer PIX_BITS = 8
) (
    input wire [3*PIX_BITS-1:0] px,
    output wire [${wm - 1}:0] rec
);
  localparam integer MAXV = (1 << PIX_BITS) - 1;
${_hslNormkFunction()}${divMaxvFunction()}
  // Q14 normalize (round v*16384 over MAXV) via Mersenne folding, no divider.
  wire [PIX_BITS+13:0] rs = px[3*PIX_BITS-1 -: PIX_BITS] << 14;
  wire [PIX_BITS+14:0] rd = {1'b0, rs} + (MAXV >> 1);
  wire [14:0] r = f_div_maxv(rd);
  wire [PIX_BITS+13:0] gs = px[2*PIX_BITS-1 -: PIX_BITS] << 14;
  wire [PIX_BITS+14:0] gd = {1'b0, gs} + (MAXV >> 1);
  wire [14:0] g = f_div_maxv(gd);
  wire [PIX_BITS+13:0] bs = px[PIX_BITS-1:0] << 14;
  wire [PIX_BITS+14:0] bd = {1'b0, bs} + (MAXV >> 1);
  wire [14:0] b = f_div_maxv(bd);
  wire [14:0] mx01 = g > b ? g : b;
  wire [14:0] mn01 = g < b ? g : b;
  wire [14:0] mx = r > mx01 ? r : mx01;
  wire [14:0] mn = r < mn01 ? r : mn01;
  wire [14:0] d = mx - mn;
  wire [15:0] sum = {1'b0, mx} + {1'b0, mn};
  wire [15:0] l = sum >> 1;
  wire [16:0] den = (l > 16'd8192)
      ? (17'd32768 - {1'b0, sum}) : {1'b0, sum};
  wire [1:0] sel = (mx == r) ? 2'd0 : ((mx == g) ? 2'd1 : 2'd2);
  wire signed [15:0] dfs = (sel == 2'd0)
      ? (\$signed({1'b0, g}) - \$signed({1'b0, b}))
      : ((sel == 2'd1)
          ? (\$signed({1'b0, b}) - \$signed({1'b0, r}))
          : (\$signed({1'b0, r}) - \$signed({1'b0, g})));
  wire [15:0] dfa16 = dfs[15] ? (-dfs) : {1'b0, dfs[14:0]};
  wire [14:0] dfa = dfa16[14:0];
  // 规格化 + 种子 ROM 索引提前到本级算（与本级 rec 同拍寄存）：种子表的
  // **读取**因此能落在 m→q 这一个时钟沿上（BRAM 同步读），不必在 q 级组合
  // 读表，整链 LAT 与数值都不变。
  wire [16:0] dent = {2'd0, d};
  wire [4:0]  shs = 5'd19 - f_hsl_normk(den);
  wire [4:0]  sht = 5'd19 - f_hsl_normk(dent);
  wire [16:0] dns = den << (5'd19 - shs);
  wire [16:0] dnt = dent << (5'd19 - sht);
  assign rec = {dnt[15:8], dns[15:8], sht, shs,
      dfs[15], dfa, den, d, sel, l};
endmodule
''';
  final q = '''
(* keep_hierarchy = "yes" *)
module ${top}_hsl_q (
    input wire [${wm - 1}:0] rec,
    input wire [16:0] a0s,
    input wire [16:0] a0t,
    output wire [${wq - 1}:0] q
);
  wire [16:0] dens = ${mf('den')};
  wire [16:0] dent = {2'd0, ${mf('d')}};
  wire [14:0] nvs = ${mf('d')};
  wire [14:0] nvt = ${mf('dfa')};
  wire [4:0]  shs = ${mf('shs')};
  wire [4:0]  sht = ${mf('sht')};
  wire [16:0] dns = dens << (5'd19 - shs);
  wire [16:0] dnt = dent << (5'd19 - sht);
  wire nzs = (dens != 17'd0);
  wire nzt = (dent != 17'd0);
  assign q = {${mf('dfn')}, 17'd0, 17'd0, a0t, a0s, nzt, nzs, sht, shs,
      dent, dens, dnt, dns, nvt, nvs, ${mf('sel')}, ${mf('l')}};
endmodule
''';
  final corr = '''
(* keep_hierarchy = "yes" *)
module ${top}_hsl_corr (
    input wire [${wq - 1}:0] rec,
    input wire [31:0] p4s,
    input wire [31:0] p4t,
    output wire [${wo - 1}:0] out
);
  wire [15:0] nv_s = {1'b0, ${qf('nvs')}};
  wire [15:0] nv_t = {1'b0, ${qf('nvt')}};
  wire [16:0] dn_s = ${qf('dens')};
  wire [16:0] dn_t = ${qf('dent')};
  wire [15:0] qe_s = rec[${_recQ.off('slots')} +: 15];
  wire [15:0] qe_t = rec[${_recQ.off('slott')} +: 15];
  wire signed [31:0] p4sv = \$signed({1'b0, p4s[30:0]});
  wire signed [31:0] p4tv = \$signed({1'b0, p4t[30:0]});
  wire [30:0] mg_s = {15'd0, nv_s} << 14;
  wire [30:0] mg_t = {15'd0, nv_t} << 14;
  // 余数链只保留低 19 位：rm = mg - q0*den ∈ (-den, den) 且 den ≤ 2^17，
  // 19 位有符号（±2^18）留一倍余量；后续三项修正/比较都在这条窄总线上算
  // （原写法 32 位，每级多花 ~13 LUT）。
  wire signed [31:0] rm_s0 = \$signed({1'b0, mg_s}) - p4sv;
  wire signed [31:0] rm_t0 = \$signed({1'b0, mg_t}) - p4tv;
  wire signed [18:0] r0s = rm_s0[18:0];
  wire signed [18:0] r0t = rm_t0[18:0];
  wire signed [18:0] dnsx = \$signed({2'd0, dn_s});
  wire signed [18:0] dntx = \$signed({2'd0, dn_t});
  wire signed [18:0] rm_s1 = (r0s < 19'sd0) ? (r0s + dnsx) : r0s;
  wire signed [18:0] rm_t1 = (r0t < 19'sd0) ? (r0t + dntx) : r0t;
  wire [15:0] qs1 = (r0s < 19'sd0) ? (qe_s - 1'b1) : qe_s;
  wire [15:0] qt1 = (r0t < 19'sd0) ? (qe_t - 1'b1) : qe_t;
  wire signed [18:0] rm_s2 = (rm_s1 >= dnsx) ? (rm_s1 - dnsx) : rm_s1;
  wire signed [18:0] rm_t2 = (rm_t1 >= dntx) ? (rm_t1 - dntx) : rm_t1;
  wire [15:0] qs2 = (rm_s1 >= dnsx) ? (qs1 + 1'b1) : qs1;
  wire [15:0] qt2 = (rm_t1 >= dntx) ? (qt1 + 1'b1) : qt1;
  wire [18:0] rm_s3 = {rm_s2, 1'b0};
  wire [18:0] rm_t3 = {rm_t2, 1'b0};
  wire [15:0] qs3 = (rm_s3 >= {2'd0, dn_s}) ? (qs2 + 1'b1) : qs2;
  wire [15:0] qt3 = (rm_t3 >= {2'd0, dn_t}) ? (qt2 + 1'b1) : qt2;
  wire [14:0] s_q14 = ${qf('nzs')} ? qs3[14:0] : 15'd0;
  wire [15:0] qt4 = ${qf('nzt')} ? qt3 : 16'd0;
  wire signed [17:0] td = ${qf('dfn')}
      ? (-\$signed({2'd0, qt4})) : \$signed({2'd0, qt4});
  wire [1:0] selx = ${qf('sel')};
  wire signed [17:0] base = (selx == 2'd0)
      ? ((td < 18'sd0) ? 18'sd98304 : 18'sd0)
      : ((selx == 2'd1) ? 18'sd32768 : 18'sd65536);
  wire signed [17:0] tv = td + base;
${_div6FoldBlock()}
  assign out = {${qf('l')}, {1'b0, s_q14}, {1'b0, h_q14}};
endmodule
''';
  return '$m\n$q\n$corr';
}

/// 全流水 HSL 专用的 DSP48E2 乘法模块（三个内部寄存器级各由一位使能驱动）。
String hslDspMulDef(String top, bool xilinx) {
  final primitive = '''
  // 用算术扩展代替 {N{...}} 复制：N 可能为 0（AW=30/BW=18），
  // Verilog 的 0 次复制会被 Vivado 报 `[Synth 8-693] zero replication count`。
  wire signed [29:0] a_pad = (SIGNED_A != 0) ? \$signed(a) : \$signed({1'b0, a});
  wire signed [17:0] b_pad = (SIGNED_B != 0) ? \$signed(b) : \$signed({1'b0, b});
  wire [47:0] dsp_p;
  DSP48E2 #(
      .A_INPUT("DIRECT"), .B_INPUT("DIRECT"),
      .AMULTSEL("A"), .BMULTSEL("B"),
      .AREG(1), .BREG(1), .ACASCREG(1), .BCASCREG(1),
      .OPMODEREG(0), .MREG(1), .PREG(1), .USE_MULT("MULTIPLY")
  ) u_dsp (
      .CLK(clk),
      .CEA1(1'b0), .CEA2(en_a), .CEB1(1'b0), .CEB2(en_a),
      .CEAD(1'b0), .CEALUMODE(1'b0), .CEC(1'b0), .CECARRYIN(1'b0),
      .CECTRL(1'b0), .CED(1'b0), .CEINMODE(1'b0),
      .CEM(en_m), .CEP(en_p),
      .A(a_pad), .B(b_pad), .C(48'd0), .D(27'd0),
      .INMODE(5'd0), .OPMODE(9'b000000101), .ALUMODE(4'd0),
      .CARRYIN(1'b0), .CARRYINSEL(3'd0),
      .ACIN(30'd0), .BCIN(18'd0), .CARRYCASCIN(1'b0), .PCIN(48'd0),
      .MULTSIGNIN(1'b0),
      .RSTA(1'b0), .RSTB(1'b0), .RSTC(1'b0), .RSTD(1'b0),
      .RSTINMODE(1'b0), .RSTM(1'b0), .RSTP(1'b0),
      .RSTALLCARRYIN(1'b0), .RSTALUMODE(1'b0), .RSTCTRL(1'b0),
      .ACOUT(), .BCOUT(), .CARRYCASCOUT(), .CARRYOUT(),
      .MULTSIGNOUT(), .OVERFLOW(), .PATTERNBDETECT(), .PATTERNDETECT(),
      .PCOUT(), .UNDERFLOW(), .XOROUT(), .P(dsp_p)
  );
  generate
    if (PW >= 48) begin : g_p_full
      assign p = dsp_p;
    end else begin : g_p_trunc
      assign p = dsp_p[PW-1:0];
    end
  endgenerate
''';
  final fallback = '''
  wire signed [AW:0] a_ext = (SIGNED_A != 0)
      ? {a[AW-1], a} : {1'b0, a};
  wire signed [BW:0] b_ext = (SIGNED_B != 0)
      ? {b[BW-1], b} : {1'b0, b};
  reg signed [AW:0] a_r;
  reg signed [BW:0] b_r;
  reg signed [PW-1:0] m_r, p_r;
  always @(posedge clk) begin
    if (en_a) begin
      a_r <= a_ext;
      b_r <= b_ext;
    end
    if (en_m) m_r <= a_r * b_r;
    if (en_p) p_r <= m_r;
  end
  assign p = p_r;
''';
  return '''
module ${top}_hsl_mul #(
    parameter integer AW = 17, parameter integer BW = 17,
    parameter integer PW = 34,
    parameter integer SIGNED_A = 0, parameter integer SIGNED_B = 0
) (
    input wire clk,
    input wire en_a, input wire en_m, input wire en_p,
    input wire [AW-1:0] a, input wire [BW-1:0] b,
    output wire [PW-1:0] p
);
${xilinx ? '`ifdef SYNTHESIS\n$primitive`else\n$fallback`endif' : fallback}
endmodule
''';
}

/// 生成 HSL 单节点全流水数据通路的各级流水。`baseStage` 为本次生成在 core
/// 中的起始拍号。
List<HslPipeStage> buildHslPipeStages({
  required String top,
  required String id,
  required int pb,
  required String input,
  required int baseStage,
  String mul = '',
}) {
  final bw = 3 * pb;
  final mulName = mul.isEmpty ? '${top}_hsl_mul' : mul;
  final stages = <HslPipeStage>[];
  void add(String suffix, int width, String source, String expr) =>
      stages.add(HslPipeStage('${id}_$suffix', width, source, expr));

  String fq(String reg, String key) => _recQ.get_(reg, key);
  String packQ(String reg, [Map<String, String> overrides = const {}]) =>
      '{${[
        for (final k in _recQ.order.reversed) overrides[k] ?? fq(reg, k),
      ].join(', ')}}';

  /// 一个乘法级（双通道）：`${tag}a/b/c` 三个延迟级承载侧数据，DSP 原语的
  /// AREG/MREG/PREG 分别跟随这三级的 ready；消费级在 `${tag}c` 之后一拍。
  void addMulLevel({
    required String tag,
    required String operandStage,
    required String aS,
    required String bS,
    required String aT,
    required String bT,
    required int aw,
    required int bwBits,
    required int pw,
  }) {
    final k = baseStage + stages.length; // 操作数级在 core 中的绝对拍号
    final src = '''
  wire [$pw - 1:0] ${id}_${tag}_ps, ${id}_${tag}_pt;
  $mulName #(.AW($aw), .BW($bwBits), .PW($pw))
  ${id}_u_${tag}s (
      .clk(clk),
      .en_a(stage_ready[$k]), .en_m(stage_ready[${k + 1}]),
      .en_p(stage_ready[${k + 2}]),
      .a($aS), .b($bS), .p(${id}_${tag}_ps));
  $mulName #(.AW($aw), .BW($bwBits), .PW($pw))
  ${id}_u_${tag}t (
      .clk(clk),
      .en_a(stage_ready[$k]), .en_m(stage_ready[${k + 1}]),
      .en_p(stage_ready[${k + 2}]),
      .a($aT), .b($bT), .p(${id}_${tag}_pt));''';
    add('${tag}a', _recQ.width, src, packQ(operandStage));
    add('${tag}b', _recQ.width, '', '${id}_${tag}a_reg');
    add('${tag}c', _recQ.width, '', '${id}_${tag}b_reg');
  }

  // ---- 0：入口寄存 ----
  add('in', bw, '', input);

  // ---- 1：Q14 归一化 + 最大/最小 + den/差分（子模块，保留层级）----
  // 种子表的**读取寄存器**也放在这一级：地址取本级组合输出（rec M 的
  // sid/tid），时钟沿与本级 rec 同拍 → 数据在 q 级有效，整链 LAT 不变。
  add(
    'm',
    _recM.width,
    '''
  wire [${_recM.width - 1}:0] ${id}_m_v;
  ${top}_hsl_m #(.PIX_BITS(PIX_BITS)) ${id}_u_m (
      .px(${id}_in_reg), .rec(${id}_m_v));
  reg [16:0] ${id}_a0s, ${id}_a0t;
  generate
    if (USE_BRAM != 0) begin : g_seed_bram_$id
      // 种子表放 BRAM（1 个 BRAM18，真双口同时读 S/L 两个地址）。
      (* rom_style = "block" *) reg [16:0] ${id}_seed_rom [0:255];
      initial begin
${hslSeedRomInit('${id}_seed_rom')}      end
      always @(posedge clk) begin
        if (stage_ready[$baseStage + 1]) begin
          ${id}_a0s <= ${id}_seed_rom[${id}_m_v[${_recM.off('sid')} +: 8]];
          ${id}_a0t <= ${id}_seed_rom[${id}_m_v[${_recM.off('tid')} +: 8]];
        end
      end
    end else begin : g_seed_lut_$id
      // 组合 ROM（上一版实现，LUT 逻辑）：同一组寄存器承接，时序一致。
      // 尽量让综合器留在 LUT 逻辑（rom_style=logic 只是提示：Vivado 仍可能
      // 自行识别成 ROM 并推断成 BRAM，此时与 USE_BRAM=1 结果相同）。
      (* rom_style = "logic" *) reg [16:0] ${id}_a0s_l, ${id}_a0t_l;
      always @(posedge clk) begin
        if (stage_ready[$baseStage + 1]) begin
          ${id}_a0s_l <= f_hsl_seed({1'b1, ${id}_m_v[${_recM.off('sid')} +: 8]});
          ${id}_a0t_l <= f_hsl_seed({1'b1, ${id}_m_v[${_recM.off('tid')} +: 8]});
        end
      end
      always @* begin
        ${id}_a0s = ${id}_a0s_l;
        ${id}_a0t = ${id}_a0t_l;
      end
    end
  endgenerate''',
    '${id}_m_v',
  );


  // ---- 2：除法预备（子模块：规格化 / 移位量 / 打包；种子值由上一级寄存）----
  add(
    'q',
    _recQ.width,
    '''
  wire [${_recQ.width - 1}:0] ${id}_q_v;
  ${top}_hsl_q ${id}_u_q (
      .rec(${id}_m_reg), .a0s(${id}_a0s), .a0t(${id}_a0t), .q(${id}_q_v));''',
    '${id}_q_v',
  );


  // ---- 3/4/5：乘法级 1（dn × A0）----
  addMulLevel(
    tag: 'm1',
    operandStage: '${id}_q_reg',
    aS: fq('${id}_q_reg', 'dns'),
    bS: fq('${id}_q_reg', 'a0s'),
    aT: fq('${id}_q_reg', 'dnt'),
    bT: fq('${id}_q_reg', 'a0t'),
    aw: _denW,
    bwBits: _denW,
    pw: _p1W,
  );

  // ---- 6：牛顿因子 nf = 2^17 - (p >> 17) ----
  add(
    'p1',
    _recQ.width,
    '''
  wire [17:0] ${id}_nfx_s = 18'd131072 - {1'b0, ${id}_m1_ps[33:17]};
  wire [17:0] ${id}_nfx_t = 18'd131072 - {1'b0, ${id}_m1_pt[33:17]};
  wire [16:0] ${id}_nf_s = ${id}_nfx_s[16:0];
  wire [16:0] ${id}_nf_t = ${id}_nfx_t[16:0];''',
    packQ('${id}_m1c_reg', {
      'slots': '${id}_nf_s',
      'slott': '${id}_nf_t',
    }),
  );

  // ---- 7/8/9：乘法级 2（A0 × nf）----
  addMulLevel(
    tag: 'm2',
    operandStage: '${id}_p1_reg',
    aS: fq('${id}_p1_reg', 'a0s'),
    bS: fq('${id}_p1_reg', 'slots'),
    aT: fq('${id}_p1_reg', 'a0t'),
    bT: fq('${id}_p1_reg', 'slott'),
    aw: _denW,
    bwBits: _denW,
    pw: _p1W,
  );

  // ---- 10：R = (p >> 16) ----
  add(
    'p2',
    _recQ.width,
    '''
  wire [16:0] ${id}_rw_s = ${id}_m2_ps[32:16];
  wire [16:0] ${id}_rw_t = ${id}_m2_pt[32:16];''',
    packQ('${id}_m2c_reg', {
      'slots': '${id}_rw_s',
      'slott': '${id}_rw_t',
    }),
  );

  // ---- 11/12/13：乘法级 3（nv × R）----
  addMulLevel(
    tag: 'm3',
    operandStage: '${id}_p2_reg',
    aS: fq('${id}_p2_reg', 'nvs'),
    bS: fq('${id}_p2_reg', 'slots'),
    aT: fq('${id}_p2_reg', 'nvt'),
    bT: fq('${id}_p2_reg', 'slott'),
    aw: _nvW,
    bwBits: _denW,
    pw: _p1W,
  );

  // ---- 14：q0 = p >> (19 - k) ----
  add(
    'p3',
    _recQ.width,
    '''
  wire [16:0] ${id}_qw_s = ${id}_m3_ps >> ${fq('${id}_m3c_reg', 'shs')};
  wire [16:0] ${id}_qw_t = ${id}_m3_pt >> ${fq('${id}_m3c_reg', 'sht')};''',
    packQ('${id}_m3c_reg', {
      'slots': '${id}_qw_s',
      'slott': '${id}_qw_t',
    }),
  );

  // ---- 15/16/17：乘法级 4（q0 × den）----
  addMulLevel(
    tag: 'm4',
    operandStage: '${id}_p3_reg',
    aS: '${id}_p3_reg[${_recQ.off('slots')} +: 15]',
    bS: fq('${id}_p3_reg', 'dens'),
    aT: '${id}_p3_reg[${_recQ.off('slott')} +: 15]',
    bT: fq('${id}_p3_reg', 'dent'),
    aw: 15,
    bwBits: _denW,
    pw: _p5W,
  );

  // ---- 18：精确余数修正 + 色相基点 + 除 6（子模块）----
  add(
    'p4',
    _recOut.width,
    '''
  wire [${_recOut.width - 1}:0] ${id}_p4_v;
  ${top}_hsl_corr ${id}_u_corr (
      .rec(${id}_m4c_reg), .p4s(${id}_m4_ps), .p4t(${id}_m4_pt),
      .out(${id}_p4_v));''',
    '${id}_p4_v',
  );


  // ---- 19/20/21：缩放乘法级（h/s/l × MAXV）----
  final scK = baseStage + 19;
  final sc = StringBuffer('''
  wire [${_p5W - 1}:0] ${id}_m5_ph, ${id}_m5_ps, ${id}_m5_pl;''');
  for (final ch in ['h', 's', 'l']) {
    sc.writeln('''
  $mulName #(.AW($_lW), .BW(16), .PW($_p5W))
  ${id}_u_m5$ch (
      .clk(clk),
      .en_a(stage_ready[$scK]), .en_m(stage_ready[${scK + 1}]),
      .en_p(stage_ready[${scK + 2}]),
      .a(${_recOut.get_('${id}_p4_reg', ch)}),
      .b(${zeroPad16('MAXV', pb)}),
      .p(${id}_m5_p$ch));''');
  }
  add(
    'm5a',
    _recOut.width,
    sc.toString(),
    '{${[
      for (final k in _recOut.order.reversed) _recOut.get_('${id}_p4_reg', k),
    ].join(', ')}}',
  );
  add('m5b', _recOut.width, '', '${id}_m5a_reg');
  add('m5c', _recOut.width, '', '${id}_m5b_reg');

  // ---- 22：四舍五入 + 钳位输出 ----
  add(
    'o',
    bw,
    '''
  wire signed [31:0] ${id}_rh = ({1'b0, ${id}_m5_ph[30:0]} + 32'sd8192) >>> 14;
  wire signed [31:0] ${id}_rsc = ({1'b0, ${id}_m5_ps[30:0]} + 32'sd8192) >>> 14;
  wire signed [31:0] ${id}_rl = ({1'b0, ${id}_m5_pl[30:0]} + 32'sd8192) >>> 14;''',
    '{f_clamp_q14(${id}_rh), f_clamp_q14(${id}_rsc), f_clamp_q14(${id}_rl)}',
  );
  return stages;
}

// ---------------------------------------------------------------------------
// HSL→RGB：全流水 DSP 数据通路
//
// 与 RGB→HSL 同一套思路（显式 DSP48E2 + 分级 CE + 逐级弹性），但数学上更简单：
// HSL→RGB 全程只有**乘法与移位**，没有除法器。
//   q  = l < 0.5 ? l + q14mul(l, s) : l + s - q14mul(l, s)
//   p  = 2l - q
//   qm = q - p
//   r/g/b = hue(p, q, t)   （t 由 h×3 与 ±16384 回绕得出，三支路按 t 的区间选择）
//   R/G/B = clamp(round(ch × MAXV / 16384))
//
// 校验：`scratch/hsl2rgb_pipe_math.dart` 与 Dart 定点参考 `_hslToRgbQ14`
// 逐位一致（256³ 全组合 + PIX_BITS 10/12/16 抽样 0 失配）。
// ---------------------------------------------------------------------------

/// HSL→RGB 的三段组合逻辑各自成一级子模块并保留层级（`keep_hierarchy`），
/// 核心只留流水寄存器与 DSP 原语：避免综合后单一 cellview 摊成扁平网表
/// （`[Netlist 29-101]/[29-43] not ideal for floorplanning`）。
String hsl2RgbBlockDefs(String top) {
  final wn = _recN.width;
  final wq = _recQ2.width;
  final wr = _recRgb.width;
  String nf(String key) => 'rec[${_recN.off(key)} +: ${_recN.w(key)}]';
  String qf(String key) => 'rec[${_recQ2.off(key)} +: ${_recQ2.w(key)}]';
  final n = '''
(* keep_hierarchy = "yes" *)
module ${top}_hsl2rgb_n #(
    parameter integer PIX_BITS = 8
) (
    input wire [3*PIX_BITS-1:0] px,
    output wire [${wn - 1}:0] rec
);
  localparam integer MAXV = (1 << PIX_BITS) - 1;
${divMaxvFunction()}
  // H/S/L Q14 normalize (round v*16384 over MAXV) via Mersenne folding.
  wire [PIX_BITS+13:0] hs = px[3*PIX_BITS-1 -: PIX_BITS] << 14;
  wire [PIX_BITS+14:0] hd = {1'b0, hs} + (MAXV >> 1);
  wire [14:0] hn = f_div_maxv(hd);
  wire [13:0] h14 = (hn == 15'd16384) ? 14'd0 : hn[13:0];
  wire [PIX_BITS+13:0] ss = px[2*PIX_BITS-1 -: PIX_BITS] << 14;
  wire [PIX_BITS+14:0] sd = {1'b0, ss} + (MAXV >> 1);
  wire [14:0] s14 = f_div_maxv(sd);
  wire [PIX_BITS+13:0] ls = px[PIX_BITS-1:0] << 14;
  wire [PIX_BITS+14:0] ld = {1'b0, ls} + (MAXV >> 1);
  wire [14:0] l14 = f_div_maxv(ld);
  wire [15:0] h3 = {2'd0, h14} * 3;
  wire [16:0] tr0 = {1'd0, h3} + 17'd16384;
  wire [16:0] tr1 = (tr0 >= 17'd49152) ? (tr0 - 17'd49152) : tr0;
  wire [15:0] tr = tr1[15:0];
  wire [15:0] tb = (h3 >= 16'd16384) ? (h3 - 16'd16384) : (h3 + 16'd32768);
  assign rec = {tb, h3, tr, s14, l14};
endmodule
''';
  final q = '''
(* keep_hierarchy = "yes" *)
module ${top}_hsl2rgb_q (
    input wire [${wn - 1}:0] rec,
    input wire [29:0] lsm,
    output wire [${wq - 1}:0] q
);
  wire [15:0] l1 = {1'b0, ${nf('l')}};
  wire [15:0] s1 = {1'b0, ${nf('s')}};
  wire [14:0] mul = (lsm + 30'd8192) >> 14;
  wire snz = (s1 != 16'd0);
  wire [15:0] qv = !snz ? 16'd0
      : ((l1 < 16'd8192) ? (l1 + {1'b0, mul}) : (l1 + s1 - {1'b0, mul}));
  wire [15:0] pv = !snz ? 16'd0 : ({1'b0, l1} << 1) - qv;
  wire [15:0] qm = !snz ? 16'd0 : qv - pv;
  wire [15:0] tr1v = ${nf('tr')};
  wire [15:0] tg1v = ${nf('tg')};
  wire [15:0] tb1v = ${nf('tb')};
  wire [15:0] opr = (tr1v < 16'd8192) ? tr1v
      : ((tr1v < 16'd32768) ? (16'd32768 - tr1v) : 16'd0);
  wire [15:0] opg = (tg1v < 16'd8192) ? tg1v
      : ((tg1v < 16'd32768) ? (16'd32768 - tg1v) : 16'd0);
  wire [15:0] opb = (tb1v < 16'd8192) ? tb1v
      : ((tb1v < 16'd32768) ? (16'd32768 - tb1v) : 16'd0);
  wire [1:0] selr = (tr1v < 16'd8192) ? 2'd0
      : ((tr1v < 16'd24576) ? 2'd1 : ((tr1v < 16'd32768) ? 2'd0 : 2'd2));
  wire [1:0] selg = (tg1v < 16'd8192) ? 2'd0
      : ((tg1v < 16'd24576) ? 2'd1 : ((tg1v < 16'd32768) ? 2'd0 : 2'd2));
  wire [1:0] selb = (tb1v < 16'd8192) ? 2'd0
      : ((tb1v < 16'd24576) ? 2'd1 : ((tb1v < 16'd32768) ? 2'd0 : 2'd2));
  assign q = {snz, selb, selg, selr, opb[14:0], opg[14:0], opr[14:0], l1,
      qm, pv, qv};
endmodule
''';
  final c = '''
(* keep_hierarchy = "yes" *)
module ${top}_hsl2rgb_c (
    input wire [${wq - 1}:0] rec,
    input wire [27:0] pr,
    input wire [27:0] pg,
    input wire [27:0] pb,
    output wire [${wr - 1}:0] rgb
);
  wire [15:0] p2v = ${qf('p')};
  wire [15:0] q2v = ${qf('q')};
  wire [15:0] l2v = ${qf('lc')};
  wire snz2 = ${qf('snz')};
  wire [1:0] selr = ${qf('selr')};
  wire [1:0] selg = ${qf('selg')};
  wire [1:0] selb = ${qf('selb')};
  wire [14:0] hr = (pr + 28'd4096) >> 13;
  wire [14:0] hg = (pg + 28'd4096) >> 13;
  wire [14:0] hb = (pb + 28'd4096) >> 13;
  wire [15:0] rv = !snz2 ? l2v
      : ((selr == 2'd1) ? q2v
        : ((selr == 2'd2) ? p2v : (p2v + {1'b0, hr})));
  wire [15:0] gv = !snz2 ? l2v
      : ((selg == 2'd1) ? q2v
        : ((selg == 2'd2) ? p2v : (p2v + {1'b0, hg})));
  wire [15:0] bv = !snz2 ? l2v
      : ((selb == 2'd1) ? q2v
        : ((selb == 2'd2) ? p2v : (p2v + {1'b0, hb})));
  assign rgb = {bv, gv, rv};
endmodule
''';
  return '$n\n$q\n$c';
}

/// HSL→RGB 流水线单节点总拍数。
const int kHsl2RgbPipeLatency = 14;

/// HSL→RGB 级 1 记录：l / s 与三条色相支路 t。
final _recN = _Rec()
  ..add('l', _nvW) // 归一化后 ≤ 16384（15 位）
  ..add('s', _nvW)
  ..add('tr', _lW)
  ..add('tg', _lW)
  ..add('tb', _lW);

/// 级 5 记录：q / p / qm、三通道乘法操作数与分支选择、s==0 标志、l 备份。
final _recQ2 = _Rec()
  ..add('q', _lW)
  ..add('p', _lW)
  ..add('qm', _lW)
  ..add('lc', _lW)
  ..add('opr', 15)
  ..add('opg', 15)
  ..add('opb', 15)
  ..add('selr', 2)
  ..add('selg', 2)
  ..add('selb', 2)
  ..add('snz', 1);

/// 级 9 记录：三通道 Q14 结果。
final _recRgb = _Rec()
  ..add('r', _lW)
  ..add('g', _lW)
  ..add('b', _lW);

/// 生成 HSL→RGB 单节点全流水数据通路的各级流水。
List<HslPipeStage> buildHsl2RgbPipeStages({
  required String top,
  required String id,
  required int pb,
  required String input,
  required int baseStage,
  String mul = '',
  /// true 时末级输出 `{b, g, r}` 三通道 0..MAXV 码（16 位/通道）记录，
  /// 供 HSL→YUV 接着做矩阵；false 输出 3×PIX_BITS 像素。
  bool rgbCodes = false,
}) {
  final bw = 3 * pb;
  final mulName = mul.isEmpty ? '${top}_hsl_mul' : mul;
  final stages = <HslPipeStage>[];
  void add(String suffix, int width, String source, String expr) =>
      stages.add(HslPipeStage('${id}_$suffix', width, source, expr));

  String fn(String reg, String key) => _recN.get_(reg, key);
  String fq(String reg, String key) => _recQ2.get_(reg, key);
  String fr(String reg, String key) => _recRgb.get_(reg, key);

  String packN(String reg) =>
      '{${[for (final k in _recN.order.reversed) fn(reg, k)].join(', ')}}';
  String packQ(String reg) =>
      '{${[for (final k in _recQ2.order.reversed) fq(reg, k)].join(', ')}}';
  String packRgb(String reg) =>
      '{${[for (final k in _recRgb.order.reversed) fr(reg, k)].join(', ')}}';

  /// 一级乘法（可 1～3 路并行）：DSP 的三级内部寄存器各跟所在流水级的 ready，
  /// 侧数据走框架寄存器；消费级固定在操作数级 + 4。
  void addMulLevel({
    required String tag,
    required String operandStage,
    required int recWidth,
    required String pack,
    required List<({String ch, String a, String b, int aw, int bwBits, int pw})>
    lanes,
  }) {
    final k = baseStage + stages.length;
    final b = StringBuffer();
    for (final lane in lanes) {
      b.writeln('''
  wire [${lane.pw - 1}:0] ${id}_${tag}_p${lane.ch};
  $mulName #(.AW(${lane.aw}), .BW(${lane.bwBits}), .PW(${lane.pw}))
  ${id}_u_$tag${lane.ch} (
      .clk(clk),
      .en_a(stage_ready[$k]), .en_m(stage_ready[${k + 1}]),
      .en_p(stage_ready[${k + 2}]),
      .a(${lane.a}), .b(${lane.b}),
      .p(${id}_${tag}_p${lane.ch}));''');
    }
    add('${tag}a', recWidth, b.toString(), pack);
    add('${tag}b', recWidth, '', '${id}_${tag}a_reg');
    add('${tag}c', recWidth, '', '${id}_${tag}b_reg');
  }

  // ---- 0：入口寄存 ----
  add('in', bw, '', input);

  // ---- 1：Q14 归一化 + 色相指数（子模块，保留层级）----
  add(
    'n',
    _recN.width,
    '''
  wire [${_recN.width - 1}:0] ${id}_n_v;
  ${top}_hsl2rgb_n #(.PIX_BITS(PIX_BITS)) ${id}_u_n (
      .px(${id}_in_reg), .rec(${id}_n_v));''',
    '${id}_n_v',
  );

  // ---- 2/3/4：乘法级 1（l × s）----
  addMulLevel(
    tag: 'k1',
    operandStage: '${id}_n_reg',
    recWidth: _recN.width,
    pack: packN('${id}_n_reg'),
    lanes: [
      (
        ch: 'ls',
        a: fn('${id}_n_reg', 'l'),
        b: fn('${id}_n_reg', 's'),
        aw: _nvW,
        bwBits: _nvW,
        pw: 30,
      ),
    ],
  );

  // ---- 5：q / p / qm 与三通道乘法操作数（子模块）----
  add(
    'p1',
    _recQ2.width,
    '''
  wire [${_recQ2.width - 1}:0] ${id}_p1_v;
  ${top}_hsl2rgb_q ${id}_u_p1 (
      .rec(${id}_k1c_reg), .lsm(${id}_k1_pls), .q(${id}_p1_v));''',
    '${id}_p1_v',
  );

  // ---- 6/7/8：乘法级 2（qm × op，三通道并行）----
  addMulLevel(
    tag: 'k2',
    operandStage: '${id}_p1_reg',
    recWidth: _recQ2.width,
    pack: packQ('${id}_p1_reg'),
    lanes: [
      for (final ch in ['r', 'g', 'b'])
        (
          ch: ch,
          a: fq('${id}_p1_reg', 'qm'),
          b: fq('${id}_p1_reg', 'op$ch'),
          aw: _lW,
          bwBits: 15,
          pw: 28,
        ),
    ],
  );

  // ---- 9：还原 r/g/b（Q14，子模块）----
  add(
    'p2',
    _recRgb.width,
    '''
  wire [${_recRgb.width - 1}:0] ${id}_p2_v;
  ${top}_hsl2rgb_c ${id}_u_p2 (
      .rec(${id}_k2c_reg), .pr(${id}_k2_pr), .pg(${id}_k2_pg),
      .pb(${id}_k2_pb), .rgb(${id}_p2_v));''',
    '${id}_p2_v',
  );

  // ---- 10/11/12：乘法级 3（× MAXV，三通道并行）----
  addMulLevel(
    tag: 'k3',
    operandStage: '${id}_p2_reg',
    recWidth: _recRgb.width,
    pack: packRgb('${id}_p2_reg'),
    lanes: [
      for (final ch in ['r', 'g', 'b'])
        (
          ch: ch,
          a: fr('${id}_p2_reg', ch),
          b: '{{${16 - pb}{1\'b0}}, MAXV}',
          aw: _lW,
          bwBits: 16,
          pw: 31,
        ),
    ],
  );

  // ---- 13：舍入 + 钳位输出 ----
  final oSrc = '''
  wire signed [31:0] rr = ({1'b0, ${id}_k3_pr} + 32'sd8192) >>> 14;
  wire signed [31:0] rg = ({1'b0, ${id}_k3_pg} + 32'sd8192) >>> 14;
  wire signed [31:0] rb = ({1'b0, ${id}_k3_pb} + 32'sd8192) >>> 14;
  wire [15:0] rc16 = ${zeroPad16('f_clamp_q14(rr)', pb)};
  wire [15:0] gc16 = ${zeroPad16('f_clamp_q14(rg)', pb)};
  wire [15:0] bc16 = ${zeroPad16('f_clamp_q14(rb)', pb)};''';
  if (rgbCodes) {
    add('o', 48, oSrc, '{bc16, gc16, rc16}');
  } else {
    add(
      'o',
      bw,
      oSrc,
      '{f_clamp_q14(rr), f_clamp_q14(rg), f_clamp_q14(rb)}',
    );
  }
  return stages;
}

// ---------------------------------------------------------------------------
// HSL→YUV：全流水 DSP 数据通路
//
// HSL→RGB（复用 `buildHsl2RgbPipeStages` 的 `rgbCodes` 形态，产出 0..MAXV
// 的 r/g/b 码）→ BT.601 定点矩阵（9 个 DSP：y/u/v 各 3 个乘加）→ 舍入钳位。
//
// 与 Dart 参考 `cscFixedPixel('csc_hsl2yuv')`（`_hslToRgbQ14` + `rgbToYuv`
// 的 BT.601 常数）逐位一致：`scratch/hsl2yuv_pipe_math.dart` 256³ 全组合 +
// PIX_BITS 10/12/16 抽样 0 失配。
// ---------------------------------------------------------------------------

/// HSL→YUV 流水线单节点总拍数（HSL→RGB 14 拍 + 矩阵 4 拍）。
const int kHsl2YuvPipeLatency = 18;

/// `YUV_STANDARD` 参数（0=BT.601 / 1=BT.709 / 2=BT.2020）选择系数时的
/// Verilog 三目表达式；系数是参数常量，展开后仍是常量，DSP 的 B 端口可直接吃。
String _stdSel18(List<int> coefs) {
  String lit(int v) => v < 0 ? "-18'sd${-v}" : "18'sd$v";
  return '((YUV_STANDARD == 0) ? ${lit(coefs[0])} : '
      '((YUV_STANDARD == 1) ? ${lit(coefs[1])} : ${lit(coefs[2])}))';
}

/// RGB→YUV 三套标准下的 (cyR, cyG, cyB) / (cuR, cuG) / (cvG, cvB)。
List<List<int>> _rgbToYuvRows(String which) {
  final a = rgbToYuvCoefficients('bt601');
  final b = rgbToYuvCoefficients('bt709');
  final c = rgbToYuvCoefficients('bt2020');
  return switch (which) {
    'y' => [
      [a.cyR, b.cyR, c.cyR],
      [a.cyG, b.cyG, c.cyG],
      [a.cyB, b.cyB, c.cyB],
    ],
    'u' => [
      [a.cuR, b.cuR, c.cuR],
      [a.cuG, b.cuG, c.cuG],
      const [32768, 32768, 32768],
    ],
    _ => [
      const [32768, 32768, 32768],
      [a.cvG, b.cvG, c.cvG],
      [a.cvB, b.cvB, c.cvB],
    ],
  };
}

/// 生成 HSL→YUV 单节点全流水数据通路的各级流水。
List<HslPipeStage> buildHsl2YuvPipeStages({
  required String top,
  required String id,
  required int pb,
  required String input,
  required int baseStage,
  String mul = '',
}) {
  final bw = 3 * pb;
  final mulName = mul.isEmpty ? '${top}_hsl_mul' : mul;
  // HSL→RGB 部分（末级 `${id}_o_reg` 为 {b, g, r} 三通道 0..MAXV 码）。
  final stages = buildHsl2RgbPipeStages(
    top: top,
    id: id,
    pb: pb,
    input: input,
    baseStage: baseStage,
    mul: mulName,
    rgbCodes: true,
  );
  void add(String suffix, int width, String source, String expr) =>
      stages.add(HslPipeStage('${id}_$suffix', width, source, expr));

  String code(String ch) => '${id}_o_reg[${16 * "rgb".indexOf(ch)} +: 16]';

  // ---- 14/15/16：BT.601 矩阵乘法级（y/u/v 各 3 个 DSP48E2）----
  final k = baseStage + stages.length;
  final b = StringBuffer();
  for (final row in ['y', 'u', 'v']) {
    final rows = _rgbToYuvRows(row);
    for (var idx = 0; idx < 3; idx++) {
      final ch = 'rgb'[idx];
      b.writeln('''
  wire signed [39:0] ${id}_mx_p$row$idx;
  $mulName #(.AW(16), .BW(18), .PW(40), .SIGNED_A(0), .SIGNED_B(1))
  ${id}_u_mx_$row$idx (
      .clk(clk),
      .en_a(stage_ready[$k]), .en_m(stage_ready[${k + 1}]),
      .en_p(stage_ready[${k + 2}]),
      .a(${code(ch)}), .b(${_stdSel18(rows[idx])}),
      .p(${id}_mx_p$row$idx));''');
    }
  }
  add('y1a', 48, b.toString(), '${id}_o_reg');
  add('y1b', 48, '', '${id}_y1a_reg');
  add('y1c', 48, '', '${id}_y1b_reg');

  // ---- 17：三路累加 + 舍入 + 钳位输出 ----
  add(
    'y2',
    bw,
    '''
  wire signed [40:0] ${id}_half = \$signed({24'd0, MAXV}) >>> 1;
  wire signed [40:0] ${id}_sum_y = ${id}_mx_py0 + ${id}_mx_py1 +
      ${id}_mx_py2 + 41'sd32768;
  wire signed [40:0] ${id}_sum_u = ${id}_mx_pu0 + ${id}_mx_pu1 +
      ${id}_mx_pu2 + 41'sd32768;
  wire signed [40:0] ${id}_sum_v = ${id}_mx_pv0 + ${id}_mx_pv1 +
      ${id}_mx_pv2 + 41'sd32768;
  wire signed [40:0] ${id}_yv = ${id}_sum_y >>> 16;
  wire signed [40:0] ${id}_uv = (${id}_sum_u >>> 16) + ${id}_half;
  wire signed [40:0] ${id}_vv = (${id}_sum_v >>> 16) + ${id}_half;''',
    '{f_clamp_q14(${id}_yv), f_clamp_q14(${id}_uv), f_clamp_q14(${id}_vv)}',
  );
  return stages;
}

// ---------------------------------------------------------------------------
// YUV→HSL：全流水 DSP 数据通路
//
// BT.601 定点矩阵（4 个 DSP：crV·V'、cgU·U'、cgV·V'、cbU·U'，U'/V' 为
// 减去中点的有符号差值）→ 相加/舍入/钳位得到 R/G/B 码 → 复用 RGB→HSL 全流水
// 通路（`buildHslPipeStages`，含 Q14 归一化 + 四级定点除法 + 缩放）。
//
// 与 Dart 参考 `cscFixedPixel('csc_yuv2hsl')`（`yuvToRgb` BT.601 +
// `_rgbToHslQ14`）逐位一致：`scratch/yuv2hsl_pipe_math.dart` 256³ 全组合 +
// PIX_BITS 10/12/16 抽样 0 失配。
// ---------------------------------------------------------------------------

/// YUV→HSL 流水线单节点总拍数（矩阵 5 拍 + RGB→HSL 23 拍）。
const int kYuv2HslPipeLatency = kHslPipeLatency + 5;

/// 生成 YUV→HSL 单节点全流水数据通路的各级流水。
List<HslPipeStage> buildYuv2HslPipeStages({
  required String top,
  required String id,
  required int pb,
  required String input,
  required int baseStage,
  String mul = '',
}) {
  final bw = 3 * pb;
  final mulName = mul.isEmpty ? '${top}_hsl_mul' : mul;
  final stages = <HslPipeStage>[];
  void add(String suffix, int width, String source, String expr) =>
      stages.add(HslPipeStage('${id}_$suffix', width, source, expr));

  // 矩阵记录：只带 Y 码（4 个乘积由 DSP 自带寄存器搬运）。

  // ---- 0：入口寄存 ----
  add('yin', bw, '', input);

  // ---- 1：BT.601 矩阵乘法级（4 个 DSP，U'/V' 为有符号差值）----
  final c601 = yuvToRgbCoefficients('bt601');
  final c709 = yuvToRgbCoefficients('bt709');
  final c2020 = yuvToRgbCoefficients('bt2020');
  List<int> trip(int a, int b, int c) => [a, b, c];
  final k = baseStage + stages.length; // 操作数级 = 0
  final src = StringBuffer('''
  wire signed [$pb:0] ${id}_half = \$signed({1'b0, MAXV}) >>> 1;
  wire signed [$pb:0] ${id}_uu =
      \$signed({1'b0, ${id}_yin_reg[${2 * pb - 1} -: $pb]}) - ${id}_half;
  wire signed [$pb:0] ${id}_vv =
      \$signed({1'b0, ${id}_yin_reg[${pb - 1}:0]}) - ${id}_half;''');
  for (final (tag, a, b) in [
    ('rr', '${id}_vv',
        _stdSel18(trip(c601.crV, c709.crV, c2020.crV))),
    ('gg1', '${id}_uu',
        _stdSel18(trip(c601.cgU, c709.cgU, c2020.cgU))),
    ('gg2', '${id}_vv',
        _stdSel18(trip(c601.cgV, c709.cgV, c2020.cgV))),
    ('bb', '${id}_uu',
        _stdSel18(trip(c601.cbU, c709.cbU, c2020.cbU))),
  ]) {
    src.writeln('''
  wire signed [39:0] ${id}_mk_p$tag;
  $mulName #(.AW(${pb + 1}), .BW(18), .PW(40), .SIGNED_A(1), .SIGNED_B(1))
  ${id}_u_mk_$tag (
      .clk(clk),
      .en_a(stage_ready[$k]), .en_m(stage_ready[${k + 1}]),
      .en_p(stage_ready[${k + 2}]),
      .a($a), .b($b),
      .p(${id}_mk_p$tag));''');
  }
  add('ya', pb, src.toString(), '${id}_yin_reg[${bw - 1} -: $pb]');
  add('yb', pb, '', '${id}_ya_reg');
  add('yc', pb, '', '${id}_yb_reg');

  // ---- 4：矩阵累加 + 舍入 + 钳位 → R/G/B 码 ----
  add(
    'yrgb',
    bw,
    '''
  wire signed [40:0] ${id}_yy = \$signed({24'd0, ${id}_yc_reg[0 +: $pb]});
  wire signed [40:0] ${id}_sum_r = ${id}_mk_prr + 41'sd32768;
  wire signed [40:0] ${id}_sum_g = ${id}_mk_pgg1 + ${id}_mk_pgg2 + 41'sd32768;
  wire signed [40:0] ${id}_sum_b = ${id}_mk_pbb + 41'sd32768;
  wire signed [40:0] ${id}_rv = ${id}_yy + (${id}_sum_r >>> 16);
  wire signed [40:0] ${id}_gv = ${id}_yy + (${id}_sum_g >>> 16);
  wire signed [40:0] ${id}_bv = ${id}_yy + (${id}_sum_b >>> 16);''',
    // 输出按像素打包 {R, G, B}（R 在最高位），直接喂给 _hsl_m 子模块。
    '{f_clamp_q14(${id}_rv), f_clamp_q14(${id}_gv), f_clamp_q14(${id}_bv)}',
  );

  // ---- 5 起：复用 RGB→HSL 全流水通路（输入为上一步的 R/G/B 码）----
  stages.addAll(
    buildHslPipeStages(
      top: top,
      id: id,
      pb: pb,
      input: '${id}_yrgb_reg',
      baseStage: baseStage + stages.length,
      mul: mulName,
    ),
  );
  return stages;
}
