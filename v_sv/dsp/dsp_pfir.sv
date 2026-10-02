//=============================================================================
// dsp_pfir.sv -- 多相滤波器组 FIR (PFB 信道化的滤波级)
//
// 功能: 原型低通 h[0..N*K-1] 的多相实现。全率输入流按信道分发到 N 个
//       相位支路, 每支路 K 抽头; 每输入 N 个样输出一帧 N 个信道值
//       (即原型 FIR 输出按 N 抽取后的 N 个相位)。
//
// 数学定义 (对拍参考同款):
//   y_full[n] = sum_j h[j] * x[n-j]          (全率原型 FIR)
//   y_p[m]    = y_full[m*N + p]              (抽取 N, 信道 p = 0..N-1)
//   多相恒等: y_p[m] = sum_r h[p + r*N] * x[(m-r)*N + p]
//
// 结构:
//   - 循环缓冲 RAM (深度 (K+1)*N, 多留一帧防读写冲突, 见下): 写口 A
//     每输入样写入; 读口 B 由 MAC 引擎按斜步进地址读;
//   - MAC 引擎: 1 个乘法器, 每拍 1 tap (RAM 读延迟 1 由流水吸收),
//     系数 ROM 按 h[p + r*N] 斜读 (地址步进 N);
//   - 每帧计算量 N*K 个 tap, 需约 2*N*K 拍 -- 输入率须 <= clk/(2*K)
//     (后 CIC 场景恒满足); 计算与输入流水重叠 (双口 RAM);
//   - RAM 深度余量推导: 计算窗 = [w-N*K, w-1] (w = 写指针), 写覆盖
//     [w, w+N) -- 深 (K+1)*N 时两者不相交; 深 K*N 会在全速输入时
//     覆盖计算未读的最老样。
//
// 端口:
//   clk, rst      高有效同步清零
//   in_valid      输入有效门控
//   in_data       [B_IN-1:0] 输入
//   out_valid     每信道一个脉冲, 顺序 p = 0..N-1 连续成帧
//   out_data      [B_OUT-1:0] 信道值
//   out_frame     帧首 (p == 0) 标记, 与该信道 out_valid 同拍
//
// 参数:
//   N          信道数/相位数, 2 的幂, 4..1024, 默认 64 (FFT 点数对齐)
//   K          每相位抽头数, 2..64, 默认 8 (原型 = N*K 抽头)
//   B_IN       输入位宽, 4..32, 默认 16
//   B_CO       系数位宽 (Q1.(B_CO-1) 有符号), 8..24, 默认 16
//   B_OUT      输出位宽, 默认 16 (饱和到 +-2^(B_OUT-1)-1)
//   ROUND      1 (默认) = round half up; 0 = 截断
//   COEF_FILE  系数 hex 文件 ($readmemh, N*K 项, Q1.(B_CO-1) 补码);
//              空串 = 全 0 系数 (仅占位, 须提供实际系数才有意义)
//
// 系数约定: 原型低通的 DC 增益建议归一到 2^(B_CO-1) (即 sum(h) =
//   2^(B_CO-1)), 此时 DC 输入下稳态 out == in (matlab/+dsp/ 脚本生成)。
//
// 参考: ADI hdl fir_decim (时分复用乘法器); benreynwar/fpga-sdrlib
//       channelizer (filterbank + dit 分层确认); hogenauer 多相结构。
//=============================================================================

`timescale 1ns / 1ps

module dsp_pfir #(
  parameter int unsigned N         = 64,
  parameter int unsigned K         = 8,
  parameter int unsigned B_IN      = 16,
  parameter int unsigned B_CO      = 16,
  parameter int unsigned B_OUT     = 16,
  parameter bit          ROUND     = 1'b1,
  parameter string       COEF_FILE = ""
) (
  input  logic                     clk,
  input  logic                     rst,
  input  logic                     in_valid,
  input  logic signed [B_IN-1:0]   in_data,
  output logic                     out_valid,
  output logic signed [B_OUT-1:0]  out_data,
  output logic                     out_frame
);

  //--------------------------------------------------------------------------
  // 预检
  //--------------------------------------------------------------------------
  localparam int DEP = 1 << $clog2((K + 1) * N);  // RAM 深度: (K+1)*N 上取整到 2 的幂
  localparam int AW  = $clog2(DEP);
  localparam int LG  = $clog2(N);
  localparam int MACW = B_CO + B_IN + $clog2(K) + 1;   // MAC 累加器宽

  initial begin
    if (N < 4 || N > 1024 || (N & (N - 1)) != 0)
      $error("dsp_pfir: N=%0d 不是 2 的幂或超出 4..1024", N);
    if (K < 2 || K > 64)
      $error("dsp_pfir: K=%0d 超出 2..64", K);
    if (B_IN < 4 || B_IN > 32)
      $error("dsp_pfir: B_IN=%0d 超出 4..32", B_IN);
    if (B_CO < 8 || B_CO > 24)
      $error("dsp_pfir: B_CO=%0d 超出 8..24", B_CO);
    if (B_OUT < 4 || B_OUT > MACW)
      $error("dsp_pfir: B_OUT=%0d 超出 4..%0d", B_OUT, MACW);
  end

  //--------------------------------------------------------------------------
  // 系数 ROM (h[0..N*K-1], Q1.(B_CO-1) 补码, $readmemh 加载)
  //--------------------------------------------------------------------------
  logic signed [B_CO-1:0] coef_rom [0:N*K-1];
  initial begin
    for (int i = 0; i < N * K; i++) coef_rom[i] = '0;
    if (COEF_FILE != "") $readmemh(COEF_FILE, coef_rom);
  end

  //--------------------------------------------------------------------------
  // 循环缓冲 RAM (xpm_sdpram, 库内复用): 写口 A = 输入样, 读口 B = 计算
  //--------------------------------------------------------------------------
  logic [AW-1:0] waddr;
  logic [AW-1:0] raddr;
  logic          ram_we;
  logic signed [B_IN-1:0] ram_q;

  xpm_sdpram #(
    .MEM_TYPE   ("distributed"),
    .RD_MODE_B  ("read_first"),   // distributed 仅支持 read_first (事实 #14)
    .DW_A       (B_IN),
    .DW_B       (B_IN),
    .DEPTH      (DEP),
    .LATENCY_B  (1)
  ) u_buf (
    .clka  (clk),
    .addra (waddr),
    .dina  (in_data),
    .wea   (ram_we),
    .clkb  (clk),
    .enb   (1'b1),
    .addrb (raddr),
    .doutb (ram_q),
    .doutb_vld ()
  );

  //--------------------------------------------------------------------------
  // 控制状态机: IDLE (收 N 个样) <-> RUN (N*K 个 tap, 每拍 1 个)
  // tap 全序 g = p*K + r (p = 信道, r = 抽头), 用 ch/tap 联合计数。
  // 流水 (每 tap 1 拍吞吐):
  //   沿 t:   raddr <= addr(g); coef_r1 <= coef(g); macen1 <= 1
  //   RAM 内部: 沿 t+1 采样, 沿 t+2 ram_q = data(g)
  //   沿 t+1: coef_r2 <= coef_r1; macen2 <= macen1
  //   沿 t+2: acc <= acc + coef_r2 * ram_q (macen2 门控) = MAC(g)
  // 输出: branch p 的最后 tap (g = p*K+K-1) MAC 完成后 2 拍寄存输出
  //   (done_p1/p2/p3 三级链对齐流水)。
  //--------------------------------------------------------------------------
  localparam int S_IDLE = 0, S_RUN = 1;
  logic          st;
  logic [LG-1:0]  collect;      // 帧内输入样计数 (0..N-1)
  logic [AW-1:0]  wpos;         // 写指针 (DEP 循环)
  logic [$clog2(N)-1:0] ch;     // 计算信道序号 p
  logic [$clog2(K+1)-1:0] slot; // 支路内 slot 0..K-1 = 抽头, K = 空拍
  logic [AW-1:0]  w_end;        // 帧末写指针快照
  logic signed [B_CO-1:0] coef_r1, coef_r2;
  logic          macen1, macen2;
  logic          done_p1, done_p2, done_p3;
  logic          first_p1, first_p2, first_p3;
  logic signed [MACW-1:0] acc;
  logic signed [MACW-1:0] sout;
  // 乘法必须在"全 signed 操作数"的独立表达式里完成: 若直接写进含无类型
  // '0 的三元, Verilog 按无符号求值整个表达式, 负数系数被当无符号数
  // (-6 -> 65530), 乘积错成 2.1e9 (实测踩中, 经典 signedness 陷阱)
  logic signed [MACW-1:0] prod;
  assign prod = coef_r2 * ram_q;
  // 输出标定: 累加器含 2^(B_CO-1) 系数标定, 右移 (舍入) 恢复码值
  always_comb sout = ROUND ? ((acc + (signed'(1) <<< (B_CO - 2))) >>> (B_CO - 1))
                           : (acc >>> (B_CO - 1));

  // 写指针 / 帧计数 (输入侧, 与计算流水重叠)
  always_ff @(posedge clk) begin
    if (rst) begin
      wpos <= '0;
      collect <= '0;
    end else if (in_valid) begin
      wpos <= (wpos == DEP - 1) ? '0 : wpos + 1'b1;
      collect <= (collect == N - 1) ? '0 : collect + 1'b1;
    end
  end

  assign ram_we = in_valid & ~rst;
  assign waddr = wpos;

  // 读地址 (组合, 由状态机在 address 拍寄存进 raddr):
  //   addr(p, r) = w_end - N + p - r*N (mod DEP)
  // w_end = 帧末写指针快照 (= 最新样的下一位置)
  logic [AW+2:0] a_t;
  always_comb a_t = w_end + DEP * 2 + ch - N - (slot * N);

  // 主状态机 + MAC 流水
  // 流水语义 (每 tap 1 拍吞吐):
  //   沿 T:   raddr <= addr(g); coef_r1 <= coef(g); macen1 <= 1
  //   RAM:    沿 T+1 采样, 沿 T+2 ram_q = data(g)
  //   沿 T+2: acc <= acc + coef_r2 * ram_q   (= MAC(g), macen2 门控)
  //   支路 p 末 tap g=pK+K-1 的 MAC 在 T_p+2 完成 (T_p = 该 tap 的发出沿),
  //   输出捕获在 T_p+3 (acc 已含支路和, done 四级链对齐)。
  // 块间: 数据连续突发 (每帧 N 样后需 >= N*K 拍间隙, 见模块头)。
  always_ff @(posedge clk) begin
    if (rst) begin
      st <= S_IDLE;
      ch <= '0;
      slot <= '0;
      w_end <= '0;
      acc <= '0;
      coef_r1 <= '0;
      coef_r2 <= '0;
      macen1 <= 1'b0;
      macen2 <= 1'b0;
      done_p1 <= 1'b0;
      done_p2 <= 1'b0;
      done_p3 <= 1'b0;
      first_p1 <= 1'b0;
      first_p2 <= 1'b0;
      first_p3 <= 1'b0;
      out_valid <= 1'b0;
      out_data <= '0;
      out_frame <= 1'b0;
      raddr <= '0;
    end else begin
      // 默认 (脉冲类信号必须每拍默认清零: 闲置槽置 1 后若无默认清零会
      // 保持整支路高电平, 输出每拍重复, 实测)
      out_valid <= 1'b0;
      out_frame <= 1'b0;
      done_p1   <= 1'b0;
      first_p1  <= 1'b0;

      unique case (st)
        S_IDLE: begin
          macen1 <= 1'b0;               // 关键: 排空后必须清零, 否则虚假累加
          // 帧边界: 第 N 个输入样拍 (collect == N-1)
          if (in_valid && collect == N - 1) begin
            w_end <= wpos + 1'b1;       // 该拍 wpos NBA 后 = 最新样的下一位置
            ch <= '0;
            slot <= '0;
            acc <= '0;                  // 上一帧排空早已完成 (间隙 >= N*K 拍)
            coef_r1 <= '0;
            coef_r2 <= '0;
            macen2 <= 1'b0;
                  st <= S_RUN;
          end
        end
        S_RUN: begin
          if (slot == K) begin
            // 空拍 = 零系数虚拟取指: 保持取指/使能相位连续 (末 tap 的 MAC
            // 在其 +2 拍仍要发生), 且下一支路首拍前的悬空 MAC 乘积恒 0
            coef_r1 <= '0;
            macen1  <= 1'b1;
            done_p1 <= 1'b1;
            first_p1 <= (ch == 0);
            slot    <= '0;
            if (ch == N - 1) st <= S_IDLE;
            else             ch <= ch + 1'b1;
          end else begin
            // 发出拍: 地址 / 系数 / MAC 使能
            raddr   <= a_t[AW-1:0];
            coef_r1 <= coef_rom[slot * N + ch];   // h[p + r*N]: r 步进 N, p 步进 1
            macen1  <= 1'b1;
            slot    <= slot + 1'b1;
          end
        end
      endcase

      // MAC 硬件移出 case: 排空期 (末支路切回 IDLE 后的 1 拍) 仍须执行末
      // tap 的 MAC。两级使能链对齐两条数据路径 (addr→ram_q 与 coef→coef_r2
      // 均为 2 寄存器), 用 macen2 门控; 三级会错过全部 MAC (实测)。
      coef_r2 <= coef_r1;
      macen2  <= macen1;
      // 捕获拍 (done_p3) 同时把本支路和清零, 下一支路首 tap 的乘积成为新和
      // 首项: 单表达式完成 (避免同沿对 acc 的双写)
      acc <= (done_p3 ? '0 : acc) + (macen2 ? prod : '0);

      // done 三级链: 空拍 (T_p+K) + 2 = 捕获拍 -- 该拍 acc 含支路完整和,
      // 且下一支路首 MAC 在 +1 拍 (无竞争); 捕获同时清零 acc
      done_p2  <= done_p1;
      done_p3  <= done_p2;
      first_p2 <= first_p1;
      first_p3 <= first_p2;
      if (done_p3) begin
        out_valid <= 1'b1;
        out_frame <= first_p3;
        if      (sout >  (1 << (B_OUT - 1)) - 1) out_data <= ((1 << (B_OUT - 1)) - 1);
        else if (sout < -(1 << (B_OUT - 1)))     out_data <= (1 << (B_OUT - 1));
        else                                     out_data <= sout[B_OUT-1:0];
      end
    end
  end

endmodule
