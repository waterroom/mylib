//=============================================================================
// xpm_sync_fifo.sv -- 同步 FIFO (Xilinx XPM 薄封装, 单时钟)
//
// 内部实现: xpm_fifo_sync (+ xpm_cdc_async_rst 做复位整理)
//
// 设计意图 (为什么包这一层):
//   - 固定一套常用配置和端口命名, 器件代际 / Vivado 版本带来的参数差异只
//     改这一个文件;
//   - USE_ADV_FEATURES 位映射在 XPM 里是"暗知识"(见下), 这里固化正确值,
//     避免 count / valid / almost 标志被静默关掉后读到常数 0。
//
// 端口:
//   clk            时钟
//   rst            复位, 高有效。异步置位、同步释放, 任意宽度脉冲都会被捕获;
//                  释放后 rst_busy 还要保持几拍, 期间写入被内部屏蔽、empty=1。
//   wr_en, din     写使能 / 写数据 (full 时写被忽略, 不报错)
//   full           满 (写不进)
//   almost_full    "接近满"标志, 比 full 早 1 个写入量置起 (实测见 README)
//   count          当前占用量 (写域视角, 宽度 CNT_W)。注意有 ±1 拍的寄存器
//                  时序差, 不要拿它当精确流控阈值 -- 流控用 full/almost_full。
//   overflow       写满还写时的溢出指示 (1 拍脉冲, 便于排查协议 bug)
//   rst_busy       复位进行中 (xpm_fifo_sync 内部 wr_rst_busy == rd_rst_busy,
//                  所以只引出这一个)
//   rd_en          读使能 (empty 时读被忽略, 不报错)
//   dout           读数据
//   empty          空 (读不出)
//   almost_empty   "接近空"标志
//   valid          读数据有效 (std 模式: rd_en 后 READ_LATENCY 拍; fwft 模式:
//                  dout 有数据即有效)。把 dout 打拍使用时用 valid 判断。
//   underflow      读空还读时的下溢指示 (1 拍脉冲)
//
// 参数:
//   DW           数据宽度, 默认 8
//   DEPTH        深度, 必须是 2 的幂且 >= 16 (XPM 硬性要求, 非法值会被
//                XPM 的 DRC 直接报 $error), 默认 16
//   READ_MODE    "std"  = 标准模式, 读延迟 READ_LATENCY 拍;
//                "fwft" = first-word-fall-through (show-ahead),
//                         数据先出现在 dout 上, rd_en 取走, empty 低即有数据。
//                默认 "std"
//   READ_LATENCY 仅 READ_MODE="std" 时生效的输出寄存级数 (>=1, 默认 1);
//                "fwft" 时 XPM 内部固定按 2 拍处理, 本参数被忽略
//   MEM_TYPE     FIFO_MEMORY_TYPE: "auto" (默认, 由工具选) / "block"(BRAM) /
//                "distributed"(LUTRAM) / "uram"(UltraRAM, 仅 UltraScale+)
//   CNT_W        count 位宽, 由 DEPTH 自动推导 (clog2(DEPTH)+1), 请勿覆盖
//
// 复位与初值:
//   rst 由 xpm_cdc_async_rst 整理过: 外部异步短脉冲也能捕获, 撤销与 clk 同步。
//   rst_busy 期间写会被 XPM 内部静默丢弃 (内部写门控与 wr_rst_busy 同项),
//   读被 empty=1 屏蔽 —— FIFO 不会失控, 但数据会丢。所以上游逻辑的复位应保持
//   到 rst_busy 撤销再开始写 (1 行 OR 门控的写法见 README 的
//   "复位释放与能不能马上写")。
//   上电初值: DOUT_RESET_VALUE="0", 标志位复位值 FULL_RESET_VALUE=0。
//
// 已固化的 XPM 配置 (改动前请先读 XPM 源码):
//   USE_ADV_FEATURES = "1D0D", 即只开本 wrapper 引出的高级标志:
//     [0]=overflow  [2]=wr_data_count  [3]=almost_full        写侧
//     [8]=underflow [10]=rd_data_count [11]=almost_empty
//     [12]=data_valid                                         读侧
//   (位定义见 <Vivado>/data/ip/xpm/xpm_fifo/hdl/xpm_fifo.sv 第 208~218 行;
//    默认值 "0707" 并不包含 almost_full / almost_empty / data_valid,
//    网上照抄的 "0707" 会让这些输出恒为 0。)
//   prog_full / prog_empty 未开 (会引入阈值合法范围检查), 需要时打开
//   bit1/bit9 并同时设置 PROG_FULL_THRESH / PROG_EMPTY_THRESH 合法值。
//
// 例化示例:
//   xpm_sync_fifo #(.DW(32), .DEPTH(512), .READ_MODE("fwft")) u_fifo (
//       .clk(clk100), .rst(rst100),
//       .wr_en(wr_en), .din(data_in),  .full(), .almost_full(), .count(),
//       .overflow(), .rst_busy(),
//       .rd_en(rd_en), .dout(data_out), .empty(), .almost_empty(),
//       .valid(), .underflow());
//
// 参考: UG974 / UG953 XPM_FIFO_SYNC;
//       <Vivado>/data/ip/xpm/xpm_fifo/hdl/xpm_fifo.sv (参数合法范围以源码 DRC 为准)
//=============================================================================

`timescale 1ns / 1ps

module xpm_sync_fifo #(
  parameter int unsigned DW            = 8,
  parameter int unsigned DEPTH         = 16,
  parameter string       READ_MODE     = "std",
  parameter int unsigned READ_LATENCY  = 1,
  parameter string       MEM_TYPE      = "auto",
  parameter int unsigned CNT_W         = $clog2(DEPTH) + 1
) (
  input  logic             clk,
  input  logic             rst,

  input  logic             wr_en,
  input  logic [DW-1:0]    din,
  output logic             full,
  output logic             almost_full,
  output logic [CNT_W-1:0] count,
  output logic             overflow,
  output logic             rst_busy,

  input  logic             rd_en,
  output logic [DW-1:0]    dout,
  output logic             empty,
  output logic             almost_empty,
  output logic             valid,
  output logic             underflow
);

  // 复位桥: 异步置位 / 同步释放 / 保证 >= 2 个 clk 的复位宽度。
  // xpm_fifo_sync 的 rst 是在 clk 上升沿采样进内部复位序列机的,
  // 窄脉冲会被漏掉, 所以统一在 wrapper 里过一级桥。
  logic rst_sync;

  xpm_cdc_async_rst #(
    .DEST_SYNC_FF    (2),
    .INIT_SYNC_FF    (0),
    .RST_ACTIVE_HIGH (1)
  ) u_rst_bridge (
    .src_arst  (rst),
    .dest_clk  (clk),
    .dest_arst (rst_sync)
  );

  xpm_fifo_sync #(
    .FIFO_MEMORY_TYPE    (MEM_TYPE),
    .ECC_MODE            ("no_ecc"),
    .FIFO_WRITE_DEPTH    (DEPTH),
    .WRITE_DATA_WIDTH    (DW),
    .WR_DATA_COUNT_WIDTH (CNT_W),
    .FULL_RESET_VALUE    (0),
    .USE_ADV_FEATURES    ("1D0D"),
    .READ_MODE           (READ_MODE),
    .FIFO_READ_LATENCY   (READ_LATENCY),
    .READ_DATA_WIDTH     (DW),
    .RD_DATA_COUNT_WIDTH (CNT_W),
    .DOUT_RESET_VALUE    ("0"),
    .WAKEUP_TIME         (0)
  ) u_xpm_fifo_sync (
    .sleep         (1'b0),
    .rst           (rst_sync),

    .wr_clk        (clk),
    .wr_en         (wr_en),
    .din           (din),
    .full          (full),
    .prog_full     (),                 // 未启用 (USE_ADV_FEATURES[1]=0)
    .wr_data_count (count),
    .overflow      (overflow),
    .wr_rst_busy   (rst_busy),
    .almost_full   (almost_full),
    .wr_ack        (),                 // 未启用 (USE_ADV_FEATURES[4]=0)

    .rd_en         (rd_en),
    .dout          (dout),
    .empty         (empty),
    .prog_empty    (),                 // 未启用 (USE_ADV_FEATURES[9]=0)
    .rd_data_count (),
    .underflow     (underflow),
    .rd_rst_busy   (),                 // 同步 FIFO 内部 == wr_rst_busy
    .almost_empty  (almost_empty),
    .data_valid    (valid),

    .injectsbiterr (1'b0),             // ECC_MODE="no_ecc", 不使用
    .injectdbiterr (1'b0),
    .sbiterr       (),
    .dbiterr       ()
  );

endmodule