/// func_fixed 的 DSP_PIPE=3 全流水数据通路。仅在该档且 GSTRATEGY 非 0 时
/// 实例化；原 0/1/2 档保留原组合单元与分级结构。
library;

const int _fullBandCount = 16;

int mbFxFullLatency(bool serial) => serial ? 889 : 89;

int mbFxLatency(bool serial, int dspPipe, {int gstrategy = 2}) {
  if (dspPipe == 3 && gstrategy != 0) return mbFxFullLatency(serial);
  final legacyPipe = dspPipe.clamp(0, 2);
  return serial ? 16 * (1 + legacyPipe) + 4 : 5 + legacyPipe;
}

({String hc, String q, String dh, String s1, String l1}) _fullPorts(int i) => (
  hc: 'par_b${i}_hc',
  q: 'par_b${i}_q',
  dh: 'par_b${i}_dh',
  s1: 'par_b${i}_s1',
  l1: 'par_b${i}_l1',
);

String mbDspMulDef(String prefix, bool xilinx) {
  final primitive = '''
`ifdef SYNTHESIS
  wire [29:0] a_pad;
  wire [17:0] b_pad;
  wire [47:0] dsp_p;
  generate
    if (AW == 30) begin : g_a_full
      assign a_pad = a;
    end else if (SIGNED_A != 0) begin : g_a_signed
      assign a_pad = {{(30-AW){a[AW-1]}}, a};
    end else begin : g_a_unsigned
      assign a_pad = {{(30-AW){1'b0}}, a};
    end
    if (BW == 18) begin : g_b_full
      assign b_pad = b;
    end else if (SIGNED_B != 0) begin : g_b_signed
      assign b_pad = {{(18-BW){b[BW-1]}}, b};
    end else begin : g_b_unsigned
      assign b_pad = {{(18-BW){1'b0}}, b};
    end
    if ((BW == 18) && (SIGNED_B == 0)) begin : g_b_unsigned_18
      wire [PW-1:0] a_wide = a;
      reg signed [PW-1:0] corr0, corr1, corr2, p_corr;
      always @(posedge clk) if (en) begin
        corr0 <= b[17] ? (a_wide << 18) : {PW{1'b0}};
        corr1 <= corr0;
        corr2 <= corr1;
        p_corr <= \$signed(dsp_p[PW-1:0]) + corr2;
      end
      assign p = p_corr;
    end else if (PW > 48) begin : g_p_extend
      assign p = {{(PW-48){dsp_p[47]}}, dsp_p};
    end else if (PW == 48) begin : g_p_full
      assign p = dsp_p;
    end else begin : g_p_truncate
      assign p = dsp_p[PW-1:0];
    end
  endgenerate
  DSP48E2 #(
      .A_INPUT("DIRECT"), .B_INPUT("DIRECT"),
      .AMULTSEL("A"), .BMULTSEL("B"),
      .AREG(1), .BREG(1), .ACASCREG(1), .BCASCREG(1),
      .OPMODEREG(0), .MREG(1), .PREG(1), .USE_MULT("MULTIPLY")
  ) u_dsp (
      .CLK(clk), .A(a_pad), .B(b_pad), .C(48'd0), .D(27'd0),
      .INMODE(5'd0), .OPMODE(9'b000000101), .ALUMODE(4'd0),
      .CARRYIN(1'b0), .CARRYINSEL(3'd0),
      .ACIN(30'd0), .BCIN(18'd0), .CARRYCASCIN(1'b0), .PCIN(48'd0),
      .CEA1(1'b0), .CEA2(en), .CEB1(1'b0), .CEB2(en),
      .CEAD(1'b0), .CEALUMODE(1'b0), .CEC(1'b0), .CECARRYIN(1'b0),
      .CECTRL(1'b0), .CED(1'b0), .CEINMODE(1'b0), .CEM(en), .CEP(en),
      .MULTSIGNIN(1'b0),
      .RSTA(1'b0), .RSTB(1'b0), .RSTC(1'b0), .RSTD(1'b0),
      .RSTINMODE(1'b0), .RSTM(1'b0), .RSTP(1'b0),
      .RSTALLCARRYIN(1'b0), .RSTALUMODE(1'b0), .RSTCTRL(1'b0),
      .ACOUT(), .BCOUT(), .CARRYCASCOUT(), .CARRYOUT(),
      .MULTSIGNOUT(), .OVERFLOW(), .PATTERNBDETECT(), .PATTERNDETECT(),
      .PCOUT(), .UNDERFLOW(), .XOROUT(), .P(dsp_p)
  );
`else
''';
  final fallback = '''
  wire signed [AW:0] a_ext = SIGNED_A ? {a[AW-1], a} : {1'b0, a};
  wire signed [BW:0] b_ext = ((BW == 18) && (SIGNED_B == 0))
      ? {b[BW-1], b} : (SIGNED_B ? {b[BW-1], b} : {1'b0, b});
  reg signed [AW:0] a_reg;
  reg signed [BW:0] b_reg;
  reg signed [PW-1:0] mul_m, p_reg;
  always @(posedge clk) if (en) begin
    a_reg <= a_ext;
    b_reg <= b_ext;
    mul_m <= a_reg * b_reg;
    p_reg <= mul_m;
  end
  generate
    if ((BW == 18) && (SIGNED_B == 0)) begin : g_b_unsigned_18
      wire [PW-1:0] a_wide = a;
      reg signed [PW-1:0] corr0, corr1, corr2, p_corr;
      always @(posedge clk) if (en) begin
        corr0 <= b[17] ? (a_wide << 18) : {PW{1'b0}};
        corr1 <= corr0;
        corr2 <= corr1;
        p_corr <= p_reg + corr2;
      end
      assign p = p_corr;
    end else begin : g_no_correction
      assign p = p_reg;
    end
  endgenerate
''';
  return '''
module ${prefix}_dsp_mul #(
    parameter integer AW = 30, parameter integer BW = 18,
    parameter integer PW = 48, parameter integer SIGNED_A = 0,
    parameter integer SIGNED_B = 0
) (
    input wire clk, input wire en,
    input wire [AW-1:0] a, input wire [BW-1:0] b,
    output wire signed [PW-1:0] p
);
${xilinx ? '$primitive$fallback`endif' : fallback}
endmodule
''';
}

/// 并联原语单元实测 pre=20 拍、mid=35 拍；串联使用独立旧模块。
/// DSP48E2 原语显式启用 AREG/BREG/MREG/PREG；18 位无符号乘法在 PREG 后补偿符号位。
/// 数据寄存器不带复位，valid 在 core 内单独复位；en 由整条全流水链统一驱动。
String mbFxFullUnitDefs(
  String prefix, {
  required bool par,
  required bool ser,
  bool xilinx = false,
}) {
  final b = StringBuffer();
  b.write(mbDspMulDef(prefix, xilinx));
  b.writeln('''
module ${prefix}_band_pre_full (
    input wire clk, input wire en,
    input wire [31:0] h_q16, input wire [31:0] hc_q16,
    input wire [31:0] q_q20, output wire [63:0] u_q16
);
  wire signed [33:0] d0 = \$signed({2'b00, h_q16}) - \$signed({2'b00, hc_q16});
  wire [33:0] d1 = (d0 < 0) ? (34'd0 - d0) : d0;
  wire [33:0] d2 = (d1 >= 34'd23592960) ? (d1 - 34'd23592960) : d1;
  wire [33:0] dd = (d2 > 34'd11796480) ? (34'd23592960 - d2) : d2;
  reg [23:0] dd0;
  reg [21:0] q0;
  (* use_dsp = "yes" *) reg [45:0] x0_mul;
  reg [45:0] x0, x0_q, x0_r, x0_s;
  reg [59:0] x1, x1_q, x1_r, x1_s;
  reg [59:0] u0, u0_q, u0_r, u0_s;
  wire [29:0] x1_hh, x1_ll, x1_hl;
  wire [31:0] u_c0, u_c1;
  wire [29:0] u_c2;
  reg [39:0] u_hi_d1, u_hi_d2, u_hi_d3, u_hi_d4;
  ${prefix}_dsp_mul #(.AW(15), .BW(15), .PW(30)) u_x1_hh (
      .clk(clk), .en(en), .a(x0_s[45:31]), .b(x0_s[45:31]), .p(x1_hh));
  ${prefix}_dsp_mul #(.AW(15), .BW(15), .PW(30)) u_x1_ll (
      .clk(clk), .en(en), .a(x0_s[30:16]), .b(x0_s[30:16]), .p(x1_ll));
  ${prefix}_dsp_mul #(.AW(15), .BW(15), .PW(30)) u_x1_hl (
      .clk(clk), .en(en), .a(x0_s[45:31]), .b(x0_s[30:16]), .p(x1_hl));
  ${prefix}_dsp_mul #(.AW(14), .BW(18), .PW(32)) u_u0_c0 (
      .clk(clk), .en(en), .a(x1_s[33:20]), .b(18'd232117), .p(u_c0));
  ${prefix}_dsp_mul #(.AW(14), .BW(18), .PW(32)) u_u0_c1 (
      .clk(clk), .en(en), .a(x1_s[47:34]), .b(18'd232117), .p(u_c1));
  ${prefix}_dsp_mul #(.AW(12), .BW(18), .PW(30)) u_u0_c2 (
      .clk(clk), .en(en), .a(x1_s[59:48]), .b(18'd232117), .p(u_c2));
  wire [59:0] x1_mul = ({34'd0, x1_hh} << 30)
      + ({34'd0, x1_hl} << 16) + {34'd0, x1_ll};
  wire [59:0] u0_mul = {32'd0, u_c0} + ({32'd0, u_c1} << 14)
      + ({34'd0, u_c2} << 28) + ({24'd0, u_hi_d4} << 19);
  always @(posedge clk) if (en) begin
    dd0 <= dd[23:0];
    q0 <= q_q20[21:0];
    x0_mul <= dd0 * q0;
    x0 <= x0_mul;
    x0_q <= x0;
    x0_r <= x0_q;
    x0_s <= x0_r;
    x1 <= x1_mul + 60'd524288;
    x1_q <= x1;
    x1_r <= x1_q;
    x1_s <= x1_r;
    u_hi_d1 <= x1_s[59:20];
    u_hi_d2 <= u_hi_d1;
    u_hi_d3 <= u_hi_d2;
    u_hi_d4 <= u_hi_d3;
    u0 <= u0_mul + 60'd8388608;
    u0_q <= u0;
    u0_r <= u0_q;
    u0_s <= u0_r;
  end
  assign u_q16 = {28'd0, u0_s[59:24]};
endmodule

module ${prefix}_band_mid_full (
    input wire clk, input wire en,
    input wire [63:0] u_q16, output wire [14:0] w_q14
);
  reg [63:0] fr0, fr1, fr2, fr3, fr4, fr5;
  reg [63:0] fr6, fr7, fr8, fr9, fr10, fr11;
  reg [63:0] fr12, fr13, fr14, fr15, fr16, fr17;
  reg [63:0] fr18, fr19, fr20, fr21, fr22, fr23, fr24, fr25;
  reg [63:0] fr26, fr27, fr28, fr29, fr30;
  reg [63:0] fr31, fr32, fr33, fr34, fr35, fr36;
  reg [3:0] nn0, nn1, nn2, nn3, nn4, nn5;
  reg [3:0] nn6, nn7, nn8, nn9, nn10, nn11;
  reg [3:0] nn12, nn13, nn14, nn15, nn16, nn17;
  reg [3:0] nn18, nn19, nn20, nn21, nn22, nn23, nn24, nn25;
  reg [3:0] nn26, nn27, nn28, nn29, nn30;
  reg [3:0] nn31, nn32, nn33, nn34, nn35, nn36;
  reg ov0, ov1, ov2, ov3, ov4, ov5;
  reg ov6, ov7, ov8, ov9, ov10, ov11;
  reg ov12, ov13, ov14, ov15, ov16, ov17;
  reg ov18, ov19, ov20, ov21, ov22, ov23, ov24, ov25;
  reg ov26, ov27, ov28, ov29, ov30;
  reg ov31, ov32, ov33, ov34, ov35, ov36;
  wire signed [63:0] m1, m2, m3, m4, m5;
  reg signed [63:0] p1, p2, p3, p4, p5;
  reg signed [63:0] p1_d, p2_d, p3_d, p4_d, p5_d;
  reg signed [63:0] p1_e, p2_e, p3_e, p4_e, p5_e;
  reg signed [63:0] p1_f, p2_f, p3_f, p4_f, p5_f;
  ${prefix}_dsp_mul #(.AW(16), .BW(18), .PW(64), .SIGNED_B(1)) u_m1 (
      .clk(clk), .en(en), .a(fr0[15:0]), .b(-18'sd62), .p(m1));
  ${prefix}_dsp_mul #(.AW(16), .BW(18), .PW(64), .SIGNED_B(1)) u_m2 (
      .clk(clk), .en(en), .a(fr7[15:0]), .b(p1_f[33:16]), .p(m2));
  ${prefix}_dsp_mul #(.AW(16), .BW(18), .PW(64), .SIGNED_B(1)) u_m3 (
      .clk(clk), .en(en), .a(fr14[15:0]), .b(p2_f[33:16]), .p(m3));
  ${prefix}_dsp_mul #(.AW(16), .BW(18), .PW(64), .SIGNED_B(1)) u_m4 (
      .clk(clk), .en(en), .a(fr21[15:0]), .b(p3_f[33:16]), .p(m4));
  ${prefix}_dsp_mul #(.AW(16), .BW(18), .PW(64), .SIGNED_B(1)) u_m5 (
      .clk(clk), .en(en), .a(fr28[15:0]), .b(p4_f[33:16]), .p(m5));
  always @(posedge clk) if (en) begin
    fr0 <= {48'd0, u_q16[15:0]};
    fr1 <= fr0;
    fr2 <= fr1;
    fr3 <= fr2;
    fr4 <= fr3;
    fr5 <= fr4;
    fr6 <= fr5;
    fr7 <= fr6;
    fr8 <= fr7;
    fr9 <= fr8;
    fr10 <= fr9;
    fr11 <= fr10;
    fr12 <= fr11;
    fr13 <= fr12;
    fr14 <= fr13;
    fr15 <= fr14;
    fr16 <= fr15;
    fr17 <= fr16;
    fr18 <= fr17;
    fr19 <= fr18;
    fr20 <= fr19;
    fr21 <= fr20;
    fr22 <= fr21;
    fr23 <= fr22;
    fr24 <= fr23;
    fr25 <= fr24;
    fr26 <= fr25;
    fr27 <= fr26;
    fr28 <= fr27;
    fr29 <= fr28;
    fr30 <= fr29;
    fr31 <= fr30;
    fr32 <= fr31;
    fr33 <= fr32;
    fr34 <= fr33;
    fr35 <= fr34;
    fr36 <= fr35;
    nn0 <= u_q16[19:16];
    nn1 <= nn0;
    nn2 <= nn1;
    nn3 <= nn2;
    nn4 <= nn3;
    nn5 <= nn4;
    nn6 <= nn5;
    nn7 <= nn6;
    nn8 <= nn7;
    nn9 <= nn8;
    nn10 <= nn9;
    nn11 <= nn10;
    nn12 <= nn11;
    nn13 <= nn12;
    nn14 <= nn13;
    nn15 <= nn14;
    nn16 <= nn15;
    nn17 <= nn16;
    nn18 <= nn17;
    nn19 <= nn18;
    nn20 <= nn19;
    nn21 <= nn20;
    nn22 <= nn21;
    nn23 <= nn22;
    nn24 <= nn23;
    nn25 <= nn24;
    nn26 <= nn25;
    nn27 <= nn26;
    nn28 <= nn27;
    nn29 <= nn28;
    nn30 <= nn29;
    nn31 <= nn30;
    nn32 <= nn31;
    nn33 <= nn32;
    nn34 <= nn33;
    nn35 <= nn34;
    nn36 <= nn35;
    ov0 <= |u_q16[63:20];
    ov1 <= ov0;
    ov2 <= ov1;
    ov3 <= ov2;
    ov4 <= ov3;
    ov5 <= ov4;
    ov6 <= ov5;
    ov7 <= ov6;
    ov8 <= ov7;
    ov9 <= ov8;
    ov10 <= ov9;
    ov11 <= ov10;
    ov12 <= ov11;
    ov13 <= ov12;
    ov14 <= ov13;
    ov15 <= ov14;
    ov16 <= ov15;
    ov17 <= ov16;
    ov18 <= ov17;
    ov19 <= ov18;
    ov20 <= ov19;
    ov21 <= ov20;
    ov22 <= ov21;
    ov23 <= ov22;
    ov24 <= ov23;
    ov25 <= ov24;
    ov26 <= ov25;
    ov27 <= ov26;
    ov28 <= ov27;
    ov29 <= ov28;
    ov30 <= ov29;
    ov31 <= ov30;
    ov32 <= ov31;
    ov33 <= ov32;
    ov34 <= ov33;
    ov35 <= ov34;
    ov36 <= ov35;
    p1 <= m1 + (64'sd603 <<< 16) + 64'sd32768;
    p1_d <= p1;
    p1_e <= p1_d;
    p1_f <= p1_e;
    p2 <= m2 - (64'sd3623 <<< 16) + 64'sd32768;
    p2_d <= p2;
    p2_e <= p2_d;
    p2_f <= p2_e;
    p3 <= m3 + (64'sd15740 <<< 16) + 64'sd32768;
    p3_d <= p3;
    p3_e <= p3_d;
    p3_f <= p3_e;
    p4 <= m4 - (64'sd45426 <<< 16) + 64'sd32768;
    p4_d <= p4;
    p4_e <= p4_d;
    p4_f <= p4_e;
    p5 <= m5 + (64'sd65536 <<< 16) + 64'sd32768;
    p5_d <= p5;
    p5_e <= p5_d;
    p5_f <= p5_e;
  end
  wire signed [63:0] p5_q16 = p5_f >>> 16;
  wire [63:0] wv = ov35 ? 64'd0
      : (\$unsigned(p5_q16) + (64'd1 << ({1'b0, nn35} + 5'd1)))
        >> ({1'b0, nn35} + 5'd2);
  assign w_q14 = wv[14:0];
endmodule''');
  if (par) {
    b.writeln('''
module ${prefix}_band_par_post_full (
    input wire clk, input wire en,
    input wire [14:0] w_q14,
    input wire signed [31:0] dh_q16,
    input wire signed [31:0] s1_q14,
    input wire signed [31:0] l1_q14,
    output wire signed [47:0] dh_term,
    output wire signed [47:0] s_term,
    output wire signed [47:0] l_term
);
  reg [14:0] w0;
  reg signed [31:0] dh0, s10, l10;
  reg signed [47:0] dh1, s1, l1, dh2, s2, l2, dh3, s3, l3;
  reg signed [47:0] dh4, s4, l4, dh5, s5, l5;
  always @(posedge clk) if (en) begin
    w0 <= w_q14;
    dh0 <= dh_q16;
    s10 <= s1_q14;
    l10 <= l1_q14;
    dh1 <= \$signed({33'd0, w0}) * dh0;
    s1 <= \$signed({33'd0, w0}) * s10;
    l1 <= \$signed({33'd0, w0}) * l10;
    dh2 <= dh1;
    s2 <= s1;
    l2 <= l1;
    dh3 <= dh2;
    s3 <= s2;
    l3 <= l2;
    dh4 <= dh3;
    s4 <= s3;
    l4 <= l3;
    dh5 <= dh4;
    s5 <= s4;
    l5 <= l4;
  end
  assign dh_term = dh5;
  assign s_term = s5;
  assign l_term = l5;
endmodule''');
  }
  if (ser) {
    b.writeln('''
module ${prefix}_band_ser_post_full (
    input wire clk, input wire en,
    input wire [31:0] h_cur,
    input wire signed [47:0] s_acc,
    input wire signed [47:0] l_acc,
    input wire [14:0] w_q14,
    input wire signed [31:0] dh_q16,
    input wire signed [31:0] s1_q14,
    input wire signed [31:0] l1_q14,
    output reg [31:0] h_next,
    output wire signed [47:0] s_next,
    output wire signed [47:0] l_next
);
  reg [31:0] h0, h0_d1, h0_d2, h0_d3, h0_d4, h0_d5;
  reg signed [47:0] sa0, la0, sa0_d1, la0_d1, sa0_d2, la0_d2;
  reg signed [47:0] sa0_d3, la0_d3, sa0_d4, la0_d4, sa0_d5, la0_d5;
  reg [14:0] w0;
  reg signed [31:0] dh0, s10, l10;
  reg signed [47:0] ws_mul, wl_mul, wdh_mul;
  reg signed [47:0] mul_s_full, mul_l_full, inc_full;
  reg signed [47:0] mul_s_q, mul_l_q, inc_q;
  reg signed [47:0] mul_s_r, mul_l_r, inc_r;
  reg signed [47:0] mul_s_s, mul_l_s, inc_s;
  reg signed [47:0] sa_mul, la_mul, s_next_full, l_next_full;
  reg signed [47:0] s_next_q, l_next_q, s_next_r, l_next_r;
  reg signed [47:0] s_next_s, l_next_s;
  reg [31:0] h_temp, h_temp_q, h_temp_r, h_temp_s;
  wire signed [47:0] mul_s = mul_s_s >>> 14;
  wire signed [47:0] mul_l = mul_l_s >>> 14;
  wire signed [47:0] inc = inc_s >>> 14;
  function [31:0] _ser_h_wrap;
    input [31:0] h;
    input signed [47:0] offset;
    reg signed [47:0] h1, h2;
    begin
      h1 = \$signed({16'd0, h}) + offset;
      h2 = (h1 >= 48'sd23592960) ? (h1 - 48'sd23592960)
           : ((h1 < 0) ? (h1 + 48'sd23592960) : h1);
      _ser_h_wrap = h2[31:0];
    end
  endfunction
  always @(posedge clk) if (en) begin
    h0 <= h_cur;
    h0_d1 <= h0;
    h0_d2 <= h0_d1;
    h0_d3 <= h0_d2;
    h0_d4 <= h0_d3;
    h0_d5 <= h0_d4;
    sa0 <= s_acc;
    la0 <= l_acc;
    sa0_d1 <= sa0;
    la0_d1 <= la0;
    sa0_d2 <= sa0_d1;
    la0_d2 <= la0_d1;
    sa0_d3 <= sa0_d2;
    la0_d3 <= la0_d2;
    sa0_d4 <= sa0_d3;
    la0_d4 <= la0_d3;
    sa0_d5 <= sa0_d4;
    la0_d5 <= la0_d4;
    w0 <= w_q14;
    dh0 <= dh_q16;
    s10 <= s1_q14;
    l10 <= l1_q14;
    ws_mul <= \$signed({33'd0, w0}) * s10;
    wl_mul <= \$signed({33'd0, w0}) * l10;
    wdh_mul <= \$signed({33'd0, w0}) * dh0;
    mul_s_full <= ws_mul + (48'sd16384 <<< 14) + 48'sd8192;
    mul_l_full <= wl_mul + (48'sd16384 <<< 14) + 48'sd8192;
    inc_full <= wdh_mul + 48'sd8192;
    mul_s_q <= mul_s_full;
    mul_l_q <= mul_l_full;
    inc_q <= inc_full;
    mul_s_r <= mul_s_q;
    mul_l_r <= mul_l_q;
    inc_r <= inc_q;
    mul_s_s <= mul_s_r;
    mul_l_s <= mul_l_r;
    inc_s <= inc_r;
    sa_mul <= sa0_d5 * mul_s;
    la_mul <= la0_d5 * mul_l;
    h_temp <= _ser_h_wrap(h0_d5, inc);
    s_next_full <= sa_mul + 48'sd8192;
    l_next_full <= la_mul + 48'sd8192;
    s_next_q <= s_next_full;
    l_next_q <= l_next_full;
    s_next_r <= s_next_q;
    l_next_r <= l_next_q;
    s_next_s <= s_next_r;
    l_next_s <= l_next_r;
    h_temp_q <= h_temp;
    h_temp_r <= h_temp_q;
    h_temp_s <= h_temp_r;
    h_next <= h_temp_s;
  end
  assign s_next = s_next_s >>> 14;
  assign l_next = l_next_s >>> 14;
endmodule''');
  }
  b.write(_mbSerialLegacyUnitDefs(prefix));
  return b.toString();
}

String _mbSerialLegacyUnitDefs(String prefix) {
  return '''
module ${prefix}_band_pre_serial_full (
    input wire clk, input wire en,
    input wire [31:0] h_q16, input wire [31:0] hc_q16,
    input wire [31:0] q_q20, output wire [63:0] u_q16
);
  wire signed [33:0] d0 = \$signed({2'b00, h_q16}) - \$signed({2'b00, hc_q16});
  wire [33:0] d1 = (d0 < 0) ? (34'd0 - d0) : d0;
  wire [33:0] d2 = (d1 >= 34'd23592960) ? (d1 - 34'd23592960) : d1;
  wire [33:0] dd = (d2 > 34'd11796480) ? (34'd23592960 - d2) : d2;
  reg [23:0] dd0;
  reg [21:0] q0;
  (* use_dsp = "yes" *) reg [45:0] x0_mul;
  (* use_dsp = "yes" *) reg [59:0] x1_mul, u0_mul;
  reg [45:0] x0, x0_q, x0_r, x0_s;
  reg [59:0] x1, x1_q, x1_r, x1_s;
  reg [59:0] u0, u0_q, u0_r, u0_s;
  always @(posedge clk) if (en) begin
    dd0 <= dd[23:0];
    q0 <= q_q20[21:0];
    x0_mul <= dd0 * q0;
    x0 <= x0_mul;
    x0_q <= x0;
    x0_r <= x0_q;
    x0_s <= x0_r;
    x1_mul <= x0_s[45:16] * x0_s[45:16];
    x1 <= x1_mul + 60'd524288;
    x1_q <= x1;
    x1_r <= x1_q;
    x1_s <= x1_r;
    u0_mul <= x1_s[59:20] * 20'd756405;
    u0 <= u0_mul + 60'd8388608;
    u0_q <= u0;
    u0_r <= u0_q;
    u0_s <= u0_r;
  end
  assign u_q16 = {28'd0, u0_s[59:24]};
endmodule

module ${prefix}_band_mid_serial_full (
    input wire clk, input wire en,
    input wire [63:0] u_q16, output wire [14:0] w_q14
);
  reg [63:0] fr [0:25];
  reg [3:0] nn [0:25];
  reg ov [0:25];
  integer k;
  (* use_dsp = "yes" *) reg signed [63:0] m1, m2, m3, m4, m5;
  reg signed [63:0] p1, p2, p3, p4, p5;
  reg signed [63:0] p1_d, p2_d, p3_d, p4_d, p5_d;
  reg signed [63:0] p1_e, p2_e, p3_e, p4_e, p5_e;
  reg signed [63:0] p1_f, p2_f, p3_f, p4_f, p5_f;
  always @(posedge clk) if (en) begin
    fr[0] <= {48'd0, u_q16[15:0]};
    nn[0] <= u_q16[19:16];
    ov[0] <= |u_q16[63:20];
    for (k = 1; k <= 25; k = k + 1) begin
      fr[k] <= fr[k-1];
      nn[k] <= nn[k-1];
      ov[k] <= ov[k-1];
    end
    m1 <= \$signed(fr[0]) * (-64'sd62);
    p1 <= m1 + (64'sd603 <<< 16) + 64'sd32768;
    p1_d <= p1;
    p1_e <= p1_d;
    p1_f <= p1_e;
    m2 <= \$signed(fr[5]) * (p1_f >>> 16);
    p2 <= m2 - (64'sd3623 <<< 16) + 64'sd32768;
    p2_d <= p2;
    p2_e <= p2_d;
    p2_f <= p2_e;
    m3 <= \$signed(fr[10]) * (p2_f >>> 16);
    p3 <= m3 + (64'sd15740 <<< 16) + 64'sd32768;
    p3_d <= p3;
    p3_e <= p3_d;
    p3_f <= p3_e;
    m4 <= \$signed(fr[15]) * (p3_f >>> 16);
    p4 <= m4 - (64'sd45426 <<< 16) + 64'sd32768;
    p4_d <= p4;
    p4_e <= p4_d;
    p4_f <= p4_e;
    m5 <= \$signed(fr[20]) * (p4_f >>> 16);
    p5 <= m5 + (64'sd65536 <<< 16) + 64'sd32768;
    p5_d <= p5;
    p5_e <= p5_d;
    p5_f <= p5_e;
  end
  wire signed [63:0] p5_q16 = p5_f >>> 16;
  wire [63:0] wv = ov[25] ? 64'd0
      : (\$unsigned(p5_q16) + (64'd1 << ({1'b0, nn[25]} + 5'd1)))
        >> ({1'b0, nn[25]} + 5'd2);
  assign w_q14 = wv[14:0];
endmodule
''';
}

String _fullApply(int pb) {
  return '''
  reg [$pb-1:0] s_in, l_in;
  reg signed [17:0] sm_in, lm_in;
  (* use_dsp = "yes" *) reg signed [47:0] sp_mul, lp_mul;
  reg signed [47:0] sp_full, lp_full;
  reg signed [47:0] sp_q, lp_q, sp_r, lp_r, sp_s, lp_s;
  reg [$pb-1:0] resh_d, resh_d2, resh_d3, resh_d4, resh_d5, resh_full;
  wire signed [31:0] mp1_full = \$signed({16'd0, MAXV}) + 32'sd1;
  wire signed [31:0] hsum_full = \$signed({16'd0, hvF}) + shift3;
  wire signed [31:0] hwrap_full = (hsum_full > \$signed({16'd0, MAXV}))
      ? (hsum_full - mp1_full) : ((hsum_full < 0) ? (hsum_full + mp1_full) : hsum_full);
  always @(posedge clk) if (full_en) begin
    s_in <= sF;
    l_in <= lF;
    sm_in <= sm3[17:0];
    lm_in <= lm3[17:0];
    sp_mul <= \$signed({32'd0, s_in}) * sm_in;
    lp_mul <= \$signed({32'd0, l_in}) * lm_in;
    sp_full <= sp_mul + 48'sd8192;
    lp_full <= lp_mul + 48'sd8192;
    sp_q <= sp_full;
    lp_q <= lp_full;
    sp_r <= sp_q;
    lp_r <= lp_q;
    sp_s <= sp_r;
    lp_s <= lp_r;
    resh_d <= hwrap_full[$pb-1:0];
    resh_d2 <= resh_d;
    resh_d3 <= resh_d2;
    resh_d4 <= resh_d3;
    resh_d5 <= resh_d4;
    resh_full <= resh_d5;
  end
  wire signed [47:0] sr_full = sp_s >>> 14;
  wire signed [47:0] lr_full = lp_s >>> 14;
  wire [$pb-1:0] res_s_full = (sr_full < 0) ? {$pb{1'b0}}
      : ((sr_full > MAXV_S) ? MAXV : sr_full[$pb-1:0]);
  wire [$pb-1:0] res_l_full = (lr_full < 0) ? {$pb{1'b0}}
      : ((lr_full > MAXV_S) ? MAXV : lr_full[$pb-1:0]);
  assign full_result = {resh_full, res_s_full, res_l_full};
''';
}

String _fullParallel(String prefix, int pb) {
  final b = StringBuffer();
  b.writeln('  reg [31:0] h1;');
  b.writeln('  reg [$pb-1:0] hv1, s1, l1;');
  b.writeln('  always @(posedge clk) if (full_en) begin');
  b.writeln('    h1 <= hq16_full[31:0]; hv1 <= hv0; s1 <= s0; l1 <= l0;');
  b.writeln('  end');
  // 像素直通延迟线：各 band 内容完全相同，统一共享一份（原先每 band 复制
  // 一份，16 段等于白扔 16x74xPIX_BITS 个寄存器）。
  b.writeln('''
  reg [${74 * pb - 1}:0] hv_d, s_d, l_d;
  always @(posedge clk) if (full_en) begin
    hv_d <= {hv_d[${73 * pb - 1}:0], hv1};
    s_d <= {s_d[${73 * pb - 1}:0], s1};
    l_d <= {l_d[${73 * pb - 1}:0], l1};
  end
''');
  // 各 band 的输出项先在外层声明：未被 NUM_BANDS 启用的 band 直接接 0，
  // 且其 pre/mid/post 在 elaboration 期就不实例化（此前只做权重掩码，
  // 16 份硬件全部实现——2 段配置也要背 127 个 DSP 与数倍 LUT）。
  for (var i = 0; i < _fullBandCount; i++) {
    b.writeln('  wire signed [47:0] b${i}_dh, b${i}_s, b${i}_l;');
  }
  for (var i = 0; i < _fullBandCount; i++) {
    final p = _fullPorts(i);
    b.writeln('''
    if (NUM_BANDS > $i) begin : g_b$i
      wire [63:0] uc$i;
      ${prefix}_band_pre_full u_b${i}_pre (
          .clk(clk), .en(full_en), .h_q16(h1), .hc_q16(${p.hc}),
          .q_q20(${p.q}), .u_q16(uc$i));
      wire [14:0] wc$i;
      ${prefix}_band_mid_full u_b${i}_mid (
          .clk(clk), .en(full_en), .u_q16(uc$i), .w_q14(wc$i));
      reg [2047:0] dh_d$i, s1_d$i, l1_d$i;
      always @(posedge clk) if (full_en) begin
        dh_d$i <= {dh_d$i[2015:0], ${p.dh}};
        s1_d$i <= {s1_d$i[2015:0], ${p.s1}};
        l1_d$i <= {l1_d$i[2015:0], ${p.l1}};
      end
      wire [14:0] wsel$i = !ch_enable_ext[$i] ? 15'd0 : wc$i;
      ${prefix}_band_par_post_full u_b${i}_post (
          .clk(clk), .en(full_en), .w_q14(wsel$i),
          .dh_q16(dh_d$i[2047 -: 32]),
          .s1_q14(s1_d$i[2047 -: 32]), .l1_q14(l1_d$i[2047 -: 32]),
          .dh_term(b${i}_dh), .s_term(b${i}_s), .l_term(b${i}_l));
    end else begin : g_b${i}_off
      assign b${i}_dh = 48'sd0;
      assign b${i}_s = 48'sd0;
      assign b${i}_l = 48'sd0;
    end''');
  }
  final dh = [for (var i = 0; i < _fullBandCount; i++) 'b${i}_dh'].join(' + ');
  final s = [for (var i = 0; i < _fullBandCount; i++) 'b${i}_s'].join(' + ');
  final l = [for (var i = 0; i < _fullBandCount; i++) 'b${i}_l'].join(' + ');
  b.writeln('''
  wire signed [47:0] dh_sum_c = $dh;
  wire signed [47:0] s_sum_c = $s;
  wire signed [47:0] l_sum_c = $l;
  reg signed [47:0] dh2, s2, l2;
  reg signed [47:0] s2_d1, l2_d1, s2_d2, l2_d2;
  reg signed [47:0] s2_d3, l2_d3, s2_d4, l2_d4;
  reg signed [47:0] s2_d5, l2_d5, s2_d6, l2_d6;
  reg signed [47:0] s2_d7, l2_d7, s2_d8, l2_d8;
  reg signed [47:0] s2_d9, l2_d9, s2_d10, l2_d10;
  reg [$pb-1:0] hv2, s2v, l2v;
  always @(posedge clk) if (full_en) begin
    dh2 <= dh_sum_c;
    s2 <= s_sum_c;
    l2 <= l_sum_c;
    s2_d1 <= s2;
    l2_d1 <= l2;
    s2_d2 <= s2_d1;
    l2_d2 <= l2_d1;
    s2_d3 <= s2_d2;
    l2_d3 <= l2_d2;
    s2_d4 <= s2_d3;
    l2_d4 <= l2_d3;
    s2_d5 <= s2_d4;
    l2_d5 <= l2_d4;
    s2_d6 <= s2_d5;
    l2_d6 <= l2_d5;
    s2_d7 <= s2_d6;
    l2_d7 <= l2_d6;
    s2_d8 <= s2_d7;
    l2_d8 <= l2_d7;
    s2_d9 <= s2_d8;
    l2_d9 <= l2_d8;
    s2_d10 <= s2_d9;
    l2_d10 <= l2_d9;
    hv2 <= hv_d[${74 * pb - 1} -: $pb];
    s2v <= s_d[${74 * pb - 1} -: $pb];
    l2v <= l_d[${74 * pb - 1} -: $pb];
  end
  wire signed [47:0] dh_cl = (dh2 < -48'sd193273528320) ? -48'sd193273528320
      : ((dh2 > 48'sd193273528320) ? 48'sd193273528320 : dh2);
  wire dh_neg = dh_cl[47];
  wire [47:0] dh_mag = dh_neg ? (~dh_cl + 48'd1) : dh_cl;
  reg neg_d1, neg_d2, neg_d3, neg_d4, neg_d5, neg_d6;
  reg neg_d7, neg_d8, neg_d9, neg_d10;
  reg [63:0] sh_mul, sh_a, sh_a_d, sh_a_e, sh_a_f;
  reg [63:0] shq_mul, sh_q, sh_q_d, sh_q_e, sh_q_f;
  wire [63:0] sh_a_q = sh_a_f >> 30;
  wire [63:0] sh_q_q = sh_q_f >> 33;
  reg [${6 * pb - 1}:0] hv_pipe, s_pipe, l_pipe;
  wire signed [47:0] sm_c0 = 48'sd16384 + ((s2_d10 + 48'sd8192) >>> 14);
  wire signed [47:0] lm_c0 = 48'sd16384 + ((l2_d10 + 48'sd8192) >>> 14);
  wire signed [47:0] sm_c = (NUM_BANDS > 1)
      ? ((sm_c0 < 0) ? 48'sd0 : ((sm_c0 > 48'sd81920) ? 48'sd81920 : sm_c0))
      : sm_c0;
  wire signed [47:0] lm_c = (NUM_BANDS > 1)
      ? ((lm_c0 < 0) ? 48'sd0 : ((lm_c0 > 48'sd81920) ? 48'sd81920 : lm_c0))
      : lm_c0;
  always @(posedge clk) if (full_en) begin
    neg_d1 <= dh_neg;
    neg_d2 <= neg_d1;
    neg_d3 <= neg_d2;
    neg_d4 <= neg_d3;
    neg_d5 <= neg_d4;
    neg_d6 <= neg_d5;
    neg_d7 <= neg_d6;
    neg_d8 <= neg_d7;
    neg_d9 <= neg_d8;
    neg_d10 <= neg_d9;
    sh_mul <= dh_mag * {48'd0, MAXV};
    sh_a <= sh_mul + (64'd180 << 30);
    sh_a_d <= sh_a;
    sh_a_e <= sh_a_d;
    sh_a_f <= sh_a_e;
    shq_mul <= sh_a_q * 64'd23860930;
    sh_q <= shq_mul;
    sh_q_d <= sh_q;
    sh_q_e <= sh_q_d;
    sh_q_f <= sh_q_e;
    shift3 <= neg_d10 ? -\$signed(sh_q_q[31:0]) : \$signed(sh_q_q[31:0]);
    sm3 <= sm_c[31:0];
    lm3 <= lm_c[31:0];
    hv_pipe <= {hv_pipe[${5 * pb - 1}:0], hv2};
    s_pipe <= {s_pipe[${5 * pb - 1}:0], s2v};
    l_pipe <= {l_pipe[${5 * pb - 1}:0], l2v};
  end
  assign hvF = hv_pipe[${6 * pb - 1} -: $pb];
  assign sF = s_pipe[${6 * pb - 1} -: $pb];
  assign lF = l_pipe[${6 * pb - 1} -: $pb];
''');
  return b.toString();
}

String _fullSerial(String prefix, int pb) {
  final b = StringBuffer();
  b.writeln('''
  reg [31:0] hcur0, hqd0;
  reg signed [47:0] sacc0, lacc0;
  reg [$pb-1:0] hvp0, sp0, lp0;
  always @(posedge clk) if (full_en) begin
    hcur0 <= hq16_full[31:0];
    hqd0 <= hq16_full[31:0];
    sacc0 <= 48'sd16384;
    lacc0 <= 48'sd16384;
    hvp0 <= hv0;
    sp0 <= s0;
    lp0 <= l0;
  end
''');
  for (var i = 0; i < _fullBandCount; i++) {
    final p = _fullPorts(i);
    final phv = i == 0 ? 'hvp0' : 'hv$i';
    final pss = i == 0 ? 'sp0' : 's$i';
    final pll = i == 0 ? 'lp0' : 'l$i';
    const hBits = 42 * 32;
    final accCycles = i == 0 ? 48 : 42;
    final paramBits = accCycles * 32;
    final accBits = accCycles * 48;
    const origBits = 53 * 32;
    final origPixels = i == 0 ? 55 : 53;
    // 段内延迟线（无算术）：无论该段是否启用都必须存在——它定义了这一级的
    // 流水深度；未启用的段只保留它，pre/mid/post 在 elaboration 期被裁掉。
    b.writeln('''
  reg [${hBits - 1}:0] h_d$i;
  reg [${paramBits - 1}:0] dh_d$i, s1_d$i, l1_d$i;
  reg [${origBits - 1}:0] hqd_d$i;
  reg [${accBits - 1}:0] sa_d$i, la_d$i;
  reg [${origPixels * pb - 1}:0] hv_d$i, s_d$i, l_d$i;
  always @(posedge clk) if (full_en) begin
    h_d$i <= {h_d$i[${hBits - 33}:0], ${i == 0 ? 'hcur0' : 'hcur$i'}};
    hqd_d$i <= {hqd_d$i[${origBits - 33}:0], ${i == 0 ? 'hqd0' : 'hqd$i'}};
    sa_d$i <= {sa_d$i[${accBits - 49}:0], ${i == 0 ? 'sacc0' : 'sacc$i'}};
    la_d$i <= {la_d$i[${accBits - 49}:0], ${i == 0 ? 'lacc0' : 'lacc$i'}};
    dh_d$i <= {dh_d$i[${paramBits - 33}:0], ${p.dh}};
    s1_d$i <= {s1_d$i[${paramBits - 33}:0], ${p.s1}};
    l1_d$i <= {l1_d$i[${paramBits - 33}:0], ${p.l1}};
    hv_d$i <= {hv_d$i[${(origPixels - 1) * pb - 1}:0], $phv};
    s_d$i <= {s_d$i[${(origPixels - 1) * pb - 1}:0], $pss};
    l_d$i <= {l_d$i[${(origPixels - 1) * pb - 1}:0], $pll};
  end
  reg [31:0] hcur${i + 1}, hqd${i + 1};
  reg signed [47:0] sacc${i + 1}, lacc${i + 1};
  reg [$pb-1:0] hv${i + 1}, s${i + 1}, l${i + 1};
  if (NUM_BANDS > $i) begin : g_b$i
    wire [63:0] uc$i;
    ${prefix}_band_pre_serial_full u_b${i}_pre (
        .clk(clk), .en(full_en), .h_q16(${i == 0 ? 'hcur0' : 'hcur$i'}),
        .hc_q16(${p.hc}), .q_q20(${p.q}), .u_q16(uc$i));
    wire [14:0] wc$i;
    ${prefix}_band_mid_serial_full u_b${i}_mid (
        .clk(clk), .en(full_en), .u_q16(uc$i), .w_q14(wc$i));
    wire [14:0] wsel$i = !ch_enable_ext[$i] ? 15'd0 : wc$i;
    wire [31:0] bw${i}_h;
    wire signed [47:0] bw${i}_s, bw${i}_l;
    ${prefix}_band_ser_post_full u_b${i}_post (
        .clk(clk), .en(full_en),
        .h_cur(h_d$i[${hBits - 1} -: 32]),
        .s_acc(sa_d$i[${accBits - 1} -: 48]),
        .l_acc(la_d$i[${accBits - 1} -: 48]),
        .w_q14(wsel$i), .dh_q16(dh_d$i[${paramBits - 1} -: 32]),
        .s1_q14(s1_d$i[${paramBits - 1} -: 32]),
        .l1_q14(l1_d$i[${paramBits - 1} -: 32]),
        .h_next(bw${i}_h), .s_next(bw${i}_s), .l_next(bw${i}_l));
    always @(posedge clk) if (full_en) begin
      hcur${i + 1} <= bw${i}_h;
      hqd${i + 1} <= hqd_d$i[${origBits - 1} -: 32];
      sacc${i + 1} <= bw${i}_s;
      lacc${i + 1} <= bw${i}_l;
      hv${i + 1} <= hv_d$i[${origPixels * pb - 1} -: $pb];
      s${i + 1} <= s_d$i[${origPixels * pb - 1} -: $pb];
      l${i + 1} <= l_d$i[${origPixels * pb - 1} -: $pb];
    end
  end else begin : g_b${i}_off
    // Disabled band: ser_post is identity at w=0 (h/s/l pass through), but it
    // carries 11 pipeline stages of its own (h0..h0_d5 -> h_temp -> 3 more;
    // s/l likewise). They must be compensated here, otherwise the cascade
    // latency shortens and the frozen LAT/golden no longer line up.
    // hqd and the pixel delay lines use the same tap in both branches.
    reg [31:0] hof${i}_1, hof${i}_2, hof${i}_3, hof${i}_4, hof${i}_5;
    reg [31:0] hof${i}_6, hof${i}_7, hof${i}_8, hof${i}_9, hof${i}_10;
    reg [31:0] hof${i}_11;
    reg signed [47:0] sof${i}_1, sof${i}_2, sof${i}_3, sof${i}_4, sof${i}_5;
    reg signed [47:0] sof${i}_6, sof${i}_7, sof${i}_8, sof${i}_9, sof${i}_10;
    reg signed [47:0] sof${i}_11;
    reg signed [47:0] lof${i}_1, lof${i}_2, lof${i}_3, lof${i}_4, lof${i}_5;
    reg signed [47:0] lof${i}_6, lof${i}_7, lof${i}_8, lof${i}_9, lof${i}_10;
    reg signed [47:0] lof${i}_11;
    always @(posedge clk) if (full_en) begin
      hof${i}_1 <= h_d$i[${hBits - 1} -: 32];
      hof${i}_2 <= hof${i}_1;
      hof${i}_3 <= hof${i}_2;
      hof${i}_4 <= hof${i}_3;
      hof${i}_5 <= hof${i}_4;
      hof${i}_6 <= hof${i}_5;
      hof${i}_7 <= hof${i}_6;
      hof${i}_8 <= hof${i}_7;
      hof${i}_9 <= hof${i}_8;
      hof${i}_10 <= hof${i}_9;
      hof${i}_11 <= hof${i}_10;
      sof${i}_1 <= sa_d$i[${accBits - 1} -: 48];
      sof${i}_2 <= sof${i}_1;
      sof${i}_3 <= sof${i}_2;
      sof${i}_4 <= sof${i}_3;
      sof${i}_5 <= sof${i}_4;
      sof${i}_6 <= sof${i}_5;
      sof${i}_7 <= sof${i}_6;
      sof${i}_8 <= sof${i}_7;
      sof${i}_9 <= sof${i}_8;
      sof${i}_10 <= sof${i}_9;
      sof${i}_11 <= sof${i}_10;
      lof${i}_1 <= la_d$i[${accBits - 1} -: 48];
      lof${i}_2 <= lof${i}_1;
      lof${i}_3 <= lof${i}_2;
      lof${i}_4 <= lof${i}_3;
      lof${i}_5 <= lof${i}_4;
      lof${i}_6 <= lof${i}_5;
      lof${i}_7 <= lof${i}_6;
      lof${i}_8 <= lof${i}_7;
      lof${i}_9 <= lof${i}_8;
      lof${i}_10 <= lof${i}_9;
      lof${i}_11 <= lof${i}_10;
      hcur${i + 1} <= hof${i}_11;
      hqd${i + 1} <= hqd_d$i[${origBits - 1} -: 32];
      sacc${i + 1} <= sof${i}_11;
      lacc${i + 1} <= lof${i}_11;
      hv${i + 1} <= hv_d$i[${origPixels * pb - 1} -: $pb];
      s${i + 1} <= s_d$i[${origPixels * pb - 1} -: $pb];
      l${i + 1} <= l_d$i[${origPixels * pb - 1} -: $pb];
    end
  end''');
  }
  const n = _fullBandCount;
  b.writeln('''
  wire signed [63:0] dd0 = \$signed({32'd0, hcur$n}) - \$signed({32'd0, hqd$n});
  wire signed [63:0] dd1 = (dd0 < 0) ? (dd0 + 64'sd23592960) : dd0;
  wire signed [63:0] ddf = (dd1 > 64'sd11796480) ? (dd1 - 64'sd23592960) : dd1;
  wire dd_neg = ddf[63];
  wire [63:0] dd_mag = dd_neg ? (~ddf + 64'd1) : ddf;
  reg neg_d1, neg_d2, neg_d3, neg_d4, neg_d5, neg_d6;
  reg neg_d7, neg_d8, neg_d9, neg_d10;
  reg [63:0] sh_mul, sh_a, sh_a_d, sh_a_e, sh_a_f;
  reg [63:0] shq_mul, sh_q, sh_q_d, sh_q_e, sh_q_f;
  wire [63:0] sh_a_q = sh_a_f >> 16;
  wire [63:0] sh_q_q = sh_q_f >> 33;
  reg signed [47:0] sacc_d1, lacc_d1, sacc_d2, lacc_d2;
  reg signed [47:0] sacc_d3, lacc_d3, sacc_d4, lacc_d4;
  reg signed [47:0] sacc_d5, lacc_d5, sacc_d6, lacc_d6;
  reg signed [47:0] sacc_d7, lacc_d7, sacc_d8, lacc_d8;
  reg signed [47:0] sacc_d9, lacc_d9, sacc_d10, lacc_d10;
  reg [${15 * pb - 1}:0] hv_pipe, s_pipe, l_pipe;
  always @(posedge clk) if (full_en) begin
    neg_d1 <= dd_neg;
    neg_d2 <= neg_d1;
    neg_d3 <= neg_d2;
    neg_d4 <= neg_d3;
    neg_d5 <= neg_d4;
    neg_d6 <= neg_d5;
    neg_d7 <= neg_d6;
    neg_d8 <= neg_d7;
    neg_d9 <= neg_d8;
    neg_d10 <= neg_d9;
    sacc_d1 <= sacc$n;
    lacc_d1 <= lacc$n;
    sacc_d2 <= sacc_d1;
    lacc_d2 <= lacc_d1;
    sacc_d3 <= sacc_d2;
    lacc_d3 <= lacc_d2;
    sacc_d4 <= sacc_d3;
    lacc_d4 <= lacc_d3;
    sacc_d5 <= sacc_d4;
    lacc_d5 <= lacc_d4;
    sacc_d6 <= sacc_d5;
    lacc_d6 <= lacc_d5;
    sacc_d7 <= sacc_d6;
    lacc_d7 <= lacc_d6;
    sacc_d8 <= sacc_d7;
    lacc_d8 <= lacc_d7;
    sacc_d9 <= sacc_d8;
    lacc_d9 <= lacc_d8;
    sacc_d10 <= sacc_d9;
    lacc_d10 <= lacc_d9;
    sh_mul <= dd_mag * {48'd0, MAXV};
    sh_a <= sh_mul + (64'd180 << 16);
    sh_a_d <= sh_a;
    sh_a_e <= sh_a_d;
    sh_a_f <= sh_a_e;
    shq_mul <= sh_a_q * 64'd23860930;
    sh_q <= shq_mul;
    sh_q_d <= sh_q;
    sh_q_e <= sh_q_d;
    sh_q_f <= sh_q_e;
    shift3 <= neg_d10 ? -\$signed(sh_q_q[31:0]) : \$signed(sh_q_q[31:0]);
    sm3 <= (sacc_d10 < 0) ? 32'sd0 : ((sacc_d10 > 48'sd81920) ? 32'sd81920 : sacc_d10[31:0]);
    lm3 <= (lacc_d10 < 0) ? 32'sd0 : ((lacc_d10 > 48'sd81920) ? 32'sd81920 : lacc_d10[31:0]);
    hv_pipe <= {hv_pipe[${14 * pb - 1}:0], hv$n};
    s_pipe <= {s_pipe[${14 * pb - 1}:0], s$n};
    l_pipe <= {l_pipe[${14 * pb - 1}:0], l$n};
  end
  assign hvF = hv_pipe[${15 * pb - 1} -: $pb];
  assign sF = s_pipe[${15 * pb - 1} -: $pb];
  assign lF = l_pipe[${15 * pb - 1} -: $pb];
''');
  return b.toString();
}

/// 在共享 MAXV/hq16_c 下发射 generate 的 full 分支；另一分支为原 0/1/2 档。
String emitMultiBandEqFxFullPipeline(
  String unitPrefix,
  int pixBits,
  int bandCount,
  bool serial,
) {
  final pb = pixBits;
  final bw = 3 * pb;
  final ser = serial && bandCount >= 2;
  final lat = mbFxFullLatency(ser);
  final b = StringBuffer();
  b.writeln('''
  if ((DSP_PIPE == 3) && (GSTRATEGY != 0)) begin : g_full_pipeline
  localparam integer FULL_LAT = $lat;
  reg [FULL_LAT-1:0] full_v, full_sof, full_eol;
  wire full_en = ~out_valid | out_ready;
  assign in_ready = full_en;
  reg signed [$pb:0] shift3;
  reg signed [31:0] sm3, lm3;
  wire [$pb-1:0] hvF, sF, lF;
  wire [$bw-1:0] full_result;
  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      full_v <= {FULL_LAT{1'b0}};
      full_sof <= {FULL_LAT{1'b0}};
      full_eol <= {FULL_LAT{1'b0}};
      out_valid <= 1'b0;
      out_sof <= 1'b0;
      out_eol <= 1'b0;
      out_data <= {$bw{1'b0}};
    end else if (full_en) begin
      full_v <= {full_v[FULL_LAT-2:0], in_valid};
      full_sof <= {full_sof[FULL_LAT-2:0], in_sof};
      full_eol <= {full_eol[FULL_LAT-2:0], in_eol};
      out_valid <= full_v[FULL_LAT-1];
      out_sof <= full_sof[FULL_LAT-1];
      out_eol <= full_eol[FULL_LAT-1];
      out_data <= full_result;
    end
  end
  always @(posedge clk) if (full_en) begin
    hv0 <= in_h;
    s0 <= in_s;
    l0 <= in_l;
  end
  reg [$pb-1:0] hvc_full;
  reg [63:0] ht_mul, ht_p, ht_q, ht_r, ht_s;
  always @(posedge clk) if (full_en) begin
    hvc_full <= (hv0 > MAXV) ? MAXV : hv0;
    ht_mul <= hvc_full * CIRCLE_Q16;
    ht_p <= ht_mul + HALF_MV;
    ht_q <= ht_p;
    ht_r <= ht_q;
    ht_s <= ht_r;
  end
  wire [63:0] hf1_full = (ht_s >> PIX_BITS) + (ht_s & MAXV);
  wire [63:0] hf2_full = (hf1_full >> PIX_BITS) + (hf1_full & MAXV);
  wire [63:0] hf3_full = (hf2_full >> PIX_BITS) + (hf2_full & MAXV);
  wire [63:0] hf4_full = (hf3_full >> PIX_BITS) + (hf3_full & MAXV);
  wire [63:0] hq16_full = (ht_s >> PIX_BITS) + (hf1_full >> PIX_BITS)
      + (hf2_full >> PIX_BITS) + (hf3_full >> PIX_BITS)
      + ((hf4_full >= MAXV) ? 64'd1 : 64'd0);
''');
  b.write(ser ? _fullSerial(unitPrefix, pb) : _fullParallel(unitPrefix, pb));
  b.write(_fullApply(pb));
  return b.toString();
}
