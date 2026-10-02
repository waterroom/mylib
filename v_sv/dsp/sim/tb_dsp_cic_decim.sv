//=============================================================================
// tb_dsp_cic_decim.sv -- dsp_cic_decim 自检 testbench
//
// 验证方法: longint 位精确参考 (与 RTL 同款整数运算, 无容差), 逐输出样
//           比对。CIC 是纯整数线性运算, 对拍必须 bit-exact。
//
// 覆盖:
//   [1] DC 增益 1: 恒 A 输入, 稳态输出 == A (瞬态后)
//   [2] 零点: ±A 交替 (f_s/2, k=R/2 零点), 稳态输出 == 0
//   [3] 最大摆动: ±FS 交替 bit-exact
//   [4] 斜坡 + 随机 500 样 bit-exact
//   [5] 参数变体: N=2/R=16/B_OUT=24 (B_OUT > B_IN 保留分数精度)
//   输出计数 == 输入样数/R (队列清空隐式验证)
//=============================================================================
`timescale 1ns / 1ps

module tb_dsp_cic_decim;

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

  localparam int N1 = 3, R1 = 64, G1 = N1 * $clog2(R1);
  localparam int N2 = 2, R2 = 16, G2 = N2 * $clog2(R2);

  //---------------------------------------------------------------------------
  // DUT1: N=3, R=64, B_IN=16, B_OUT=16, ROUND=1
  //---------------------------------------------------------------------------
  logic        rst1 = 1'b1, iv1 = 1'b0;
  logic [15:0] d1 = '0;
  logic        ov1;
  logic [15:0] dout1;

  dsp_cic_decim #(.N(N1), .R(R1), .B_IN(16), .B_OUT(16), .ROUND(1'b1)) u_cic1 (
    .clk(clk), .rst(rst1), .in_valid(iv1), .in_data(d1),
    .out_valid(ov1), .out_data(dout1));

  //---------------------------------------------------------------------------
  // DUT2: N=2, R=16, B_IN=16, B_OUT=24, ROUND=1 (B_OUT > B_IN)
  //---------------------------------------------------------------------------
  logic        rst2 = 1'b1, iv2 = 1'b0;
  logic [15:0] d2 = '0;
  logic        ov2;
  logic [23:0] dout2;

  dsp_cic_decim #(.N(N2), .R(R2), .B_IN(16), .B_OUT(24), .ROUND(1'b1)) u_cic2 (
    .clk(clk), .rst(rst2), .in_valid(iv2), .in_data(d2),
    .out_valid(ov2), .out_data(dout2));

  //---------------------------------------------------------------------------
  // 位精确参考 (longint, 64 位容纳 WI <= 48)
  //---------------------------------------------------------------------------
  typedef struct { int e; string tag; } exp_t;
  exp_t q1[$], q2[$];
  longint a1 [0:7], p1 [0:7], a2 [0:7], p2 [0:7];
  int c1 = 0, c2 = 0;

  task automatic ref_tick(input int x, input int n, input int r, input int gsh,
                          ref longint acc[0:7], ref longint prv[0:7], ref int cnt,
                          output int e, output bit got);
    // 镜像 RTL 非阻塞语义: acc_new[i] = acc_old[i] + acc_old[i-1]
    // (阻塞级联会与 RTL 差 N 拍, 实测输出窗错位)
    longint old[0:7];
    longint v;
    for (int i = 0; i < n; i++) old[i] = acc[i];
    acc[0] = old[0] + x;
    for (int i = 1; i < n; i++) acc[i] = old[i] + old[i-1];
    // sample 拍 = cnt==R-1 (第 R 个输入样); RTL 的 c[0] 采样旧 acc[n-1]
    // (含前 R-1 个样) -- 首个输出窗少 1 样, 稳态无影响
    e = 0; got = 1'b0;
    if (cnt == r - 1) begin
      cnt = 0;
      v = old[n-1];
      for (int g = 0; g < n; g++) begin
        longint d = v - prv[g];
        prv[g] = v;
        v = d;
      end
      got = 1'b1;
      e = int'((v + (64'sd1 <<< (gsh - 1))) >>> gsh);   // round half up
    end else begin
      cnt = cnt + 1;
    end
  endtask

  //---------------------------------------------------------------------------
  // 记分板
  //---------------------------------------------------------------------------
  exp_t e1, e2;
  int d1s, d2s;

  always @(posedge clk) begin
    if (ov1 && !rst1 && q1.size() > 0) begin
      e1 = q1.pop_front();
      d1s = $signed(dout1) - e1.e;
      if (d1s < 0) d1s = -d1s;
      chk($sformatf("cic1 [%s] bit-exact", e1.tag), d1s == 0);
      if (d1s != 0) $display("    DBG cic1[%s] dut=%0d exp=%0d", e1.tag, $signed(dout1), e1.e);
    end
    if (ov2 && !rst2 && q2.size() > 0) begin
      e2 = q2.pop_front();
      d2s = $signed(dout2) - e2.e;
      if (d2s < 0) d2s = -d2s;
      chk($sformatf("cic2 [%s] bit-exact", e2.tag), d2s == 0);
      if (d2s != 0) $display("    DBG cic2[%s] dut=%0d exp=%0d", e2.tag, $signed(dout2), e2.e);
    end
  end

  //---------------------------------------------------------------------------
  // 主流程
  //---------------------------------------------------------------------------
  int out_cnt1 = 0;
  int dc_ok, zp_ok;

  initial begin
    $display("=== dsp_cic_decim self-check start ===");

    //---------------------------------------------------------
    // [1] DC 增益 1: 恒 A=1000
    //---------------------------------------------------------
    $display("[1] DC gain == 1 (constant 1000)");
    for (int i = 0; i < 8; i++) begin a1[i] = 0; p1[i] = 0; end
    c1 = 0;
    rst1 = 1'b1; iv1 = 1'b0;
    repeat (2) @(posedge clk);
    rst1 = 1'b0;
    dc_ok = 0; zp_ok = 0;
    // 恒 1000 共 200 拍 (iv 与首激励拍同起, 避免 DUT 多计一拍)
    for (int k = 0; k < 200; k++) begin
      automatic int e; automatic bit g;
      @(negedge clk);
      iv1 = 1'b1; d1 = 16'd1000;
      ref_tick(1000, N1, R1, G1, a1, p1, c1, e, g);
      if (g) begin
        q1.push_back('{e, $sformatf("dc%0d", out_cnt1)});
        // 瞬态 2 个输出样 (三阶差分窗填充), 第 3 个输出起 DC 增益精确 1
        if (out_cnt1 >= 2 && out_cnt1 < 10) chk_eq($sformatf("dc gain out[%0d]", out_cnt1), e, 1000);
        dc_ok++;
        out_cnt1++;
      end
    end
    chk("dc: >= 3 outputs", dc_ok >= 3);

    //---------------------------------------------------------
    // [2] 零点: ±1000 交替 (f_s/2, k=R/2 零点), 稳态输出 0
    //---------------------------------------------------------
    $display("[2] null at f_s/2 (alternating +-1000)");
    begin
      automatic int zc = 0;   // 本段输出计数 (瞬态 = 前 N 个输出样)
      for (int k = 0; k < 700; k++) begin
        automatic int e; automatic bit g;
        automatic int x = (k % 2 == 0) ? 1000 : -1000;
        @(negedge clk);
        d1 = x[15:0];
        ref_tick(x, N1, R1, G1, a1, p1, c1, e, g);
        if (g) begin
          q1.push_back('{e, $sformatf("zp%0d", zc)});
          // 段内第 5 个输出起稳态应为 0 (交替段是 f_s/2 = k*R/2 零点)
          if (zc >= 4 && zc < 12) chk_eq($sformatf("null out[%0d]", zc), e, 0);
          zc++;
          out_cnt1++;
        end
      end
      chk("null: >= 8 outputs checked", zc >= 8);
    end

    //---------------------------------------------------------
    // [3] 最大摆动 + [4] 斜坡 + 随机: bit-exact
    //---------------------------------------------------------
    $display("[3] max swing bit-exact");
    for (int k = 0; k < 100; k++) begin
      automatic int e; automatic bit g;
      automatic int x = (k % 2 == 0) ? 32767 : -32768;
      @(negedge clk);
      d1 = x[15:0];
      ref_tick(x, N1, R1, G1, a1, p1, c1, e, g);
      if (g) begin q1.push_back('{e, $sformatf("sw%0d", k)}); out_cnt1++; end
    end
    $display("[4] ramp + random bit-exact");
    for (int k = 0; k < 100; k++) begin
      automatic int e; automatic bit g;
      @(negedge clk);
      d1 = (k * 257) % 65536 - 32768;
      ref_tick($signed(d1), N1, R1, G1, a1, p1, c1, e, g);
      if (g) begin q1.push_back('{e, $sformatf("rp%0d", k)}); out_cnt1++; end
    end
    for (int k = 0; k < 500; k++) begin
      automatic int e; automatic bit g;
      automatic int x = $signed($urandom_range(0, 65535) - 32768);
      @(negedge clk);
      d1 = x[15:0];
      ref_tick(x, N1, R1, G1, a1, p1, c1, e, g);
      if (g) begin q1.push_back('{e, $sformatf("rnd%0d", k)}); out_cnt1++; end
    end
    @(negedge clk); iv1 = 1'b0;   // 停流 (延后 1 拍, 让最后一个样被采样)
    chk_eq("cic1 output count == samples/R", out_cnt1, (200 + 700 + 100 + 100 + 500) / R1);

    //---------------------------------------------------------
    // [5] 参数变体 DUT2: N=2, R=16, B_OUT=24 (bit-exact, 随机+DC)
    //---------------------------------------------------------
    $display("[5] variant N=2 R=16 B_OUT=24");
    for (int i = 0; i < 8; i++) begin a2[i] = 0; p2[i] = 0; end
    c2 = 0;
    rst2 = 1'b1; iv2 = 1'b0;
    repeat (2) @(posedge clk);
    rst2 = 1'b0;
    // DC 段 (iv 与首激励拍同起, 与 DUT 对齐)
    for (int k = 0; k < 64; k++) begin
      automatic int e; automatic bit g;
      @(negedge clk);
      iv2 = 1'b1; d2 = 16'd500;
      ref_tick(500, N2, R2, G2, a2, p2, c2, e, g);
      if (g) begin
        q2.push_back('{e, $sformatf("dc%0d", k)});
        if (k == 2) chk_eq("dc gain2 out[2]", e, 500);
      end
    end
    // 随机段
    for (int k = 0; k < 400; k++) begin
      automatic int e; automatic bit g;
      automatic int x = $signed($urandom_range(0, 65535) - 32768);
      @(negedge clk);
      d2 = x[15:0];
      ref_tick(x, N2, R2, G2, a2, p2, c2, e, g);
      if (g) q2.push_back('{e, $sformatf("rnd%0d", k)});
    end
    @(negedge clk); iv2 = 1'b0;   // 停流

    // 排空
    repeat (R1 + N1 + 4) @(posedge clk); #1;
    $display("    MEASURE cic queue: q1=%0d q2=%0d (out_cnt1=%0d expect %0d)",
             q1.size(), q2.size(), out_cnt1, (200 + 700 + 100 + 100 + 500) / R1);
    chk("cic1 queue empty", q1.size() == 0);
    chk("cic2 queue empty", q2.size() == 0);

    $display("=== RESULT: %0d checks, %0d failures ===", checks, errors);
    if (errors == 0) $display("=== ALL PASS ===");
    else             $display("=== FAILED ===");
    $finish;
  end

  initial begin
    #500000;
    $display("=== TIMEOUT ===");
    $finish;
  end

endmodule
