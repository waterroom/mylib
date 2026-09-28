//=============================================================================
// xpm_handshake.sv -- 多 bit 数据握手跨时钟域 (Xilinx XPM 薄封装)
//
// 内部实现: xpm_cdc_handshake (DEST_EXT_HSK=0, 目的端自动应答)
//
// 用途: 低频多 bit 数据跨时钟域 (寄存器值、配置字、事件伴随数据)。
//       比挂异步 FIFO 轻; 比电平同步 (xpm_cdc_sync) 多了无中间态保证。
//       高吞吐数据流不要用 (一次握手跨两域往返, 每笔好几拍), 用
//       xpm_async_fifo。
//
// 协议 (本层已固化 DEST_EXT_HSK=0, 目的端无需任何握手逻辑):
//   源端:   src_data 放好 -> src_send 置高并**保持** -> src_rcv 高 (目的端
//           已接收) -> src_send 撤低, 等 src_rcv 撤低后可发下一笔
//   目的端: dest_req 上升沿当拍采样 dest_data (req 与数据同沿更新,
//           实测确认); req 撤销 = 本笔完成
//   约束:   src_send 高期间 src_data 必须保持不变 (数据路径无同步链,
//           目的域直接采样源域寄存器, 稳定性靠握手保证)
//
//   !! src_send 千万不要打单拍脉冲: 它直接进电平同步器
//   (src_sendd_nxt = src_send, 无延长逻辑), 脉冲窄于目的域采样窗口会被
//   整笔漏掉且不报任何错 -- 必须电平式保持到 src_rcv 返回。
//
// 端口:
//   src_clk    源时钟
//   src_data   源数据 [WIDTH-1:0], src_rcv 返回前保持稳定
//   src_send   源发送, 高有效**电平**: 置高后保持, src_rcv 高才允许撤低;
//              撤低并等 src_rcv 撤销后才能发下一笔 (单拍脉冲会被漏采!)
//   src_rcv    源域确认: 高 = 目的端已接收本笔, src_data 可以撤/换
//   dest_clk   目的时钟
//   dest_data  目的数据 [WIDTH-1:0], dest_req 高期间有效
//   dest_req   目的域"新数据有效"电平, 目的端当拍采样; 自动应答后撤销
//
// 参数:
//   WIDTH          数据位宽, 1..1024, 默认 8
//   STAGES         同步级数, 同时喂 DEST_SYNC_FF 与 SRC_SYNC_FF,
//                  合法 2..10, 默认 2 (库内统一; XPM 原语默认 4, 追求
//                  更高 MTBF 可加大)
//   SIM_ASSERT_CHK 1 = 打开 XPM 断言 (检查 src_send 在 src_rcv 撤销前
//                  重发等协议违规), 默认 0
//
// 说明:
//   - 原语无复位端口: 上电后 src_rcv/dest_req/dest_data 初值由 FF INIT
//     决定 (全 0, 即"无进行中的握手"), 复位期间不要依赖其值。
//   - 上电后目的端可能看到一次多余的 dest_req (源端未发过数据) 吗?
//     实测不会: 上电 req=0, 首笔 src_send 前保持 0。
//
// 例化示例:
//   // 100M 域的配置字发给 57M 域, 目的端 req 高时采样
//   xpm_handshake #(.WIDTH(32)) u_cfg_send (
//       .src_clk(clk_100m), .src_data(cfg_word), .src_send(cfg_load),
//       .src_rcv(cfg_sent),
//       .dest_clk(clk_57m), .dest_data(cfg_word_57m), .dest_req(cfg_upd_57m));
//
// 参考: UG974 / UG953 XPM_CDC_HANDSHAKE;
//       <Vivado>/data/ip/xpm/xpm_cdc/hdl/xpm_cdc.sv
//=============================================================================

`timescale 1ns / 1ps

module xpm_handshake #(
  parameter int unsigned WIDTH          = 8,
  parameter int unsigned STAGES         = 2,
  parameter bit          SIM_ASSERT_CHK = 1'b0
) (
  input  logic              src_clk,
  input  logic [WIDTH-1:0]  src_data,
  input  logic              src_send,
  output logic              src_rcv,

  input  logic              dest_clk,
  output logic [WIDTH-1:0]  dest_data,
  output logic              dest_req
);

  xpm_cdc_handshake #(
    .DEST_EXT_HSK   (0),            // 目的端自动应答, 本层固化的关键选择
    .DEST_SYNC_FF   (STAGES),
    .INIT_SYNC_FF   (0),            // 上电 req/rcv/数据 = 0 (无进行中握手)
    .SIM_ASSERT_CHK (SIM_ASSERT_CHK),
    .SRC_SYNC_FF    (STAGES),
    .WIDTH          (WIDTH)
  ) u_cdc_handshake (
    .src_clk   (src_clk),
    .src_in    (src_data),
    .src_send  (src_send),
    .src_rcv   (src_rcv),
    .dest_clk  (dest_clk),
    .dest_out  (dest_data),
    .dest_req  (dest_req),
    .dest_ack  ()                  // DEST_EXT_HSK=0, 内部自动生成
  );

endmodule
