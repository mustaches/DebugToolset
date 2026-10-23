// 一键仿真 testbench：读 golden_in.hex 喂核心 → 收集输出 → FNV-1a 对拍
// golden_hash.txt（期望值内嵌为 EXPECTED_HASH，EXACT 模式逐位一致）。
`timescale 1ns/1ps
module tb_isp_ip_multi_band_eq;
  localparam integer PIX_BITS = 8;
  localparam integer W  = 64;
  localparam integer H  = 48;
  localparam integer N  = W * H;
  localparam [31:0] EXPECTED_HASH = 32'h4d402029;

  reg clk = 1'b0, rst_n = 1'b0;
  reg in_valid = 1'b0, in_sof = 1'b0, in_eol = 1'b0;
  reg [24-1:0] in_data = {24{1'b0}};
  reg out_ready = 1'b1;
  wire in_ready, out_valid, out_sof, out_eol;
  wire [24-1:0] out_data;

  isp_ip_multi_band_eq_top #(.PIX_BITS(PIX_BITS), .MAX_WIDTH(4096)) dut (
      .clk(clk), .rst_n(rst_n),
      .in_valid(in_valid), .in_ready(in_ready),
      .in_sof(in_sof), .in_eol(in_eol), .in_data(in_data),
      .out_valid(out_valid), .out_ready(out_ready),
      .out_sof(out_sof), .out_eol(out_eol), .out_data(out_data)
  );

  reg [24-1:0] mem [0:N-1];
  initial $readmemh("golden_in.hex", mem);

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
    input [24-1:0] px;
    reg [31:0] hh;
    begin
      hh = fnv;
      hh = fnv_u16(hh, {16'd0, px[24-1 -: 8]});
      hh = fnv_u16(hh, {16'd0, px[16-1 -: 8]});
      hh = fnv_u16(hh, {16'd0, px[8-1:0]});
      fnv = hh;
    end
  endtask

  // 波形转储：vvp 运行产出 wave.vcd，仿真结束后由 GTKWave 打开。
  initial begin
    $dumpfile("wave.vcd");
    $dumpvars(0, tb_isp_ip_multi_band_eq);
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
      $display("PASS  frame=%0dx%0d  fnv=%08x", W, H, fnv);
    else
      $display("FAIL  got=%0d/%0d  fnv=%08x  expected=%08x",
                 got, N, fnv, EXPECTED_HASH);
    $finish;
  end
endmodule
