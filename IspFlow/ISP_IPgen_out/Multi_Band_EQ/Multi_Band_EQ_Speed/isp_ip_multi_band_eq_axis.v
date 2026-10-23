// 本文件由 DebugToolSet ISP Studio 自动生成（编组 → FPGA Verilog IP 包）。
// 目标厂商：AMD/Xilinx Vivado
// 像素位宽 PIX_BITS=8（MAXV=255）、LUT 域 0..255
// Vivado AXI4-Stream 封装：像素流 → AXI4-Stream（tuser=sof、
// tlast=eol）。仅转接口不含逻辑。
`timescale 1ns/1ps
module isp_ip_multi_band_eq_axis #(
    parameter integer PIX_BITS  = 8,
    parameter integer MAX_WIDTH = 4096,
    parameter integer GSTRATEGY = 2,
    parameter integer FOLD      = 1
) (
    input  wire                   aclk,
    input  wire                   aresetn,
    input  wire [24-1:0]         s_axis_tdata,
    input  wire                   s_axis_tvalid,
    output wire                   s_axis_tready,
    input  wire                   s_axis_tuser,
    input  wire                   s_axis_tlast,
    output wire [24-1:0]         m_axis_tdata,
    output wire                   m_axis_tvalid,
    input  wire                   m_axis_tready,
    output wire                   m_axis_tuser,
    output wire                   m_axis_tlast
);
  isp_ip_multi_band_eq_core #(
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
