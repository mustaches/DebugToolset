// 本文件由 DebugToolSet ISP Studio 自动生成（编组 → FPGA Verilog IP 包）。
// 目标厂商：AMD/Xilinx Vivado
// 像素位宽 PIX_BITS=8（MAXV=255）、LUT 域 0..255
// 顶层装配：VIN_TYPE=none（直通）时直接透传核心像素流端口。
`timescale 1ns/1ps
module isp_ip_multi_band_eq_top #(
    parameter integer PIX_BITS  = 8,
    parameter integer MAX_WIDTH = 4096,
    parameter integer GSTRATEGY = 0,
    parameter integer FOLD      = 4
) (
    input  wire                   clk,
    input  wire                   rst_n,
    input  wire                   in_valid,
    output wire                   in_ready,
    input  wire                   in_sof,
    input  wire                   in_eol,
    input  wire [24-1:0]         in_data,
    output wire                   out_valid,
    input  wire                   out_ready,
    output wire                   out_sof,
    output wire                   out_eol,
    output wire [24-1:0]         out_data
);
  isp_ip_multi_band_eq_core #(
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
