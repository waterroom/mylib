//=============================================================================
// xpm_cdc_sync.sv -- 单 bit / 向量电平跨时钟同步 (Xilinx XPM 薄封装)
//
// 内部实现 (Vivado 自带 XPM 库, 无需额外源文件):
//   W == 1 : xpm_cdc_single
//   W  > 1 : xpm_cdc_array_single
//
// 用途: 慢变电平信号跨时钟域 -- 配置位、状态位、使能、锁定标志等。
//       每 bit 独立打拍同步; 不做握手、不做格雷码。因此:
//       - 被同步信号的变化间隔必须 >= 目标域同步级数 + 1 个目标周期,
//         否则目标域可能采不到 (信号太窄) 或采到中间态;
//       - 多 bit 总线各 bit 不同步到达, 目标域可能短暂出现中间值。
//         所以只适合"最终会稳定"的电平量; 要多 bit 无中间态,
//         用 xpm_async_fifo 或握手类宏。
//
// 端口:
//   src_clk   源时钟 (REG_SRC=0 且源信号本身是寄存器输出时, 可接 dest_clk)
//   src_in    源域信号 [W-1:0]
//   dest_clk  目标时钟
//   dest_out  目标域同步输出, 延迟 STAGES 个 dest_clk 周期
//
// 参数:
//   W              位宽, 1..1024, 默认 1
//   STAGES         目标域同步级数 (DEST_SYNC_FF), 合法 2..10, 默认 2
//   REG_SRC        1 = 源域先打一拍 (SRC_INPUT_REG=1)。源信号是组合逻辑
//                  时必须为 1; 源信号已是寄存器输出时可设 0 省一级寄存器。
//   SIM_ASSERT_CHK 1 = 打开 XPM 自带仿真断言, 默认 0
//
// 说明:
//   - 默认 STAGES=2 满足绝大多数设计; 目标时钟频率很高 (>300MHz)、
//     寄存器扇出大或使用 7 系列老器件时建议 3~4 (MTBF 与时钟频率、
//     器件工艺相关, 量化方法见 UG974 / UG953)。
//   - 该宏没有复位端口: 上电后 dest_out 初值由 GSR / FF INIT 决定 (默认 0),
//     复位期间不要依赖它的值。
//   - 若需要"源域同步复位 -> 目标域复位", 用 xpm_rst_sync。
//
// 例化示例:
//   xpm_cdc_sync #(.W(1), .STAGES(2)) u_locked_sync (
//       .src_clk  (clk_mmcm),
//       .src_in   (mmcm_locked),
//       .dest_clk (clk_100m),
//       .dest_out (locked_100m));
//
// 参考: UG974 (UltraScale 库指南) / UG953 (7 系列库指南) XPM_CDC_SINGLE,
//       XPM_CDC_ARRAY_SINGLE; 参数合法性以下载安装目录中的 XPM 源码为准:
//       <Vivado>/data/ip/xpm/xpm_cdc/hdl/xpm_cdc.sv
//=============================================================================

`timescale 1ns / 1ps

module xpm_cdc_sync #(
  parameter int unsigned W              = 1,
  parameter int unsigned STAGES         = 2,
  parameter bit          REG_SRC        = 1'b1,
  parameter bit          SIM_ASSERT_CHK = 1'b0
) (
  input  logic         src_clk,
  input  logic [W-1:0] src_in,
  input  logic         dest_clk,
  output logic [W-1:0] dest_out
);

  generate
    if (W == 1) begin : g_bit
      xpm_cdc_single #(
        .DEST_SYNC_FF   (STAGES),
        .INIT_SYNC_FF   (0),
        .SIM_ASSERT_CHK (SIM_ASSERT_CHK),
        .SRC_INPUT_REG  (REG_SRC)
      ) u_cdc_single (
        .src_clk  (src_clk),
        .src_in   (src_in[0]),
        .dest_clk (dest_clk),
        .dest_out (dest_out[0])
      );
    end
    else begin : g_bus
      xpm_cdc_array_single #(
        .DEST_SYNC_FF   (STAGES),
        .INIT_SYNC_FF   (0),
        .SIM_ASSERT_CHK (SIM_ASSERT_CHK),
        .SRC_INPUT_REG  (REG_SRC),
        .WIDTH          (W)
      ) u_cdc_array_single (
        .src_clk  (src_clk),
        .src_in   (src_in),
        .dest_clk (dest_clk),
        .dest_out (dest_out)
      );
    end
  endgenerate

endmodule