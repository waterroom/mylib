//=============================================================================
// xpm_async_fifo.sv -- 异步 FIFO (Xilinx XPM 薄封装, 双时钟/跨时钟域数据通路)
//
// 内部实现: xpm_fifo_async (+ xpm_cdc_async_rst 做复位整理)
//
// 用途: 跨时钟域的**数据**传输 (格雷码指针 + 内部 CDC, 任意多 bit 无中间态),
//       这是 CDC 场景下唯一"什么信号都能过"的通用载体。
//
// 端口:
//   写域: wr_clk, wr_en, din[DW], full, almost_full, prog_full, wr_count,
//         overflow, wr_rst_busy
//   读域: rd_clk, rd_en, dout[DW], empty, almost_empty, prog_empty, valid,
//         underflow, rd_count, rd_rst_busy
//   rst 为公共复位 (高有效), 具体语义见下。
//
// 各信号语义 (与 xpm_sync_fifo 一致, 这里只列差异):
//   wr_count / rd_count  各自时钟域视角的占用量。异步模式下指针经 CDC 同步,
//                        有 CDC_STAGES 拍的延迟: wr_count 偏大、rd_count 偏小,
//                        只适合看趋势/调试, 流控请用 full/almost_full/empty/
//                        almost_empty。变宽时 wr_count 单位是写侧字,
//                        rd_count 单位是读侧字。
//   prog_full / prog_empty  可编程水线 (PROG_*_THRESH, 0 = 不启用恒 0),
//                        语义见 xpm_sync_fifo 头部。异步模式水线比较用的对侧
//                        指针带同步延迟, 标志的置起/撤销比同步模式多
//                        CDC_STAGES 拍级别的迟滞, 提前量要按这个余量估。
//   valid                "读数据有效": std 模式为 rd_en 后 READ_LATENCY 拍;
//                        fwft 模式 dout 上有数据即有效。
//
// 有效深度 (重要):
//   异步 FIFO 的**可用深度是 DEPTH-1**, XPM 为跨时钟指针同步保留了 1 个位置
//   (本机实测: DEPTH=16 只能写进/读出 15 个, DEPTH=32 只能 31 个; 同步 FIFO
//   没有这个折损)。要"能装 N 个字"就取 DEPTH >= N+1, 工程上再留余量。
//
// 复位 (rst):
//   高有效, 单复位管两域。wrapper 内先过复位桥 (异步置位 / 同步释放,
//   保证 >=2 个 wr_clk 的宽度, 窄脉冲不漏), 再进 xpm_fifo_async;
//   XPM 内部用 wr<->rd 握手把复位同步到读域, 复位期间
//   wr_rst_busy (写域) 与 rd_rst_busy (读域) 都为高。
//   复位完成后各自域等到自己的 rst_busy 撤销**才能**开始操作: 撤销前的写会被
//   XPM 内部静默丢弃 (内部写门控与 wr_rst_busy 同项), 不会失控但会丢数据。
//   上游逻辑的复位建议保持到 wr_rst_busy 撤销 (1 行 OR 门控, 写法见 README 的
//   "复位释放与能不能马上写")。
//
// 参数:
//   DW            写侧数据宽度, 默认 8
//   RD_DW         读侧数据宽度, 默认 = DW (等宽)。变宽 (非对称位宽) 规则:
//                 宽度比限 1:1 / 2:1 / 4:1 / 8:1 及倒数 (2 的幂); 读侧深度
//                 = DEPTH*DW/RD_DW, XPM 硬性要求 >= 16; MEM_TYPE 只能
//                 "block" 或 "uram" ("auto" 只保证等宽行为; "distributed"
//                 即 LUTRAM 根本不支持变宽, XPM_MEMORY DRC 直接报错) --
//                 前两条 XPM 会报, auto/distributed 这条本 wrapper 预检
//                 直接拦下。
//                 拼包顺序: 先写入的字落在宽字低位 (小端), 实测见自检 [10]。
//                 变宽时 full/almost_full/prog_full/wr_count 单位是写侧字,
//                 empty/almost_empty/prog_empty/rd_count 单位是读侧字;
//                 有效深度 = DEPTH-1 个写侧字。
//   DEPTH         深度, 2 的幂且 >= 16, 默认 16
//   READ_MODE     "std" (默认) / "fwft"
//   READ_LATENCY  仅 std 模式生效 (默认 1); fwft 内部固定 2 拍
//   MEM_TYPE      FIFO_MEMORY_TYPE: "auto"/"block"/"distributed";
//                 "uram" 只能用于同步 FIFO (XPM 会报 DRC 错误)
//   PROG_FULL_THRESH  可编程满水线阈值, 0 = 不启用 (默认)。异步模式的合法
//                 区间下限比同步多抬 CDC_STAGES (等宽 + std + DEPTH=16 +
//                 CDC=2 时为 [5, 13]), 非法值由 XPM DRC $error 并打印合法区间。
//   PROG_EMPTY_THRESH 可编程空水线阈值, 0 = 不启用 (默认); fwft 下实际水线
//                 = 参数值 - 2 (同 xpm_sync_fifo 的 THRESH_ADJ 说明)。
//   CDC_STAGES    CDC_SYNC_STAGES, 2..8, 默认 2。深 16 的 FIFO 最大只能取 4;
//                 RELATED_CLOCKS=1 时必须保持默认 2
//   RELATED_CLOCKS 1 = 两时钟同源/频率关系确定 (工具可放宽时序), 默认 0
//   CNT_W         count 位宽, 由 DEPTH 自动推导, 请勿覆盖
//
// 已固化的 XPM 配置:
//   USE_ADV_FEATURES 由 prog 阈值参数推导: 全 0 (默认) 为 "1D0D", 开
//   prog_full / prog_empty 后为 "1D0F" / "1F0D" / "1F0F" (位定义、XPM 默认
//   "0707" 少开 almost_*/data_valid 的坑、以及"位开而阈值为 0 时 prog_empty
//   恒 1"的暗坑, 说明见 xpm_sync_fifo.sv 头部)。
//
// 命名提示:
//   官方宏名是 xpm_fifo_async, 本 wrapper 叫 xpm_async_fifo 以免与 XPM 原语
//   重名; 反过来的 xpm_sync_fifo / 官方 xpm_fifo_sync 同理。
//
// 例化示例:
//   // 采集域 250M -> 处理域 100M, 512 深, show-ahead 读
//   xpm_async_fifo #(.DW(16), .DEPTH(512), .READ_MODE("fwft")) u_cdc_fifo (
//       .wr_clk(clk250), .rst(rst), .wr_en(wr_en), .din(din),
//       .full(), .almost_full(), .wr_count(), .overflow(), .wr_rst_busy(),
//       .rd_clk(clk100), .rd_en(rd_en), .dout(dout),
//       .empty(), .almost_empty(), .valid(), .underflow(),
//       .rd_count(), .rd_rst_busy());
//
// 参考: UG974 / UG953 XPM_FIFO_ASYNC;
//       <Vivado>/data/ip/xpm/xpm_fifo/hdl/xpm_fifo.sv (参数合法范围以源码 DRC 为准)
//=============================================================================

`timescale 1ns / 1ps

module xpm_async_fifo #(
  parameter int unsigned DW             = 8,
  parameter int unsigned RD_DW          = DW,
  parameter int unsigned DEPTH          = 16,
  parameter string       READ_MODE      = "std",
  parameter int unsigned READ_LATENCY   = 1,
  parameter string       MEM_TYPE       = "auto",
  parameter int unsigned PROG_FULL_THRESH  = 0,
  parameter int unsigned PROG_EMPTY_THRESH = 0,
  parameter int unsigned CDC_STAGES     = 2,
  parameter bit          RELATED_CLOCKS = 1'b0,
  parameter int unsigned CNT_W          = $clog2(DEPTH) + 1,
  parameter int unsigned RCNT_W         = $clog2(DEPTH * DW / RD_DW) + 1
) (
  // 写域
  input  logic             wr_clk,
  input  logic             wr_en,
  input  logic [DW-1:0]    din,
  output logic             full,
  output logic             almost_full,
  output logic             prog_full,
  output logic [CNT_W-1:0] wr_count,
  output logic             overflow,
  output logic             wr_rst_busy,

  // 读域
  input  logic             rd_clk,
  input  logic             rd_en,
  output logic [RD_DW-1:0] dout,
  output logic             empty,
  output logic             almost_empty,
  output logic             prog_empty,
  output logic             valid,
  output logic             underflow,
  output logic [RCNT_W-1:0] rd_count,
  output logic             rd_rst_busy,

  // 公共复位
  input  logic             rst
);

  // 复位桥: 异步置位 / 同步释放 / >=2 个 wr_clk 宽度。
  // 异步 FIFO 的 rst 由内部复位序列机在 wr_clk 上采样, 读域复位由内部
  // 握手同步过去, 因此只需在写域整理一次。
  logic rst_sync;

  xpm_cdc_async_rst #(
    .DEST_SYNC_FF    (2),
    .INIT_SYNC_FF    (0),
    .RST_ACTIVE_HIGH (1)
  ) u_rst_bridge (
    .src_arst  (rst),
    .dest_clk  (wr_clk),
    .dest_arst (rst_sync)
  );

  // 变宽合法性预检 (说明同 xpm_sync_fifo.sv)
  localparam int unsigned RATIO = (DW >= RD_DW) ? DW / RD_DW : RD_DW / DW;
  initial begin
    if (RD_DW != DW) begin
      if (MEM_TYPE != "block" && MEM_TYPE != "uram")
        $error("xpm_async_fifo: 变宽 (DW=%0d -> RD_DW=%0d) 时 MEM_TYPE 只能 \"block\"/\"uram\" (auto 不保证行为, distributed/LUTRAM 不支持变宽)", DW, RD_DW);
      if (((DW % RD_DW) != 0 && (RD_DW % DW) != 0)
          || (RATIO & (RATIO - 1)) != 0 || RATIO > 8)
        $error("xpm_async_fifo: DW=%0d / RD_DW=%0d 宽度比不合法 (限 1:1/2:1/4:1/8:1 及倒数)", DW, RD_DW);
      if (DEPTH * DW / RD_DW < 16)
        $error("xpm_async_fifo: 变宽后读侧深度 DEPTH*DW/RD_DW = %0d < 16 (XPM DRC 硬性要求), 请加大 DEPTH", DEPTH * DW / RD_DW);
    end
  end

  // prog 水线特性位推导 (规则与暗坑说明见 xpm_sync_fifo.sv):
  // 阈值 0 = 位也不开, 保持默认 "1D0D" 契约; 禁用时阈值透传 0 安全
  // (DRC 与水线比较都在 EN_PF/EN_PE 的 generate 里)。
  localparam bit EN_PF = (PROG_FULL_THRESH  != 0);
  localparam bit EN_PE = (PROG_EMPTY_THRESH != 0);
  // 同 xpm_sync_fifo: 不写 localparam string, 否则 Vivado 综合器会在
  // xpm_fifo.sv 的 hstr2bin() 处报 bit[127:0] vs string 类型不匹配。
  localparam ADV_FEATURES = EN_PF ? (EN_PE ? "1F0F" : "1D0F")
                                  : (EN_PE ? "1F0D" : "1D0D");

  xpm_fifo_async #(
    .FIFO_MEMORY_TYPE    (MEM_TYPE),
    .ECC_MODE            ("no_ecc"),
    .RELATED_CLOCKS      (RELATED_CLOCKS),
    .FIFO_WRITE_DEPTH    (DEPTH),
    .WRITE_DATA_WIDTH    (DW),
    .WR_DATA_COUNT_WIDTH (CNT_W),
    .FULL_RESET_VALUE    (0),
    .USE_ADV_FEATURES    (ADV_FEATURES),
    .READ_MODE           (READ_MODE),
    .FIFO_READ_LATENCY   (READ_LATENCY),
    .READ_DATA_WIDTH     (RD_DW),
    .RD_DATA_COUNT_WIDTH (RCNT_W),
    .PROG_FULL_THRESH    (PROG_FULL_THRESH),
    .PROG_EMPTY_THRESH   (PROG_EMPTY_THRESH),
    .DOUT_RESET_VALUE    ("0"),
    .CDC_SYNC_STAGES     (CDC_STAGES),
    .WAKEUP_TIME         (0)
  ) u_xpm_fifo_async (
    .sleep         (1'b0),
    .rst           (rst_sync),

    .wr_clk        (wr_clk),
    .wr_en         (wr_en),
    .din           (din),
    .full          (full),
    .prog_full     (prog_full),          // 特性位未开时 XPM 输出恒 0
    .wr_data_count (wr_count),
    .overflow      (overflow),
    .wr_rst_busy   (wr_rst_busy),
    .almost_full   (almost_full),
    .wr_ack        (),                   // 未启用 (USE_ADV_FEATURES[4]=0)

    .rd_clk        (rd_clk),
    .rd_en         (rd_en),
    .dout          (dout),
    .empty         (empty),
    .prog_empty    (prog_empty),         // 特性位未开时 XPM 输出恒 0
    .rd_data_count (rd_count),
    .underflow     (underflow),
    .rd_rst_busy   (rd_rst_busy),
    .almost_empty  (almost_empty),
    .data_valid    (valid),

    .injectsbiterr (1'b0),             // ECC_MODE="no_ecc", 不使用
    .injectdbiterr (1'b0),
    .sbiterr       (),
    .dbiterr       ()
  );

endmodule