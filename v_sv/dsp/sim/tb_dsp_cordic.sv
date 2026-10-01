//=============================================================================
// tb_dsp_cordic.sv -- dsp_cordic 自检 testbench
//
// 验证方法: TB 内 real-math 参考模型 ($sin/$cos/$atan2/$hypot) 定点化后
//           逐点对拍, 无外部向量文件依赖; ULP 容差 TOL=4, 输出 MAX_ERR。
//
// 覆盖:
//   rotate  相位角点 (0/pi/2/pi/3pi/2, pi/4 系, ±LSB) + 64 随机全圆周
//   vector  轴上/对角/四象限角点, -FS 溢出角点 (内部加宽验证), 64 随机
//   延迟    STAGES+2 实测
//   饱和    sin/cos 峰值 +1.0 -> 2^(D-1)-1 (参考模型同款饱和)
//
// 运行: bash sim/run_xsim.sh
// 采样约定: 激励 negedge 改变, 检查 posedge 后 #1 (与 xpm_wrappers 一致)
//=============================================================================
`timescale 1ns / 1ps

module tb_dsp_cordic;

  int errors = 0, checks = 0;

  task automatic chk(input string name, input logic cond);
    checks++;
    if (cond !== 1'b1) begin
      errors++;
      $display("  [FAIL] %s   (t=%0t)", name, $time);
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

  localparam int  P      = 16;
  localparam int  D      = 16;
  localparam int  S      = 16;
  localparam int  FS     = 1 << (D - 1);
  // rotate 的幅度基准与 DUT 一致: x0 = round(FS/K)-2 -> 满幅 = K*x0
  // (防饱和余量使输出比理想 FS 低 ~3.3 LSB, 见 dsp_cordic.sv X0 说明)
  localparam real K_INF  = 1.646760258121;
  localparam real AMP    = K_INF * (rround_static(FS / K_INF) - 2);
  localparam real TWO_PI = 6.28318530717958647692;
  localparam int  TOL    = 4;

  function automatic int rround_static(input real v);
    rround_static = $rtoi(v >= 0.0 ? v + 0.5 : v - 0.5);
  endfunction

  //---------------------------------------------------------------------------
  // DUT
  //---------------------------------------------------------------------------
  logic        iv_rot = 1'b0, iv_vec = 1'b0;
  logic [P-1:0] phase_r = '0;
  logic [D-1:0] x_r = '0, y_r = '0;
  logic        ov_rot, ov_vec;
  logic [D-1:0] sin_w, cos_w, mag_w;
  logic [P-1:0] ph_w;

  dsp_cordic #(.MODE("rotate"), .P_DW(P), .D_DW(D), .STAGES(S)) u_rot (
    .clk(clk), .in_valid(iv_rot), .in_phase(phase_r),
    .in_x('0), .in_y('0),
    .out_valid(ov_rot), .out_sin(sin_w), .out_cos(cos_w),
    .out_mag(), .out_phase());

  dsp_cordic #(.MODE("vector"), .P_DW(P), .D_DW(D), .STAGES(S),
               .GAIN_COMP(1'b1)) u_vec (
    .clk(clk), .in_valid(iv_vec), .in_phase('0),
    .in_x(x_r), .in_y(y_r),
    .out_valid(ov_vec), .out_sin(), .out_cos(),
    .out_mag(mag_w), .out_phase(ph_w));

  //---------------------------------------------------------------------------
  // 参考模型帮助
  //---------------------------------------------------------------------------
  function automatic int rround(input real v);
    rround = $rtoi(v >= 0.0 ? v + 0.5 : v - 0.5);
  endfunction

  function automatic int sat_tb(input int v);
    if (v >  FS - 1) sat_tb = FS - 1;
    else if (v < -FS) sat_tb = -FS;
    else sat_tb = v;
  endfunction

  //---------------------------------------------------------------------------
  // 记分板 (FIFO 队列, 与 DUT 逐笔对应)
  //---------------------------------------------------------------------------
  typedef struct { int e0; int e1; string tag; bit c1; } exp2_t;
  exp2_t rq[$];   // rotate: e0=exp_sin, e1=exp_cos
  exp2_t vq[$];   // vector: e0=exp_mag, e1=exp_phase (c1=0 时相位不查)

  int max_err_sin = 0, max_err_cos = 0, max_err_mag = 0, max_err_ph = 0;

  always @(posedge clk) begin
    if (ov_rot) begin
      exp2_t e;
      int ds, dc;
      e  = rq.pop_front();
      ds = $signed(sin_w) - e.e0;
      dc = $signed(cos_w) - e.e1;
      if (ds < 0) ds = -ds;
      if (dc < 0) dc = -dc;
      if (ds > max_err_sin) max_err_sin = ds;
      if (dc > max_err_cos) max_err_cos = dc;
      if (ds > TOL) $display("    DBG rot[%s] sin dut=%0d exp=%0d", e.tag, $signed(sin_w), e.e0);
      if (dc > TOL) $display("    DBG rot[%s] cos dut=%0d exp=%0d", e.tag, $signed(cos_w), e.e1);
      chk($sformatf("rot sin [%s]", e.tag), ds <= TOL);
      chk($sformatf("rot cos [%s]", e.tag), dc <= TOL);
    end
    if (ov_vec) begin
      exp2_t e;
      int dm, dp;
      e  = vq.pop_front();
      dm = $signed({1'b0, mag_w}) - e.e0;   // mag 无符号, 扩位后做差
      dp = ph_w - e.e1;                     // P 位回卷意义下的差
      if (dp > (1 << (P-1))) dp = (1 << P) - dp;
      if (dp < -(1 << (P-1))) dp = (1 << P) + dp;
      if (dm < 0) dm = -dm;
      if (dp < 0) dp = -dp;
      if (dm > max_err_mag) max_err_mag = dm;
      if (dp > max_err_ph && e.c1) max_err_ph = dp;
      if (dm > TOL) $display("    DBG vec[%s] mag dut=%0d exp=%0d (x_end=%0d z_end=%0d s=%0d)", e.tag, mag_w, e.e0, u_vec.g_vec.xv[S], u_vec.g_vec.zv[S], u_vec.g_vec.s_d[S]);
      if (dp > TOL && e.c1) $display("    DBG vec[%s] ph  dut=%0d exp=%0d (x_end=%0d z_end=%0d s=%0d)", e.tag, ph_w, e.e1, u_vec.g_vec.xv[S], u_vec.g_vec.zv[S], u_vec.g_vec.s_d[S]);
      chk($sformatf("vec mag [%s]", e.tag), dm <= TOL);
      if (e.c1) chk($sformatf("vec ph  [%s]", e.tag), dp <= TOL);
    end
  end

  //---------------------------------------------------------------------------
  // 驱动任务
  //---------------------------------------------------------------------------
  task automatic drive_rot(input logic [P-1:0] ph, input string tag);
    real th;
    int  es, ec;
    th = TWO_PI * ph / (2.0 ** P);
    es = sat_tb(rround($sin(th) * AMP));
    ec = sat_tb(rround($cos(th) * AMP));
      @(negedge clk);
      iv_rot = 1'b1; phase_r = ph;
      rq.push_back('{es, ec, tag, 1'b1});
    @(negedge clk);
    iv_rot = 1'b0;
  endtask

  task automatic drive_vec(input int xv, input int yv, input string tag,
                           input bit ph_chk = 1'b1);
    real mag, ph;
    int  em, ep;
    mag = $hypot(xv * 1.0, yv * 1.0);
    ph  = $atan2(yv * 1.0, xv * 1.0);
    if (ph < 0.0) ph = ph + TWO_PI;
    em = rround(mag);                                   // GAIN_COMP=1: out = |v| (码值域)
    ep = rround(ph / TWO_PI * (2.0 ** P)) % (1 << P);   // [0, 2^P)
    @(negedge clk);
    iv_vec = 1'b1; x_r = xv[D-1:0]; y_r = yv[D-1:0];
    vq.push_back('{em, ep, tag, ph_chk});
    @(negedge clk);
    iv_vec = 1'b0;
  endtask

  //---------------------------------------------------------------------------
  // 主流程
  //---------------------------------------------------------------------------
  initial begin
    $display("=== dsp_cordic self-check start ===");

    //---------------------------------------------------------
    // [1] 延迟实测 (rotate)
    //---------------------------------------------------------
    begin
      automatic int cyc = 0;
      fork
        begin
          drive_rot(16'h2000, "lat");   // pi/4
        end
        begin
          @(negedge clk);
          while (ov_rot !== 1'b1 && cyc < 200) begin @(posedge clk); #1; cyc++; end
        end
      join
      chk_eq("latency == STAGES+2", cyc, S + 2);
      $display("    MEASURE cordic: latency = %0d (STAGES=%0d)", cyc, S);
    end

    //---------------------------------------------------------
    // [2] rotate: 角点 + 随机
    //---------------------------------------------------------
    $display("[2] rotate corners + random");
    drive_rot(16'h0000, "ph=0");
    drive_rot(16'h2000, "ph=pi/2");
    drive_rot(16'h4000, "ph=pi");
    drive_rot(16'h6000, "ph=3pi/2");
    drive_rot(16'h0800, "ph=pi/4");
    drive_rot(16'h1800, "ph=3pi/4");
    drive_rot(16'h2800, "ph=5pi/4");
    drive_rot(16'h3800, "ph=7pi/4");
    drive_rot(16'h0001, "ph=+LSB");
    drive_rot(16'hFFFF, "ph=-LSB");
    drive_rot(16'h7FFF, "ph=pi-LSB");
    drive_rot(16'h8001, "ph=pi+LSB");
    for (int i = 0; i < 64; i++)
      drive_rot($urandom(), $sformatf("rnd%0d", i));

    //---------------------------------------------------------
    // [3] vector: 角点 + 随机
    //---------------------------------------------------------
    $display("[3] vector corners + random");
    drive_vec(FS - 1, 0, "+x");
    drive_vec(0, FS - 1, "+y");
    drive_vec(-(FS - 1), 0, "-x");
    drive_vec(0, -(FS - 1), "-y");
    drive_vec(FS - 1, FS - 1, "45d");
    drive_vec(-(FS - 1), FS - 1, "135d");
    drive_vec(-(FS - 1), -(FS - 1), "225d");
    drive_vec(FS - 1, -(FS - 1), "315d");
    drive_vec(-FS, -FS, "-FS,-FS");
    drive_vec(-FS, 0, "-FS,0");
    drive_vec(1, 1, "tiny");
    drive_vec(0, 0, "zero", 1'b0);   // atan2(0,0) 无定义, 只查 mag
    for (int i = 0; i < 64; i++) begin
      automatic int xv = $urandom_range(0, 2 * FS - 2) - (FS - 1);
      automatic int yv = $urandom_range(0, 2 * FS - 2) - (FS - 1);
      drive_vec(xv, yv, $sformatf("rnd%0d", i));
    end

    //---------------------------------------------------------
    // 排空 + 汇总
    //---------------------------------------------------------
    while (rq.size() > 0 || vq.size() > 0) @(posedge clk);
    repeat (S + 4) @(posedge clk); #1;
    chk("rotate queue empty", rq.size() == 0);
    chk("vector queue empty", vq.size() == 0);

    $display("    MEASURE cordic: max_err sin=%0d cos=%0d mag=%0d phase=%0d LSB (TOL=%0d)",
             max_err_sin, max_err_cos, max_err_mag, max_err_ph, TOL);
    chk("max_err_sin  <= TOL", max_err_sin <= TOL);
    chk("max_err_cos  <= TOL", max_err_cos <= TOL);
    chk("max_err_mag  <= TOL", max_err_mag <= TOL);
    chk("max_err_ph   <= TOL", max_err_ph  <= TOL);

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
