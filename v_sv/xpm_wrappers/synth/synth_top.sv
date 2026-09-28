//=============================================================================
// synth_top.sv -- 综合验证用顶层 (不参与设计, 只给 synth_check.tcl 用)
//
// 把 5 个 wrapper 按典型配置各例化一遍, 覆盖:
//   - CDC: 单 bit / 多 bit 电平同步、脉冲同步、复位桥
//   - 同步 FIFO: BRAM ("block") + std、分布式 RAM ("distributed") + fwft
//   - 异步 FIFO: BRAM + 双时钟
//   - prog 可编程水线: 两个 FIFO 各开 PROG_FULL/EMPTY_THRESH (含 fwft 的
//     THRESH_ADJ 路径), 验证参数与端口贯通
// 端口全部引到顶层, 综合时不会被裁掉。
//=============================================================================

`timescale 1ns / 1ps

module synth_top #(
  parameter int unsigned DW = 32,
  parameter int unsigned DEPTH = 512
) (
  input  logic        clk_a,
  input  logic        clk_b,
  input  logic        rst_a,
  input  logic        rst_b,

  input  logic        bit_in,
  input  logic [15:0] bus_in,
  input  logic        pulse_in,

  // 同步 FIFO (BRAM, std)
  input  logic        s_wr_en,
  input  logic [DW-1:0] s_din,
  output logic        s_full,
  output logic        s_almost_full,
  output logic [$clog2(DEPTH):0] s_count,
  output logic        s_overflow,
  output logic        s_rst_busy,
  input  logic        s_rd_en,
  output logic [DW-1:0] s_dout,
  output logic        s_empty,
  output logic        s_almost_empty,
  output logic        s_valid,
  output logic        s_underflow,

  // 同步 FIFO (分布式 RAM, fwft)
  input  logic        f_wr_en,
  input  logic [15:0] f_din,
  output logic        f_full,
  output logic        f_almost_full,
  output logic [6:0]  f_count,
  output logic        f_overflow,
  output logic        f_rst_busy,
  input  logic        f_rd_en,
  output logic [15:0] f_dout,
  output logic        f_empty,
  output logic        f_almost_empty,
  output logic        f_valid,
  output logic        f_underflow,
  output logic        f_prog_full,
  output logic        f_prog_empty,

  // 异步 FIFO (BRAM, 双时钟)
  input  logic        a_wr_en,
  input  logic [DW-1:0] a_din,
  output logic        a_full,
  output logic        a_almost_full,
  output logic [$clog2(DEPTH):0] a_wr_count,
  output logic        a_overflow,
  output logic        a_wr_rst_busy,
  input  logic        a_rd_en,
  output logic [DW-1:0] a_dout,
  output logic        a_empty,
  output logic        a_almost_empty,
  output logic        a_valid,
  output logic        a_underflow,
  output logic [$clog2(DEPTH):0] a_rd_count,
  output logic        a_rd_rst_busy,
  output logic        a_prog_full,
  output logic        a_prog_empty,

  // 异步 FIFO 变宽 (8:1): 写 64 -> 读 16, 读侧深度 = 256*64/16 = 1024
  input  logic [63:0] aw_din,
  input  logic        aw_wr_en,
  output logic        aw_full,
  output logic [8:0]  aw_wr_count,
  input  logic        aw_rd_en,
  output logic [15:0] aw_dout,
  output logic        aw_empty,
  output logic        aw_valid,
  output logic [10:0] aw_rd_count,

  // 同步 FIFO (URAM): 验证 MEM_TYPE="uram" 综合映射 (仅 UltraScale+ 器件)
  input  logic        u_wr_en,
  input  logic [63:0] u_din,
  output logic        u_full,
  output logic        u_empty,
  input  logic        u_rd_en,
  output logic [63:0] u_dout,
  output logic        u_rst_busy,

  // 简单双口 RAM: 变宽 4:1 (64->16) + 读延迟 2 拍, 验证 sdpram 综合路径
  input  logic [6:0]  s_addra,
  input  logic [63:0] s_dina,
  input  logic        s_wea,
  input  logic [8:0]  s_addrb,
  input  logic        s_enb,
  output logic [15:0] s_doutb,
  output logic        s_doutb_vld,

  // 简单双口 RAM: 独立时钟模式冒烟 (common_clock 已有实例)
  input  logic        s2_wea,
  input  logic [15:0] s2_dina,
  input  logic [3:0]  s2_addra,
  input  logic        s2_enb,
  input  logic [3:0]  s2_addrb,
  output logic [15:0] s2_doutb,

  // 握手跨时钟: 多 bit 数据
  input  logic        h_send,
  input  logic [15:0] h_data,
  output logic        h_rcv,
  output logic        h_req,
  output logic [15:0] h_dest_data,

  // 同步复位同步器
  input  logic        sr_src,
  output logic        sr_dest,

  // CDC / 复位桥
  output logic        bit_out,
  output logic [15:0] bus_out,
  output logic        pulse_out,
  output logic        rst_b_out
);

  // ---- CDC: 单 bit / 16bit 电平, 100M -> 目标域 ----
  xpm_cdc_sync #(.W(1), .STAGES(2)) u_cdc_bit (
    .src_clk (clk_a), .src_in (bit_in), .dest_clk (clk_b), .dest_out (bit_out));

  xpm_cdc_sync #(.W(16), .STAGES(3), .REG_SRC(1'b0)) u_cdc_bus (
    .src_clk (clk_a), .src_in (bus_in), .dest_clk (clk_b), .dest_out (bus_out));

  // ---- 脉冲同步 ----
  xpm_pulse_sync #(.STAGES(2), .REG_OUT(1'b1)) u_pulse (
    .src_clk  (clk_a), .src_rst (rst_a), .src_pulse (pulse_in),
    .dest_clk (clk_b), .dest_rst(rst_b), .dest_pulse(pulse_out));

  // ---- 复位桥 ----
  xpm_rst_sync #(.STAGES(2)) u_rst (
    .src_rst (rst_a), .dest_clk(clk_b), .dest_rst(rst_b_out));

  // ---- 同步 FIFO: BRAM, std 模式 ----
  xpm_sync_fifo #(
    .DW(32), .DEPTH(512), .READ_MODE("std"), .MEM_TYPE("block")
  ) u_sfifo_bram (
    .clk(clk_a), .rst(rst_a),
    .wr_en(s_wr_en), .din(s_din), .full(s_full), .almost_full(s_almost_full),
    .count(s_count), .overflow(s_overflow), .rst_busy(s_rst_busy),
    .rd_en(s_rd_en), .dout(s_dout), .empty(s_empty),
    .almost_empty(s_almost_empty), .valid(s_valid), .underflow(s_underflow));

  // ---- 同步 FIFO: 分布式 RAM, fwft 模式, 开 prog 水线 ----
  // (fwft 实际水线 = 阈值-2, 见 xpm_sync_fifo.sv 头部 THRESH_ADJ 说明)
  xpm_sync_fifo #(
    .DW(16), .DEPTH(64), .READ_MODE("fwft"), .MEM_TYPE("distributed"),
    .PROG_FULL_THRESH(48), .PROG_EMPTY_THRESH(8)
  ) u_sfifo_lutram (
    .clk(clk_a), .rst(rst_a),
    .wr_en(f_wr_en), .din(f_din), .full(f_full), .almost_full(f_almost_full),
    .prog_full(f_prog_full),
    .count(f_count), .overflow(f_overflow), .rst_busy(f_rst_busy),
    .rd_en(f_rd_en), .dout(f_dout), .empty(f_empty),
    .almost_empty(f_almost_empty), .prog_empty(f_prog_empty),
    .valid(f_valid), .underflow(f_underflow));

  // ---- 异步 FIFO: BRAM, 双时钟, 开 prog 水线 ----
  xpm_async_fifo #(
    .DW(32), .DEPTH(512), .READ_MODE("std"), .MEM_TYPE("block"),
    .PROG_FULL_THRESH(500), .PROG_EMPTY_THRESH(8)
  ) u_afifo (
    .wr_clk(clk_a), .wr_en(a_wr_en), .din(a_din),
    .full(a_full), .almost_full(a_almost_full), .prog_full(a_prog_full),
    .wr_count(a_wr_count),
    .overflow(a_overflow), .wr_rst_busy(a_wr_rst_busy),
    .rd_clk(clk_b), .rd_en(a_rd_en), .dout(a_dout),
    .empty(a_empty), .almost_empty(a_almost_empty), .prog_empty(a_prog_empty),
    .valid(a_valid),
    .underflow(a_underflow), .rd_count(a_rd_count),
    .rd_rst_busy(a_rd_rst_busy), .rst(rst_a));

  // ---- 异步 FIFO: BRAM, 非对称位宽 8:1 (变宽只支持 block/uram) ----
  xpm_async_fifo #(
    .DW(64), .RD_DW(16), .DEPTH(256), .READ_MODE("std"), .MEM_TYPE("block")
  ) u_afifo_asym (
    .wr_clk(clk_a), .wr_en(aw_wr_en), .din(aw_din),
    .full(aw_full), .wr_count(aw_wr_count),
    .rd_clk(clk_b), .rd_en(aw_rd_en), .dout(aw_dout),
    .empty(aw_empty), .valid(aw_valid), .rd_count(aw_rd_count),
    .rst(rst_a));

  // ---- 同步 FIFO: URAM, 512 深 64bit (大缓存的典型配置) ----
  xpm_sync_fifo #(
    .DW(64), .DEPTH(512), .READ_MODE("std"), .MEM_TYPE("uram")
  ) u_sfifo_uram (
    .clk(clk_a), .rst(rst_a),
    .wr_en(u_wr_en), .din(u_din), .full(u_full),
    .rd_en(u_rd_en), .dout(u_dout), .empty(u_empty),
    .rst_busy(u_rst_busy));

  // ---- 简单双口 RAM: 变宽 4:1, 读延迟 2 拍, common_clock ----
  xpm_sdpram #(
    .DW_A(64), .DW_B(16), .DEPTH(128), .LATENCY_B(2), .MEM_TYPE("block")
  ) u_sdpram (
    .clka(clk_a), .addra(s_addra), .dina(s_dina), .wea(s_wea),
    .clkb(clk_a), .enb(s_enb), .addrb(s_addrb),
    .doutb(s_doutb), .doutb_vld(s_doutb_vld));

  // ---- 简单双口 RAM: 独立时钟模式 (时序约束见 constrs/xpm_wrappers.xdc) ----
  xpm_sdpram #(
    .DW_A(16), .DEPTH(16), .LATENCY_B(1), .MEM_TYPE("block"),
    .CLOCKING_MODE("independent_clock")
  ) u_sdpram_async (
    .clka(clk_a), .addra(s2_addra), .dina(s2_dina), .wea(s2_wea),
    .clkb(clk_b), .enb(s2_enb), .addrb(s2_addrb),
    .doutb(s2_doutb), .doutb_vld());

  // ---- 握手跨时钟: 多 bit 数据, 目的端自动应答 ----
  xpm_handshake #(.WIDTH(16), .STAGES(2)) u_handshake (
    .src_clk(clk_a), .src_data(h_data), .src_send(h_send), .src_rcv(h_rcv),
    .dest_clk(clk_b), .dest_data(h_dest_data), .dest_req(h_req));

  // ---- 同步复位同步器 ----
  xpm_sync_rst #(.STAGES(2), .INIT(1'b1)) u_sync_rst (
    .src_rst(sr_src), .dest_clk(clk_b), .dest_rst(sr_dest));

endmodule