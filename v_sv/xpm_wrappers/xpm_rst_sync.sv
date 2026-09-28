//=============================================================================
// xpm_rst_sync.sv -- 复位跨时钟域同步 / 复位桥 (Xilinx XPM 薄封装)
//
// 内部实现: xpm_cdc_async_rst (RST_ACTIVE_HIGH=1)
//
// 语义 (标准 reset bridge):
//   src_rst 一拉高, dest_rst 立即异步置位 (不依赖 dest_clk, 组合路径);
//   src_rst 撤销后, dest_rst 在 dest_clk 上同步撤销 (STAGES 拍后)。
//   因此 dest_rst 是目标域的标准复位: 异步置位 / 同步释放,
//   不会有"复位撤销沿落在时钟沿附近"的 recovery 问题。
//
// 端口:
//   src_rst   源复位 (极性由 RST_ACTIVE_HIGH 决定, 默认高有效)。
//             任意宽度 (含远窄于目标周期的异步脉冲) 都会被捕获。
//   dest_clk  目标时钟
//   dest_rst  目标域复位, 异步置位 / 同步释放, 极性同 src_rst
//
// 参数:
//   STAGES   目标域同步级数 (DEST_SYNC_FF), 合法 2..10, 默认 2
//   RST_ACTIVE_HIGH 复位极性: 1 (默认) = 高有效; 0 = 低有效 (src_rst/dest_rst
//            都变低有效, 直接接工程的 rst_n)
//
// 说明:
//   - 本库统一采用"高有效复位"风格 (与 XPM FIFO 的 rst 极性一致)。
//     工程用低有效 rst_n 时, 在 wrapper 外取反, 或直接例化
//     xpm_cdc_async_rst 并把 RST_ACTIVE_HIGH 置 0。
//   - 上电初值: dest_rst = 0 (未复位), 直到 src_rst 拉高。
//     若需要"上电即处于复位态", 让 src_rst 在上电阶段保持高电平
//     (例如接 MMCM locked 的取反 / 上电计数器)。
//   - 不要用本模块同步一个"每个周期都在变"的普通信号 -- 它只适用于复位。
//
// 例化示例:
//   // 全局复位进 100M 域
//   xpm_rst_sync #(.STAGES(2)) u_rst_100m (
//       .src_rst  (global_rst),
//       .dest_clk (clk_100m),
//       .dest_rst (rst_100m));
//
// 参考: UG974 / UG953 XPM_CDC_ASYNC_RST;
//       <Vivado>/data/ip/xpm/xpm_cdc/hdl/xpm_cdc.sv
//=============================================================================

`timescale 1ns / 1ps

module xpm_rst_sync #(
  parameter int unsigned STAGES          = 2,
  parameter bit          RST_ACTIVE_HIGH = 1'b1
) (
  input  logic src_rst,
  input  logic dest_clk,
  output logic dest_rst
);

  xpm_cdc_async_rst #(
    .DEST_SYNC_FF    (STAGES),
    .INIT_SYNC_FF    (0),
    .RST_ACTIVE_HIGH (RST_ACTIVE_HIGH)
  ) u_cdc_async_rst (
    .src_arst  (src_rst),
    .dest_clk  (dest_clk),
    .dest_arst (dest_rst)
  );

endmodule