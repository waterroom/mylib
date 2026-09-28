//=============================================================================
// xpm_sync_rst.sv -- 同步复位同步器 (Xilinx XPM 薄封装)
//
// 内部实现: xpm_cdc_sync_rst (INIT=INIT_SYNC_FF 绑定)
//
// 与 xpm_rst_sync (复位桥) 的对照 -- 两者名字只差词序, 用前看清:
//   ----------------+--------------------------------+--------------------------
//                   | xpm_rst_sync (复位桥)          | xpm_sync_rst (本模块)
//   ----------------+--------------------------------+--------------------------
//   内部原语        | xpm_cdc_async_rst              | xpm_cdc_sync_rst
//   置位方式        | 异步置位 (不依赖 dest_clk,     | 同步置位 (src_rst 被
//                   | 任意窄脉冲都能捕获)            | dest_clk 采样, 需保持
//                   |                                | >=1 个 dest 周期)
//   释放方式        | 同步释放                       | 同步释放
//   上电初值        | dest_rst=0 (不在复位态!),      | INIT=1 (默认) 时
//                   | 要上电即复位需让 src_rst       | dest_rst=1, 上电即处于
//                   | 先保持高                       | 复位态, 无需外部配合
//   src_rst 可以是  | 任意异步电平/窄脉冲            | 相对 dest_clk 的电平量
//   ----------------+--------------------------------+--------------------------
//
// 用途: src_rst 本身就是 dest_clk 域 (或已同步) 的电平复位, 需要上电默认
//       复位、或需要比异步桥更"干净"的全同步复位时序时用它。
//       窄于 1 个 dest 周期的异步脉冲会漏采 -- 那种场景用 xpm_rst_sync。
//
// 端口:
//   src_rst   源复位, 高有效, 电平量 (置位保持 >= 1 个 dest_clk 周期)
//   dest_clk  目标时钟
//   dest_rst  目标复位, 高有效, 置位/释放都与 dest_clk 同步,
//             上电初值 = INIT (默认 1 = 上电即复位)
//
// 参数:
//   STAGES         同步级数 (DEST_SYNC_FF), 合法 2..10, 默认 2
//   INIT           上电初值: 1 (默认) = 上电即处于复位态; 0 = 上电不复位。
//                  注意 XPM 里 INIT 只在 INIT_SYNC_FF=1 时生效, 本 wrapper
//                  已把两者绑定为同一个值。
//   RST_ACTIVE_HIGH 复位极性: 1 (默认) = 高有效; 0 = 低有效 (src_rst/dest_rst
//                  都变低有效)。XPM 原语只有高有效, 低有效由本层在两侧
//                  取反实现 (纯组合, 无 CDC 影响); INIT 的语义不变
//                  (上电即处于复位态 = 低有效输出上电为 0)。
//   SIM_ASSERT_CHK 1 = 打开 XPM 的采样稳定性断言 (src_rst 需稳定 >=2 拍),
//                  排查复位采样问题时打开, 默认 0
//
// 例化示例:
//   // 100M 域内已同步的软复位, 进 57M 域, 上电即复位
//   xpm_sync_rst #(.STAGES(2), .INIT(1'b1)) u_rst_57m (
//       .src_rst (soft_rst_100m),   // 电平量, 与 57M 域无相对时序要求即可
//       .dest_clk(clk_57m),
//       .dest_rst(rst_57m));
//
// 参考: UG974 / UG953 XPM_CDC_SYNC_RST;
//       <Vivado>/data/ip/xpm/xpm_cdc/hdl/xpm_cdc.sv
//=============================================================================

`timescale 1ns / 1ps

module xpm_sync_rst #(
  parameter int unsigned STAGES         = 2,
  parameter bit          INIT           = 1'b1,
  parameter bit          RST_ACTIVE_HIGH = 1'b1,
  parameter bit          SIM_ASSERT_CHK = 1'b0
) (
  input  logic src_rst,
  input  logic dest_clk,
  output logic dest_rst
);

  logic src_rst_h;      // 原语内部只认高有效
  logic dest_rst_h;

  xpm_cdc_sync_rst #(
    .DEST_SYNC_FF   (STAGES),
    .INIT           (INIT),
    .INIT_SYNC_FF   (INIT),      // XPM 源码: 仅 =1 时同步链初值取 INIT, =0 恒 0
    .SIM_ASSERT_CHK (SIM_ASSERT_CHK)
  ) u_cdc_sync_rst (
    .src_rst  (src_rst_h),
    .dest_clk (dest_clk),
    .dest_rst (dest_rst_h)
  );

  assign src_rst_h  = RST_ACTIVE_HIGH ? src_rst   : ~src_rst;
  assign dest_rst   = RST_ACTIVE_HIGH ? dest_rst_h : ~dest_rst_h;

endmodule
