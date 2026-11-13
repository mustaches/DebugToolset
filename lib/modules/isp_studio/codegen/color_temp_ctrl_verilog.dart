/// 色温调节器 IP 的运行期控制块（Verilog 发射器）。
///
/// `*_core.v` 会附带这几个子模块，负责三件事：
///
/// 1. **目标色温 → 内部 CCM**：`cct_in`（14 位端口，K）经烘焙白点表 +
///    倒数表算出 von Kries 对角增益（Q14），逐帧在帧起始切换；CCM 不对外
///    暴露参数（只有这一对 14 位接口）。
/// 2. **帧测量**：核心侧累加输入帧的 R/G/B，帧起始把上一帧的和投入 FSM：
///    sRGB→XYZ（Q16）→ McCamy 色度比 → 逐位长除法 → 三次多项式 →
///    14 位 `cct_out`。
/// 3. 与 `pipeline/color_temp_hw.dart` **逐位一致**（golden 用同一套整数
///    语义）；两边的表、插值写法、移位与钳位必须同步修改。
///
/// 时序口径：测量在帧起始启动、约 65 个时钟后完成；一帧像素数不足该窗口
///（约 96 像素）时会丢掉那次测量（IP 假设正常视频帧宽 ≥ 96）。增益是 6 级
/// 流水（表在块 RAM 里，同步读），帧起始锁存——参数在帧起始前 ≥6 拍稳定即可。
///
/// **资源/干净度口径**（Vivado 2020.2 xczu15eg 实测）：
/// - 白点表/倒数表放**块 RAM**（`ram_style="block"`，双端口读，插值两端点
///   一拍取出）。组合 ROM 多路器实测量级：4×513×19 表 ≈ 5.0k LUT、1024×24
///   倒数表 ≈ 2.6k LUT；改块 RAM 后这部分只剩布线级开销。
/// - `nq²/nq³` 用 `${top}_dsp_mul` 原语（AREG/BREG/MREG/PREG 全开、内部同步
///   复位）→ 零 DPIP/DPOP/DPOR；多项式常数乘法强制 LUT（系数置位数少）。
/// - 一个模块塞太多原语会触发 `[Netlist 29-101]`（floorplanning 提示），故按
///   功能拆成 romr/romb/romq/gain/meas 五个 `keep_hierarchy` 子模块。
/// - `(* use_dsp = "no" *)` 只认**模块级**（挂 wire/assign 上无效）。
library;

import '../pipeline/color_temp_hw.dart';

/// 表烘焙：`reg [w-1:0] name [0:n-1]` + `initial` 块（iverilog 与综合均可，
/// 块 RAM 的初始化同样走 `initial`）。
String _bakeTable(String name, List<int> values, int widthBits,
    {String? attr}) {
  final b = StringBuffer();
  b.writeln('  ${attr ?? ''}reg [$widthBits-1:0] $name [0:${values.length - 1}];');
  b.writeln('  initial begin');
  for (var i = 0; i < values.length; i++) {
    b.writeln("    $name[$i] = $widthBits'd${values[i]};");
  }
  b.writeln('  end');
  return b.toString();
}

/// 白点表 ROM（块 RAM，双端口读）：`[下支 513 项 | 上支 513 项]`，插值的两个
/// 端点由两个读口一拍取出。
String _ctWhiteRom(String top, String ch, List<int> lower, List<int> upper) {
  final mem = 'ct_w${ch}_mem';
  final b = StringBuffer();
  final name = ch == 'r' ? 'R' : 'B';
  b.writeln('''
// 白点表（$name 通道，Q16，块 RAM 双端口读）：段宽 32K、网格偏移 8K
//（索引 = (K-8)>>5，让 6600K 的 Tanner Helland 断点正好落在节点上），
// 6600K 断点两侧各 513 项。
(* keep_hierarchy = "yes", use_dsp = "no" *)
module ${top}_ct_rom$ch (
    input  wire        clk,
    input  wire [9:0]  a0,
    input  wire [9:0]  a1,
    output reg  [18:0] d0,
    output reg  [18:0] d1
);
''');
  b.writeln('  (* ram_style = "block" *) reg [18:0] $mem [0:1025];');
  b.writeln('  initial begin');
  for (var i = 0; i < lower.length; i++) {
    b.writeln("    $mem[$i] = 19'd${lower[i]};");
  }
  for (var i = 0; i < upper.length; i++) {
    b.writeln("    $mem[${513 + i}] = 19'd${upper[i]};");
  }
  b.writeln('  end');
  b.writeln('''
  always @(posedge clk) begin
    d0 <= $mem[a0];
    d1 <= $mem[a1];
  end
endmodule
''');
  return b.toString();
}


/// 组合 ROM 版白点表（`USE_BRAM=0`，上一版实现）：每通道一个模块，
/// lo/up 两套表 + 段内线性插值，kelvin/upper 组合输入、无读延迟。
String _ctWhiteRomLut(String top, String ch, List<int> lower, List<int> upper) {
  final mem = 'ct_lut_w$ch';
  final b = StringBuffer();
  final name = ch == 'r' ? 'R' : 'B';
  b.writeln('''
// 白点表（$name 通道，组合 ROM 版，Q16）：段宽 32K、网格偏移 8K，6600K 两侧
// 各一套表，段内线性插值。与块 RAM 版共用同一份表数据与插值写法。
// 注意：表与查表必须留在**本模块内**、并让模块自成一个层次——把表和乘法放在
// 同一个大模块里时 Vivado 会把查表当常量折叠掉（实测模块被砍成 34 LUT 且
// 仿真全 X），拆成独立 ROM 子模块后行为正确。
(* keep_hierarchy = "yes", use_dsp = "no" *)
module ${top}_ct_ln$ch (
    input  wire [13:0] kelvin,
    input  wire        upper,
    output reg  [18:0] q16
);
''');
  b.writeln(_bakeTable('${mem}_lo', lower, 19));
  b.writeln(_bakeTable('${mem}_up', upper, 19));
  b.writeln("""
  // 注意：查表必须写成 always @* 组合块——**不能放进 function**：Vivado 的
  // XSim 不支持在 function 里读 unpacked array（仿真返回 X，而综合/iverilog
  // 都正常，极易误判）。
  reg   [13:0] k;
  reg   [8:0]  idx;
  reg   [4:0]  frac;
  reg   [18:0] y0, y1;
  reg   [24:0] acc;
  always @* begin
    k = (kelvin < 14'd8) ? 14'd8 : ((kelvin > 14'd16375) ? 14'd16375 : kelvin);
    k = k - 14'd8;
    idx = (k[13:5] > 9'd511) ? 9'd511 : k[13:5];
    frac = k[4:0];
    y0 = upper ? ${mem}_up[idx] : ${mem}_lo[idx];
    y1 = upper ? ${mem}_up[idx + 9'd1] : ${mem}_lo[idx + 9'd1];
    acc = y0 * (25'd32 - {20'd0, frac}) + y1 * {20'd0, frac} + 25'd16;
    q16 = acc >> 5;
  end
endmodule
""");
  return b.toString();
}

/// 组合 ROM 版倒数表（`USE_BRAM=0`）。
String _ctRomqLut(String top, List<int> recip) {
  final b = StringBuffer();
  b.writeln('''
// 倒数表（组合 ROM 版，Q30）：Q16 白点值 -> 2^30/v，步长 512、段内线性插值。
(* keep_hierarchy = "yes", use_dsp = "no" *)
module ${top}_ct_lq (
    input  wire [18:0] v,
    output reg  [23:0] q30
);
''');
  b.writeln(_bakeTable('ct_lut_rcp', recip, 24));
  b.writeln("""
  // 同白点 ROM：查表用 always @*（function 读内存 XSim 会返回 X）。
  reg   [18:0] vv;
  reg   [9:0]  idx;
  reg   [8:0]  frac;
  reg   [23:0] y0, y1;
  reg   [33:0] acc;
  always @* begin
    vv = (v < 19'd512) ? 19'd512 : ((v > 19'd523776) ? 19'd523776 : v);
    idx = vv[18:9];
    frac = vv[8:0];
    y0 = ct_lut_rcp[idx];
    y1 = ct_lut_rcp[idx + 10'd1];
    acc = y0 * (34'd512 - {25'd0, frac}) + y1 * {25'd0, frac} + 34'd256;
    q30 = acc >> 9;
  end
endmodule
""");
  return b.toString();
}

/// 组合 ROM 版增益（`USE_BRAM=0`，即上一版实现）：白点/倒数表放独立组合 ROM
/// 子模块，插值与白点比全组合、帧起始锁存。与块 RAM 版**逐位一致**（同一份
/// 表数据、同一插值写法），差别只有表存储方式与读延迟（此版组合读、无流水）。
String _ctGainLut(String top, CtWhiteTables t) {
  final b = StringBuffer();
  b.writeln(_ctWhiteRomLut(top, 'r', t.lowerR, t.upperR));
  b.writeln(_ctWhiteRomLut(top, 'b', t.lowerB, t.upperB));
  b.writeln(_ctRomqLut(top, t.recip));
  b.writeln('''
// 色温增益（组合 ROM 版，上一版实现）：目标/参考白点 -> Q14 增益。
(* keep_hierarchy = "yes", use_dsp = "no" *)
module ${top}_ct_gain_lut (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        sof,
    input  wire [13:0] cct_in,
    input  wire [13:0] cct_ref,
    output wire [15:0] gain_r,
    output wire [15:0] gain_b
);
  localparam [15:0] CT_Q14_ONE = 16'd16384;
  localparam [13:0] CT_CCT_MIN = 14'd1800;
  localparam [13:0] CT_CCT_MAX = 14'd12000;
  localparam [13:0] CT_BRANCH  = 14'd6600;

  wire [13:0] tc = (cct_in < CT_CCT_MIN) ? CT_CCT_MIN :
                   ((cct_in > CT_CCT_MAX) ? CT_CCT_MAX : cct_in);
  wire [13:0] rc = (cct_ref < CT_CCT_MIN) ? CT_CCT_MIN :
                   ((cct_ref > CT_CCT_MAX) ? CT_CCT_MAX : cct_ref);
  wire tu = (tc > CT_BRANCH);
  wire ru = (rc > CT_BRANCH);

  wire [18:0] wt_r, wt_b, wr_r, wr_b;
  ${top}_ct_lnr u_wt_r (.kelvin(tc), .upper(tu), .q16(wt_r));
  ${top}_ct_lnb u_wt_b (.kelvin(tc), .upper(tu), .q16(wt_b));
  ${top}_ct_lnr u_wr_r (.kelvin(rc), .upper(ru), .q16(wr_r));
  ${top}_ct_lnb u_wr_b (.kelvin(rc), .upper(ru), .q16(wr_b));
  wire [23:0] rcp_r, rcp_b;
  ${top}_ct_lq u_rcp_r (.v(wr_r), .q30(rcp_r));
  ${top}_ct_lq u_rcp_b (.v(wr_b), .q30(rcp_b));

  function [15:0] ct_gainq;
    input [18:0] wt;
    input [23:0] rcp;
    reg   [42:0] prod;
    begin
      prod = (wt * rcp + 43'd32768) >> 16;
      ct_gainq = (prod > 43'd65535) ? 16'd65535 : prod[15:0];
    end
  endfunction

  wire [15:0] gain_r_new = (tc == rc) ? CT_Q14_ONE : ct_gainq(wt_r, rcp_r);
  wire [15:0] gain_b_new = (tc == rc) ? CT_Q14_ONE : ct_gainq(wt_b, rcp_b);

  reg [15:0] gain_r_reg, gain_b_reg;
  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      gain_r_reg <= CT_Q14_ONE;
      gain_b_reg <= CT_Q14_ONE;
    end else if (sof) begin
      gain_r_reg <= gain_r_new;
      gain_b_reg <= gain_b_new;
    end
  end
  // 帧起始那拍直接用组合值：整帧像素与增益严格对齐。
  assign gain_r = sof ? gain_r_new : gain_r_reg;
  assign gain_b = sof ? gain_b_new : gain_b_reg;
endmodule
''');
  return b.toString();
}

/// 色温控制块全套模块：`_ct_romr` / `_ct_romb` / `_ct_romq` / `_ct_gain` /
/// `_ct_meas` / `_ct_ctrl`（均按 `<top>` 前缀命名）。
String ctCtrlVerilog(String top,
    {CtWhiteTables? tables, bool useBram = true}) {
  final t = tables ?? CtWhiteTables();
  final b = StringBuffer();

  // ---- 顶层：只做互连（cellview 原语极少，避开 29-101）----
  b.writeln('''
// ---------------------------------------------------------------------------
// 色温控制块顶层：目标色温端口 -> 内部 CCM（von Kries 对角 Q14 增益）；输入
// 帧统计 -> 固定点 McCamy 测量（14 位 cct_out）。所有表在生成期烘焙，全整数，
// 与 Dart 参考 color_temp_hw.dart 逐位一致。
// ---------------------------------------------------------------------------
(* keep_hierarchy = "yes" *)
module ${top}_ct_ctrl #(
    // 表存储：1 = Block RAM（省 CLB LUT，默认）；0 = 分布式组合 ROM（上一版实现）。
    // 两套实现同时打进核，综合按参数折叠；Vivado Customize IP 的 Optimization
    // 页可改（改值后重新生成 IP 即时生效）。
    parameter integer USE_BRAM = ${useBram ? 1 : 0}
) (
    input  wire               clk,
    input  wire               rst_n,
    input  wire               sof,      // 帧起始（有效像素处）
    input  wire signed [47:0] sum_r,
    input  wire signed [47:0] sum_g,
    input  wire signed [47:0] sum_b,
    input  wire [13:0]        cct_in,
    output wire [15:0]        gain_r,   // Q14，帧起始切换后的有效增益
    output wire [15:0]        gain_b,   // Q14
    output wire [13:0]        cct_out   // 实测色温 K（每帧更新）
);
  ${top}_ct_meas u_meas (
      .clk(clk), .rst_n(rst_n), .sof(sof),
      .sum_r(sum_r), .sum_g(sum_g), .sum_b(sum_b),
      .cct_out(cct_out));
  generate
    if (USE_BRAM != 0) begin : g_bram
      ${top}_ct_gain u_gain (
          .clk(clk), .rst_n(rst_n), .sof(sof),
          .cct_in(cct_in), .cct_ref(cct_out),
          .gain_r(gain_r), .gain_b(gain_b));
    end else begin : g_lut
      ${top}_ct_gain_lut u_gain (
          .clk(clk), .rst_n(rst_n), .sof(sof),
          .cct_in(cct_in), .cct_ref(cct_out),
          .gain_r(gain_r), .gain_b(gain_b));
    end
  endgenerate
endmodule
''');

  // ---- 白点表（块 RAM 版；组合 ROM 版在 _ctGainLut 里一并发射）----
  b.writeln(_ctWhiteRom(top, 'r', t.lowerR, t.upperR));
  b.writeln(_ctWhiteRom(top, 'b', t.lowerB, t.upperB));

  // ---- 倒数表（块 RAM 版）----
  {
    b.writeln('''
// 倒数表（Q30，块 RAM 双端口）：Q16 白点值 -> 2^30/v，步长 512、段内线性插值
//（插值两端点用两个读口一拍取出）。下标 = v>>9；v < 512 时钳到 512。
(* keep_hierarchy = "yes", use_dsp = "no" *)
module ${top}_ct_romq (
    input  wire        clk,
    input  wire [9:0]  a0,
    input  wire [9:0]  a1,
    output reg  [23:0] d0,
    output reg  [23:0] d1
);
''');
    b.writeln(_bakeTable('ct_rcp', t.recip, 24, attr: '(* ram_style = "block" *) '));
    b.writeln('''
  always @(posedge clk) begin
    d0 <= ct_rcp[a0];
    d1 <= ct_rcp[a1];
  end
endmodule
''');
  }

  // ---- 增益（块 RAM 版：6 级流水）----
  {
    b.writeln('''
  // 目标/参考白点 -> Q14 增益（与 Dart ctGainsQ14 逐位一致）：目标==参考时短路
  // 成恒等，其余走「白点比 × 倒数表」——没有除法器。整链 6 级流水（表在块 RAM
  // 里需同步读），帧起始锁存最新结果，整帧像素与增益严格对齐。
  (* keep_hierarchy = "yes", use_dsp = "no" *)
  module ${top}_ct_gain (
      input  wire        clk,
      input  wire        rst_n,
      input  wire        sof,
      input  wire [13:0] cct_in,
      input  wire [13:0] cct_ref,
      output wire [15:0] gain_r,
      output wire [15:0] gain_b
  );
    localparam [15:0] CT_Q14_ONE = 16'd16384;
    localparam [13:0] CT_CCT_MIN = 14'd1800;
    localparam [13:0] CT_CCT_MAX = 14'd12000;
    localparam [13:0] CT_BRANCH  = 14'd6600;   // Tanner Helland 的 t=66 断点

    // ---- 级 0（组合）：参数钳位、段索引/小数、表地址 ----
    wire [13:0] tc = (cct_in < CT_CCT_MIN) ? CT_CCT_MIN :
                     ((cct_in > CT_CCT_MAX) ? CT_CCT_MAX : cct_in);
    wire [13:0] rc = (cct_ref < CT_CCT_MIN) ? CT_CCT_MIN :
                     ((cct_ref > CT_CCT_MAX) ? CT_CCT_MAX : cct_ref);
    wire tu = (tc > CT_BRANCH);
    wire ru = (rc > CT_BRANCH);
    function [13:0] ct_koff;
      input [13:0] k;
      begin
        ct_koff = (k < 14'd8) ? 14'd0 :
                  ((k > 14'd16375) ? 14'd16367 : (k - 14'd8));
      end
    endfunction
    function [9:0] ct_sel;
      input [13:0] k;
      input        up;
      reg   [13:0] idx;
      begin
        idx = ct_koff(k) >> 5;
        ct_sel = (up ? 10'd513 : 10'd0) + ((idx > 14'd511) ? 10'd511 : idx[9:0]);
      end
    endfunction

    reg [9:0] a_t_r, a_t_b, a_r_r, a_r_b;
    reg [4:0] f_t, f_r;
    reg       eq_rc;
    always @(posedge clk) begin
      a_t_r <= ct_sel(tc, tu);
      a_t_b <= ct_sel(tc, tu);
      a_r_r <= ct_sel(rc, ru);
      a_r_b <= ct_sel(rc, ru);
      f_t   <= ct_koff(tc) & 14'h1f;
      f_r   <= ct_koff(rc) & 14'h1f;
      eq_rc <= (tc == rc);
    end

    // ---- 级 1/2：白点 ROM 同步读 + 段内线性插值（与 Dart _lookupWhite 同口径）----
    wire [18:0] wt_r0, wt_r1, wt_b0, wt_b1, wr_r0, wr_r1, wr_b0, wr_b1;
    ${top}_ct_romr u_wt_r (.clk(clk), .a0(a_t_r), .a1(a_t_r + 10'd1),
                           .d0(wt_r0), .d1(wt_r1));
    ${top}_ct_romb u_wt_b (.clk(clk), .a0(a_t_b), .a1(a_t_b + 10'd1),
                           .d0(wt_b0), .d1(wt_b1));
    ${top}_ct_romr u_wr_r (.clk(clk), .a0(a_r_r), .a1(a_r_r + 10'd1),
                           .d0(wr_r0), .d1(wr_r1));
    ${top}_ct_romb u_wr_b (.clk(clk), .a0(a_r_b), .a1(a_r_b + 10'd1),
                           .d0(wr_b0), .d1(wr_b1));

    function [18:0] ct_interp;
      input [18:0] y0;
      input [18:0] y1;
      input [4:0]  frac;
      reg   [24:0] acc;
      begin
        acc = y0 * (25'd32 - {20'd0, frac}) + y1 * {20'd0, frac} + 25'd16;
        ct_interp = acc >> 5;
      end
    endfunction
    reg [18:0] q_wt_r, q_wt_b, q_wr_r, q_wr_b;
    reg        eq2;
    always @(posedge clk) begin
      q_wt_r <= ct_interp(wt_r0, wt_r1, f_t);
      q_wt_b <= ct_interp(wt_b0, wt_b1, f_t);
      q_wr_r <= ct_interp(wr_r0, wr_r1, f_r);
      q_wr_b <= ct_interp(wr_b0, wr_b1, f_r);
      eq2 <= eq_rc;
    end

    // ---- 级 3/4/5：倒数表（双端口读 + 段内插值）----
    // 白点值先钳到表域，再把 (idx, idx+1) 与该段的 frac 打一拍给 ROM。
    function [18:0] ct_recip_clamp;
      input [18:0] v;
      begin
        ct_recip_clamp = (v < 19'd512) ? 19'd512 :
                         ((v > 19'd523776) ? 19'd523776 : v);
      end
    endfunction
    reg [9:0]  aq_r, aq_b;
    reg [8:0]  fq_r, fq_b;
    reg        eq3;
    wire [18:0] qc_r = ct_recip_clamp(q_wr_r);
    wire [18:0] qc_b = ct_recip_clamp(q_wr_b);
    always @(posedge clk) begin
      aq_r <= qc_r[18:9];
      aq_b <= qc_b[18:9];
      fq_r <= qc_r[8:0];
      fq_b <= qc_b[8:0];
      eq3 <= eq2;
    end
    wire [23:0] rq_r0, rq_r1, rq_b0, rq_b1;
    ${top}_ct_romq u_rcp_r (.clk(clk), .a0(aq_r), .a1(aq_r + 10'd1),
                            .d0(rq_r0), .d1(rq_r1));
    ${top}_ct_romq u_rcp_b (.clk(clk), .a0(aq_b), .a1(aq_b + 10'd1),
                            .d0(rq_b0), .d1(rq_b1));
    function [23:0] ct_recip_interp;
      input [23:0] y0;
      input [23:0] y1;
      input [8:0]  frac;
      reg   [33:0] acc;
      begin
        acc = y0 * (34'd512 - {25'd0, frac}) + y1 * {25'd0, frac} + 34'd256;
        ct_recip_interp = acc >> 9;
      end
    endfunction
    reg [23:0] rcp_r, rcp_b;
    reg [18:0] wt_r3, wt_b3;
    always @(posedge clk) begin
      rcp_r <= ct_recip_interp(rq_r0, rq_r1, fq_r);
      rcp_b <= ct_recip_interp(rq_b0, rq_b1, fq_b);
      wt_r3 <= q_wt_r;
      wt_b3 <= q_wt_b;
    end

    // ---- 级 6：白点比 = 目标白点 × 倒数（Q14）；目标==参考短路成恒等 ----
    function [15:0] ct_gain_f;
      input [18:0] wt;
      input [23:0] rcp;
      reg   [42:0] prod;
      begin
        prod = (wt * rcp + 43'd32768) >> 16;
        ct_gain_f = (prod > 43'd65535) ? 16'd65535 : prod[15:0];
      end
    endfunction
    reg [15:0] gain_r_new, gain_b_new;
    always @(posedge clk) begin
      gain_r_new <= eq3 ? CT_Q14_ONE : ct_gain_f(wt_r3, rcp_r);
      gain_b_new <= eq3 ? CT_Q14_ONE : ct_gain_f(wt_b3, rcp_b);
    end

    // ---- 帧起始锁存：整帧像素与增益严格对齐 ----
    // 帧起始那拍直接用流水输出（`gain_*_new`），保证首像素就用本帧增益；
    // 其余像素用锁存值。
    reg [15:0] gain_r_reg, gain_b_reg;
    always @(posedge clk or negedge rst_n) begin
      if (!rst_n) begin
        gain_r_reg <= CT_Q14_ONE;
        gain_b_reg <= CT_Q14_ONE;
      end else if (sof) begin
        gain_r_reg <= gain_r_new;
        gain_b_reg <= gain_b_new;
      end
    end
    assign gain_r = sof ? gain_r_new : gain_r_reg;
    assign gain_b = sof ? gain_b_new : gain_b_reg;
  endmodule
  ''');

  }

  // ---- 组合 ROM 版（useBram=false，上一版实现：表 + 增益一起发）----
  b.writeln(_ctGainLut(top, t));

  // ---- 测量 ----
  b.writeln('''
// 帧测量：累加和 -> 固定点 McCamy。nq^2/nq^3 走 DSP48 原语（全流水，内部
// 寄存器自带同步复位），多项式常数乘法走 LUT（系数置位数少）；FSM 全部同步
// 复位（避免 DPOR-2）。FSM 约 65 拍，一帧像素数需 ≥96。
(* keep_hierarchy = "yes", use_dsp = "no" *)
module ${top}_ct_meas (
    input  wire               clk,
    input  wire               rst_n,
    input  wire               sof,
    input  wire signed [47:0] sum_r,
    input  wire signed [47:0] sum_g,
    input  wire signed [47:0] sum_b,
    output reg  [13:0]        cct_out
);
  localparam [13:0] CT_CCT_MIN = 14'd1800;
  localparam [13:0] CT_CCT_MAX = 14'd12000;

  localparam [3:0] CT_IDLE = 4'd0, CT_XYZ = 4'd1, CT_AB = 4'd2,
                   CT_CHK = 4'd3, CT_DIV = 4'd4, CT_NQ = 4'd5,
                   CT_D1 = 4'd6, CT_D2 = 4'd7, CT_D3 = 4'd8, CT_D4 = 4'd9,
                   CT_E1 = 4'd10, CT_E2 = 4'd11, CT_E3 = 4'd12, CT_E4 = 4'd13,
                   CT_POLY = 4'd14, CT_OUT = 4'd15;
  reg [3:0]  st;
  reg signed [47:0] s_r, s_g, s_b;
  reg signed [47:0] av, bv;
  reg        dv_neg;
  reg [47:0] dv_dend, dv_den, dv_rem, dv_quo;
  reg [5:0]  dv_cnt;
  reg signed [31:0] nq;
  reg        nq_neg;
  reg [15:0] nqm;              // |nq|（≤32767），DSP 的 A/B 操作数
  reg [47:0] nq2;              // |nq|^2
  reg signed [47:0] nq3;       // nq^3（带符号）
  reg signed [63:0] poly;

  // McCamy 色度比 n = A/B 的合并系数（见 color_temp_hw.dart kCtCoefA/B）：
  // 直接对累加和做线性组合，6 次宽乘法即可（原先 X/Y/Z/S 要 12 次）。
  wire signed [47:0] av_w =
      (-48'sd13008 * s_r + 48'sd2500 * s_g + 48'sd14351 * s_b +
       48'sd32768) >>> 16;
  wire signed [47:0] bv_w =
      (48'sd6088 * s_r + 48'sd32356 * s_g - 48'sd9918 * s_b +
       48'sd32768) >>> 16;

  wire signed [47:0] nq2_dsp, nq3_dsp;
  ${top}_dsp_mul #(.AW(16), .BW(16), .PW(48), .SIGNED_A(0), .SIGNED_B(0))
      u_nq2 (.clk(clk), .en(1'b1), .a(nqm), .b(nqm), .p(nq2_dsp));
  ${top}_dsp_mul #(.AW(30), .BW(16), .PW(48), .SIGNED_A(0), .SIGNED_B(0))
      u_nq3 (.clk(clk), .en(1'b1), .a(nq2[29:0]), .b(nqm), .p(nq3_dsp));

  (* use_dsp = "no" *) wire signed [63:0] poly_t3 = (64'sd449 * nq3) >>> 26;
  (* use_dsp = "no" *) wire signed [63:0] poly_t2 =
      (64'sd3525 * \$signed({16'd0, nq2})) >>> 12;
  (* use_dsp = "no" *) wire signed [63:0] poly_t1 =
      (64'sd$kCtPolyC1 * nq) >>> 8;

  always @(posedge clk) begin
    if (!rst_n) begin
      st <= CT_IDLE;
      cct_out <= 14'd6500;   // 未测量前用 D65 作参考
      s_r <= 48'sd0; s_g <= 48'sd0; s_b <= 48'sd0;
      av <= 48'sd0; bv <= 48'sd0;
      dv_neg <= 1'b0; dv_dend <= 48'd0; dv_den <= 48'd0;
      dv_rem <= 48'd0; dv_quo <= 48'd0; dv_cnt <= 6'd0;
      nq <= 32'sd0; nq_neg <= 1'b0; nqm <= 16'd0;
      nq2 <= 48'd0; nq3 <= 48'sd0; poly <= 64'sd0;
    end else begin
      case (st)
        CT_IDLE: begin
          if (sof) begin
            s_r <= sum_r; s_g <= sum_g; s_b <= sum_b;
            st <= CT_XYZ;
          end
        end
        CT_XYZ: begin
          av <= av_w;
          bv <= bv_w;
          st <= CT_AB;
        end
        CT_AB: st <= CT_CHK;
        CT_CHK: begin
          // 全黑（S<=0）或灰区（B<=0）无法估色温：保持上一次测量。
          if (bv <= 48'sd0) begin
            st <= CT_IDLE;
          end else begin
            dv_neg <= (av < 48'sd0);
            dv_dend <= ((av < 48'sd0) ? (48'sd0 - av) : av) << 14;
            dv_den <= bv;
            dv_rem <= 48'd0;
            dv_quo <= 48'd0;
            dv_cnt <= 6'd48;
            st <= CT_DIV;
          end
        end
        CT_DIV: begin
          // 逐位长除法（每拍一位）：rem = (rem<<1)|bit，减得动则商位 1。
          if ({dv_rem[46:0], dv_dend[47]} >= dv_den) begin
            dv_rem <= {dv_rem[46:0], dv_dend[47]} - dv_den;
            dv_quo <= {dv_quo[46:0], 1'b1};
          end else begin
            dv_rem <= {dv_rem[46:0], dv_dend[47]};
            dv_quo <= {dv_quo[46:0], 1'b0};
          end
          dv_dend <= {dv_dend[46:0], 1'b0};
          dv_cnt <= dv_cnt - 6'd1;
          if (dv_cnt == 6'd1) st <= CT_NQ;
        end
        CT_NQ: begin
          // |n| 钳到 32767（真实 n 在 ±0.6 内；防极端色度让三次项溢出）。
          if (dv_quo > 48'd32767) begin
            nqm <= 16'd32767;
            nq <= dv_neg ? -32'sd32767 : 32'sd32767;
          end else begin
            nqm <= dv_quo[15:0];
            nq <= dv_neg ? -\$signed({16'd0, dv_quo[15:0]})
                         : \$signed({16'd0, dv_quo[15:0]});
          end
          nq_neg <= dv_neg;
          st <= CT_D1;
        end
        CT_D1, CT_D2, CT_D3: st <= st + 4'd1;   // DSP1：A/B -> M -> P
        CT_D4: begin
          nq2 <= nq2_dsp;
          st <= CT_E1;
        end
        CT_E1, CT_E2, CT_E3: st <= st + 4'd1;   // DSP2：A/B -> M -> P
        CT_E4: begin
          nq3 <= nq_neg ? -nq3_dsp : nq3_dsp;
          st <= CT_POLY;
        end
        CT_POLY: begin
          poly <= poly_t3 + poly_t2 + poly_t1 + 64'sd$kCtPolyConstQ16;
          st <= CT_OUT;
        end
        CT_OUT: begin
          if (((poly + 64'sd32768) >>> 16) < 64'sd1800) begin
            cct_out <= CT_CCT_MIN;
          end else if (((poly + 64'sd32768) >>> 16) > 64'sd12000) begin
            cct_out <= CT_CCT_MAX;
          end else begin
            cct_out <= ((poly + 64'sd32768) >>> 16) & 14'h3fff;
          end
          st <= CT_IDLE;
        end
        default: st <= CT_IDLE;
      endcase
    end
  end
endmodule
''');

  // ---- 像素增益缩放 ----
  b.writeln(ctScaleModuleVerilog(top));
  return b.toString();
}

/// 像素增益缩放器：`(* use_dsp = "no" *)` 只在**模块级**被 Vivado 采纳
///（挂在 wire/assign 上无效，实测仍会被推断成未流水的 DSP 并报 DPIP/DPOP），
/// 所以把 8x16 / 16x16 的小乘法包成模块——1 拍延迟不变，零 DSP 建议。
String ctScaleModuleVerilog(String top) => '''
// 像素通道增益缩放：Q14 增益乘加 + 钳位（纯 LUT，见上方注释）。
(* use_dsp = "no" *)
module ${top}_ct_scale #(
    parameter integer PW = 8
) (
    input  wire [PW-1:0]  px,
    input  wire [15:0]    gain,   // Q14
    output wire [PW-1:0]  y
);
  localparam [PW-1:0] MAXV = {PW{1'b1}};
  wire signed [PW+17:0] prod =
      (\$signed({1'b0, px}) * \$signed({1'b0, gain}) + 18'sd8192) >>> 14;
  assign y = (prod < 0) ? {PW{1'b0}} : ((prod > MAXV) ? MAXV : prod[PW-1:0]);
endmodule
''';

/// 核心侧胶水：帧统计累加器 + 控制块例化 + 运行期 Q14 增益像素通路。
///
/// [id] 为该色温节点在编组内的标识；调用方把本级的 wire 写成
/// `{<id>_r, <id>_g, <id>_b}`。
String ctCoreGlue({
  required String top,
  required String id,
  required int pixBits,
  required int bw,
  required String input,
}) {
  return '''
  // ---- 色温调节器（$id）：帧统计 + 控制块 + 运行期 Q14 增益 ----
  wire [13:0] ${id}_cct_out;
  wire [15:0] ${id}_gain_r, ${id}_gain_b;
  reg  signed [47:0] ${id}_sum_r, ${id}_sum_g, ${id}_sum_b;
  wire [$pixBits-1:0] ${id}_px_r = $input[$bw-1 -: $pixBits];
  wire [$pixBits-1:0] ${id}_px_g = $input[${2 * pixBits}-1 -: $pixBits];
  wire [$pixBits-1:0] ${id}_px_b = $input[$pixBits-1:0];
  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      ${id}_sum_r <= 48'sd0; ${id}_sum_g <= 48'sd0; ${id}_sum_b <= 48'sd0;
    end else if (in_valid && in_sof) begin
      ${id}_sum_r <= \$signed({1'b0, ${id}_px_r});
      ${id}_sum_g <= \$signed({1'b0, ${id}_px_g});
      ${id}_sum_b <= \$signed({1'b0, ${id}_px_b});
    end else if (in_valid) begin
      ${id}_sum_r <= ${id}_sum_r + \$signed({1'b0, ${id}_px_r});
      ${id}_sum_g <= ${id}_sum_g + \$signed({1'b0, ${id}_px_g});
      ${id}_sum_b <= ${id}_sum_b + \$signed({1'b0, ${id}_px_b});
    end
  end
  ${top}_ct_ctrl #(.USE_BRAM(USE_BRAM)) ${id}_ct_ctrl (
      .clk(clk), .rst_n(rst_n),
      .sof(in_valid & in_sof),
      .sum_r(${id}_sum_r), .sum_g(${id}_sum_g), .sum_b(${id}_sum_b),
      .cct_in(cct_in),
      .gain_r(${id}_gain_r), .gain_b(${id}_gain_b),
      .cct_out(${id}_cct_out)
  );
  assign cct_out = ${id}_cct_out;
  wire [$pixBits-1:0] ${id}_r, ${id}_b, ${id}_g;
  ${top}_ct_scale #(.PW($pixBits)) ${id}_u_r (
      .px(${id}_px_r), .gain(${id}_gain_r), .y(${id}_r));
  ${top}_ct_scale #(.PW($pixBits)) ${id}_u_b (
      .px(${id}_px_b), .gain(${id}_gain_b), .y(${id}_b));
  // G 通道增益恒 1.0（Q14=16384），乘加即恒等，直接直通。
  assign ${id}_g = ${id}_px_g;
''';
}
