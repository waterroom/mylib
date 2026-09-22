//=============================================================================
// xpm_pulse_sync.sv -- 单周期脉冲/事件跨时钟域 (Xilinx XPM 薄封装)
//
// 内部实现: xpm_cdc_pulse + 两个 xpm_cdc_async_rst (复位桥)
//
// 原理: 源域检测 src_pulse 上升沿并翻转一个电平, 该电平经同步器送到目标域
//       后做边沿检测, 得到目标域的单周期脉冲。因此不要求脉冲"足够宽才能被
//       目标时钟采到", 但要求脉冲之间有间隔 (见下面的约束)。
//
// 端口:
//   src_clk     源时钟
//   src_rst     源域复位, 高有效 (任意宽度)
//   src_pulse   源域脉冲, 高有效, 至少持续 1 个 src_clk 周期
//   dest_clk    目标时钟
//   dest_rst    目标域复位, 高有效 (任意宽度)
//   dest_pulse  目标域单周期脉冲, 高有效
//
// 参数:
//   STAGES         同步级数 (DEST_SYNC_FF), 合法 2..10, 默认 2
//   REG_OUT        1 = dest_pulse 在目标域再打一拍 (REG_OUTPUT=1)。
//                  dest_pulse 扇出大 / 目标时钟高时建议置 1 改善时序,
//                  代价是脉冲推迟 1 拍。默认 0。
//   SIM_ASSERT_CHK 1 = 打开 XPM 自带仿真断言 (会检查复位期间脉冲变化), 默认 0
//
// 使用约束:
//   - 相邻 src_pulse 的间隔必须 > STAGES+2 个 dest_clk 周期 (保守取值),
//     否则两次翻转在目标域被合并成一个脉冲 -- 表现是"丢脉冲"。
//     源域脉冲密于目标域周期时, 请改用 xpm_async_fifo 计数传递事件。
//   - src_rst / dest_rst 在脉冲传输过程中拉高可能丢脉冲;
//     本 wrapper 内部已把两域复位经复位桥整理成"异步置位/同步释放",
//     直接接外部异步短脉冲不会漏采 (xpm_cdc_pulse 原语的 rst 是同步采样)。
//   - 本库统一高有效复位。
//
// 例化示例:
//   // 100M 域的一个单周期事件, 送到 250M 域
//   xpm_pulse_sync u_evt_sync (
//       .src_clk (clk_100m), .src_rst (rst_100m), .src_pulse (evt_100m),
//       .dest_clk(clk_250m), .dest_rst(rst_250m), .dest_pulse(evt_250m));
//
// 参考: UG974 / UG953 XPM_CDC_PULSE;
//       <Vivado>/data/ip/xpm/xpm_cdc/hdl/xpm_cdc.sv
//=============================================================================

`timescale 1ns / 1ps

module xpm_pulse_sync #(
  parameter int unsigned STAGES         = 2,
  parameter bit          REG_OUT        = 1'b0,
  parameter bit          SIM_ASSERT_CHK = 1'b0
) (
  input  logic src_clk,
  input  logic src_rst,
  input  logic src_pulse,
  input  logic dest_clk,
  input  logic dest_rst,
  output logic dest_pulse
);

  // xpm_cdc_pulse 的 src_rst/dest_rst 是同步复位 (内部用 XPM_XSRREG,
  // 只在 clk 上升沿采样), 因此先各过一级复位桥,
  // 保证任意宽度的外部复位脉冲都被捕获且撤销与各自时钟同步。
  logic src_rst_sync;
  logic dest_rst_sync;

  xpm_cdc_async_rst #(
    .DEST_SYNC_FF    (2),
    .INIT_SYNC_FF    (0),
    .RST_ACTIVE_HIGH (1)
  ) u_src_rst_bridge (
    .src_arst  (src_rst),
    .dest_clk  (src_clk),
    .dest_arst (src_rst_sync)
  );

  xpm_cdc_async_rst #(
    .DEST_SYNC_FF    (2),
    .INIT_SYNC_FF    (0),
    .RST_ACTIVE_HIGH (1)
  ) u_dest_rst_bridge (
    .src_arst  (dest_rst),
    .dest_clk  (dest_clk),
    .dest_arst (dest_rst_sync)
  );

  xpm_cdc_pulse #(
    .DEST_SYNC_FF   (STAGES),
    .INIT_SYNC_FF   (0),
    .REG_OUTPUT     (REG_OUT),
    .RST_USED       (1),
    .SIM_ASSERT_CHK (SIM_ASSERT_CHK)
  ) u_cdc_pulse (
    .src_clk    (src_clk),
    .src_pulse  (src_pulse),
    .src_rst    (src_rst_sync),
    .dest_clk   (dest_clk),
    .dest_rst   (dest_rst_sync),
    .dest_pulse (dest_pulse)
  );

endmodule