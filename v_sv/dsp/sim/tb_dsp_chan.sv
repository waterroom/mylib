//=============================================================================
// tb_dsp_chan.sv -- dsp_chan 系统级自检 (多音注入)
//
// 验证方法: 端到端分析校验 (pfir/fft 各自已有位精确对拍, 这里验证装配):
//   注入 3 个信道中心的复正弦 (ch5=8000, ch17=4000, ch40=8000), 检查:
//   [1] 音调信道: |bin| = 0.977*A, 容差 +-3% (量化标定实测 0.9768)
//   [2] 静默信道: |bin| <= 0.03*A_max (实测 -40.8 dB 隔离, 取 -30 dB 界)
//   [3] 帧标志/计数: out_frame 每帧一次, 总输出 = 帧数*N
//   [4] I/Q 锁步: 两 pfir 的帧标志一致 (配对正确性前提)
//
// 频率映射 (实测确认): 输入 e^{+j2*pi*ch*n/N} -> bin ch。
// 帧节奏: 每帧 N 样突发 + 计算间隙 (pfir 输入率约束), 前 WARM 帧热机。
//=============================================================================
`timescale 1ns / 1ps

module tb_dsp_chan;

  int errors = 0, checks = 0;
  task automatic chk(input string name, input logic cond);
    checks++;
    if (cond !== 1'b1) begin
      errors++;
      $display("  [FAIL] %s (t=%0t)", name, $time);
    end
  endtask
  task automatic chk_eq(input string name, input longint act, input longint exp);
    checks++;
    if (act !== exp) begin
      errors++;
      $display("  [FAIL] %s   got=%0d exp=%0d (t=%0t)", name, act, exp, $time);
    end
  endtask

  logic clk = 0;
  always #5 clk = ~clk;

  localparam int N  = 64;
  localparam int K  = 8;
  localparam int LG = 6;                   // log2(N)
  localparam int WI = 16 + LG + 1;         // B_IN + log2(N) + 1 = 23
  localparam real PI = 3.14159265358979323846;
  localparam int WARM = 10;               // 热机帧 (原型滤波器填充满 K 帧)
  localparam int NSTIM = 8;               // 激励帧数
  localparam int NB = WARM + NSTIM;       // 总帧数

  // 音调信道与幅度
  localparam int  TCH [0:2] = '{5, 17, 40};
  localparam real TCA [0:2] = '{8000.0, 4000.0, 8000.0};

  //---------------------------------------------------------------------------
  // DUT
  //---------------------------------------------------------------------------
  logic        rst = 1'b1;
  logic        in_valid = 1'b0;
  logic [15:0] in_i = '0, in_q = '0;
  logic        out_valid, out_frame;
  logic [WI-1:0] out_i, out_q;

  dsp_chan #(.N(N), .K(K), .B_IN(16), .B_CO(16), .B_OUT(16), .WT(16),
             .B_BIN(WI),
             .COEF_FILE("../coef_pfir_64x8.mem"),
             .TW_FILE("../coef_fft_64_w16.mem")) u_dut (
    .clk(clk), .rst(rst),
    .in_valid(in_valid), .in_i(in_i), .in_q(in_q),
    .out_valid(out_valid), .out_frame(out_frame),
    .out_i(out_i), .out_q(out_q));

  //---------------------------------------------------------------------------
  // 输出采集 (最后一帧)
  //---------------------------------------------------------------------------
  longint bi [0:N-1], bq [0:N-1];
  int     o_cnt = 0;
  int     frames_done = 0;
  int     frame_flags = 0;

  always @(posedge clk) begin
    if (rst) begin
      o_cnt <= 0; frames_done <= 0; frame_flags <= 0;
    end else begin
      if (out_valid) begin
        bi[o_cnt] <= $signed(out_i);
        bq[o_cnt] <= $signed(out_q);
        if (out_frame) frame_flags++;
        if (o_cnt == N - 1) begin
          o_cnt <= 0;
          frames_done <= frames_done + 1;
        end
        else begin
          o_cnt <= o_cnt + 1;
        end
      end
    end
  end

  // pfir I/Q 帧标志锁步
  always @(posedge clk) begin
    if (!rst && (u_dut.pf_frame_i !== u_dut.pf_frame_q))
      chk("pfir I/Q frame flags lockstep", 1'b0);
  end

  //---------------------------------------------------------------------------
  // 激励生成: 复正弦叠加 (量化到 Q1.15)
  //---------------------------------------------------------------------------
  longint xi [0:NB*N-1], xq [0:NB*N-1];

  initial begin
    for (int n = 0; n < NB*N; n++) begin
      xi[n] = 0; xq[n] = 0;
    end
    for (int n = WARM*N; n < NB*N; n++) begin
      automatic real ri = 0.0, rq = 0.0;
      for (int t = 0; t < 3; t++) begin
        ri += TCA[t] * $cos(2.0*PI*TCH[t]*(n % N)/N);   // 逐帧同相 (帧同步音)
        rq += TCA[t] * $sin(2.0*PI*TCH[t]*(n % N)/N);
      end
      xi[n] = longint'(ri);
      xq[n] = longint'(rq);
    end
  end

  //---------------------------------------------------------------------------
  // 主流程
  //---------------------------------------------------------------------------
  initial begin
    $display("=== dsp_chan self-check start ===");
    rst = 1'b1;
    repeat (3) @(posedge clk);
    rst = 1'b0;

    for (int m = 0; m < NB; m++) begin
      for (int j = 0; j < N; j++) begin
        @(negedge clk);
        in_valid = 1'b1;
        in_i = xi[m*N + j][15:0];
        in_q = xq[m*N + j][15:0];
      end
      @(negedge clk);
      in_valid = 1'b0;
      // 帧间隙必须覆盖整链瓶颈 = FFT 帧时间 (load N + compute 6*(N/2)*LG
      // + unload N+1); 否则 FFT 落后 -> 信道 FIFO 溢出丢样 (实测死锁)。
      // 真实上游 (CIC 抽取后) 远慢于此, 该间隙是保守化。
      repeat (6*(N/2)*LG + N + 80) @(posedge clk);
    end

    // 等最后帧排空
    while (frames_done < NB) @(posedge clk);
    repeat (100) @(posedge clk); #1;

    //---------------------------------------------------------
    // [1] 音调信道: |bin| = 0.977*A +-3%
    //---------------------------------------------------------
    for (int t = 0; t < 3; t++) begin : tone_chk
      automatic int ch = TCH[t];
      automatic real A = TCA[t];
      automatic real mag = $hypot(bi[ch], bq[ch]);
      automatic real ratio = mag / A;
      chk($sformatf("tone ch%0d: gain %.4f in [0.947, 1.007]", ch, ratio),
          (ratio > 0.947) && (ratio < 1.007));
      $display("    MEASURE tone ch%0d: bin=(%0d,%0d) |bin|=%.0f gain=%.4f",
               ch, bi[ch], bq[ch], mag, ratio);
    end

    //---------------------------------------------------------
    // [2] 静默信道: |bin| <= 0.03*8000 = 240 (实测 -40.8 dB = 80)
    //---------------------------------------------------------
    begin : quiet_chk
      automatic real qmax = 0.0;
      automatic int qmax_ch = -1;
      automatic real mag = 0.0;
      for (int k = 0; k < N; k++) begin
        if (k == 5 || k == 17 || k == 40) continue;
        mag = $hypot(bi[k], bq[k]);
        if (mag > qmax) begin qmax = mag; qmax_ch = k; end
      end
      chk($sformatf("quiet max = %.0f at ch%0d <= 240 (-30 dB)", qmax, qmax_ch),
          qmax <= 240.0);
      $display("    MEASURE isolation: quiet max %.0f (rel %.1f dB)",
               qmax, 20.0*$ln((qmax>0?qmax:1.0)/8000.0)/2.302585093);
    end

    //---------------------------------------------------------
    // [3] 帧计数/标志
    //---------------------------------------------------------
    chk_eq("frames == NB", frames_done, NB);
    chk_eq("frame flags == NB", frame_flags, NB);

    //---------------------------------------------------------
    // [4] bin 顺序抽查: bin0 应为小值 (无直流分量注入)
    //---------------------------------------------------------
    chk("bin0 small (no DC injected)", $hypot(bi[0], bq[0]) < 240.0);

    $display("=== RESULT: %0d checks, %0d failures ===", checks, errors);
    if (errors == 0) $display("=== ALL PASS ===");
    else             $display("=== FAILED ===");
    $finish;
  end

  initial begin
    #8000000;
    $display("=== TIMEOUT === frames=%0d o_cnt=%0d pf_st=%0d pf_nin=%0d fft_st=%0d fft_m=%0d fifo_empty=%0b fifo_full=%0b rst_busy=%0b",
             frames_done, o_cnt, u_dut.u_pfir_i.st, u_dut.u_pfir_i.collect,
             u_dut.u_fft.st, u_dut.u_fft.m, u_dut.fifo_empty, u_dut.fifo_full,
             u_dut.u_fifo.rst_busy);
    $finish;
  end

endmodule
