//=============================================================================
// dsp_cic_decim.sv -- CIC 抽取滤波器 (参数化 N/R, Hogenauer 结构)
//
// 结构: N 级积分器 (输入率, in_valid 门控) -> R 倍抽取 -> N 级梳状差分
//       (输出率) -> 输出舍入。M (差分延迟) 固定 1。
//
// 关键性质:
//   - DC 增益恰为 1 (R 为 2 的幂时增益 2^G, G = N*log2(R), 输出右移 G 位
//     正好抵消): 直流输入 A, 稳态输出 = A, 免标定;
//   - 零点在 f = k*f_s/R (k = 1..R-1): 抽取混叠落在零点上, 免抗混叠;
//   - 位增长 G bit: 内部宽度 WI = B_IN + N*log2(R), 无损无溢出;
//   - 免乘法 (纯加法/移位), 综合不占 DSP48。
//
// 端口:
//   clk       时钟
//   rst       高有效同步清零 (integrator/comb 状态与计数器); 可接常 0
//             (CIC 状态模 2^WI 自然回绕, 数学上无需复位, 只为仿真清 X)
//   in_valid  输入有效门控 (恒 1 = 自由流)
//   in_data   [B_IN-1:0] 输入
//   out_valid 输出有效, 每 R 个输入样一个
//   out_data  [B_OUT-1:0] 输出, DC 增益 1 (稳态 out == in)
//
// 参数:
//   N      级数, 1..8, 默认 3 (阻带衰减与通带 droop 都随 N 增)
//   R      抽取比, 2 的幂, 2..2^16, 默认 64
//   B_IN   输入位宽, 4..32, 默认 16
//   B_OUT  输出位宽, 1..48 且 <= B_IN + N*log2(R), 默认 16;
//          B_OUT = B_IN 时 DC 增益 1; > B_IN 保留 G 位内的小数信息
//   ROUND  1 (默认) = 输出 round half up; 0 = 截断 (向 -inf, 有负偏)
//
// 时序: 延迟 = R + N + 2 拍 (R 拍聚满第一个窗 + 积分链可见 + comb N 级 +
//       输出寄存)。out_valid 与 out_data 同拍。
//
// 参考: ADI hdl library/util_cic (cic_int/cic_comb 的分段共享加法器结构
//       为多通道复用特化, 本模块用全速标准结构换清晰性); Hogenauer,
//       "Economical Class of Digital Filters for Decimation and Interpolation"。
//=============================================================================

`timescale 1ns / 1ps

module dsp_cic_decim #(
  parameter int unsigned N     = 3,
  parameter int unsigned R     = 64,
  parameter int unsigned B_IN  = 16,
  parameter int unsigned B_OUT = 16,
  parameter bit          ROUND = 1'b1
) (
  input  logic                     clk,
  input  logic                     rst,
  input  logic                     in_valid,
  input  logic signed [B_IN-1:0]   in_data,
  output logic                     out_valid,
  output logic signed [B_OUT-1:0]  out_data
);

  //--------------------------------------------------------------------------
  // 预检
  //--------------------------------------------------------------------------
  localparam int LG = $clog2(R);          // log2(R)
  localparam int G  = N * LG;             // 位增长 (M=1)
  localparam int WI = B_IN + G;           // 内部宽度

  initial begin
    if (N < 1 || N > 8)
      $error("dsp_cic_decim: N=%0d 超出 1..8", N);
    if (R < 2 || (R & (R - 1)) != 0)
      $error("dsp_cic_decim: R=%0d 不是 2 的幂 (M=1 时增益 2^G 才能被右移整除, 免标定)", R);
    if (B_IN < 4 || B_IN > 32)
      $error("dsp_cic_decim: B_IN=%0d 超出 4..32", B_IN);
    if (B_OUT < 1 || B_OUT > WI)
      $error("dsp_cic_decim: B_OUT=%0d 超出 1..%0d (B_IN + N*log2(R))", B_OUT, WI);
    if (WI > 48)
      $error("dsp_cic_decim: 内部宽度 WI=%0d 超出 48 (B_IN+G 过大), 降 N/R 或 B_IN", WI);
  end

  //--------------------------------------------------------------------------
  // 输入侧: N 级积分器 (全速, in_valid 门控) + 抽取计数
  //--------------------------------------------------------------------------
  logic signed [WI-1:0] acc [0:N-1];
  logic [15:0]          cnt;
  logic                 sample;             // 本拍为第 R 个输入样

  always_ff @(posedge clk) begin
    if (rst) begin
      cnt <= '0;
      for (int i = 0; i < N; i++) acc[i] <= '0;
    end else if (in_valid) begin
      cnt    <= (cnt == R - 1) ? '0 : cnt + 1'b1;
      acc[0] <= acc[0] + in_data;
      for (int i = 1; i < N; i++) acc[i] <= acc[i] + acc[i-1];
    end
  end
  assign sample = in_valid && (cnt == R - 1);

  //--------------------------------------------------------------------------
  // 输出侧: 采样寄存 + N 级梳状差分 (输出率, 每输出样一次)
  //--------------------------------------------------------------------------
  logic signed [WI-1:0] c   [0:N];          // c[0] = 采样进来的积分链末端
  logic signed [WI-1:0] prv [0:N-1];        // 各级上一输出样的值
  logic                 vv  [0:N+1];

  always_ff @(posedge clk) begin
    if (rst) begin
      c[0]  <= '0;
      vv[0] <= 1'b0;
    end else if (sample) begin
      c[0]  <= acc[N-1];      // 采样拍锁存积分链末端 (否则 c[0] 每拍跟随,
      vv[0] <= 1'b1;          //  comb 窗被采样后的 acc 污染, 实测窗非整)
    end else begin
      vv[0] <= 1'b0;
    end
  end

  for (genvar g = 0; g < N; g++) begin : g_comb
    always_ff @(posedge clk) begin
      if (rst) begin
        c[g+1]  <= '0;
        prv[g]  <= '0;
        vv[g+1] <= 1'b0;
      end else if (vv[g]) begin
        c[g+1]  <= c[g] - prv[g];
        prv[g]  <= c[g];
        vv[g+1] <= vv[g];
      end else begin
        vv[g+1] <= 1'b0;
      end
    end
  end

  // 输出: 右移 G 位归一化 (DC 增益 1), 可选舍入
  logic signed [WI-1:0] sout;
  generate
    if (ROUND) begin : g_rnd
      assign sout = (c[N] + (signed'(1) <<< (G - 1))) >>> G;
    end
    else begin : g_tru
      assign sout = c[N] >>> G;
    end
  endgenerate

  always_ff @(posedge clk) begin
    if (rst) begin
      out_valid <= 1'b0;
      out_data  <= '0;
    end else begin
      out_valid <= vv[N];
      out_data  <= sout[B_OUT-1:0];
    end
  end

endmodule
