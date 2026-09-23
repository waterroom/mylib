//=============================================================================
// tb_xpm_wrappers.sv -- v_sv/xpm_wrappers 自检 testbench
//
// 覆盖:
//   xpm_cdc_sync   单 bit / 8bit 电平跨时钟同步
//   xpm_rst_sync   复位桥: 异步置位 (1ns 短脉冲立即生效) / 同步释放
//   xpm_pulse_sync 100M -> 250M 脉冲个数不丢、脉宽 1 个目标周期
//   xpm_sync_fifo  std 模式读写/标志/溢出/下溢; fwft 模式 show-ahead
//   xpm_async_fifo 100M <-> 57M 跨时钟读写; 1ns 复位脉冲能被捕获;
//                  实测有效深度 (DEPTH=16/32 两档, XPM 异步 FIFO 比标称少 1)
//   rst_busy 语义  上电 (无外部复位) / 时钟停住 / 复位窗口内写入 的行为
//   prog 水线      PROG_FULL/EMPTY_THRESH 置起边界 (同步+异步) 与
//                  阈值 0 时输出恒 0 的默认契约
//
// 运行: bash sim/run_xsim.sh   (需要 Vivado 的 xvlog/xelab/xsim)
//
// 采样约定: 检查紧跟时钟等待时, 统一先 #1ns 让非阻塞赋值生效;
//           激励统一在时钟下降沿改变, 避免与上升沿采样竞争。
// 输出为 ASCII, 避免 Windows 控制台代码页把中文显示乱码。
//=============================================================================
`timescale 1ns / 1ps

module tb_xpm_wrappers;

  int errors = 0;
  int checks = 0;

  task automatic chk(input string name, input logic cond);
    checks++;
    if (cond !== 1'b1) begin
      errors++;
      $display("  [FAIL] %s   (t=%0t)", name, $time);
    end
  endtask

  task automatic chk_eq(input string name, input logic [31:0] act, input logic [31:0] exp);
    checks++;
    if (act !== exp) begin
      errors++;
      $display("  [FAIL] %s   got=%0d exp=%0d (t=%0t)", name, act, exp, $time);
    end
  endtask

  //-------------------------------------------------------------
  // 时钟: 100M / 57M / 250M (互不相关)
  //-------------------------------------------------------------
  logic clk100 = 1'b0;
  logic clk57  = 1'b0;
  logic clk250 = 1'b0;

  always #5.0  clk100 = ~clk100;
  always #8.75 clk57  = ~clk57;
  always #2.0  clk250 = ~clk250;

  //=============================================================
  // 1) xpm_cdc_sync
  //=============================================================
  logic [7:0] src_bus = 8'h00;
  logic       src_bit = 1'b0;
  logic [7:0] dest_bus;
  logic       dest_bit;

  xpm_cdc_sync #(.W(8), .STAGES(2)) u_bus_sync (
    .src_clk (clk100), .src_in (src_bus),
    .dest_clk(clk57),  .dest_out(dest_bus));

  xpm_cdc_sync #(.W(1), .STAGES(3), .REG_SRC(1'b0)) u_bit_sync (
    .src_clk (clk100), .src_in (src_bit),
    .dest_clk(clk250), .dest_out(dest_bit));

  //=============================================================
  // 2) xpm_rst_sync  (目标域 57M)
  //=============================================================
  logic src_rst_r = 1'b0;
  logic dest_rst_r;
  real  t_rst_rise, t_rst_fall, t_release, t_exp_fall;

  xpm_rst_sync #(.STAGES(2)) u_rst_sync (
    .src_rst (src_rst_r),
    .dest_clk(clk57),
    .dest_rst(dest_rst_r));

  //=============================================================
  // 3) xpm_pulse_sync  (100M -> 250M)
  //=============================================================
  logic src_rst_p = 1'b0, dest_rst_p = 1'b0;
  logic src_pulse = 1'b0;
  logic dest_pulse;
  int   dest_pulse_cnt = 0;

  xpm_pulse_sync #(.STAGES(2)) u_pulse_sync (
    .src_clk (clk100), .src_rst (src_rst_p), .src_pulse (src_pulse),
    .dest_clk(clk250), .dest_rst(dest_rst_p), .dest_pulse(dest_pulse));

  always @(posedge clk250) if (dest_pulse) dest_pulse_cnt <= dest_pulse_cnt + 1;

  //=============================================================
  // 4) xpm_sync_fifo  std 模式   (100M, 16 深, 8bit)
  //=============================================================
  logic        rst_f1   = 1'b1;
  logic        wr_en_f1 = 1'b0, rd_en_f1 = 1'b0;
  logic [7:0]  din_f1   = 8'h00;
  logic        full_f1, afull_f1, ovf_f1, wrbusy_f1;
  logic [4:0]  cnt_f1;
  logic [7:0]  dout_f1;
  logic        empty_f1, aempty_f1, valid_f1, unf_f1;

  logic        ovf_seen_f1 = 1'b0, unf_seen_f1 = 1'b0;
  logic        ovf_busy_seen_f1 = 1'b0;
  logic        pfull_f1, pempty_f1;          // 阈值 0 (默认): 特性位不开, 应恒 0

  xpm_sync_fifo #(.DW(8), .DEPTH(16), .READ_MODE("std")) u_sfifo_std (
    .clk(clk100), .rst(rst_f1),
    .wr_en(wr_en_f1), .din(din_f1),
    .full(full_f1), .almost_full(afull_f1), .prog_full(pfull_f1),
    .count(cnt_f1),
    .overflow(ovf_f1), .rst_busy(wrbusy_f1),
    .rd_en(rd_en_f1), .dout(dout_f1),
    .empty(empty_f1), .almost_empty(aempty_f1), .prog_empty(pempty_f1),
    .valid(valid_f1), .underflow(unf_f1));

  always @(posedge clk100) begin
    if (ovf_f1) ovf_seen_f1 <= 1'b1;
    if (unf_f1) unf_seen_f1 <= 1'b1;
    if (wrbusy_f1 && ovf_f1) ovf_busy_seen_f1 <= 1'b1;   // 复位窗口内的写被丢弃
  end

  //=============================================================
  // 5) xpm_sync_fifo  fwft 模式 (100M, 16 深, 8bit)
  //=============================================================
  logic        rst_f2   = 1'b1;
  logic        wr_en_f2 = 1'b0, rd_en_f2 = 1'b0;
  logic [7:0]  din_f2   = 8'h00;
  logic        full_f2, afull_f2, ovf_f2, wrbusy_f2;
  logic [4:0]  cnt_f2;
  logic [7:0]  dout_f2;
  logic        empty_f2, aempty_f2, valid_f2, unf_f2;

  xpm_sync_fifo #(.DW(8), .DEPTH(16), .READ_MODE("fwft")) u_sfifo_fwft (
    .clk(clk100), .rst(rst_f2),
    .wr_en(wr_en_f2), .din(din_f2),
    .full(full_f2), .almost_full(afull_f2), .count(cnt_f2),
    .overflow(ovf_f2), .rst_busy(wrbusy_f2),
    .rd_en(rd_en_f2), .dout(dout_f2),
    .empty(empty_f2), .almost_empty(aempty_f2), .valid(valid_f2),
    .underflow(unf_f2));

  //=============================================================
  // 6) xpm_async_fifo  (写 100M / 读 57M)
  //    16 深 + 32 深各一个, 用来实测"有效深度"是否 = DEPTH-1
  //=============================================================
  logic        rst_f3    = 1'b1;
  logic        wr_en_f3  = 1'b0, rd_en_f3 = 1'b0;
  logic [7:0]  din_f3    = 8'h00;
  logic        full_f3, afull_f3, ovf_f3, wrbusy_f3;
  logic [4:0]  wcnt_f3;
  logic [7:0]  dout_f3;
  logic        empty_f3, aempty_f3, valid_f3, unf_f3;
  logic [4:0]  rcnt_f3;
  logic        rdbusy_f3;

  xpm_async_fifo #(.DW(8), .DEPTH(16), .READ_MODE("std")) u_afifo16 (
    .wr_clk(clk100), .wr_en(wr_en_f3), .din(din_f3),
    .full(full_f3), .almost_full(afull_f3), .wr_count(wcnt_f3),
    .overflow(ovf_f3), .wr_rst_busy(wrbusy_f3),
    .rd_clk(clk57), .rd_en(rd_en_f3), .dout(dout_f3),
    .empty(empty_f3), .almost_empty(aempty_f3), .valid(valid_f3),
    .underflow(unf_f3), .rd_count(rcnt_f3), .rd_rst_busy(rdbusy_f3),
    .rst(rst_f3));

  logic        rst_f4    = 1'b1;
  logic        wr_en_f4  = 1'b0, rd_en_f4 = 1'b0;
  logic [7:0]  din_f4    = 8'h00;
  logic        full_f4, afull_f4, ovf_f4, wrbusy_f4, rdbusy_f4;
  logic [5:0]  wcnt_f4;
  logic [7:0]  dout_f4;
  logic        empty_f4, aempty_f4, valid_f4, unf_f4;
  logic [5:0]  rcnt_f4;

  xpm_async_fifo #(.DW(8), .DEPTH(32), .READ_MODE("std")) u_afifo32 (
    .wr_clk(clk100), .wr_en(wr_en_f4), .din(din_f4),
    .full(full_f4), .almost_full(afull_f4), .wr_count(wcnt_f4),
    .overflow(ovf_f4), .wr_rst_busy(wrbusy_f4),
    .rd_clk(clk57), .rd_en(rd_en_f4), .dout(dout_f4),
    .empty(empty_f4), .almost_empty(aempty_f4), .valid(valid_f4),
    .underflow(unf_f4), .rd_count(rcnt_f4), .rd_rst_busy(rdbusy_f4),
    .rst(rst_f4));

  //=============================================================
  // 9) prog_full / prog_empty 可编程水线 (同步 + 异步)
  //    std 模式等宽 -> PF/PE_THRESH_ADJ 无修正, 边界即参数值:
  //    PF=8: 占用量 >= 8 置起; PE=4: 剩余量 <= 4 置起
  //    (阈值在合法区间中段取: 同步 std DEPTH=16 为 [3,13], 异步再加 CDC)
  //    注意: prog 标志用寄存后的差值指针比较, 比 almost_*/full/empty 多
  //    1 拍延迟 (实测: 第 8 个字写入后的下一拍才置起), 采样边界晚一拍。
  //=============================================================
  logic        rst_f7   = 1'b1;
  logic        wr_en_f7 = 1'b0, rd_en_f7 = 1'b0;
  logic [7:0]  din_f7   = 8'h00;
  logic        full_f7, afull_f7, pfull_f7, ovf_f7, wrbusy_f7;
  logic [4:0]  cnt_f7;
  logic [7:0]  dout_f7;
  logic        empty_f7, aempty_f7, pempty_f7, valid_f7, unf_f7;

  xpm_sync_fifo #(.DW(8), .DEPTH(16), .READ_MODE("std"),
                  .PROG_FULL_THRESH(8), .PROG_EMPTY_THRESH(4)) u_sfifo_prog (
    .clk(clk100), .rst(rst_f7),
    .wr_en(wr_en_f7), .din(din_f7),
    .full(full_f7), .almost_full(afull_f7), .prog_full(pfull_f7),
    .count(cnt_f7),
    .overflow(ovf_f7), .rst_busy(wrbusy_f7),
    .rd_en(rd_en_f7), .dout(dout_f7),
    .empty(empty_f7), .almost_empty(aempty_f7), .prog_empty(pempty_f7),
    .valid(valid_f7), .underflow(unf_f7));

  logic        rst_f8    = 1'b1;
  logic        wr_en_f8  = 1'b0, rd_en_f8 = 1'b0;
  logic [7:0]  din_f8    = 8'h00;
  logic        full_f8, afull_f8, pfull_f8, ovf_f8, wrbusy_f8, rdbusy_f8;
  logic [4:0]  wcnt_f8, rcnt_f8;
  logic [7:0]  dout_f8;
  logic        empty_f8, aempty_f8, pempty_f8, valid_f8, unf_f8;

  xpm_async_fifo #(.DW(8), .DEPTH(16), .READ_MODE("std"),
                   .PROG_FULL_THRESH(8), .PROG_EMPTY_THRESH(4)) u_afifo_prog (
    .wr_clk(clk100), .wr_en(wr_en_f8), .din(din_f8),
    .full(full_f8), .almost_full(afull_f8), .prog_full(pfull_f8),
    .wr_count(wcnt_f8), .overflow(ovf_f8), .wr_rst_busy(wrbusy_f8),
    .rd_clk(clk57), .rd_en(rd_en_f8), .dout(dout_f8),
    .empty(empty_f8), .almost_empty(aempty_f8), .prog_empty(pempty_f8),
    .valid(valid_f8), .underflow(unf_f8),
    .rd_count(rcnt_f8), .rd_rst_busy(rdbusy_f8), .rst(rst_f8));

  //=============================================================
  // 8) rst_busy 语义: 上电 (无外部复位) / 时钟停住 时的行为
  //    rst_busy 是 wr_clk 域内的同步信号 (同步 FIFO: 复位移位链;
  //    异步 FIFO: 复位序列机的组合输出), 这里验证它的三个边界:
  //      - 上电第一个时钟沿之前: 初值 0 (还没开始复位!)
  //      - 不接外部复位: XPM 内部 power-on reset 自己把 busy 拉高几个周期
  //      - 时钟停住: 复位拉高也不会让 busy 变化 (没有沿)
  //=============================================================
  logic clk_gate_en = 1'b1;
  logic clk_g, clk57g;
  assign clk_g  = clk100 & clk_gate_en;
  assign clk57g = clk57  & clk_gate_en;

  // 故意不接外部复位 (rst 恒 0)
  logic       rst_f5 = 1'b0;
  logic       wr_en_f5 = 1'b0, rd_en_f5 = 1'b0;
  logic [7:0] din_f5 = 8'h00;
  logic       full_f5, afull_f5, ovf_f5, wbusy_f5;
  logic [4:0] wcnt_f5;
  logic [7:0] dout_f5;
  logic       empty_f5, aempty_f5, valid_f5, unf_f5;

  xpm_sync_fifo #(.DW(8), .DEPTH(16)) u_sfifo_noreset (
    .clk(clk_g), .rst(rst_f5),
    .wr_en(wr_en_f5), .din(din_f5), .full(full_f5), .almost_full(afull_f5),
    .count(wcnt_f5), .overflow(ovf_f5), .rst_busy(wbusy_f5),
    .rd_en(rd_en_f5), .dout(dout_f5), .empty(empty_f5),
    .almost_empty(aempty_f5), .valid(valid_f5), .underflow(unf_f5));

  logic       rst_f6 = 1'b0;
  logic       wr_en_f6 = 1'b0, rd_en_f6 = 1'b0;
  logic [7:0] din_f6 = 8'h00;
  logic       full_f6, afull_f6, ovf_f6, wbusy_f6, rbusy_f6;
  logic [4:0] wcnt_f6, rcnt_f6;
  logic [7:0] dout_f6;
  logic       empty_f6, aempty_f6, valid_f6, unf_f6;

  xpm_async_fifo #(.DW(8), .DEPTH(16)) u_afifo_noreset (
    .wr_clk(clk_g), .wr_en(wr_en_f6), .din(din_f6),
    .full(full_f6), .almost_full(afull_f6), .wr_count(wcnt_f6),
    .overflow(ovf_f6), .wr_rst_busy(wbusy_f6),
    .rd_clk(clk57g), .rd_en(rd_en_f6), .dout(dout_f6),
    .empty(empty_f6), .almost_empty(aempty_f6), .valid(valid_f6),
    .underflow(unf_f6), .rd_count(rcnt_f6), .rd_rst_busy(rbusy_f6),
    .rst(rst_f6));

  // 上电采样: 在 t=0 附近 (第一个时钟沿之前) 取值, 主流程最后核对。
  // 注意 while 循环里每个沿后要 #1 再判条件: 沿时刻读到的是沿之前的值,
  // 少了 #1 会把"1 拍"记成"2 拍"。
  logic s_busy_at0, a_busy_at0;
  int   s_assert_edges, s_width_edges, a_assert_edges, a_width_edges;

  initial begin
    #0.1;
    s_busy_at0 = wbusy_f5;
    s_assert_edges = 0;
    while (!wbusy_f5) begin @(posedge clk_g); #1.0; s_assert_edges++; end
    s_width_edges = 0;
    while (wbusy_f5) begin @(posedge clk_g); #1.0; s_width_edges++; end
  end

  initial begin
    #0.1;
    a_busy_at0 = wbusy_f6;
    a_assert_edges = 0;
    while (!wbusy_f6) begin @(posedge clk_g); #1.0; a_assert_edges++; end
    a_width_edges = 0;
    while (wbusy_f6) begin @(posedge clk_g); #1.0; a_width_edges++; end
  end

  //=============================================================
  // 主测试流程
  //=============================================================
  real  t_pulse_rise, t_pulse_fall, pulse_width;
  int   accepted16, words16, accepted32;
  int   busy_cyc;

  initial begin
    $display("=== xpm_wrappers self-check start ===");

    //-----------------------------------------------------------
    $display("[1] xpm_cdc_sync");
    //-----------------------------------------------------------
    src_bus = 8'h00; src_bit = 1'b0;
    repeat (6) @(posedge clk57); #1.0;
    chk("cdc bus init 0", dest_bus === 8'h00);

    src_bus = 8'hA5; src_bit = 1'b1;
    repeat (6) @(posedge clk57); #1.0;      // 2 级同步 + 余量
    chk_eq("cdc 8bit sync (A5)", dest_bus, 8'hA5);
    repeat (10) @(posedge clk250); #1.0;    // REG_SRC=0 + 3 级同步
    chk("cdc 1bit sync (1)", dest_bit === 1'b1);

    src_bus = 8'h5A; src_bit = 1'b0;
    repeat (6) @(posedge clk57); #1.0;
    chk_eq("cdc 8bit re-sync (5A)", dest_bus, 8'h5A);
    repeat (10) @(posedge clk250); #1.0;
    chk("cdc 1bit re-sync (0)", dest_bit === 1'b0);

    //-----------------------------------------------------------
    $display("[2] xpm_rst_sync");
    //-----------------------------------------------------------
    chk("rst bridge init (released)", dest_rst_r === 1'b0);

    // 在 100M 时钟沿之间发 1ns 异步短脉冲
    @(posedge clk100); #2.0;
    t_rst_rise = $realtime;
    src_rst_r  = 1'b1;
    #1.0; src_rst_r = 1'b0;
    t_release = $realtime;
    #0.5;
    chk("rst bridge async assert (no clock needed)", dest_rst_r === 1'b1);

    // 释放: 撤销沿应落在 dest_clk (57M, 沿在 8.75+k*17.5) 的第 2 个上升沿
    @(negedge dest_rst_r);
    t_rst_fall = $realtime;
    chk("rst bridge deassert aligned to dest_clk", clk57 === 1'b1);
    t_exp_fall = 8.75 + ($floor((t_release - 8.75) / 17.5) + 2.0) * 17.5;
    chk("rst bridge deassert at 2nd dest edge after release",
        (t_rst_fall - t_exp_fall) > -0.001 && (t_rst_fall - t_exp_fall) < 0.001);
    chk("rst bridge width > 1 dest period", (t_rst_fall - t_release) > 17.4);
    $display("    MEASURE rst_sync: release->fall = %0.1f ns (1 dest period = 17.5 ns)",
             t_rst_fall - t_release);

    //-----------------------------------------------------------
    $display("[3] xpm_pulse_sync (100M -> 250M, 20 pulses)");
    //-----------------------------------------------------------
    src_rst_p = 1'b1; dest_rst_p = 1'b1;
    repeat (10) @(posedge clk250);
    src_rst_p = 1'b0; dest_rst_p = 1'b0;
    repeat (10) @(posedge clk250);

    fork
      begin : m_first_pulse_width
        @(posedge dest_pulse); t_pulse_rise = $realtime;
        @(negedge dest_pulse); t_pulse_fall = $realtime;
        pulse_width = t_pulse_fall - t_pulse_rise;
      end
      begin : m_send_pulses
        repeat (20) begin
          @(negedge clk100); src_pulse = 1'b1;
          @(negedge clk100); src_pulse = 1'b0;
          repeat (9) @(negedge clk100);
        end
      end
    join

    repeat (20) @(posedge clk250); #1.0;
    chk_eq("pulse count (20 pulses, none lost)", dest_pulse_cnt, 20);
    chk("pulse width = 1 dest period", pulse_width > 3.9 && pulse_width < 4.1);
    $display("    MEASURE pulse_sync: got %0d pulses, width %0.1f ns",
             dest_pulse_cnt, pulse_width);

    //-----------------------------------------------------------
    $display("[4] xpm_sync_fifo std mode");
    //-----------------------------------------------------------
    wr_en_f1 = 1'b0; rd_en_f1 = 1'b0; rst_f1 = 1'b1;
    repeat (5) @(posedge clk100);
    rst_f1 = 1'b0;
    wait (!wrbusy_f1);
    repeat (2) @(posedge clk100); #1.0;
    chk("after reset: empty=1",  empty_f1 === 1'b1);
    chk_eq("after reset: count=0", cnt_f1, 0);

    // 连续写 16 个字 0..15。
    // 采样点说明 (与 XPM 实现一致, 已在 README 记录):
    //   - count 用寄存器指针计算, 连续写入期间比真实占用量晚一拍;
    //   - almost_full / full 是当拍有效, 所以用"已接受的写次数"作参照:
    //     i 轮下降沿时真实占用量 = i 个字。
    for (int i = 0; i < 16; i++) begin
      @(negedge clk100);
      wr_en_f1 = 1'b1; din_f1 = i[7:0];
      if (i == 14) chk("almost_full=0 when 14 words in (2 slots free)",
                       afull_f1 === 1'b0);
      if (i == 15) chk("almost_full=1 when 15 words in (1 slot free)",
                       afull_f1 === 1'b1);
    end
    @(negedge clk100); wr_en_f1 = 1'b0;
    repeat (2) @(posedge clk100); #1.0;
    chk("full=1 after 16 writes (nominal depth usable)", full_f1 === 1'b1);
    chk_eq("count=16 after 16 writes", cnt_f1, 16);
    chk("prog tie-off: prog_full=0 while full (thresh 0 = bits off)",
        pfull_f1 === 1'b0);

    // 满时再写: overflow 应指示, 数据不进 FIFO
    @(negedge clk100); wr_en_f1 = 1'b1; din_f1 = 8'hEE;
    @(negedge clk100); wr_en_f1 = 1'b0;
    repeat (3) @(posedge clk100); #1.0;
    chk("overflow asserted on write-while-full", ovf_seen_f1 === 1'b1);
    chk_eq("overflowed data not stored (count=16)", cnt_f1, 16);

    // 顺序读 16 个字; 途中检查 almost_empty
    for (int i = 0; i < 16; i++) begin
      @(negedge clk100);
      rd_en_f1 = 1'b1;
      @(posedge clk100); #1.0;
      chk_eq($sformatf("std read data[%0d]", i), dout_f1, i[7:0]);
      chk($sformatf("std read valid[%0d]", i), valid_f1 === 1'b1);
      if (i == 12) chk("almost_empty=0 when 3 words left", aempty_f1 === 1'b0);
      if (i == 13) chk("almost_empty=0 when 2 words left", aempty_f1 === 1'b0);
      if (i == 14) chk("almost_empty=1 when 1 word left",  aempty_f1 === 1'b1);
      if (i == 15) begin
        chk("empty=1 after last read", empty_f1 === 1'b1);
        chk("almost_empty stays 1 while empty", aempty_f1 === 1'b1);
      end
    end
    @(negedge clk100); rd_en_f1 = 1'b0;
    repeat (2) @(posedge clk100); #1.0;
    chk_eq("count=0 after drain", cnt_f1, 0);
    chk("prog tie-off: prog_empty=0 while empty (thresh 0 = bits off)",
        pempty_f1 === 1'b0);

    // 空读: underflow 应指示
    @(negedge clk100); rd_en_f1 = 1'b1;
    @(negedge clk100); rd_en_f1 = 1'b0;
    repeat (3) @(posedge clk100); #1.0;
    chk("underflow asserted on read-while-empty", unf_seen_f1 === 1'b1);

    //---- 复位窗口内写入 (上游没有等 rst_busy) 的行为 ----
    // XPM 内部写门控 = wr_en & ~(wrst_busy|rst_d1), 与 wr_rst_busy 同项,
    // 所以这些写会被静默丢弃 (overflow 指示), 指针/标志不会乱。
    rst_f1 = 1'b1;
    repeat (2) @(posedge clk100);
    chk("rst_busy=1 while reset asserted", wrbusy_f1 === 1'b1);
    for (int i = 0; i < 4; i++) begin
      @(negedge clk100); wr_en_f1 = 1'b1; din_f1 = 8'hA0 + i[7:0];
    end
    @(negedge clk100); wr_en_f1 = 1'b0;
    repeat (2) @(posedge clk100); #1.0;
    chk("write during rst_busy: overflow indicates the drop",
        ovf_busy_seen_f1 === 1'b1);

    rst_f1 = 1'b0;
    busy_cyc = 0;
    while (wrbusy_f1) begin @(posedge clk100); busy_cyc++; end
    $display("    MEASURE sync: rst_busy held %0d clk after reset deassert (risk window)",
             busy_cyc);
    repeat (2) @(posedge clk100); #1.0;
    chk("no state corruption: empty=1, count=0 after reset window",
        empty_f1 === 1'b1 && cnt_f1 === 5'd0);

    // 复位后正常写读 4 个字, 数据完好 (证明 FIFO 没有"失控")
    for (int i = 0; i < 4; i++) begin
      @(negedge clk100); wr_en_f1 = 1'b1; din_f1 = 8'h50 + i[7:0];
    end
    @(negedge clk100); wr_en_f1 = 1'b0;
    repeat (2) @(posedge clk100); #1.0;
    chk_eq("count=4 after post-reset writes", cnt_f1, 4);
    for (int i = 0; i < 4; i++) begin
      @(negedge clk100); rd_en_f1 = 1'b1;
      @(posedge clk100); #1.0;
      chk_eq($sformatf("post-reset read data[%0d]", i), dout_f1, 8'h50 + i[7:0]);
    end
    @(negedge clk100); rd_en_f1 = 1'b0;
    repeat (2) @(posedge clk100); #1.0;
    chk("post-reset drain empty", empty_f1 === 1'b1);

    //-----------------------------------------------------------
    $display("[5] xpm_sync_fifo fwft mode (show-ahead)");
    //-----------------------------------------------------------
    wr_en_f2 = 1'b0; rd_en_f2 = 1'b0; rst_f2 = 1'b1;
    repeat (5) @(posedge clk100);
    rst_f2 = 1'b0;
    wait (!wrbusy_f2);
    repeat (2) @(posedge clk100);

    // 写 4 个字, 不发 rd_en: dout 应已指向第一个字
    for (int i = 0; i < 4; i++) begin
      @(negedge clk100);
      wr_en_f2 = 1'b1; din_f2 = i[7:0];
    end
    @(negedge clk100); wr_en_f2 = 1'b0;
    repeat (3) @(posedge clk100); #1.0;
    chk_eq("fwft show-ahead: dout=0 before any rd_en", dout_f2, 8'h00);
    chk("fwft show-ahead: empty=0", empty_f2 === 1'b0);
    chk("fwft show-ahead: valid=1", valid_f2 === 1'b1);

    for (int i = 0; i < 4; i++) begin
      repeat (2) @(negedge clk100);
      chk_eq($sformatf("fwft data[%0d] (pre-fetched)", i), dout_f2, i[7:0]);
      rd_en_f2 = 1'b1;
      @(negedge clk100); rd_en_f2 = 1'b0;
    end
    repeat (4) @(posedge clk100); #1.0;
    chk("fwft empty=1 after drain", empty_f2 === 1'b1);

    //-----------------------------------------------------------
    $display("[6] xpm_async_fifo (wr 100M / rd 57M)");
    //-----------------------------------------------------------
    wr_en_f3 = 1'b0; rd_en_f3 = 1'b0; rst_f3 = 1'b1;
    repeat (6) @(posedge clk100);
    rst_f3 = 1'b0;
    wait (!wrbusy_f3);
    wait (!rdbusy_f3);
    repeat (4) @(posedge clk57); #1.0;
    chk("async16 after reset: empty=1", empty_f3 === 1'b1);

    // 写直到 full, 记录被接受的写次数
    accepted16 = 0;
    for (int i = 0; i < 40; i++) begin
      @(negedge clk100);
      if (full_f3 === 1'b1) break;
      wr_en_f3 = 1'b1; din_f3 = 8'h80 + i[7:0];
      accepted16++;
    end
    @(negedge clk100); wr_en_f3 = 1'b0;
    repeat (2) @(posedge clk100); #1.0;
    chk("async16 full=1 after fill", full_f3 === 1'b1);
    chk("async16 almost_full=1 when full", afull_f3 === 1'b1);

    // 等 CDC 同步后从读侧读空, 统计实际读出的字数
    repeat (12) @(posedge clk57); #1.0;
    chk("async16 read side sees data (empty=0)", empty_f3 === 1'b0);
    $display("    MEASURE async16: accepted=%0d wr_count=%0d rd_count=%0d",
             accepted16, wcnt_f3, rcnt_f3);

    words16 = 0;
    for (int i = 0; i < 40; i++) begin
      @(negedge clk57);
      if (empty_f3 === 1'b1) break;
      rd_en_f3 = 1'b1;
      @(posedge clk57); #1.0;
      chk_eq($sformatf("async16 read data[%0d]", i), dout_f3, 8'h80 + i[7:0]);
      words16++;
    end
    @(negedge clk57); rd_en_f3 = 1'b0;
    repeat (4) @(posedge clk57); #1.0;
    chk("async16 empty=1 after drain", empty_f3 === 1'b1);
    chk("async16 almost_empty=1 while empty", aempty_f3 === 1'b1);
    chk_eq("async16 words read back == accepted", words16, accepted16);

    // 1ns 复位脉冲 (落在 100M 时钟沿之间, 靠复位桥的异步置位捕获)
    @(posedge clk100); #2.0;
    rst_f3 = 1'b1;
    #1.0; rst_f3 = 1'b0;
    @(posedge clk100); #1.0;
    chk("async16 1ns reset pulse captured (wr_rst_busy=1)", wrbusy_f3 === 1'b1);
    wait (!wrbusy_f3);
    wait (!rdbusy_f3);
    repeat (2) @(posedge clk57); #1.0;
    chk("async16 usable after short reset pulse", empty_f3 === 1'b1);

    //---- 复位窗口内写入: 异步 FIFO 同样被内部写门控丢弃, 复位后两域都可用 ----
    rst_f3 = 1'b1;
    repeat (4) @(posedge clk100);
    for (int i = 0; i < 4; i++) begin
      @(negedge clk100); wr_en_f3 = 1'b1; din_f3 = 8'hC0 + i[7:0];
    end
    @(negedge clk100); wr_en_f3 = 1'b0;
    #1.0;
    chk("async16 wr_rst_busy=1 during reset-window writes", wrbusy_f3 === 1'b1);

    rst_f3 = 1'b0;
    busy_cyc = 0;
    while (wrbusy_f3) begin @(posedge clk100); busy_cyc++; end
    $display("    MEASURE async16: wr_rst_busy held %0d wr_clk after reset deassert",
             busy_cyc);
    wait (!rdbusy_f3);
    repeat (10) @(posedge clk57); #1.0;
    chk("async16 reset-window writes dropped (rd_count=0, empty=1)",
        rcnt_f3 === 5'd0 && empty_f3 === 1'b1);

    // 复位后写 4 个读 4 个, 数据完好
    for (int i = 0; i < 4; i++) begin
      @(negedge clk100); wr_en_f3 = 1'b1; din_f3 = 8'h70 + i[7:0];
    end
    @(negedge clk100); wr_en_f3 = 1'b0;
    repeat (12) @(posedge clk57); #1.0;
    chk("async16 usable after reset-window writes (empty=0)", empty_f3 === 1'b0);
    for (int i = 0; i < 4; i++) begin
      @(negedge clk57); rd_en_f3 = 1'b1;
      @(posedge clk57); #1.0;
      chk_eq($sformatf("async16 post-reset read data[%0d]", i), dout_f3, 8'h70 + i[7:0]);
    end
    @(negedge clk57); rd_en_f3 = 1'b0;
    repeat (4) @(posedge clk57); #1.0;
    chk("async16 post-reset drain empty", empty_f3 === 1'b1);

    //-----------------------------------------------------------
    $display("[7] xpm_async_fifo DEPTH=32 (effective depth rule)");
    //-----------------------------------------------------------
    wr_en_f4 = 1'b0; rd_en_f4 = 1'b0; rst_f4 = 1'b1;
    repeat (6) @(posedge clk100);
    rst_f4 = 1'b0;
    wait (!wrbusy_f4);
    wait (!rdbusy_f4);
    repeat (4) @(posedge clk57); #1.0;

    accepted32 = 0;
    for (int i = 0; i < 80; i++) begin
      @(negedge clk100);
      if (full_f4 === 1'b1) break;
      wr_en_f4 = 1'b1; din_f4 = i[7:0];
      accepted32++;
    end
    @(negedge clk100); wr_en_f4 = 1'b0;
    repeat (2) @(posedge clk100); #1.0;
    chk("async32 full=1 after fill", full_f4 === 1'b1);
    $display("    MEASURE async32: accepted=%0d (nominal depth 32)", accepted32);
    chk_eq("async32 effective depth == DEPTH-1", accepted32, 31);

    //-----------------------------------------------------------
    $display("[8] rst_busy semantics (power-up / no ext reset / stopped clock)");
    //-----------------------------------------------------------
    chk("t=0 before 1st clock edge: busy=0 (FF init, reset has NOT started)",
        s_busy_at0 === 1'b0 && a_busy_at0 === 1'b0);
    chk("no ext reset: sync busy asserts within 1 clk", s_assert_edges <= 1);
    chk("no ext reset: async busy asserts within 2 clk", a_assert_edges <= 2);
    chk("power-on reset self-holds busy several clk",
        s_width_edges >= 3 && a_width_edges >= 3);
    $display("    MEASURE power-on (no ext rst): sync busy after %0d clk, width %0d clk | async after %0d clk, width %0d clk",
             s_assert_edges, s_width_edges, a_assert_edges, a_width_edges);

    // 时钟停住: busy 是同步信号, 复位拉高也不会动
    clk_gate_en = 1'b0;
    #20.0;
    rst_f5 = 1'b1;
    #60.0;
    chk("stopped clock: rst asserted but busy stays 0 (needs clock edges)",
        wbusy_f5 === 1'b0);

    clk_gate_en = 1'b1;
    @(posedge clk_g); #1.0;
    chk("clock resumed: busy asserts at the 1st edge", wbusy_f5 === 1'b1);

    // 释放复位后该实例正常工作
    rst_f5 = 1'b0;
    busy_cyc = 0;
    while (wbusy_f5) begin @(posedge clk_g); busy_cyc++; end
    for (int i = 0; i < 4; i++) begin
      @(negedge clk_g); wr_en_f5 = 1'b1; din_f5 = 8'hE0 + i[7:0];
    end
    @(negedge clk_g); wr_en_f5 = 1'b0;
    repeat (2) @(posedge clk_g); #1.0;
    chk_eq("no-ext-reset instance works after gated-clock reset (count=4)", wcnt_f5, 4);
    for (int i = 0; i < 4; i++) begin
      @(negedge clk_g); rd_en_f5 = 1'b1;
      @(posedge clk_g); #1.0;
      chk_eq($sformatf("no-ext-reset instance read[%0d]", i), dout_f5, 8'hE0 + i[7:0]);
    end
    @(negedge clk_g); rd_en_f5 = 1'b0;

    //-----------------------------------------------------------
    $display("[9] prog_full / prog_empty watermarks (PF=8, PE=4)");
    //-----------------------------------------------------------
    //---- 同步 FIFO: 边界即参数值 (std 等宽无 THRESH_ADJ) ----
    wr_en_f7 = 1'b0; rd_en_f7 = 1'b0; rst_f7 = 1'b1;
    repeat (5) @(posedge clk100);
    rst_f7 = 1'b0;
    wait (!wrbusy_f7);
    repeat (2) @(posedge clk100); #1.0;
    chk("prog: empty fifo -> prog_empty=1 (occ 0 <= 4)", pempty_f7 === 1'b1);
    chk("prog: empty fifo -> prog_full=0",              pfull_f7  === 1'b0);

    for (int i = 0; i < 16; i++) begin
      @(negedge clk100);
      wr_en_f7 = 1'b1; din_f7 = 8'h20 + i[7:0];
      // i 轮下降沿时已接受 i 个字 (与 [4] 的采样约定一致);
      // prog 标志滞后 1 拍, 本拍看到的是 i-1
      if (i == 7) chk("prog_full=0 when 7 words in", pfull_f7 === 1'b0);
      if (i == 8) chk("prog_full still 0 at 8 in (flag lags 1 clk)",
                      pfull_f7 === 1'b0);
      if (i == 9) chk("prog_full=1 at 9 in (saw 8>=8 one clk late)",
                      pfull_f7 === 1'b1);
    end
    @(negedge clk100); wr_en_f7 = 1'b0;
    repeat (2) @(posedge clk100); #1.0;
    chk("prog_full stays 1 when full (16 in)",
        pfull_f7 === 1'b1 && full_f7 === 1'b1);

    for (int i = 0; i < 16; i++) begin
      @(negedge clk100);
      rd_en_f7 = 1'b1;
      @(posedge clk100); #1.0;
      // 已读出 i+1 个, 剩 15-i 个; prog 标志滞后 1 拍, 看到的是 16-i
      if (i == 7)  chk("prog_full=1 when 8 words left (lag sees 9)",
                       pfull_f7 === 1'b1);
      if (i == 8)  chk("prog_full=1 when 7 words left (lag sees 8)",
                       pfull_f7 === 1'b1);
      if (i == 9)  chk("prog_full=0 when 6 words left (lag sees 7)",
                       pfull_f7 === 1'b0);
      if (i == 11) chk("prog_empty=0 when 4 words left (lag sees 5)",
                       pempty_f7 === 1'b0);
      if (i == 12) chk("prog_empty=1 when 3 words left (lag sees 4)",
                       pempty_f7 === 1'b1);
    end
    @(negedge clk100); rd_en_f7 = 1'b0;
    repeat (2) @(posedge clk100); #1.0;
    chk("prog_empty stays 1 when empty",
        pempty_f7 === 1'b1 && empty_f7 === 1'b1);

    //---- 异步 FIFO: 水线比较用同步后的对侧指针, 边界同参数值 ----
    wr_en_f8 = 1'b0; rd_en_f8 = 1'b0; rst_f8 = 1'b1;
    repeat (6) @(posedge clk100);
    rst_f8 = 1'b0;
    wait (!wrbusy_f8);
    wait (!rdbusy_f8);
    repeat (4) @(posedge clk57); #1.0;
    chk("async prog: empty -> prog_empty=1", pempty_f8 === 1'b1);

    for (int i = 0; i < 40; i++) begin
      @(negedge clk100);
      if (full_f8 === 1'b1) break;
      wr_en_f8 = 1'b1; din_f8 = 8'h40 + i[7:0];
      if (i == 8) chk("async prog_full still 0 at 8 in (lags 1 wr_clk)",
                      pfull_f8 === 1'b0);
      if (i == 9) chk("async prog_full=1 at 9 in", pfull_f8 === 1'b1);
    end
    @(negedge clk100); wr_en_f8 = 1'b0;
    repeat (2) @(posedge clk100); #1.0;
    chk("async prog_full=1 when full (15 in)", pfull_f8 === 1'b1);

    repeat (12) @(posedge clk57); #1.0;   // 等指针 CDC 收敛再读
    for (int i = 0; i < 40; i++) begin
      @(negedge clk57);
      if (empty_f8 === 1'b1) break;
      rd_en_f8 = 1'b1;
      @(posedge clk57); #1.0;
      // 已读 i+1 个, 剩 14-i 个; prog 滞后 1 拍看到 15-i
      if (i == 10) chk("async prog_empty still 0 at 4 left (lags 1 rd_clk)",
                       pempty_f8 === 1'b0);
      if (i == 11) chk("async prog_empty=1 at 3 left (lag sees 4)",
                       pempty_f8 === 1'b1);
    end
    @(negedge clk57); rd_en_f8 = 1'b0;
    repeat (4) @(posedge clk57); #1.0;
    chk("async prog_empty stays 1 when empty",
        pempty_f8 === 1'b1 && empty_f8 === 1'b1);

    //-----------------------------------------------------------
    $display("=== RESULT: %0d checks, %0d failures ===", checks, errors);
    if (errors == 0) $display("=== ALL PASS ===");
    else             $display("=== FAILED ===");
    $finish;
  end

  // 超时保护
  initial begin
    #300000;
    $display("=== TIMEOUT ===");
    $finish;
  end

endmodule