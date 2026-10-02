//=============================================================================
// dsp_chan.sv -- 多相信道化器 (PFB: 多相滤波 + FFT, IQ 入 / N 信道复数出)
//
// 结构: dsp_pfir ×2 (I/Q 共享系数, 线性分离性: H(I+jQ)=H(I)+jH(Q)) ->
//       同步 FIFO (解耦 pfir 的稀疏信道脉冲与 fft 的 load 握手) ->
//       dsp_fft。上游 IQ 流按帧 (每 N 样一帧) 信道化为 N 个复数 bin。
//
// 频率映射 (实测确认): 输入复正弦 e^{+j2*pi*k*n/N} 落在 bin k (bin k =
// 信道 k); bin 0 = 直流, 1..N/2-1 = 正频率, N/2..N-1 = 负频率。
//
// 增益与隔离 (xczu48dr 量化模型实测, N=64/K=8/B_CO=16):
//   信道中心音: |bin| = 0.977 * A (A = 输入音幅度, 亏差来自系数/相位的
//   组合标定); 邻道泄漏: 最强音的 -40.8 dB。输出满精度 (相对 1/N 归一
//   DFT 的 N 倍增益已被 pfir 的 1/N 结构标定抵消, 见事实 #14)。
//
// 端口:
//   clk, rst            高有效同步复位
//   in_valid            IQ 输入有效 (帧节奏: 每帧 N 样后建议留计算间隙,
//                       见 dsp_pfir 头部输入率约束)
//   in_i/in_q           [B_IN-1:0] IQ 输入
//   out_valid           每信道一个脉冲, 顺序 bin = 0..N-1 连续成帧
//   out_frame           帧首 (bin 0) 标记
//   out_i/out_q         [B_BIN-1:0] 信道复数输出
//
// 参数:
//   N          信道数/FFT 点数, 2 的幂, 8..1024, 默认 64
//   K          每相位抽头数, 2..64, 默认 8
//   B_IN       输入位宽, 8..24, 默认 16
//   B_CO       原型系数位宽, 8..24, 默认 16
//   B_OUT      pfir 输出 / fft 输入位宽, 默认 16
//   WT         twiddle 位宽, 默认 16
//   B_BIN      信道输出位宽, 默认 B+log2(N)+1 (fft 满精度)
//   ROUND      输出舍入 (传给 pfir)
//   COEF_FILE  原型系数 (sim/gen_coef_pfir.py 生成)
//   TW_FILE    twiddle (sim/gen_coef_fft.py 生成)
//
// 例化示例:
//   dsp_chan #(.N(64), .K(8), .COEF_FILE("coef_pfir_64x8.mem"),
//              .TW_FILE("coef_fft_64_w16.mem")) u_chan (
//       .clk(clk), .rst(rst),
//       .in_valid(ddc_valid), .in_i(ddc_i), .in_q(ddc_q),
//       .out_valid(chan_vld), .out_frame(chan_frame),
//       .out_i(chan_i), .out_q(chan_q));
//
// 参考: 本库 dsp_pfir / dsp_fft (各自头部有结构细节与事实清单);
//       信道-频率映射与隔离度实测见 sim/tb_dsp_chan.sv。
//=============================================================================

`timescale 1ns / 1ps

module dsp_chan #(
  parameter int unsigned N         = 64,
  parameter int unsigned K         = 8,
  parameter int unsigned B_IN      = 16,
  parameter int unsigned B_CO      = 16,
  parameter int unsigned B_OUT     = 16,
  parameter int unsigned WT        = 16,
  parameter int unsigned B_BIN     = B_IN + $clog2(N) + 1,
  parameter bit          ROUND     = 1'b1,
  parameter string       COEF_FILE = "",
  parameter string       TW_FILE   = ""
) (
  input  logic                     clk,
  input  logic                     rst,
  input  logic                     in_valid,
  input  logic signed [B_IN-1:0]   in_i,
  input  logic signed [B_IN-1:0]   in_q,
  output logic                     out_valid,
  output logic                     out_frame,
  output logic signed [B_BIN-1:0]  out_i,
  output logic signed [B_BIN-1:0]  out_q
);

  //--------------------------------------------------------------------------
  // 预检
  //--------------------------------------------------------------------------
  initial begin
    if (N < 8 || N > 1024 || (N & (N - 1)) != 0)
      $error("dsp_chan: N=%0d 不是 2 的幂或超出 8..1024", N);
    if (K < 2 || K > 64)
      $error("dsp_chan: K=%0d 超出 2..64", K);
    if (B_IN < 8 || B_IN > 24)
      $error("dsp_chan: B_IN=%0d 超出 8..24", B_IN);
  end

  //--------------------------------------------------------------------------
  // 多相滤波: I/Q 各一实例, 共享系数, 输入同节奏 -> 输出同拍配对
  // (线性分离性: 滤波(I)+j滤波(Q) == 滤波(I+jQ))
  //--------------------------------------------------------------------------
  logic        pf_v;
  logic signed [B_OUT-1:0] pf_i, pf_q;
  logic        pf_frame_i, pf_frame_q;    // 锁步校验用 (TB 断言)

  dsp_pfir #(
    .N(N), .K(K), .B_IN(B_IN), .B_CO(B_CO), .B_OUT(B_OUT),
    .ROUND(ROUND), .COEF_FILE(COEF_FILE)
  ) u_pfir_i (
    .clk(clk), .rst(rst),
    .in_valid(in_valid), .in_data(in_i),
    .out_valid(pf_v), .out_data(pf_i), .out_frame(pf_frame_i)
  );

  dsp_pfir #(
    .N(N), .K(K), .B_IN(B_IN), .B_CO(B_CO), .B_OUT(B_OUT),
    .ROUND(ROUND), .COEF_FILE(COEF_FILE)
  ) u_pfir_q (
    .clk(clk), .rst(rst),
    .in_valid(in_valid), .in_data(in_q),
    .out_valid(), .out_data(pf_q), .out_frame(pf_frame_q)
  );

  //--------------------------------------------------------------------------
  // 信道 FIFO: pfir 的信道值按支路节奏脉冲式产出, fft 的 load 按握手
  // 消费 -- FIFO 解耦两者 (每帧 N 对, 深 2N 覆盖最坏节奏)
  //--------------------------------------------------------------------------
  localparam int FDW = 2 * B_OUT;
  logic             fifo_wr, fifo_rd, fifo_empty, fifo_full;
  logic [FDW-1:0]   fifo_din, fifo_dout;

  xpm_sync_fifo #(
    .DW(FDW), .DEPTH(2 * N), .READ_MODE("fwft")
  ) u_fifo (
    .clk    (clk),
    .rst    (rst),
    .wr_en  (fifo_wr),
    .din    (fifo_din),
    .rd_en  (fifo_rd),
    .dout   (fifo_dout),
    .valid  (),
    .empty  (fifo_empty),
    .full   (fifo_full),
    .rst_busy (),
    .count  (),
    .overflow (),
    .underflow ()
  );

  assign fifo_wr  = pf_v & ~rst;
  assign fifo_din = {pf_i, pf_q};   // I 在高半位: fft 的 in_i 接 dout 高半位

  //--------------------------------------------------------------------------
  // FFT
  //--------------------------------------------------------------------------
  logic fft_ready;

  dsp_fft #(
    .N(N), .B(B_OUT), .WT(WT), .B_OUT(B_BIN),
    .TW_FILE(TW_FILE), .MEM_TYPE("block")
  ) u_fft (
    .clk(clk), .rst(rst),
    .in_valid(~fifo_empty), .in_ready(fft_ready),
    .in_i(fifo_dout[FDW-1:B_OUT]), .in_q(fifo_dout[B_OUT-1:0]),
    .out_valid(out_valid), .out_frame(out_frame),
    .out_i(out_i), .out_q(out_q)
  );

  assign fifo_rd = fft_ready & ~fifo_empty;

endmodule
