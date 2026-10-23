// 本文件由 DebugToolSet ISP Studio 自动生成（编组 → FPGA Verilog IP 包）。
// 目标厂商：AMD/Xilinx Vivado
// 像素位宽 PIX_BITS=8（MAXV=255）、LUT 域 0..255
// 核心模块：通用像素流 in→out（带 ready 握手），节点参数已烘焙；
// 厂商封装（AXI4-Stream / Libero）只转接口不含逻辑。
`timescale 1ns/1ps
module isp_ip_multi_band_eq_core #(
    parameter integer PIX_BITS  = 8,
    parameter integer MAX_WIDTH = 4096,
    // 优化策略预留（0 面积 / 1 平衡 / 2 性能）：当前白名单为点操作
    //（II=1 恒等），窗口算子落地后经 generate-if 分档生效。
    parameter integer GSTRATEGY = 1,
    parameter integer FOLD      = 1
) (
    input  wire                   clk,
    input  wire                   rst_n,
    // 像素流输入（{H, S, L} 打包，H 在最高位段）
    input  wire                   in_valid,
    output wire                   in_ready,
    input  wire                   in_sof,
    input  wire                   in_eol,
    input  wire [24-1:0]         in_data,
    // 像素流输出（同打包）
    output reg                    out_valid,
    input  wire                   out_ready,
    output reg                    out_sof,
    output reg                    out_eol,
    output reg  [24-1:0]         out_data
);
  localparam [8-1:0] MAXV = (1 << PIX_BITS) - 1;

  wire [8-1:0] in_h = in_data[24-1 -: 8];
  wire [8-1:0] in_s = in_data[16-1 -: 8];
  wire [8-1:0] in_l = in_data[8-1:0];

  // H 偏移表（16 位补码，|shift| ≤ MAXV/2）
  reg [15:0] n1_shift_lut [0:255];
  initial begin
    n1_shift_lut[0] = 16'h0013; n1_shift_lut[1] = 16'h0013; n1_shift_lut[2] = 16'h0013; n1_shift_lut[3] = 16'h0013;
    n1_shift_lut[4] = 16'h0013; n1_shift_lut[5] = 16'h0012; n1_shift_lut[6] = 16'h0012; n1_shift_lut[7] = 16'h0012;
    n1_shift_lut[8] = 16'h0012; n1_shift_lut[9] = 16'h0011; n1_shift_lut[10] = 16'h0011; n1_shift_lut[11] = 16'h0010;
    n1_shift_lut[12] = 16'h0010; n1_shift_lut[13] = 16'h000f; n1_shift_lut[14] = 16'h000f; n1_shift_lut[15] = 16'h000e;
    n1_shift_lut[16] = 16'h000d; n1_shift_lut[17] = 16'h000d; n1_shift_lut[18] = 16'h000c; n1_shift_lut[19] = 16'h000b;
    n1_shift_lut[20] = 16'h000b; n1_shift_lut[21] = 16'h000a; n1_shift_lut[22] = 16'h0009; n1_shift_lut[23] = 16'h0009;
    n1_shift_lut[24] = 16'h0008; n1_shift_lut[25] = 16'h0007; n1_shift_lut[26] = 16'h0007; n1_shift_lut[27] = 16'h0006;
    n1_shift_lut[28] = 16'h0006; n1_shift_lut[29] = 16'h0005; n1_shift_lut[30] = 16'h0005; n1_shift_lut[31] = 16'h0004;
    n1_shift_lut[32] = 16'h0004; n1_shift_lut[33] = 16'h0003; n1_shift_lut[34] = 16'h0003; n1_shift_lut[35] = 16'h0003;
    n1_shift_lut[36] = 16'h0002; n1_shift_lut[37] = 16'h0002; n1_shift_lut[38] = 16'h0002; n1_shift_lut[39] = 16'h0002;
    n1_shift_lut[40] = 16'h0001; n1_shift_lut[41] = 16'h0001; n1_shift_lut[42] = 16'h0001; n1_shift_lut[43] = 16'h0001;
    n1_shift_lut[44] = 16'h0001; n1_shift_lut[45] = 16'h0001; n1_shift_lut[46] = 16'h0001; n1_shift_lut[47] = 16'h0000;
    n1_shift_lut[48] = 16'h0000; n1_shift_lut[49] = 16'h0000; n1_shift_lut[50] = 16'h0000; n1_shift_lut[51] = 16'h0000;
    n1_shift_lut[52] = 16'h0000; n1_shift_lut[53] = 16'h0000; n1_shift_lut[54] = 16'h0000; n1_shift_lut[55] = 16'h0000;
    n1_shift_lut[56] = 16'h0000; n1_shift_lut[57] = 16'h0000; n1_shift_lut[58] = 16'h0000; n1_shift_lut[59] = 16'h0000;
    n1_shift_lut[60] = 16'h0000; n1_shift_lut[61] = 16'h0000; n1_shift_lut[62] = 16'h0000; n1_shift_lut[63] = 16'h0000;
    n1_shift_lut[64] = 16'h0000; n1_shift_lut[65] = 16'h0000; n1_shift_lut[66] = 16'h0000; n1_shift_lut[67] = 16'h0000;
    n1_shift_lut[68] = 16'h0000; n1_shift_lut[69] = 16'h0000; n1_shift_lut[70] = 16'h0000; n1_shift_lut[71] = 16'h0000;
    n1_shift_lut[72] = 16'h0000; n1_shift_lut[73] = 16'h0000; n1_shift_lut[74] = 16'h0000; n1_shift_lut[75] = 16'h0000;
    n1_shift_lut[76] = 16'h0000; n1_shift_lut[77] = 16'h0000; n1_shift_lut[78] = 16'h0000; n1_shift_lut[79] = 16'h0000;
    n1_shift_lut[80] = 16'h0000; n1_shift_lut[81] = 16'h0000; n1_shift_lut[82] = 16'h0000; n1_shift_lut[83] = 16'h0000;
    n1_shift_lut[84] = 16'h0000; n1_shift_lut[85] = 16'h0000; n1_shift_lut[86] = 16'h0000; n1_shift_lut[87] = 16'h0000;
    n1_shift_lut[88] = 16'h0000; n1_shift_lut[89] = 16'h0000; n1_shift_lut[90] = 16'h0000; n1_shift_lut[91] = 16'h0000;
    n1_shift_lut[92] = 16'h0000; n1_shift_lut[93] = 16'h0000; n1_shift_lut[94] = 16'h0000; n1_shift_lut[95] = 16'h0000;
    n1_shift_lut[96] = 16'h0000; n1_shift_lut[97] = 16'h0000; n1_shift_lut[98] = 16'h0000; n1_shift_lut[99] = 16'h0000;
    n1_shift_lut[100] = 16'h0000; n1_shift_lut[101] = 16'h0000; n1_shift_lut[102] = 16'h0000; n1_shift_lut[103] = 16'h0000;
    n1_shift_lut[104] = 16'h0000; n1_shift_lut[105] = 16'h0000; n1_shift_lut[106] = 16'h0000; n1_shift_lut[107] = 16'h0000;
    n1_shift_lut[108] = 16'h0000; n1_shift_lut[109] = 16'h0000; n1_shift_lut[110] = 16'h0000; n1_shift_lut[111] = 16'h0000;
    n1_shift_lut[112] = 16'h0000; n1_shift_lut[113] = 16'h0000; n1_shift_lut[114] = 16'h0000; n1_shift_lut[115] = 16'h0000;
    n1_shift_lut[116] = 16'h0000; n1_shift_lut[117] = 16'h0000; n1_shift_lut[118] = 16'h0000; n1_shift_lut[119] = 16'h0000;
    n1_shift_lut[120] = 16'h0000; n1_shift_lut[121] = 16'h0000; n1_shift_lut[122] = 16'h0000; n1_shift_lut[123] = 16'h0000;
    n1_shift_lut[124] = 16'h0000; n1_shift_lut[125] = 16'h0000; n1_shift_lut[126] = 16'h0000; n1_shift_lut[127] = 16'h0000;
    n1_shift_lut[128] = 16'h0000; n1_shift_lut[129] = 16'h0000; n1_shift_lut[130] = 16'h0000; n1_shift_lut[131] = 16'h0000;
    n1_shift_lut[132] = 16'h0000; n1_shift_lut[133] = 16'h0000; n1_shift_lut[134] = 16'h0000; n1_shift_lut[135] = 16'h0000;
    n1_shift_lut[136] = 16'h0000; n1_shift_lut[137] = 16'h0000; n1_shift_lut[138] = 16'h0000; n1_shift_lut[139] = 16'h0000;
    n1_shift_lut[140] = 16'h0000; n1_shift_lut[141] = 16'h0000; n1_shift_lut[142] = 16'h0000; n1_shift_lut[143] = 16'h0000;
    n1_shift_lut[144] = 16'h0000; n1_shift_lut[145] = 16'h0000; n1_shift_lut[146] = 16'h0000; n1_shift_lut[147] = 16'h0000;
    n1_shift_lut[148] = 16'h0000; n1_shift_lut[149] = 16'h0000; n1_shift_lut[150] = 16'h0000; n1_shift_lut[151] = 16'h0000;
    n1_shift_lut[152] = 16'h0000; n1_shift_lut[153] = 16'h0000; n1_shift_lut[154] = 16'h0000; n1_shift_lut[155] = 16'h0000;
    n1_shift_lut[156] = 16'h0000; n1_shift_lut[157] = 16'h0000; n1_shift_lut[158] = 16'h0000; n1_shift_lut[159] = 16'h0000;
    n1_shift_lut[160] = 16'h0000; n1_shift_lut[161] = 16'h0000; n1_shift_lut[162] = 16'h0000; n1_shift_lut[163] = 16'h0000;
    n1_shift_lut[164] = 16'h0000; n1_shift_lut[165] = 16'h0000; n1_shift_lut[166] = 16'h0000; n1_shift_lut[167] = 16'h0000;
    n1_shift_lut[168] = 16'h0000; n1_shift_lut[169] = 16'h0000; n1_shift_lut[170] = 16'h0000; n1_shift_lut[171] = 16'h0000;
    n1_shift_lut[172] = 16'h0000; n1_shift_lut[173] = 16'h0000; n1_shift_lut[174] = 16'h0000; n1_shift_lut[175] = 16'h0000;
    n1_shift_lut[176] = 16'h0000; n1_shift_lut[177] = 16'h0000; n1_shift_lut[178] = 16'h0000; n1_shift_lut[179] = 16'h0000;
    n1_shift_lut[180] = 16'h0000; n1_shift_lut[181] = 16'h0000; n1_shift_lut[182] = 16'h0000; n1_shift_lut[183] = 16'h0000;
    n1_shift_lut[184] = 16'h0000; n1_shift_lut[185] = 16'h0000; n1_shift_lut[186] = 16'h0000; n1_shift_lut[187] = 16'h0000;
    n1_shift_lut[188] = 16'h0000; n1_shift_lut[189] = 16'h0000; n1_shift_lut[190] = 16'h0000; n1_shift_lut[191] = 16'h0000;
    n1_shift_lut[192] = 16'h0000; n1_shift_lut[193] = 16'h0000; n1_shift_lut[194] = 16'h0000; n1_shift_lut[195] = 16'h0000;
    n1_shift_lut[196] = 16'h0000; n1_shift_lut[197] = 16'h0000; n1_shift_lut[198] = 16'h0000; n1_shift_lut[199] = 16'h0000;
    n1_shift_lut[200] = 16'h0000; n1_shift_lut[201] = 16'h0000; n1_shift_lut[202] = 16'h0000; n1_shift_lut[203] = 16'h0000;
    n1_shift_lut[204] = 16'h0000; n1_shift_lut[205] = 16'h0000; n1_shift_lut[206] = 16'h0000; n1_shift_lut[207] = 16'h0000;
    n1_shift_lut[208] = 16'h0000; n1_shift_lut[209] = 16'h0000; n1_shift_lut[210] = 16'h0001; n1_shift_lut[211] = 16'h0001;
    n1_shift_lut[212] = 16'h0001; n1_shift_lut[213] = 16'h0001; n1_shift_lut[214] = 16'h0001; n1_shift_lut[215] = 16'h0001;
    n1_shift_lut[216] = 16'h0001; n1_shift_lut[217] = 16'h0001; n1_shift_lut[218] = 16'h0002; n1_shift_lut[219] = 16'h0002;
    n1_shift_lut[220] = 16'h0002; n1_shift_lut[221] = 16'h0002; n1_shift_lut[222] = 16'h0003; n1_shift_lut[223] = 16'h0003;
    n1_shift_lut[224] = 16'h0003; n1_shift_lut[225] = 16'h0004; n1_shift_lut[226] = 16'h0004; n1_shift_lut[227] = 16'h0004;
    n1_shift_lut[228] = 16'h0005; n1_shift_lut[229] = 16'h0005; n1_shift_lut[230] = 16'h0006; n1_shift_lut[231] = 16'h0006;
    n1_shift_lut[232] = 16'h0007; n1_shift_lut[233] = 16'h0007; n1_shift_lut[234] = 16'h0008; n1_shift_lut[235] = 16'h0009;
    n1_shift_lut[236] = 16'h0009; n1_shift_lut[237] = 16'h000a; n1_shift_lut[238] = 16'h000a; n1_shift_lut[239] = 16'h000b;
    n1_shift_lut[240] = 16'h000c; n1_shift_lut[241] = 16'h000c; n1_shift_lut[242] = 16'h000d; n1_shift_lut[243] = 16'h000e;
    n1_shift_lut[244] = 16'h000e; n1_shift_lut[245] = 16'h000f; n1_shift_lut[246] = 16'h000f; n1_shift_lut[247] = 16'h0010;
    n1_shift_lut[248] = 16'h0010; n1_shift_lut[249] = 16'h0011; n1_shift_lut[250] = 16'h0011; n1_shift_lut[251] = 16'h0012;
    n1_shift_lut[252] = 16'h0012; n1_shift_lut[253] = 16'h0012; n1_shift_lut[254] = 16'h0012; n1_shift_lut[255] = 16'h0013;
  end

  // S 乘子 Q14 定点表（0..81920）
  reg [16:0] n1_s_mul_q14 [0:255];
  initial begin
    n1_s_mul_q14[0] = 17'd16384; n1_s_mul_q14[1] = 17'd16384; n1_s_mul_q14[2] = 17'd16384; n1_s_mul_q14[3] = 17'd16384;
    n1_s_mul_q14[4] = 17'd16384; n1_s_mul_q14[5] = 17'd16384; n1_s_mul_q14[6] = 17'd16384; n1_s_mul_q14[7] = 17'd16384;
    n1_s_mul_q14[8] = 17'd16384; n1_s_mul_q14[9] = 17'd16384; n1_s_mul_q14[10] = 17'd16384; n1_s_mul_q14[11] = 17'd16384;
    n1_s_mul_q14[12] = 17'd16384; n1_s_mul_q14[13] = 17'd16384; n1_s_mul_q14[14] = 17'd16384; n1_s_mul_q14[15] = 17'd16384;
    n1_s_mul_q14[16] = 17'd16384; n1_s_mul_q14[17] = 17'd16384; n1_s_mul_q14[18] = 17'd16384; n1_s_mul_q14[19] = 17'd16384;
    n1_s_mul_q14[20] = 17'd16384; n1_s_mul_q14[21] = 17'd16384; n1_s_mul_q14[22] = 17'd16384; n1_s_mul_q14[23] = 17'd16384;
    n1_s_mul_q14[24] = 17'd16384; n1_s_mul_q14[25] = 17'd16384; n1_s_mul_q14[26] = 17'd16384; n1_s_mul_q14[27] = 17'd16384;
    n1_s_mul_q14[28] = 17'd16384; n1_s_mul_q14[29] = 17'd16384; n1_s_mul_q14[30] = 17'd16384; n1_s_mul_q14[31] = 17'd16384;
    n1_s_mul_q14[32] = 17'd16384; n1_s_mul_q14[33] = 17'd16384; n1_s_mul_q14[34] = 17'd16384; n1_s_mul_q14[35] = 17'd16384;
    n1_s_mul_q14[36] = 17'd16384; n1_s_mul_q14[37] = 17'd16384; n1_s_mul_q14[38] = 17'd16384; n1_s_mul_q14[39] = 17'd16384;
    n1_s_mul_q14[40] = 17'd16384; n1_s_mul_q14[41] = 17'd16384; n1_s_mul_q14[42] = 17'd16384; n1_s_mul_q14[43] = 17'd16384;
    n1_s_mul_q14[44] = 17'd16384; n1_s_mul_q14[45] = 17'd16384; n1_s_mul_q14[46] = 17'd16384; n1_s_mul_q14[47] = 17'd16384;
    n1_s_mul_q14[48] = 17'd16384; n1_s_mul_q14[49] = 17'd16384; n1_s_mul_q14[50] = 17'd16384; n1_s_mul_q14[51] = 17'd16384;
    n1_s_mul_q14[52] = 17'd16384; n1_s_mul_q14[53] = 17'd16384; n1_s_mul_q14[54] = 17'd16384; n1_s_mul_q14[55] = 17'd16384;
    n1_s_mul_q14[56] = 17'd16384; n1_s_mul_q14[57] = 17'd16384; n1_s_mul_q14[58] = 17'd16384; n1_s_mul_q14[59] = 17'd16384;
    n1_s_mul_q14[60] = 17'd16384; n1_s_mul_q14[61] = 17'd16384; n1_s_mul_q14[62] = 17'd16384; n1_s_mul_q14[63] = 17'd16384;
    n1_s_mul_q14[64] = 17'd16384; n1_s_mul_q14[65] = 17'd16384; n1_s_mul_q14[66] = 17'd16384; n1_s_mul_q14[67] = 17'd16384;
    n1_s_mul_q14[68] = 17'd16384; n1_s_mul_q14[69] = 17'd16384; n1_s_mul_q14[70] = 17'd16384; n1_s_mul_q14[71] = 17'd16384;
    n1_s_mul_q14[72] = 17'd16384; n1_s_mul_q14[73] = 17'd16384; n1_s_mul_q14[74] = 17'd16384; n1_s_mul_q14[75] = 17'd16384;
    n1_s_mul_q14[76] = 17'd16384; n1_s_mul_q14[77] = 17'd16384; n1_s_mul_q14[78] = 17'd16384; n1_s_mul_q14[79] = 17'd16384;
    n1_s_mul_q14[80] = 17'd16384; n1_s_mul_q14[81] = 17'd16384; n1_s_mul_q14[82] = 17'd16384; n1_s_mul_q14[83] = 17'd16384;
    n1_s_mul_q14[84] = 17'd16384; n1_s_mul_q14[85] = 17'd16384; n1_s_mul_q14[86] = 17'd16384; n1_s_mul_q14[87] = 17'd16384;
    n1_s_mul_q14[88] = 17'd16384; n1_s_mul_q14[89] = 17'd16384; n1_s_mul_q14[90] = 17'd16384; n1_s_mul_q14[91] = 17'd16384;
    n1_s_mul_q14[92] = 17'd16384; n1_s_mul_q14[93] = 17'd16384; n1_s_mul_q14[94] = 17'd16384; n1_s_mul_q14[95] = 17'd16384;
    n1_s_mul_q14[96] = 17'd16384; n1_s_mul_q14[97] = 17'd16384; n1_s_mul_q14[98] = 17'd16384; n1_s_mul_q14[99] = 17'd16384;
    n1_s_mul_q14[100] = 17'd16384; n1_s_mul_q14[101] = 17'd16384; n1_s_mul_q14[102] = 17'd16384; n1_s_mul_q14[103] = 17'd16384;
    n1_s_mul_q14[104] = 17'd16384; n1_s_mul_q14[105] = 17'd16384; n1_s_mul_q14[106] = 17'd16384; n1_s_mul_q14[107] = 17'd16384;
    n1_s_mul_q14[108] = 17'd16384; n1_s_mul_q14[109] = 17'd16384; n1_s_mul_q14[110] = 17'd16384; n1_s_mul_q14[111] = 17'd16384;
    n1_s_mul_q14[112] = 17'd16384; n1_s_mul_q14[113] = 17'd16384; n1_s_mul_q14[114] = 17'd16384; n1_s_mul_q14[115] = 17'd16384;
    n1_s_mul_q14[116] = 17'd16384; n1_s_mul_q14[117] = 17'd16384; n1_s_mul_q14[118] = 17'd16384; n1_s_mul_q14[119] = 17'd16384;
    n1_s_mul_q14[120] = 17'd16384; n1_s_mul_q14[121] = 17'd16384; n1_s_mul_q14[122] = 17'd16384; n1_s_mul_q14[123] = 17'd16384;
    n1_s_mul_q14[124] = 17'd16384; n1_s_mul_q14[125] = 17'd16384; n1_s_mul_q14[126] = 17'd16384; n1_s_mul_q14[127] = 17'd16384;
    n1_s_mul_q14[128] = 17'd16384; n1_s_mul_q14[129] = 17'd16384; n1_s_mul_q14[130] = 17'd16384; n1_s_mul_q14[131] = 17'd16384;
    n1_s_mul_q14[132] = 17'd16384; n1_s_mul_q14[133] = 17'd16384; n1_s_mul_q14[134] = 17'd16384; n1_s_mul_q14[135] = 17'd16384;
    n1_s_mul_q14[136] = 17'd16384; n1_s_mul_q14[137] = 17'd16384; n1_s_mul_q14[138] = 17'd16384; n1_s_mul_q14[139] = 17'd16384;
    n1_s_mul_q14[140] = 17'd16384; n1_s_mul_q14[141] = 17'd16384; n1_s_mul_q14[142] = 17'd16384; n1_s_mul_q14[143] = 17'd16384;
    n1_s_mul_q14[144] = 17'd16384; n1_s_mul_q14[145] = 17'd16384; n1_s_mul_q14[146] = 17'd16384; n1_s_mul_q14[147] = 17'd16384;
    n1_s_mul_q14[148] = 17'd16384; n1_s_mul_q14[149] = 17'd16384; n1_s_mul_q14[150] = 17'd16384; n1_s_mul_q14[151] = 17'd16384;
    n1_s_mul_q14[152] = 17'd16384; n1_s_mul_q14[153] = 17'd16384; n1_s_mul_q14[154] = 17'd16384; n1_s_mul_q14[155] = 17'd16384;
    n1_s_mul_q14[156] = 17'd16384; n1_s_mul_q14[157] = 17'd16384; n1_s_mul_q14[158] = 17'd16384; n1_s_mul_q14[159] = 17'd16384;
    n1_s_mul_q14[160] = 17'd16384; n1_s_mul_q14[161] = 17'd16384; n1_s_mul_q14[162] = 17'd16384; n1_s_mul_q14[163] = 17'd16384;
    n1_s_mul_q14[164] = 17'd16384; n1_s_mul_q14[165] = 17'd16384; n1_s_mul_q14[166] = 17'd16384; n1_s_mul_q14[167] = 17'd16384;
    n1_s_mul_q14[168] = 17'd16384; n1_s_mul_q14[169] = 17'd16384; n1_s_mul_q14[170] = 17'd16384; n1_s_mul_q14[171] = 17'd16384;
    n1_s_mul_q14[172] = 17'd16384; n1_s_mul_q14[173] = 17'd16384; n1_s_mul_q14[174] = 17'd16384; n1_s_mul_q14[175] = 17'd16384;
    n1_s_mul_q14[176] = 17'd16384; n1_s_mul_q14[177] = 17'd16384; n1_s_mul_q14[178] = 17'd16384; n1_s_mul_q14[179] = 17'd16384;
    n1_s_mul_q14[180] = 17'd16384; n1_s_mul_q14[181] = 17'd16384; n1_s_mul_q14[182] = 17'd16384; n1_s_mul_q14[183] = 17'd16384;
    n1_s_mul_q14[184] = 17'd16384; n1_s_mul_q14[185] = 17'd16384; n1_s_mul_q14[186] = 17'd16384; n1_s_mul_q14[187] = 17'd16384;
    n1_s_mul_q14[188] = 17'd16384; n1_s_mul_q14[189] = 17'd16384; n1_s_mul_q14[190] = 17'd16384; n1_s_mul_q14[191] = 17'd16384;
    n1_s_mul_q14[192] = 17'd16384; n1_s_mul_q14[193] = 17'd16384; n1_s_mul_q14[194] = 17'd16384; n1_s_mul_q14[195] = 17'd16384;
    n1_s_mul_q14[196] = 17'd16384; n1_s_mul_q14[197] = 17'd16384; n1_s_mul_q14[198] = 17'd16384; n1_s_mul_q14[199] = 17'd16384;
    n1_s_mul_q14[200] = 17'd16384; n1_s_mul_q14[201] = 17'd16384; n1_s_mul_q14[202] = 17'd16384; n1_s_mul_q14[203] = 17'd16384;
    n1_s_mul_q14[204] = 17'd16384; n1_s_mul_q14[205] = 17'd16384; n1_s_mul_q14[206] = 17'd16384; n1_s_mul_q14[207] = 17'd16384;
    n1_s_mul_q14[208] = 17'd16384; n1_s_mul_q14[209] = 17'd16384; n1_s_mul_q14[210] = 17'd16384; n1_s_mul_q14[211] = 17'd16384;
    n1_s_mul_q14[212] = 17'd16384; n1_s_mul_q14[213] = 17'd16384; n1_s_mul_q14[214] = 17'd16384; n1_s_mul_q14[215] = 17'd16384;
    n1_s_mul_q14[216] = 17'd16384; n1_s_mul_q14[217] = 17'd16384; n1_s_mul_q14[218] = 17'd16384; n1_s_mul_q14[219] = 17'd16384;
    n1_s_mul_q14[220] = 17'd16384; n1_s_mul_q14[221] = 17'd16384; n1_s_mul_q14[222] = 17'd16384; n1_s_mul_q14[223] = 17'd16384;
    n1_s_mul_q14[224] = 17'd16384; n1_s_mul_q14[225] = 17'd16384; n1_s_mul_q14[226] = 17'd16384; n1_s_mul_q14[227] = 17'd16384;
    n1_s_mul_q14[228] = 17'd16384; n1_s_mul_q14[229] = 17'd16384; n1_s_mul_q14[230] = 17'd16384; n1_s_mul_q14[231] = 17'd16384;
    n1_s_mul_q14[232] = 17'd16384; n1_s_mul_q14[233] = 17'd16384; n1_s_mul_q14[234] = 17'd16384; n1_s_mul_q14[235] = 17'd16384;
    n1_s_mul_q14[236] = 17'd16384; n1_s_mul_q14[237] = 17'd16384; n1_s_mul_q14[238] = 17'd16384; n1_s_mul_q14[239] = 17'd16384;
    n1_s_mul_q14[240] = 17'd16384; n1_s_mul_q14[241] = 17'd16384; n1_s_mul_q14[242] = 17'd16384; n1_s_mul_q14[243] = 17'd16384;
    n1_s_mul_q14[244] = 17'd16384; n1_s_mul_q14[245] = 17'd16384; n1_s_mul_q14[246] = 17'd16384; n1_s_mul_q14[247] = 17'd16384;
    n1_s_mul_q14[248] = 17'd16384; n1_s_mul_q14[249] = 17'd16384; n1_s_mul_q14[250] = 17'd16384; n1_s_mul_q14[251] = 17'd16384;
    n1_s_mul_q14[252] = 17'd16384; n1_s_mul_q14[253] = 17'd16384; n1_s_mul_q14[254] = 17'd16384; n1_s_mul_q14[255] = 17'd16384;
  end

  // L 乘子 Q14 定点表
  reg [16:0] n1_l_mul_q14 [0:255];
  initial begin
    n1_l_mul_q14[0] = 17'd16384; n1_l_mul_q14[1] = 17'd16384; n1_l_mul_q14[2] = 17'd16384; n1_l_mul_q14[3] = 17'd16384;
    n1_l_mul_q14[4] = 17'd16384; n1_l_mul_q14[5] = 17'd16384; n1_l_mul_q14[6] = 17'd16384; n1_l_mul_q14[7] = 17'd16384;
    n1_l_mul_q14[8] = 17'd16384; n1_l_mul_q14[9] = 17'd16384; n1_l_mul_q14[10] = 17'd16384; n1_l_mul_q14[11] = 17'd16384;
    n1_l_mul_q14[12] = 17'd16384; n1_l_mul_q14[13] = 17'd16384; n1_l_mul_q14[14] = 17'd16384; n1_l_mul_q14[15] = 17'd16384;
    n1_l_mul_q14[16] = 17'd16384; n1_l_mul_q14[17] = 17'd16384; n1_l_mul_q14[18] = 17'd16384; n1_l_mul_q14[19] = 17'd16384;
    n1_l_mul_q14[20] = 17'd16384; n1_l_mul_q14[21] = 17'd16384; n1_l_mul_q14[22] = 17'd16384; n1_l_mul_q14[23] = 17'd16384;
    n1_l_mul_q14[24] = 17'd16384; n1_l_mul_q14[25] = 17'd16384; n1_l_mul_q14[26] = 17'd16384; n1_l_mul_q14[27] = 17'd16384;
    n1_l_mul_q14[28] = 17'd16384; n1_l_mul_q14[29] = 17'd16384; n1_l_mul_q14[30] = 17'd16384; n1_l_mul_q14[31] = 17'd16384;
    n1_l_mul_q14[32] = 17'd16384; n1_l_mul_q14[33] = 17'd16384; n1_l_mul_q14[34] = 17'd16384; n1_l_mul_q14[35] = 17'd16384;
    n1_l_mul_q14[36] = 17'd16384; n1_l_mul_q14[37] = 17'd16384; n1_l_mul_q14[38] = 17'd16384; n1_l_mul_q14[39] = 17'd16384;
    n1_l_mul_q14[40] = 17'd16384; n1_l_mul_q14[41] = 17'd16384; n1_l_mul_q14[42] = 17'd16384; n1_l_mul_q14[43] = 17'd16384;
    n1_l_mul_q14[44] = 17'd16384; n1_l_mul_q14[45] = 17'd16384; n1_l_mul_q14[46] = 17'd16384; n1_l_mul_q14[47] = 17'd16384;
    n1_l_mul_q14[48] = 17'd16384; n1_l_mul_q14[49] = 17'd16384; n1_l_mul_q14[50] = 17'd16384; n1_l_mul_q14[51] = 17'd16384;
    n1_l_mul_q14[52] = 17'd16384; n1_l_mul_q14[53] = 17'd16384; n1_l_mul_q14[54] = 17'd16384; n1_l_mul_q14[55] = 17'd16384;
    n1_l_mul_q14[56] = 17'd16384; n1_l_mul_q14[57] = 17'd16384; n1_l_mul_q14[58] = 17'd16384; n1_l_mul_q14[59] = 17'd16384;
    n1_l_mul_q14[60] = 17'd16384; n1_l_mul_q14[61] = 17'd16384; n1_l_mul_q14[62] = 17'd16384; n1_l_mul_q14[63] = 17'd16384;
    n1_l_mul_q14[64] = 17'd16384; n1_l_mul_q14[65] = 17'd16384; n1_l_mul_q14[66] = 17'd16384; n1_l_mul_q14[67] = 17'd16384;
    n1_l_mul_q14[68] = 17'd16384; n1_l_mul_q14[69] = 17'd16384; n1_l_mul_q14[70] = 17'd16384; n1_l_mul_q14[71] = 17'd16384;
    n1_l_mul_q14[72] = 17'd16384; n1_l_mul_q14[73] = 17'd16384; n1_l_mul_q14[74] = 17'd16384; n1_l_mul_q14[75] = 17'd16384;
    n1_l_mul_q14[76] = 17'd16384; n1_l_mul_q14[77] = 17'd16384; n1_l_mul_q14[78] = 17'd16384; n1_l_mul_q14[79] = 17'd16384;
    n1_l_mul_q14[80] = 17'd16384; n1_l_mul_q14[81] = 17'd16384; n1_l_mul_q14[82] = 17'd16384; n1_l_mul_q14[83] = 17'd16384;
    n1_l_mul_q14[84] = 17'd16384; n1_l_mul_q14[85] = 17'd16384; n1_l_mul_q14[86] = 17'd16384; n1_l_mul_q14[87] = 17'd16384;
    n1_l_mul_q14[88] = 17'd16384; n1_l_mul_q14[89] = 17'd16384; n1_l_mul_q14[90] = 17'd16384; n1_l_mul_q14[91] = 17'd16384;
    n1_l_mul_q14[92] = 17'd16384; n1_l_mul_q14[93] = 17'd16384; n1_l_mul_q14[94] = 17'd16384; n1_l_mul_q14[95] = 17'd16384;
    n1_l_mul_q14[96] = 17'd16384; n1_l_mul_q14[97] = 17'd16384; n1_l_mul_q14[98] = 17'd16384; n1_l_mul_q14[99] = 17'd16384;
    n1_l_mul_q14[100] = 17'd16384; n1_l_mul_q14[101] = 17'd16384; n1_l_mul_q14[102] = 17'd16384; n1_l_mul_q14[103] = 17'd16384;
    n1_l_mul_q14[104] = 17'd16384; n1_l_mul_q14[105] = 17'd16384; n1_l_mul_q14[106] = 17'd16384; n1_l_mul_q14[107] = 17'd16384;
    n1_l_mul_q14[108] = 17'd16384; n1_l_mul_q14[109] = 17'd16384; n1_l_mul_q14[110] = 17'd16384; n1_l_mul_q14[111] = 17'd16384;
    n1_l_mul_q14[112] = 17'd16384; n1_l_mul_q14[113] = 17'd16384; n1_l_mul_q14[114] = 17'd16384; n1_l_mul_q14[115] = 17'd16384;
    n1_l_mul_q14[116] = 17'd16384; n1_l_mul_q14[117] = 17'd16384; n1_l_mul_q14[118] = 17'd16384; n1_l_mul_q14[119] = 17'd16384;
    n1_l_mul_q14[120] = 17'd16384; n1_l_mul_q14[121] = 17'd16384; n1_l_mul_q14[122] = 17'd16384; n1_l_mul_q14[123] = 17'd16384;
    n1_l_mul_q14[124] = 17'd16384; n1_l_mul_q14[125] = 17'd16384; n1_l_mul_q14[126] = 17'd16384; n1_l_mul_q14[127] = 17'd16384;
    n1_l_mul_q14[128] = 17'd16384; n1_l_mul_q14[129] = 17'd16384; n1_l_mul_q14[130] = 17'd16384; n1_l_mul_q14[131] = 17'd16384;
    n1_l_mul_q14[132] = 17'd16384; n1_l_mul_q14[133] = 17'd16384; n1_l_mul_q14[134] = 17'd16384; n1_l_mul_q14[135] = 17'd16384;
    n1_l_mul_q14[136] = 17'd16384; n1_l_mul_q14[137] = 17'd16384; n1_l_mul_q14[138] = 17'd16384; n1_l_mul_q14[139] = 17'd16384;
    n1_l_mul_q14[140] = 17'd16384; n1_l_mul_q14[141] = 17'd16384; n1_l_mul_q14[142] = 17'd16384; n1_l_mul_q14[143] = 17'd16384;
    n1_l_mul_q14[144] = 17'd16384; n1_l_mul_q14[145] = 17'd16384; n1_l_mul_q14[146] = 17'd16384; n1_l_mul_q14[147] = 17'd16384;
    n1_l_mul_q14[148] = 17'd16384; n1_l_mul_q14[149] = 17'd16384; n1_l_mul_q14[150] = 17'd16384; n1_l_mul_q14[151] = 17'd16384;
    n1_l_mul_q14[152] = 17'd16384; n1_l_mul_q14[153] = 17'd16384; n1_l_mul_q14[154] = 17'd16384; n1_l_mul_q14[155] = 17'd16384;
    n1_l_mul_q14[156] = 17'd16384; n1_l_mul_q14[157] = 17'd16384; n1_l_mul_q14[158] = 17'd16384; n1_l_mul_q14[159] = 17'd16384;
    n1_l_mul_q14[160] = 17'd16384; n1_l_mul_q14[161] = 17'd16384; n1_l_mul_q14[162] = 17'd16384; n1_l_mul_q14[163] = 17'd16384;
    n1_l_mul_q14[164] = 17'd16384; n1_l_mul_q14[165] = 17'd16384; n1_l_mul_q14[166] = 17'd16384; n1_l_mul_q14[167] = 17'd16384;
    n1_l_mul_q14[168] = 17'd16384; n1_l_mul_q14[169] = 17'd16384; n1_l_mul_q14[170] = 17'd16384; n1_l_mul_q14[171] = 17'd16384;
    n1_l_mul_q14[172] = 17'd16384; n1_l_mul_q14[173] = 17'd16384; n1_l_mul_q14[174] = 17'd16384; n1_l_mul_q14[175] = 17'd16384;
    n1_l_mul_q14[176] = 17'd16384; n1_l_mul_q14[177] = 17'd16384; n1_l_mul_q14[178] = 17'd16384; n1_l_mul_q14[179] = 17'd16384;
    n1_l_mul_q14[180] = 17'd16384; n1_l_mul_q14[181] = 17'd16384; n1_l_mul_q14[182] = 17'd16384; n1_l_mul_q14[183] = 17'd16384;
    n1_l_mul_q14[184] = 17'd16384; n1_l_mul_q14[185] = 17'd16384; n1_l_mul_q14[186] = 17'd16384; n1_l_mul_q14[187] = 17'd16384;
    n1_l_mul_q14[188] = 17'd16384; n1_l_mul_q14[189] = 17'd16384; n1_l_mul_q14[190] = 17'd16384; n1_l_mul_q14[191] = 17'd16384;
    n1_l_mul_q14[192] = 17'd16384; n1_l_mul_q14[193] = 17'd16384; n1_l_mul_q14[194] = 17'd16384; n1_l_mul_q14[195] = 17'd16384;
    n1_l_mul_q14[196] = 17'd16384; n1_l_mul_q14[197] = 17'd16384; n1_l_mul_q14[198] = 17'd16384; n1_l_mul_q14[199] = 17'd16384;
    n1_l_mul_q14[200] = 17'd16384; n1_l_mul_q14[201] = 17'd16384; n1_l_mul_q14[202] = 17'd16384; n1_l_mul_q14[203] = 17'd16384;
    n1_l_mul_q14[204] = 17'd16384; n1_l_mul_q14[205] = 17'd16384; n1_l_mul_q14[206] = 17'd16384; n1_l_mul_q14[207] = 17'd16384;
    n1_l_mul_q14[208] = 17'd16384; n1_l_mul_q14[209] = 17'd16384; n1_l_mul_q14[210] = 17'd16384; n1_l_mul_q14[211] = 17'd16384;
    n1_l_mul_q14[212] = 17'd16384; n1_l_mul_q14[213] = 17'd16384; n1_l_mul_q14[214] = 17'd16384; n1_l_mul_q14[215] = 17'd16384;
    n1_l_mul_q14[216] = 17'd16384; n1_l_mul_q14[217] = 17'd16384; n1_l_mul_q14[218] = 17'd16384; n1_l_mul_q14[219] = 17'd16384;
    n1_l_mul_q14[220] = 17'd16384; n1_l_mul_q14[221] = 17'd16384; n1_l_mul_q14[222] = 17'd16384; n1_l_mul_q14[223] = 17'd16384;
    n1_l_mul_q14[224] = 17'd16384; n1_l_mul_q14[225] = 17'd16384; n1_l_mul_q14[226] = 17'd16384; n1_l_mul_q14[227] = 17'd16384;
    n1_l_mul_q14[228] = 17'd16384; n1_l_mul_q14[229] = 17'd16384; n1_l_mul_q14[230] = 17'd16384; n1_l_mul_q14[231] = 17'd16384;
    n1_l_mul_q14[232] = 17'd16384; n1_l_mul_q14[233] = 17'd16384; n1_l_mul_q14[234] = 17'd16384; n1_l_mul_q14[235] = 17'd16384;
    n1_l_mul_q14[236] = 17'd16384; n1_l_mul_q14[237] = 17'd16384; n1_l_mul_q14[238] = 17'd16384; n1_l_mul_q14[239] = 17'd16384;
    n1_l_mul_q14[240] = 17'd16384; n1_l_mul_q14[241] = 17'd16384; n1_l_mul_q14[242] = 17'd16384; n1_l_mul_q14[243] = 17'd16384;
    n1_l_mul_q14[244] = 17'd16384; n1_l_mul_q14[245] = 17'd16384; n1_l_mul_q14[246] = 17'd16384; n1_l_mul_q14[247] = 17'd16384;
    n1_l_mul_q14[248] = 17'd16384; n1_l_mul_q14[249] = 17'd16384; n1_l_mul_q14[250] = 17'd16384; n1_l_mul_q14[251] = 17'd16384;
    n1_l_mul_q14[252] = 17'd16384; n1_l_mul_q14[253] = 17'd16384; n1_l_mul_q14[254] = 17'd16384; n1_l_mul_q14[255] = 17'd16384;
  end


  // ---- multi_band_eq（lut_fixed Q14）组合数据通路 ----
  // H：钳上界（与 C 行核 "if (hv > max) hv = max" 同口径）。
  wire [8-1:0] n1_hv = (in_h > MAXV) ? MAXV : in_h;
  // 查表：shift 为 16 位补码；S/L 乘子为 17 位无符号 Q14。
  wire [15:0] n1_shift = n1_shift_lut[n1_hv];
  wire [16:0] n1_sq   = n1_s_mul_q14[n1_hv];
  wire [16:0] n1_lq   = n1_l_mul_q14[n1_hv];
  // 色环回绕：hv + shift（|shift| <= MAXV/2 恒成立，单次条件加减与
  // % (MAXV+1) 逐位一致；17 位带符号承载 MAXV=65535 时 hv+shift 的
  // 最大中间值）。
  wire signed [16:0] n1_hv17   = {1'b0, n1_hv};
  wire signed [16:0] n1_shift17 = {{1{n1_shift[15]}}, n1_shift};
  wire signed [16:0] n1_mp1    = $signed({1'b0, MAXV}) + 17'sd1;
  wire signed [16:0] n1_hsum   = n1_hv17 + n1_shift17;
  wire signed [16:0] n1_hwrap  =
      (n1_hsum > $signed({1'b0, MAXV})) ? (n1_hsum - n1_mp1)
    : (n1_hsum < 17'sd0)                   ? (n1_hsum + n1_mp1)
    : n1_hsum;
  wire [8-1:0] n1_res_h = n1_hwrap[8-1:0];
  // S/L：in*s_q+8192 >> 14 后钳位（in 与 q 均非负，乘积宽度
  // pixBits+17 恰好承载 MAXV*81920，无符号溢出）。
  wire [8+16:0] n1_s_prod = in_s * n1_sq;
  wire [8+16:0] n1_l_prod = in_l * n1_lq;
  wire [8+16:0] n1_s_sum  = n1_s_prod + 18'd8192;
  wire [8+16:0] n1_l_sum  = n1_l_prod + 18'd8192;
  wire [8+16:0] n1_s_scl  = n1_s_sum >> 14;
  wire [8+16:0] n1_l_scl  = n1_l_sum >> 14;
  wire [8-1:0] n1_res_s =
      (n1_s_scl > MAXV) ? MAXV : n1_s_scl[8-1:0];
  wire [8-1:0] n1_res_l =
      (n1_l_scl > MAXV) ? MAXV : n1_l_scl[8-1:0];

  // ---- 单级流水（II=1，1 拍延迟；advance = 本拍锁存新像素）----
  wire advance = in_ready & in_valid;
  assign in_ready = ~out_valid | out_ready;

  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      out_valid <= 1'b0;
      out_sof   <= 1'b0;
      out_eol   <= 1'b0;
      out_data  <= {24{1'b0}};
    end else if (advance) begin
      out_valid <= in_valid;
      out_sof   <= in_sof;
      out_eol   <= in_eol;
      out_data  <= {n1_res_h, n1_res_s, n1_res_l};
    end else if (out_ready) begin
      // 无新像素且输出已被接收：清空 valid（否则 valid 卡高，输出重复计数）。
      out_valid <= 1'b0;
    end
  end
endmodule
