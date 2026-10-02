//=============================================================================
// tb_dsp_pfir.sv -- dsp_pfir 自检 testbench
//
// 验证方法: longint 位精确参考 = 多相直接定义
//   y_p[m] = sum_r h[p + r*N] * x[m*N + p - r*N]   (越界样 = 0)
//   h 从与 RTL 相同的 .mem 文件读入; 输出 = round(v / 2^(B_CO-1)), 无容差。
//
// 覆盖:
//   [1] 冲激响应 (全局样 10*64+36 = 32767): bit-exact 覆盖全 512 抽头
//   [2] DC 帧 (突发 12 全 1000): 稳态输出 == 1000
//   [3] 随机 11 帧 bit-exact
//   输出总数 == 突发数 × N; 队列清空
//
// 突发模式: 每帧 N 样突发 + (N*K+8) 拍计算间隙 (计算需约 N*K 拍, 输入率
//           约束见模块头)。前 WARMUP 帧用于热机 (RAM 未初始化区被真实
//           值覆盖), 其输出不参与比较。
//=============================================================================
`timescale 1ns / 1ps

module tb_dsp_pfir;

  int errors = 0, checks = 0;
  task automatic chk(input string name, input logic cond);
    checks++;
    if (cond !== 1'b1) begin
      errors++;
      $display("  [FAIL] %s (t=%0t)", name, $time);
    end
  endtask
  task automatic chk_eq(input string name, input int act, input int exp);
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
  localparam int NK = N * K;
  localparam int B_CO = 16;
  localparam int WARMUP = 10;          // 热机帧数
  localparam int NB = WARMUP + 14;     // 总突发数

  //---------------------------------------------------------------------------
  // DUT
  //---------------------------------------------------------------------------
  logic        rst = 1'b1, iv = 1'b0;
  logic [15:0] din = '0;
  logic        ov, ofr;
  logic [15:0] dout;

  dsp_pfir #(.N(N), .K(K), .B_IN(16), .B_CO(B_CO), .B_OUT(16), .ROUND(1'b1),
             .COEF_FILE("../coef_pfir_64x8.mem")) u_dut (
    .clk(clk), .rst(rst), .in_valid(iv), .in_data(din),
    .out_valid(ov), .out_data(dout), .out_frame(ofr));

  //---------------------------------------------------------------------------
  // 位精确参考 (多相直接定义)
  //---------------------------------------------------------------------------
  typedef struct { int e; bit cmp; string tag; } exp_t;
  exp_t q[$];
  longint xs [0:NB*N-1];               // 全流样 (0-based 全局号)
  logic signed [B_CO-1:0] cf [0:NK-1];

  initial begin
    for (int i = 0; i < NB*N; i++) xs[i] = 0;
    for (int i = 0; i < NK; i++) cf[i] = '0;
    $readmemh("../coef_pfir_64x8.mem", cf);
  end

  // 帧 m 的 N 个期望输出 (全局样号 = m*N + j)
  task automatic ref_frame(input int m);
    longint v;
    int e;
    for (int p = 0; p < N; p++) begin
      v = 0;
      for (int r = 0; r < K; r++) begin
        automatic int idx = m * N + p - r * N;
        if (idx >= 0) v += int'(cf[p + r * N]) * xs[idx];   // 系数 h[p + r*N]
      end
      e = int'((v + (64'sd1 <<< (B_CO - 2))) >>> (B_CO - 1));
      q.push_back('{e, (m >= WARMUP), $sformatf("m%0d_p%0d", m, p)});
    end
  endtask

  //---------------------------------------------------------------------------
  // 记分板
  //---------------------------------------------------------------------------
  exp_t e;
  int ds;
  int cmp_cnt = 0;
  always @(posedge clk) begin
    if (ov && !rst && q.size() > 0) begin
      e = q.pop_front();
      if (e.cmp) begin
        ds = $signed(dout) - e.e;
        if (ds < 0) ds = -ds;
        chk($sformatf("pfir [%s] bit-exact", e.tag), ds == 0);
        if (ds != 0) $display("    DBG pfir[%s] dut=%0d exp=%0d", e.tag, $signed(dout), e.e);
        cmp_cnt++;
      end
    end
  end

  int burst_idx = 0;
  int outs_total = 0;
  always @(posedge clk) if (ov) outs_total++;

  // 帧首标记检查: 每帧第 0 支路应有 out_frame
  int frame_cnt = 0;
  always @(posedge clk) if (ov && ofr) frame_cnt++;

  //---------------------------------------------------------------------------
  // 主流程
  //---------------------------------------------------------------------------
  initial begin
    $display("=== dsp_pfir self-check start ===");

    // 激励: 突发 0..9 热机全 0; 突发 10 冲激; 12 全 1000; 其余随机
    for (int m = WARMUP + 1; m < NB; m++)
      for (int j = 0; j < N; j++)
        xs[m * N + j] = $signed($urandom_range(0, 65535) - 32768);
    xs[10 * N + 36] = 32767;                       // [1] 冲激
    for (int j = 0; j < N; j++) xs[12 * N + j] = 1000;   // [2] DC 帧

    rst = 1'b1; iv = 1'b0;
    repeat (2) @(posedge clk);
    rst = 1'b0;

    for (int m = 0; m < NB; m++) begin
      for (int j = 0; j < N; j++) begin
        @(negedge clk);
        iv = 1'b1; din = xs[m * N + j][15:0];
      end
      @(negedge clk); iv = 1'b0;
      ref_frame(m);
      repeat (N*(K+1) + 16) @(posedge clk);     // 计算间隙 (每支路 K+1 拍 + 余量)
    end
    repeat (N*(K+1) + 32) @(posedge clk); #1;

    // [2] DC 稳态: 参考数学 sum(h) = 2^15-1 -> 恒 1000 输出
    chk("dc math: ref(1000) == 1000",
        int'((64'sd1000 * 32767 + (64'sd1 <<< (B_CO - 2))) >>> (B_CO - 1)) == 1000);

    chk("pfir queue empty", q.size() == 0);
    chk_eq("pfir total outs == NB*N", outs_total, NB * N);
    chk_eq("pfir compared == (NB-WARMUP)*N", cmp_cnt, (NB - WARMUP) * N);
    chk_eq("pfir frame flags == NB", frame_cnt, NB);

    $display("    MEASURE pfir: outs=%0d compared=%0d frames=%0d checks=%0d",
             outs_total, cmp_cnt, frame_cnt, checks);
    $display("=== RESULT: %0d checks, %0d failures ===", checks, errors);
    if (errors == 0) $display("=== ALL PASS ===");
    else             $display("=== FAILED ===");
    $finish;
  end

  initial begin
    #4000000;
    $display("=== TIMEOUT ===");
    $finish;
  end

endmodule
