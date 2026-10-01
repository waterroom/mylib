//=============================================================================
// dsp_cordic.sv -- CORDIC 核 (旋转/矢量双模式, 流水线)
//
// 架构参照 ADI hdl ad_dds_sine_cordic.v (输入预旋转 + 输出零逻辑 + D 位
// 直通), 矢量模式扩展归一化与 CSD 增益补偿。本模块为独立自写实现,
// 验证走 TB 内 real-math 参考模型逐点对拍 (见 sim/tb_dsp_cordic.sv)。
//
// 模式:
//   MODE="rotate"  极坐标 -> 直角: in_phase 输出 sin/cos (NCO/DDS 核心)
//   MODE="vector"  直角 -> 极坐标: in_x/in_y 输出幅值/相位 (IFM 前置)
//
// 端口 (两种模式共用端口框架, 未用侧恒 0):
//   clk        时钟
//   in_valid   输入有效 (恒速流可恒 1)
//   in_phase   [P_DW-1:0] 无符号, [0, 2*pi) 满圆周映射, LSB = 2*pi/2^P_DW
//              (rotate 用)
//   in_x/in_y  [D_DW-1:0] Q1.(D_DW-1) 二补码 (vector 用; 全闭方形含 -FS)
//   out_valid  输出有效, 与输入逐笔对应 (FIFO 序)
//   out_sin/cos  [D_DW-1:0] Q1.(D_DW-1) (rotate); 峰值比满幅低 ~3 LSB
//              (x0 预缩防饱和, 见 X0 说明), 无饱和器
//   out_mag    [D_DW-1:0] = |v| 码值, 无符号无饱和 (vector, GAIN_COMP=1;
//              |v| 最大 sqrt2)。GAIN_COMP=0 时 = K*|v|/2 码值, |v|<=1
//   out_phase  [P_DW-1:0] 无符号 [0, 2*pi) (vector)
//
// 参数:
//   MODE      "rotate" (默认) / "vector"
//   P_DW      相位位宽, 8..32, 默认 16
//   D_DW      数据位宽, 8..32, 默认 16
//   STAGES    迭代级数, 4..32, 默认 16; 建议 STAGES >= D_DW (否则 $warning)
//   GAIN_COMP 1 (默认, 仅 vector) = 输出乘 1/K, 用 CSD 移位加实现
//             (7 个加法器, 无 DSP48); 0 = 输出 K*|v|/2, 由下游标定
//
// 量化模型 (对拍参考同款):
//   rotate: x0 = round(FS/K) - 2 (预缩 1/K + 2 LSB 防饱和余量), 峰值
//           输出比真值低 ~3 LSB (90° 处), sin/cos 误差 ±3 LSB 实测
//   vector: 输入象限折叠 (x<0 取负, 相位 +pi) + 幅度归一化 (左移到
//           MSB 就位, 移位量在输出除回), z 从 0 收敛
//
// 时序: 延迟 = STAGES + 2 拍。资源 (xczu48dr, D=S=P=16, 两模式合计):
//       ~1700 LUT / ~1300 FF / 0 DSP48 (1/K 补偿为 CSD 移位加)。
//
// 参考: ADI hdl library/common/ad_dds_sine_cordic.v / ad_dds_cordic_pipe.v;
//       Ray Andraka, "A Survey of CORDIC Algorithms for FPGA Based Computers"。
//=============================================================================

`timescale 1ns / 1ps

module dsp_cordic #(
  parameter string       MODE      = "rotate",
  parameter int unsigned P_DW      = 16,
  parameter int unsigned D_DW      = 16,
  parameter int unsigned STAGES    = 16,
  parameter bit          GAIN_COMP = 1'b1
) (
  input  logic             clk,
  input  logic             in_valid,
  input  logic [P_DW-1:0]  in_phase,
  input  logic [D_DW-1:0]  in_x,
  input  logic [D_DW-1:0]  in_y,
  output logic             out_valid,
  output logic [D_DW-1:0]  out_sin,
  output logic [D_DW-1:0]  out_cos,
  output logic [D_DW-1:0]  out_mag,
  output logic [P_DW-1:0]  out_phase
);

  //--------------------------------------------------------------------------
  // 预检
  //--------------------------------------------------------------------------
  initial begin
    if (MODE != "rotate" && MODE != "vector")
      $error("dsp_cordic: MODE=\"%s\" 不合法 (限 \"rotate\"/\"vector\")", MODE);
    if (P_DW < 8 || P_DW > 32)
      $error("dsp_cordic: P_DW=%0d 超出 8..32", P_DW);
    if (D_DW < 8 || D_DW > 32)
      $error("dsp_cordic: D_DW=%0d 超出 8..32", D_DW);
    if (STAGES < 4 || STAGES > 32)
      $error("dsp_cordic: STAGES=%0d 超出 4..32", STAGES);
    if (STAGES < D_DW)
      $warning("dsp_cordic: STAGES(%0d) < D_DW(%0d) -- 角度误差底限 ~2^-(STAGES) rad, 幅度精度受限", STAGES, D_DW);
  end

  localparam bit ROTATE = (MODE == "rotate");
  localparam int FS     = 1 << (D_DW - 1);   // 满幅 (+1.0 的标称码值)
  // vector 内部加宽 4 bit: 峰值 = K*sqrt2*FS*2^s (s = 归一化移位, 目标位
  // DWI-4 = D_DW), 峰值恒 0.58*2^(DWI-1) 与输入 MSB 无关; DWI=D+2/D+3
  // 实测在对角角点溢出
  localparam int DWI    = D_DW + 4;
  // rotate 内部相位加宽 4 bit: atan 表量化到 P_DW 时每级 ±0.5 LSB 相位
  // 误差 16 级累积成 sin/cos ±5 LSB (实测), P_DW+4 后降到 ±3 LSB
  localparam int PZ     = P_DW + 4;
  localparam int LAT    = STAGES + 2;

  //--------------------------------------------------------------------------
  // 常数
  //--------------------------------------------------------------------------
  localparam logic [31:0] ATAN32 [0:31] = '{
    32'h20000000, 32'h12E4051E, 32'h09FB385B, 32'h051111D4,
    32'h028B0D43, 32'h0145D7E1, 32'h00A2F61E, 32'h00517C55,
    32'h0028BE53, 32'h00145F2F, 32'h000A2F98, 32'h000517CC,
    32'h00028BE6, 32'h000145F3, 32'h0000A2FA, 32'h0000517D,
    32'h000028BE, 32'h0000145F, 32'h00000A30, 32'h00000518,
    32'h0000028C, 32'h00000146, 32'h000000A3, 32'h00000051,
    32'h00000029, 32'h00000014, 32'h0000000A, 32'h00000005,
    32'h00000003, 32'h00000001, 32'h00000001, 32'h00000000
  };
  localparam logic [31:0] C1K32 = 32'h4DBA76D4;  // 1/K_INF in Q1.31

  function automatic logic [PZ-1:0] a32_to_pz(input logic [31:0] v32);
    if (PZ >= 32) a32_to_pz = v32 <<< (PZ - 32);
    else          a32_to_pz = (v32 + (32'h1 << (31 - PZ))) >> (32 - PZ);
  endfunction

  function automatic logic [D_DW-1:0] c1k_to_d();
    if (D_DW >= 32) c1k_to_d = C1K32[D_DW-1:0];
    else            c1k_to_d = ((C1K32 + (32'h1 << (30 - (D_DW - 1)))) >> (31 - (D_DW - 1)));
  endfunction

  // rotate 初始向量: 预缩 1/K, 再减 2 -- K*X0 = FS-3.3 < FS-1, 免饱和器
  localparam logic [D_DW-1:0] X0 = c1k_to_d() - 2;

  //--------------------------------------------------------------------------
  // CORDIC 级 (公共宏): 统一方程 x' = x - s*(y>>>g), y' = y + s*(x>>>g),
  // z' = z - s*atan;  s = +1 当 (rotate: z>=0 / vector: y<0)
  // 移位带舍入 (round half up): 纯截断 16 级累积 ±7 LSB 输出误差 (实测)
  //--------------------------------------------------------------------------
  generate
    if (ROTATE) begin : g_rot
      //--------------------------------------------------------------------
      // rotate: 数据通路 D 位 (幅度恒 ~FS, 无增长); 输入预旋转把象限折叠
      // 进初始向量, 输出直接 x=cos, y=sin, 无象限拼装
      //--------------------------------------------------------------------
      logic signed [D_DW-1:0] xr [0:STAGES];
      logic signed [D_DW-1:0] yr [0:STAGES];
      logic signed [PZ-1:0]   zr [0:STAGES];
      logic                   vv [0:STAGES];
      logic [1:0]             q;
      assign q = in_phase[P_DW-1:P_DW-2];

      // 输入预旋转 (ADI 同款): 初始向量转到象限代表轴, 相对角折叠进 z
      always_ff @(posedge clk) begin
        vv[0] <= in_valid;
        unique case (q)
          2'b01:   begin xr[0] <= '0;          yr[0] <= signed'(X0);
                         zr[0] <= signed'({2'b00, in_phase[P_DW-3:0]}) <<< (PZ - P_DW); end
          2'b10:   begin xr[0] <= '0;          yr[0] <= -signed'(X0);
                         zr[0] <= signed'({2'b11, in_phase[P_DW-3:0]}) <<< (PZ - P_DW); end
          default: begin xr[0] <= signed'(X0); yr[0] <= '0;
                         zr[0] <= signed'(in_phase) <<< (PZ - P_DW); end
        endcase
      end

      for (genvar g = 0; g < STAGES; g++) begin : g_st
        localparam logic [PZ-1:0] AV = a32_to_pz(ATAN32[g]);
        localparam int GS = (g > 0) ? g : 1;
        logic signed [D_DW-1:0] xsh, ysh, xsh_r, ysh_r;
        logic sel;
        assign xsh_r = (xr[g] + (signed'(1) <<< (GS - 1))) >>> GS;
        assign ysh_r = (yr[g] + (signed'(1) <<< (GS - 1))) >>> GS;
        assign xsh = (g == 0) ? xr[g] : xsh_r;
        assign ysh = (g == 0) ? yr[g] : ysh_r;
        assign sel = ~zr[g][PZ-1];      // z >= 0

        always_ff @(posedge clk) begin
          vv[g+1] <= vv[g];
          if (sel) begin
            xr[g+1] <= xr[g] - ysh;
            yr[g+1] <= yr[g] + xsh;
            zr[g+1] <= zr[g] - signed'(AV);
          end else begin
            xr[g+1] <= xr[g] + ysh;
            yr[g+1] <= yr[g] - xsh;
            zr[g+1] <= zr[g] + signed'(AV);
          end
        end
      end

      always_ff @(posedge clk) begin
        out_valid <= vv[STAGES];
        out_sin   <= yr[STAGES];      // 预旋转已吸收象限, 输出零逻辑
        out_cos   <= xr[STAGES];
        out_mag   <= '0;
        out_phase <= '0;
      end
    end
    else begin : g_vec
      //--------------------------------------------------------------------
      // vector: 数据通路 D+4 位 (归一化左移 + K 增长 + 对角 sqrt2);
      // 象限折叠 (x<0 取负) + 幅度归一化 (左移到 MSB 就位, 移位量输出除回);
      // 1/K 增益补偿用 CSD 移位加 (7 项, 无 DSP48)
      //--------------------------------------------------------------------
      logic signed [DWI-1:0]  xv [0:STAGES];
      logic signed [DWI-1:0]  yv [0:STAGES];
      logic signed [PZ-1:0]   zv [0:STAGES];
      logic                   vv [0:STAGES];
      logic                   xn_d [0:STAGES];
      int                     s_d [0:STAGES];

      // 折叠 + 归一化 (组合)
      logic signed [DWI-1:0] xf, yf;
      logic [DWI-1:0]        axf, ayf;
      int                    s_norm;
      function automatic int msb_pos(input logic [DWI-1:0] v);
        msb_pos = 0;
        for (int i = DWI-1; i >= 0; i--)
          if (v[i]) begin msb_pos = i; break; end
      endfunction
      assign xf  = in_x[D_DW-1] ? -signed'(in_x) : signed'(in_x);
      assign yf  = in_x[D_DW-1] ? -signed'(in_y) : signed'(in_y);
      assign axf = xf;
      assign ayf = (yf < 0) ? -yf : yf;
      always_comb begin
        s_norm = (DWI - 4) - ((msb_pos(axf) > msb_pos(ayf)) ? msb_pos(axf) : msb_pos(ayf));
        if (s_norm < 0) s_norm = 0;
      end

      always_ff @(posedge clk) begin
        vv[0]   <= in_valid;
        xn_d[0] <= in_x[D_DW-1];
        s_d[0]  <= s_norm;
        xv[0]   <= xf <<< s_norm;
        yv[0]   <= yf <<< s_norm;
        zv[0]   <= '0;
      end

      for (genvar g = 0; g < STAGES; g++) begin : g_st
        localparam logic [PZ-1:0] AV = a32_to_pz(ATAN32[g]);
        localparam int GS = (g > 0) ? g : 1;
        logic signed [DWI-1:0] xsh, ysh, xsh_r, ysh_r;
        logic sel;
        assign xsh_r = (xv[g] + (signed'(1) <<< (GS - 1))) >>> GS;
        assign ysh_r = (yv[g] + (signed'(1) <<< (GS - 1))) >>> GS;
        assign xsh = (g == 0) ? xv[g] : xsh_r;
        assign ysh = (g == 0) ? yv[g] : ysh_r;
        assign sel = yv[g][DWI-1];      // y < 0

        always_ff @(posedge clk) begin
          vv[g+1]   <= vv[g];
          xn_d[g+1] <= xn_d[g];
          s_d[g+1]  <= s_d[g];
          if (sel) begin
            xv[g+1] <= xv[g] - ysh;
            yv[g+1] <= yv[g] + xsh;
            zv[g+1] <= zv[g] - signed'(AV);
          end else begin
            xv[g+1] <= xv[g] + ysh;
            yv[g+1] <= yv[g] - xsh;
            zv[g+1] <= zv[g] + signed'(AV);
          end
        end
      end

      // 1/K 的 CSD 移位加 (逼近误差 0.036 LSB @D=16, 7 个加法器无 DSP48):
      // 1/K = 2^-1 + 2^-3 - 2^-6 - 2^-9 - 2^-12 + 2^-14 + 2^-16
      logic signed [DWI-1:0] gc0, gc1, gc2, gc3, gc4, gc5, mag_gc;
      always_comb begin
        gc0 = xv[STAGES] - (xv[STAGES] >>> 1);       // *0.5
        gc1 = gc0 + (xv[STAGES] >>> 3);              // +0.125
        gc2 = gc1 - (xv[STAGES] >>> 6);              // -0.015625
        gc3 = gc2 - (xv[STAGES] >>> 9);              // -0.001953125
        gc4 = gc3 - (xv[STAGES] >>> 12);             // -0.000244141
        gc5 = gc4 + (xv[STAGES] >>> 14);             // +0.000061035
        mag_gc = GAIN_COMP ? (gc5 + (xv[STAGES] >>> 16))   // +0.000015259
                           : xv[STAGES];
      end

      // 除回归一化移位 (带舍入); GAIN_COMP=0 再 >>1 = K*|v|/2 码值
      logic signed [DWI-1:0] mag_us;
      always_comb begin
        if (s_d[STAGES] == 0) mag_us = mag_gc;
        else mag_us = (mag_gc + (signed'(1) <<< (s_d[STAGES] - 1))) >>> s_d[STAGES];
      end

      // 相位: z 收敛到折叠后角度 (PZ 域), x<0 时 +pi; 舍入缩回 P_DW 位
      logic signed [PZ-1:0] ph_sum;
      assign ph_sum = zv[STAGES] + (xn_d[STAGES] ? (signed'(1) <<< (PZ - 1)) : '0);

      always_ff @(posedge clk) begin
        out_valid <= vv[STAGES];
        out_sin   <= '0;
        out_cos   <= '0;
        out_mag   <= GAIN_COMP ? mag_us[D_DW-1:0] : (mag_us >>> 1);
        out_phase <= ((ph_sum + (signed'(1) <<< (PZ - P_DW - 1))) >>> (PZ - P_DW));
      end
    end
  endgenerate

endmodule
