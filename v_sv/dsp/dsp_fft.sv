//=============================================================================
// dsp_fft.sv -- N 点复数 FFT (迭代式 radix-2, in-place BRAM, 定长突发)
//
// 架构 (参照 litedsp analysis/fft_iter.py 的迭代式结构, 代码独立自写):
//   - 单个 radix-2 蝶形单元对双口 RAM 就地运算; 输入按位倒序写入 RAM
//     (DIT), log2(N) 级蝶形后自然序读出, 无需输出重排;
//   - 每帧 = N 个输入样突发 (load) -> 蝶形 (compute) -> N 个输出样
//     (unload); 与 dsp_pfir 的帧输出直接串联 (每帧 N 个信道值进, N 点
//     FFT 出);
//   - 数据 RAM 用库内 xpm_sdpram (N 深, 2*WI 位宽; 写口 A, 读口 B);
//     蝶形微序列 6 拍: ph0 发 a 地址 / ph1 锁 a + 发 b 地址与 twiddle /
//     ph2 算 p 并写 a' / ph3 写 b' / ph4 空 / ph5 推进; 单乘法器;
//   - 无逐级缩放: 位增长 LG 位由内部宽度 WI = B+LG+1 吸收; 输出为输入
//     标度下的满精度结果 (相对 1/N 归一 DFT 放大 N 倍; 需要 1/N 标度时
//     在外层右移, 或用 B_OUT 截位)。
//
// 量化模型 (TB 位精确参考同款; Python 模型经 numpy 对拍, 误差 0.002 LSB):
//   量化 twiddle: w = Q1.(WT-1) (scale = 2^(WT-1)-1, 1.0 取饱和码),
//                 ROM 每项 e^{-j2*pi*k/N}, k = 0..N/2-1;
//   蝶形: p = round_half_up(b * w) >> (WT-1); a' = a + p; b' = a - p
//        (和按 WI 位回绕; WI = B+LG+1 足够无溢出)。
//
// 端口:
//   clk, rst           高有效同步复位
//   in_valid/in_ready  输入握手 (load 阶段每拍收 1 个复样)
//   in_i/in_q          [B-1:0] 输入 (Q1.(B-1) 补码)
//   out_valid          输出有效 (unload 阶段每拍 1 个, 共 N 个)
//   out_frame          unload 首样标记 (与 out_valid 同拍)
//   out_i/out_q        [B_OUT-1:0] 输出 (默认 B_OUT = WI, 满精度)
//
// 参数:
//   N        点数, 2 的幂, 8..1024, 默认 64
//   B        输入位宽, 8..24, 默认 16
//   WT       twiddle 位宽, 8..24, 默认 16
//   B_OUT    输出位宽, 4..WI, 默认 WI; 小于 WI 时输出饱和
//   TW_FILE  twiddle ROM 文件 ($readmemh, N/2 行, "cos sin" 各 WT/4 位
//            十六进制; 由 sim/gen_coef_fft.py 生成)
//   MEM_TYPE 数据 RAM 类型, 默认 "block"
//
// 时序: 每帧 = N (load) + 6*(N/2)*log2(N) (compute) + N+1 (unload) 拍;
//       N=64 约 900 拍/帧 (后 CIC/PFB 场景余量充足)。
//
// 例化示例:
//   dsp_fft #(.N(64), .B(16), .WT(16), .TW_FILE("coef_fft_64_w16.mem")) u_fft (
//       .clk(clk), .rst(rst),
//       .in_valid(pfir_valid), .in_ready(fft_ready),
//       .in_i(pfir_dout), .in_q(16'sd0),
//       .out_valid(fft_vld), .out_frame(fft_frame),
//       .out_i(bin_i), .out_q(bin_q));
//
// 参考: litedsp (BSD-2-Clause, enjoy-digital) 迭代式 FFT 结构; 本模块为
//       独立自写实现, 验证 = TB 位精确对拍 + Python 模型 numpy 交叉验证。
//=============================================================================

`timescale 1ns / 1ps

module dsp_fft #(
  parameter int unsigned N        = 64,
  parameter int unsigned B        = 16,
  parameter int unsigned WT       = 16,
  parameter int unsigned B_OUT    = B + $clog2(N) + 1,
  parameter string       TW_FILE  = "",
  // 注意: MEM_TYPE 不能声明 string -- 它透传给 XPM 的 MEMORY_PRIMITIVE,
  // 显式 string 类型会让综合器在 xpm_memory 的映射比较处报
  // "expression must be of a packed type" (同库事实 #11, 第三次踩中)
  parameter              MEM_TYPE = "block"
) (
  input  logic                    clk,
  input  logic                    rst,
  input  logic                    in_valid,
  output logic                    in_ready,
  input  logic signed [B-1:0]     in_i,
  input  logic signed [B-1:0]     in_q,
  output logic                    out_valid,
  output logic                    out_frame,
  output logic signed [B_OUT-1:0] out_i,
  output logic signed [B_OUT-1:0] out_q
);

  //--------------------------------------------------------------------------
  // 预检与常量
  //--------------------------------------------------------------------------
  localparam int LG = $clog2(N);
  localparam int WI = B + LG + 1;          // 内部宽度 (位增长 + 裕量)

  initial begin
    if (N < 8 || N > 1024 || (N & (N - 1)) != 0)
      $error("dsp_fft: N=%0d 不是 2 的幂或超出 8..1024", N);
    if (B < 8 || B > 24)
      $error("dsp_fft: B=%0d 超出 8..24", B);
    if (WT < 8 || WT > 24)
      $error("dsp_fft: WT=%0d 超出 8..24", WT);
    if (WI > 32)
      $error("dsp_fft: 内部宽度 WI=%0d 超出 32 (B+log2(N)+1 过大)", WI);
    if (B_OUT < 4 || B_OUT > WI)
      $error("dsp_fft: B_OUT=%0d 超出 4..%0d", B_OUT, WI);
  end

  //--------------------------------------------------------------------------
  // twiddle ROM (N/2 项, 每项 {cos[WT], sin[WT]})
  //--------------------------------------------------------------------------
  logic [2*WT-1:0] tw_rom [0:N/2-1];
  initial begin
    for (int i = 0; i < N/2; i++) tw_rom[i] = '0;
    if (TW_FILE != "") $readmemh(TW_FILE, tw_rom);
  end

  //--------------------------------------------------------------------------
  // 数据 RAM (库内 xpm_sdpram: 写口 A, 读口 B)
  //--------------------------------------------------------------------------
  logic [LG-1:0]   ram_waddr, ram_raddr;
  logic            ram_we;
  logic [2*WI-1:0] ram_din, ram_dout;
  logic signed [WI-1:0] rd_i, rd_q;        // 读口数据 (ph1: mem[aa], ph2: mem[bb])
  assign rd_i = signed'(ram_dout[2*WI-1:WI]);
  assign rd_q = signed'(ram_dout[WI-1:0]);


  xpm_sdpram #(
    .MEM_TYPE  (MEM_TYPE),
    .DW_A      (2*WI),
    .DW_B      (2*WI),
    .DEPTH     (N),
    .LATENCY_B (1)
  ) u_ram (
    .clka  (clk),
    .addra (ram_waddr),
    .dina  (ram_din),
    .wea   (ram_we),
    .clkb  (clk),
    .enb   (1'b1),
    .addrb (ram_raddr),
    .doutb (ram_dout),
    .doutb_vld ()
  );

  //--------------------------------------------------------------------------
  // 主状态机
  //--------------------------------------------------------------------------
  localparam int S_LOAD = 0, S_CMP = 1, S_UNL = 2;
  logic [1:0]    st;
  logic [LG-1:0] n_in;                     // load 样计数
  logic [LG:0]   m;                        // 级 1..LG
  logic [LG-1:0] k;                        // 级内蝶形 0..N/2-1
  logic [2:0]    ph;                       // 蝶形微相位 0..5
  logic [LG-1:0] u;                        // unload 计数
  logic          unl_f;                    // unload 流水填充标记

  // 蝶形地址 (组合): g = k >> (m-1), pos = k & (half-1)
  logic [LG-1:0] half, aa, bb, twi;
  assign half = (LG'(1) << (m[LG-1:0] - 1'b1));
  assign aa   = ((k >> (m[LG-1:0] - 1'b1)) << m[LG-1:0]) + (k & (half - 1'b1));
  assign bb   = aa + half;
  assign twi  = (k & (half - 1'b1)) << (LG - m);

  //--------------------------------------------------------------------------
  // 蝶形数据通路 (全 signed 独立表达式, 规避含 '0 三元的无符号陷阱)
  //--------------------------------------------------------------------------
  logic [LG-1:0] tw_rd;                    // 组合 ROM 读地址
  assign tw_rd = (st == S_CMP) ? twi : '0;
  logic signed [WT-1:0] wc, ws;
  assign wc = signed'(tw_rom[tw_rd][2*WT-1:WT]);
  assign ws = signed'(tw_rom[tw_rd][WT-1:0]);

  logic signed [WI-1:0] ra_i, ra_q, p_r_i, p_r_q;

  logic signed [WI+WT:0] pm_i, pm_q;       // rd * w (含裕量)
  logic signed [WI+2:0]  p_i, p_q;         // 舍入后乘积
  logic signed [WI+2:0]  a_i_c, a_q_c, b_i_c, b_q_c;

  assign pm_i = rd_i * wc - rd_q * ws;
  assign pm_q = rd_i * ws + rd_q * wc;
  assign p_i  = (pm_i + signed'(1 <<< (WT - 2))) >>> (WT - 1);
  assign p_q  = (pm_q + signed'(1 <<< (WT - 2))) >>> (WT - 1);
  assign a_i_c = ra_i + p_i;               // a' (ph2 组合)
  assign a_q_c = ra_q + p_q;
  assign b_i_c = ra_i - p_r_i;             // b' (ph3 组合, 复用寄存的 p)
  assign b_q_c = ra_q - p_r_q;


  // 读地址 (组合): compute ph0 = aa, ph1.. = bb; unload: u+1 先行
  //   (sdpram 读延迟 1: 本拍地址 -> 下一拍数据)
  always_comb begin
    if (st == S_CMP)
      ram_raddr = (ph == 3'd0) ? aa : bb;
    else if (st == S_UNL)
      ram_raddr = unl_f ? (u + 1'b1) : '0;   // fill 拍必须读 0: u 尚是上帧
                                             // 残留值 (实测 bin0 曾读 mem[63])
    else
      ram_raddr = '0;
  end

  // 写口 (组合): load 写输入 (位倒序地址); compute ph2 写 a', ph3 写 b'
  always_comb begin
    ram_we    = 1'b0;
    ram_waddr = '0;
    ram_din   = '0;
    if (st == S_LOAD) begin
      if (in_valid) begin
        // 输入必须符号扩展到 WI 字段 (与计算阶段写的 46 位布局一致;
        // 直接写 32 位 {in_i,in_q} 会落在读窗口之外, 实测全桶出垃圾)
        ram_we    = 1'b1;
        ram_waddr = bitrev(n_in);
        ram_din   = {{(WI-B){in_i[B-1]}}, in_i, {(WI-B){in_q[B-1]}}, in_q};
      end
    end
    else if (st == S_CMP) begin
      if (ph == 3'd2) begin
        ram_we    = 1'b1;
        ram_waddr = aa;
        ram_din   = {a_i_c[WI-1:0], a_q_c[WI-1:0]};
      end
      else if (ph == 3'd3) begin
        ram_we    = 1'b1;
        ram_waddr = bb;
        ram_din   = {b_i_c[WI-1:0], b_q_c[WI-1:0]};
      end
    end
  end

  assign in_ready = (st == S_LOAD) && !rst;


  // 位倒序 (load 写地址)
  function automatic logic [LG-1:0] bitrev(input logic [LG-1:0] kv);
    logic [LG-1:0] r;
    r = '0;
    for (int i = 0; i < LG; i++) r = {r[LG-2:0], kv[i]};
    return r;
  endfunction

  // 输出饱和 (阈值用 signed localparam: 若在函数里写 `signed'(1<<<N) - 1'b1`,
  // 无符号字面量 1'b1 会把整个比较拖成无符号 -- 负值被当大正数, 全部饱和到
  // +max (实测: DC 的负 q 桶全变 4194303); 同 PFIR MAC 的 signedness 陷阱)
  localparam logic signed [WI:0] SAT_HI = (1 <<< (B_OUT - 1)) - 1;
  localparam logic signed [WI:0] SAT_LO = -(1 <<< (B_OUT - 1));
  function automatic logic signed [B_OUT-1:0] sat_out(input logic signed [WI-1:0] v);
    if (v > SAT_HI) sat_out = SAT_HI[B_OUT-1:0];
    else if (v < SAT_LO) sat_out = SAT_LO[B_OUT-1:0];
    else sat_out = v[B_OUT-1:0];
  endfunction

  //--------------------------------------------------------------------------
  // 时序状态机
  //   load:  in_ready 下收 N 个复样
  //   cmp:   6 拍/蝶形: ph0 发 a 地址; ph1 锁 a (rd=mem[aa]);
  //          ph2 (rd=mem[bb], w 有效) 算 p 并写 a'; ph3 写 b';
  //          ph4 空; ph5 推进 k/m
  //   unl:   fill 一拍, 之后每拍输出一个 (raddr 先行一拍)
  //--------------------------------------------------------------------------
  always_ff @(posedge clk) begin
    if (rst) begin
      st <= S_LOAD; n_in <= '0; m <= '0; k <= '0; ph <= '0; u <= '0; unl_f <= 1'b0;
      ra_i <= '0; ra_q <= '0; p_r_i <= '0; p_r_q <= '0;
      out_valid <= 1'b0; out_frame <= 1'b0; out_i <= '0; out_q <= '0;
    end else begin
      out_valid <= 1'b0;
      out_frame <= 1'b0;

      unique case (st)
        S_LOAD: begin
          if (in_valid) begin
            n_in <= n_in + 1'b1;
            if (n_in == N - 1) begin
              st <= S_CMP;
              m  <= 'd1;
              k  <= '0;
              ph <= 3'd0;
            end
          end
        end
        S_CMP: begin
          case (ph)
            3'd1: begin
              ra_i <= rd_i;                // rd = mem[aa]
              ra_q <= rd_q;
              ph   <= 3'd2;
            end
            3'd2: begin
              p_r_i <= p_i;                // rd = mem[bb], w 有效; a' 写入已由写口完成
              p_r_q <= p_q;
              ph    <= 3'd3;
            end
            3'd3: ph <= 3'd4;              // b' 写入已由写口完成
            3'd4: ph <= 3'd5;
            3'd5: begin
              ph <= 3'd0;
              if (k == N/2 - 1) begin
                k <= '0;
                if (m == LG) st <= S_UNL;
                else               m <= m + 1'b1;
              end
              else begin
                k <= k + 1'b1;
              end
            end
            default: ph <= 3'd1;           // ph0: 发 a 地址 (组合读口), 推进到 ph1
          endcase
        end
        S_UNL: begin
          if (!unl_f) begin
            u     <= '0;                   // 关键: 每帧重置 (实测第二帧起沿用终值 63)
            unl_f <= 1'b1;                 // fill 拍: raddr=0 已组合发出
          end
          else begin
            out_i     <= sat_out(rd_i);
            out_q     <= sat_out(rd_q);
            out_valid <= 1'b1;
            out_frame <= (u == 0);
            if (u == N - 1) begin
              unl_f <= 1'b0;
              st    <= S_LOAD;
              n_in  <= '0;
            end
            else begin
              u <= u + 1'b1;
            end
          end
        end
      endcase
    end
  end

endmodule
