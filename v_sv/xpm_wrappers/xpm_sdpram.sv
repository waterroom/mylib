//=============================================================================
// xpm_sdpram.sv -- 简单双口 RAM (Xilinx XPM 薄封装, 一写一读)
//
// 内部实现: xpm_memory_sdpram (no_ecc, 无初始化, 无字节写)
//
// 用途: 数据缓冲 / 延迟线 / 乒乓缓存这类"一端只写、一端只读"的存储。
//       相比直接例化 XPM, 本层固化了:
//       - doutb_vld 读有效跟踪 (enb 延迟 LATENCY_B 拍, 与 doutb 对齐),
//         延迟线用法不用再手打 valid 移位链;
//       - 变宽 (DW_A != DW_B) 的合法性预检;
//       - 复位省略的取舍: 数据 RAM 读流水不需要复位, rstb 内部恒 0,
//         doutb 初值由 FF INIT (READ_RESET_VALUE_B="0") 决定。
//
// 端口:
//   clka       写时钟 (CLOCKING_MODE="common_clock" 时与 clkb 接同一时钟)
//   addra      写地址 [AW_A-1:0]
//   dina       写数据 [DW_A-1:0]
//   wea        写使能, 高有效 (写口 ena 内部恒 1, 功耗门控靠 wea)
//   clkb       读时钟
//   enb        读使能 (门控读地址/输出流水, 不用接 1'b1)
//   addrb      读地址 [AW_B-1:0]
//   doutb      读数据 [DW_B-1:0]
//   doutb_vld  doutb 有效指示: enb 延迟 LATENCY_B 拍 (读流水线跟踪),
//              与 doutb 数据严格对齐; LATENCY_B=0 (组合读) 时与 enb 同拍。
//              注意寄存读 (LATENCY_B>=1) 在 enb 撤低后 vld 还会多保持 1 拍
//              (流水线尾巴, 对应 doutb 保持的最后一次读结果), 之后清零。
//
// 参数:
//   DW_A        写口位宽, 默认 8
//   DW_B        读口位宽, 默认 = DW_A (等宽)。变宽规则: 宽度比限 1:1 /
//               2:1 / 4:1 / 8:1 及倒数 (2 的幂); MEM_TYPE 只能 "block"/
//               "uram" (distributed 即 LUTRAM 不支持变宽, XPM_MEMORY DRC
//               报错) -- 本层预检提前拦下。拼包顺序: 写侧第 0 字落宽字
//               低位 (小端, 与 xpm_*_fifo 一致, 实测见自检 [11])。
//   DEPTH       写口深度, 2 的幂且 >= 2 (本库统一约定, 预检拦截);
//               读口深度 = DEPTH*DW_A/DW_B
//   LATENCY_B   读延迟拍数, 默认 1。0 = 组合读, 仅 "distributed" 合法
//               (block/uram 物理上必须寄存读, XPM DRC 报错, 预检提前拦);
//               block/uram 建议 1 (输出寄存) 起步, 时序紧可加大
//   MEM_TYPE    "auto" (默认, 工具选) / "block" (BRAM) / "distributed"
//               (LUTRAM) / "uram" (UltraRAM, 仅 UltraScale+; 浅深度浪费
//               单元, 建议 512 深起步)
//   CLOCKING_MODE "common_clock" (默认, 读写同钟) / "independent_clock"
//               (独立时钟)。独立时钟模式下 clka/clkb 间是异步路径, 需要
//               自行加时钟组约束 (set_clock_groups -asynchronous), 与异步
//               FIFO 同理
//   RD_MODE_B   "no_change" (默认) / "read_first" / "write_first",
//               读写同地址冲突时的行为; 延迟线/顺序缓冲用默认即可。
//               注意 distributed 只支持 "read_first" (预检拦截)
//   AW_A/AW_B   地址位宽, 由 DEPTH/宽度自动推导, 请勿覆盖
//
// 例化示例:
//   // 延迟线: 64 深字节宽, 读延迟 1 拍, doutb_vld 与数据对齐
//   xpm_sdpram #(.DW_A(8), .DEPTH(64), .LATENCY_B(1)) u_delay (
//       .clka(clk), .addra(waddr), .dina(din), .wea(we),
//       .clkb(clk), .enb(1'b1), .addrb(raddr),
//       .doutb(dout), .doutb_vld(dout_vld));
//
// 参考: UG974 / UG953 XPM_MEMORY_SDPRAM;
//       <Vivado>/data/ip/xpm/xpm_memory/hdl/xpm_memory.sv (参数合法范围以源码 DRC 为准)
//=============================================================================

`timescale 1ns / 1ps

module xpm_sdpram #(
  parameter int unsigned DW_A          = 8,
  parameter int unsigned DW_B          = DW_A,
  parameter int unsigned DEPTH         = 64,
  parameter int unsigned LATENCY_B     = 1,
  // 注意: 以下三个参数不写 string 关键字 -- XPM 的参数端口按打包位向量
  // 处理, 显式 string 类型会让 Vivado 综合器在 xpm_memory.sv 内部报
  // "expression must be of a packed type" (同 xpm_fifo 的 hstr2bin 坑,
  // 仿真器不受影响)。字符串字面量经无类型参数流动正好匹配。
  parameter              MEM_TYPE      = "auto",
  parameter              CLOCKING_MODE = "common_clock",
  parameter              RD_MODE_B     = "no_change",
  parameter int unsigned AW_A          = $clog2(DEPTH),
  parameter int unsigned AW_B          = $clog2(DEPTH * DW_A / DW_B)
) (
  input  logic              clka,
  input  logic [AW_A-1:0]   addra,
  input  logic [DW_A-1:0]   dina,
  input  logic              wea,

  input  logic              clkb,
  input  logic              enb,
  input  logic [AW_B-1:0]   addrb,
  output logic [DW_B-1:0]   doutb,
  output logic              doutb_vld
);

  // 合法性预检 (报错信息比 XPM_MEMORY 的 DRC 更直接):
  // - 变宽时 distributed 禁用 (xpm_memory.sv 315 行同款 DRC, 但报错在存储
  //   层, 信息绕), auto 下变宽行为不保证, 故只放行 block/uram;
  // - LATENCY_B=0 (组合读) 仅 distributed -- block/uram 物理必须寄存读
  //   (xpm_memory.sv 580 行 DRC), 预检提前说清;
  // - 变宽比例 / 深度 2 的幂, 与 FIFO wrapper 同一套约定。
  localparam int unsigned RATIO = (DW_A >= DW_B) ? DW_A / DW_B : DW_B / DW_A;
  initial begin
    if (DW_A != DW_B) begin
      if (MEM_TYPE != "block" && MEM_TYPE != "uram")
        $error("xpm_sdpram: 变宽 (DW_A=%0d -> DW_B=%0d) 时 MEM_TYPE 只能 \"block\"/\"uram\" (auto 不保证行为, distributed/LUTRAM 不支持变宽)", DW_A, DW_B);
      if (((DW_A % DW_B) != 0 && (DW_B % DW_A) != 0)
          || (RATIO & (RATIO - 1)) != 0 || RATIO > 8)
        $error("xpm_sdpram: DW_A=%0d / DW_B=%0d 宽度比不合法 (限 1:1/2:1/4:1/8:1 及倒数)", DW_A, DW_B);
    end
    if (DEPTH < 2 || (DEPTH & (DEPTH - 1)) != 0)
      $error("xpm_sdpram: DEPTH=%0d 不是 2 的幂 (本库统一约定, 需要非 2 次幂深度请直接例化 XPM)", DEPTH);
    if (LATENCY_B == 0 && MEM_TYPE != "distributed" && MEM_TYPE != "auto")
      $error("xpm_sdpram: LATENCY_B=0 (组合读) 仅 \"distributed\" 支持, %s 必须寄存读 (LATENCY_B>=1)", MEM_TYPE);
    if (MEM_TYPE == "distributed" && RD_MODE_B != "read_first")
      $error("xpm_sdpram: distributed/LUTRAM 的写读冲突模式只支持 \"read_first\" (no_change/write_first 会 XPM_MEMORY DRC 报错), 请改 RD_MODE_B 或换 \"block\"");
  end

  xpm_memory_sdpram #(
    .MEMORY_SIZE            (DW_A * DEPTH),
    .MEMORY_PRIMITIVE       (MEM_TYPE),
    .CLOCKING_MODE          (CLOCKING_MODE),
    .MEMORY_INIT_FILE       ("none"),
    .MEMORY_INIT_PARAM      (""),
    .USE_MEM_INIT           (0),
    .WAKEUP_TIME            ("disable_sleep"),
    .MESSAGE_CONTROL        (0),
    .ECC_MODE               ("no_ecc"),
    .AUTO_SLEEP_TIME        (0),
    .USE_EMBEDDED_CONSTRAINT(0),
    .MEMORY_OPTIMIZATION    ("true"),
    .WRITE_DATA_WIDTH_A     (DW_A),
    .BYTE_WRITE_WIDTH_A     (DW_A),      // 不做字节写, 需要时直接例化 XPM
    .ADDR_WIDTH_A           (AW_A),
    .READ_DATA_WIDTH_B      (DW_B),
    .ADDR_WIDTH_B           (AW_B),
    .READ_RESET_VALUE_B     ("0"),
    .READ_LATENCY_B         (LATENCY_B),
    .WRITE_MODE_B           (RD_MODE_B)
  ) u_xpm_memory_sdpram (
    .sleep            (1'b0),
    .clka             (clka),
    .ena              (1'b1),
    .wea              (wea),
    .addra            (addra),
    .dina             (dina),
    .injectsbiterra   (1'b0),
    .injectdbiterra   (1'b0),
    .clkb             (clkb),
    .rstb             (1'b0),           // 数据 RAM 读流水不复位, 见头部说明
    .enb              (enb),
    .regceb           (1'b1),
    .addrb            (addrb),
    .doutb            (doutb),
    .sbiterrb         (),
    .dbiterrb         ()
  );

  // 读有效跟踪: enb 移位 LATENCY_B 拍, 与 doutb 对齐
  generate
    if (LATENCY_B == 0) begin : g_vld_comb
      assign doutb_vld = enb;
    end
    else begin : g_vld_pipe
      logic [LATENCY_B-1:0] enb_pipe;
      always_ff @(posedge clkb) begin
        enb_pipe[0] <= enb;
        for (int i = 1; i < LATENCY_B; i++) enb_pipe[i] <= enb_pipe[i-1];
      end
      assign doutb_vld = enb_pipe[LATENCY_B-1];
    end
  endgenerate

endmodule
