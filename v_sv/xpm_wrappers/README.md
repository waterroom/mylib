# xpm_wrappers —— Xilinx XPM 常用宏的薄封装

Vivado 自带 XPM（Xilinx Parameterized Macros）是 Xilinx 器件的官方基础库，
CDC / FIFO 这类"看着简单、坑极深"的基础设施应当直接用 XPM 而不是手写。
但 XPM 的**接口名跨代稳定、参数契约不稳定**：合法参数值、可用特性、默认行为
随器件代际和 Vivado 版本变化，而 `USE_ADV_FEATURES` 这类参数的位定义属于
"暗知识"，抄错一个字符就会让输出静默恒零。

所以按"把用到的 XPM 配置固化成一层 wrapper"的思路做了这一组文件：
统一命名、统一复位风格、固化参数与 `USE_ADV_FEATURES`，以后换器件 / 换
Vivado 版本只需要改这一层。这一层只覆盖日常最高频的几件事，**不追求功能
全覆盖**。

## 文件清单

| 文件 | 模块 | 内部用的 XPM 原语 | 用途 |
| --- | --- | --- | --- |
| `xpm_cdc_sync.sv` | `xpm_cdc_sync` | `xpm_cdc_single` / `xpm_cdc_array_single` | 单 bit / 多 bit 电平跨时钟同步 |
| `xpm_rst_sync.sv` | `xpm_rst_sync` | `xpm_cdc_async_rst` | 复位跨时钟域（复位桥） |
| `xpm_pulse_sync.sv` | `xpm_pulse_sync` | `xpm_cdc_pulse` | 单周期脉冲 / 事件跨时钟 |
| `xpm_sync_fifo.sv` | `xpm_sync_fifo` | `xpm_fifo_sync` | 同步 FIFO |
| `xpm_async_fifo.sv` | `xpm_async_fifo` | `xpm_fifo_async` | 异步 FIFO（跨时钟域数据通路） |
| `sim/tb_xpm_wrappers.sv` | — | — | 行为自检 testbench（214 项检查） |
| `sim/run_xsim.sh` | — | — | 一键跑 xsim 自检 |
| `synth/synth_top.sv` `synth/synth_check.tcl` | — | — | 真实器件综合检查（默认 xczu48dr） |

命名说明：wrapper 名和官方宏名**刻意错开**（官方是 `xpm_fifo_sync`，本层叫
`xpm_sync_fifo`），避免重名冲突。

## 统一约定

* **复位一律高有效**（与 XPM FIFO 的 `rst` 极性一致）。工程里用低有效
  `rst_n` 时在外层取反，或直接例化原语把 `RST_ACTIVE_HIGH` 置 0。
* **复位风格一律"异步置位、同步释放"**：任意宽度的异步复位脉冲都能被捕获
  （实测 1ns 脉冲有效），撤销沿与目标时钟对齐，不会出现复位撤销沿落在
  时钟沿附近的 recovery 问题。
* 端口用的是 `logic`、参数用 `int unsigned` / `string`，文件自带
  `` `timescale ``，`iverilog` 之外的仿真器（xsim/Questa/VCS）都能直接编译。

## 用法示例

```systemverilog
// 全局复位进 100M 域
xpm_rst_sync #(.STAGES(2)) u_rst_100m (
    .src_rst(global_rst), .dest_clk(clk_100m), .dest_rst(rst_100m));

// 采集域 250M -> 处理域 100M, 512 深, show-ahead 读
xpm_async_fifo #(.DW(16), .DEPTH(512), .READ_MODE("fwft")) u_cdc_fifo (
    .wr_clk(clk250), .rst(rst250), .wr_en(wr_en), .din(din),
    .full(), .almost_full(), .wr_count(), .overflow(), .wr_rst_busy(),
    .rd_clk(clk100), .rd_en(rd_en), .dout(dout),
    .empty(), .almost_empty(), .valid(), .underflow(),
    .rd_count(), .rd_rst_busy());

// 单 bit / 总线电平同步, 100M -> 57M
xpm_cdc_sync #(.W(16), .STAGES(2)) u_status_sync (
    .src_clk(clk100), .src_in(status_bus), .dest_clk(clk57), .dest_out(status_bus_57m));

// 事件脉冲跨时钟
xpm_pulse_sync #(.STAGES(2)) u_evt (
    .src_clk(clk100), .src_rst(rst100), .src_pulse(evt),
    .dest_clk(clk250), .dest_rst(rst250), .dest_pulse(evt_250m));

// 提前背压: 占用量 >= 500 就让上游停发 (almost_full 钉死在 DEPTH-1 挪不动)
xpm_sync_fifo #(.DW(32), .DEPTH(512), .PROG_FULL_THRESH(500)) u_fifo (
    .clk(clk100), .rst(rst100),
    .wr_en(wr_en), .din(din), .prog_full(stop_accept), ...);

// 非对称位宽: 采集侧 64bit 写, 处理侧 16bit 读 (8:1, 读侧深度 256*64/16=1024)
// 变宽时 MEM_TYPE 只能 "block"/"uram"; 先写的字落在宽字低位 (小端)
xpm_async_fifo #(.DW(64), .RD_DW(16), .DEPTH(256), .MEM_TYPE("block")) u_wide (
    .wr_clk(clk_a), .wr_en(wr_en), .din(din64), .full(full), .wr_count(wcnt),
    .rd_clk(clk_b), .rd_en(rd_en), .dout(dout16), .empty(empty),
    .valid(vld), .rd_count(rcnt), .rst(rst));
```

## 参数速查

| 模块 | 参数（默认值） | 合法范围 / 说明 |
| --- | --- | --- |
| `xpm_cdc_sync` | `W`(1) `STAGES`(2) `REG_SRC`(1) `SIM_ASSERT_CHK`(0) | `W`: 1..1024；`STAGES`(=`DEST_SYNC_FF`): 2..10；`REG_SRC=1` 表示源域先打一拍（源信号是组合逻辑时必须为 1） |
| `xpm_rst_sync` | `STAGES`(2) | 2..10 |
| `xpm_pulse_sync` | `STAGES`(2) `REG_OUT`(0) `SIM_ASSERT_CHK`(0) | `STAGES`: 2..10；`REG_OUT=1` 让 `dest_pulse` 在目标域再打一拍（扇出大时改善时序） |
| `xpm_sync_fifo` | `DW`(8) `RD_DW`(=DW) `DEPTH`(16) `READ_MODE`("std") `READ_LATENCY`(1) `MEM_TYPE`("auto") `PROG_FULL_THRESH`(0) `PROG_EMPTY_THRESH`(0) `CNT_W`(推导) `RCNT_W`(推导) | `DEPTH` 必须是 **2 的幂且 ≥16**（非法值 XPM 会直接 `$error`）；等宽时 `MEM_TYPE`: "auto"/"block"/"distributed"/"uram"（uram 仅 UltraScale+）；`RD_DW` 变宽时限 2 的幂比例且 `MEM_TYPE` 只能 "block"/"uram"（见"已验证的事实"12）；`READ_MODE`: "std"/"fwft"；`READ_LATENCY` 只在 std 模式生效（fwft 内部固定 2 拍）；prog 阈值 0 = 不启用（恒 0），fwft 实际水线 = 阈值−2 |
| `xpm_async_fifo` | 同上 + `CDC_STAGES`(2) `RELATED_CLOCKS`(0) | `CDC_STAGES`(=`CDC_SYNC_STAGES`): 2..8，`DEPTH=16` 时最大 4，`RELATED_CLOCKS=1` 时必须为 2；prog 满水线下限比同步多抬 `CDC_STAGES`；**"uram" 不能用于异步 FIFO**（XPM 报错，变宽时也一样）；变宽规则同上 |

`CNT_W` 是 `count` 的位宽，由 `DEPTH` 自动推导（`clog2(DEPTH)+1`），不要覆盖。

## 端口速查

同步 FIFO（`xpm_sync_fifo`，单时钟）：

| 方向 | 写侧 | 读侧 |
| --- | --- | --- |
| in | `clk` `rst` `wr_en` `din[DW-1:0]` | `rd_en` |
| out | `full` `almost_full` `prog_full` `count[CNT_W-1:0]` `overflow` `rst_busy` | `dout[RD_DW-1:0]` `empty` `almost_empty` `prog_empty` `valid` `underflow` |

异步 FIFO（`xpm_async_fifo`）：写侧 `wr_clk/wr_en/din[DW-1:0]/full/almost_full/prog_full/wr_count[CNT_W-1:0]/overflow/wr_rst_busy`，
读侧 `rd_clk/rd_en/dout[RD_DW-1:0]/empty/almost_empty/prog_empty/valid/underflow/rd_count[RCNT_W-1:0]/rd_rst_busy`，
外加公共 `rst`。

* `valid`：std 模式为 `rd_en` 后 `READ_LATENCY` 拍的"数据有效"（实测与 `dout`
  同拍），fwft 模式为"`dout` 上有数据"。把 `dout` 打拍使用时用它判断。
* `overflow` / `underflow`：满写 / 空读的指示（1 拍脉冲）。XPM 内部会屏蔽这些
  误操作（写不进 / 读不出），这两个信号是给调试看的，方便抓协议 bug。
* `prog_full` / `prog_empty`：可编程水线（`PROG_FULL_THRESH` / `PROG_EMPTY_THRESH`，
  **0 = 不启用，输出恒 0**）。std 等宽时边界即参数值（占用量 ≥ 阈值 / 剩余 ≤ 阈值），
  但标志比 `almost_*` **多 1 拍**寄存延迟（XPM 用寄存后的差值指针比较，实测第 8 个
  字写入后的下一拍才置起）；fwft 实际水线 = 阈值 − 2；异步模式的置起/撤销还带
  对侧指针 CDC 同步的迟滞。与 `almost_*` 互补不是替代：prog 的合法区间够不到
  两端端点，almost 的水线挪不出端点。
* `rst_busy`（同步 FIFO）与 `*_rst_busy`（异步 FIFO）：复位进行中标志。复位
  释放后等它撤销再开始操作即可，复位期间即使驱动 `wr_en/rd_en` 也不会写坏。

## 复位释放与"能不能马上写"

**结论：不要在 FIFO wrapper 里加"复位延后允许写入"的门控**——XPM 内部已经屏
蔽了，wrapper 里再屏蔽一遍仍然丢数据；要做的是**复位分发**：让上游逻辑的复位
保持到 FIFO 说 ready。

依据（XPM 源码 + 本目录实测）：

* XPM 内部写门控和 `wr_rst_busy` 用的是**同一个表达式**（`xpm_fifo.sv` 里
  `wr_rst_busy` 与 `ram_wr_en_i` 两条 assign；2022.1 在 465/479 行、
  2024.2 在 471/486 行，行号随版本漂移，以信号名为准）：

      assign wr_rst_busy = wrst_busy | rst_d1;
      assign ram_wr_en_i = wr_en & ~ram_full_i & ~(wrst_busy|rst_d1);

  所以"等 `wr_rst_busy` 撤销再写"既**必要**也**充分**。在它撤销前写，写会被
  静默丢弃（只有 `overflow` 会闪一下），写指针计数器在 `wrst_busy` 下被复位、
  标志按 `FULL_RESET_VALUE` 置位，**FIFO 不会失控**，但数据会丢。实测：复位
  窗口内连写 4 个，复位后 `count=0`、`empty=1`，之后正常写读数据完好。
* 读侧同理：复位窗口内 `empty=1`，读被忽略。
* 异步 FIFO 的 `wr_rst_busy` 要等两域复位握手完成（`xpm_fifo_rst` 的 FSM 要等
  读域复位经 `xpm_cdc_sync_rst` 回写过来）才撤销，所以它是"写侧可以开工"的
  唯一正确判据；`rd_rst_busy` 对应读侧。
* 窗口有多宽（实测，自检输出里带 `MEASURE` 行，可随时复跑核对）：同步 FIFO 在
  外部复位撤销后 `rst_busy` 还要保持 **7 个 clk**（其中 2 拍来自本层复位桥）；
  异步 FIFO 的 `wr_rst_busy` 要 **34 个 wr_clk**（写 100M / 读 57M 实测；两域
  要握手 + CDC，时钟比越悬殊拍数越多）。上游若在同一个复位一撤销就开写，会整段
  落进这个窗口 —— 这就是"要不要加复位延后"的由来，只是要加在**复位分发**上。

### `rst_busy` 本身能不能信？（实测，见自检 `[8] rst_busy semantics`）

* **会拉高，而且是设计保证**：复位期间它高；复位撤销后到内部序列完成它保持高
  （同步 7 拍 / 异步 34 写时钟，见上）。**即使完全不接外部复位**，XPM 内部的
  power-on reset 也会自己把 busy 拉起来：上电后第 1 个时钟沿拉高，同步 FIFO 保持
  5 拍、异步 FIFO 保持 48 个写时钟（两域握手）。它和"写被内部丢弃"的窗口是同一
  个表达式，所以 **`busy` 低 = 写一定进得去（除满之外）**。
* **边界一：第一个时钟沿之前 `busy = 0`**（FF 初值），此时 FIFO 其实还没复位完。
  别把 `!busy` 当"上电就绪"的判据 —— 那一刻时钟也还没有沿，上游同样写不了，
  实际无害；要判"上电了没"用 MMCM locked 之类。
* **边界二：时钟停住时 busy 不会变**（它是写时钟域的同步信号）：实测停钟 + 拉复位，
  busy 仍是 0；时钟一恢复，第 1 个沿就拉高。所以它也不能当"时钟起来了"的判据。
  同域上游没有时钟也写不了，两者组合起来是安全的。
* **边界三：断言有 1 拍延迟**（`rst` 拉高 → 至多 1 个写时钟后 busy 高）。写门控用的
  `wrst_busy|rst_d1` 与 busy 完全相同（含这一拍），所以按 `!busy` 写依然一个字不丢。

推荐写法（1 行 OR 门控，把上游逻辑的复位拖到 FIFO ready）：

```systemverilog
// 全局复位 -> 写域复位 (异步置位 / 同步释放)
xpm_rst_sync #(.STAGES(2)) u_rst_wr (
    .src_rst(global_rst), .dest_clk(wr_clk), .dest_rst(rst_wr));

xpm_async_fifo #(...) u_fifo (
    .wr_clk(wr_clk), .rst(rst_wr), ...);      // FIFO 用同一个域复位

// 写侧逻辑的复位: 一直保持到 FIFO 就绪。
// 撤销沿要么来自 rst_wr (复位桥同步释放), 要么来自 wr_rst_busy (FIFO 内部同步
// 释放), 两者都是时钟同步的, 所以 OR 之后的复位撤销也是同步的, 不会引入
// recovery/removal 问题。
assign rst_wr_logic = rst_wr | u_fifo_wr_rst_busy;
```

等价做法是让上游 FSM 显式等待 `!wr_rst_busy` 再进入发送状态（本目录自检
testbench 就是这么写的）。两种做法选一个即可。

反面写法：`assign rst_fifo = global_rst | wr_rst_busy;` —— 把 FIFO 自己的 busy
反馈回 FIFO 自己的复位会**复位自锁**：FIFO 要等 `rst` 撤销才撤销 `busy`，而
`rst` 又在等 `busy` 撤销，结果是复位永远不释放。门控的对象应该是**用这个 busy
标志的上下游逻辑**的复位。

## 已验证的事实（这些是包这一层的直接理由）

以下每一条都在本机 Vivado 2022.1 下用真实 XPM 源码核实并实测过
（自检 testbench 的输出里带 `MEASURE` 行）：

1. **`USE_ADV_FEATURES` 的位定义**（源码 `xpm_fifo.sv` 的 `EN_OF..EN_DVLD`
   localparam 区，2022.1 在 208~218 行、2024.2 在 212~222 行；保留位 DRC
   在 2022.1 的 349~355 行、2024.2 的 353~358 行）：
   `[0]`overflow `[1]`prog_full `[2]`wr_data_count `[3]`almost_full `[4]`wr_ack
   `[8]`underflow `[9]`prog_empty `[10]`rd_data_count `[11]`almost_empty
   `[12]`data_valid；`[7:5]`、`[13]`、`[15:14]` 保留必须为 0。
   **XPM 默认值 `"0707"` 只开了 overflow/prog_full/wr_data_count 和
   underflow/prog_empty/rd_data_count —— 网上到处照抄的 `"0707"` 会让
   `almost_full` / `almost_empty` / `data_valid` 恒为 0。**
   本层固化的是 `"1D0D"`（只开 wrapper 实际引出的标志：overflow、wr_data_count、
   almost_full、underflow、rd_data_count、almost_empty、data_valid）。
2. **异步 FIFO 的有效深度 = `DEPTH` - 1**（实测 `DEPTH=16` 只能写入/读出 15 个，
   `DEPTH=32` 只能 31 个）。XPM 为跨时钟指针同步保留了 1 个位置；同步 FIFO
   没有这个折损（实测 `DEPTH=16` 可写满 16 个）。要"能装 N 个字"，异步 FIFO
   的 `DEPTH` 至少要取 N+1（实际工程建议留更多余量）。
3. **`count` 不能当精确流控阈值**：连续写入时 `wr_data_count` 用的是上一次时钟
   沿的指针，比真实占用量**晚一拍**（实测边写边读的差值为 1）；异步模式两侧的
   `wr_count` / `rd_count` 还各带 `CDC_STAGES` 拍的跨时钟延迟。流控请用
   `full` / `almost_full` / `empty` / `almost_empty`。
4. **`almost_full` = 剩 1 个空位、`almost_empty` = 剩 1 个字**（实测：`DEPTH=16`
   装到第 15 个字时 `almost_full` 置起；读到剩 1 个字时 `almost_empty` 置起，
   并一直保持到再次写入）。
5. **`MEM_TYPE="auto"` 由工具选原语**：综合实测（xczu48dr）里 512 深 32bit 的
   FIFO 映射成 1 个 RAMB18E2，64 深 16bit 的 distributed 配置映射成 20 个
   LUTRAM，异步 FIFO 的指针 CDC 带 `ASYNC_REG`（综合后 144 个 `ASYNC_REG` 单元
   仍在，不会被优化掉）。
6. **复位桥/复位脉冲**：1ns 的异步复位脉冲（刻意落在时钟沿之间）能被捕获；
   `dest_rst` 在源复位释放后的第 2 个目标时钟沿撤销（实测 57M 目标域
   23.2ns 宽）。XPM FIFO 的 `rst` 由写时钟域采样，读域复位靠内部握手同步，
   所以异步 FIFO 只需要一个 `rst`。
7. **脉冲同步**：100M → 250M 连续 20 个脉冲一个不丢，`dest_pulse` 宽度恰为
   1 个目标周期（4ns）。约束是**相邻 `src_pulse` 间隔要大于原语同步往返**
   （保守取 `STAGES+2` 个目标周期），脉冲密于目标域周期时改用异步 FIFO 计数传递。
8. 上电初值：XPM FIFO 内部有 2 拍的 power-on reset，`dout` 复位值为
   `DOUT_RESET_VALUE="0"`；CDC 类原语**没有复位端口**，上电后前几拍输出初值
   由 GSR/FF INIT 决定（默认 0），复位期间不要依赖它。
9. **复位窗口内写入不会让 FIFO 失控，但会被静默丢弃**：XPM 内部写门控与
   `wr_rst_busy` 是同一个项，实测复位期间连写 4 个字，复位后 `count=0`、
   `empty=1`，随后写读数据完好；`overflow` 会指示这次丢弃。读侧同理（复位期间
   `empty=1`）。窗口宽度实测：同步 FIFO 复位撤销后还要 `rst_busy` 7 个 clk、
   异步 FIFO 要 `wr_rst_busy` 34 个 wr_clk —— 所以上游必须等到对应的
   `rst_busy` 撤销，做法见"复位释放与能不能马上写"。
10. **prog 水线（`PROG_FULL_THRESH` / `PROG_EMPTY_THRESH`，本层 0 = 不启用）**：
   std 等宽时边界即参数值（`prog_full`：占用量 ≥ 阈值；`prog_empty`：剩余 ≤
   阈值），但标志用**寄存后的差值指针**比较，比 `almost_*` / `full` / `empty`
   **多 1 拍**（实测：第 8 个字写入后的下一拍才置起）。fwft 模式 XPM 内部把
   阈值减 2 再比（`PF/PE_THRESH_ADJ`）；异步模式水线比较用对侧同步指针，
   置起/撤销带 `CDC_STAGES` 拍级迟滞。**特性位开了但阈值为 0 时 `prog_empty`
   输出恒 1**（不是 0；见 `xpm_fifo.sv` 里 `prog_full`/`prog_empty` 的输出
   门控 assign，2022.1 在 525~526 行、2024.2 在 538~539 行）——本层"阈值 0 =
   位也不开"
   的推导从结构上避开这个坑。合法区间（等宽、`DEPTH=16` 示例）：std 同步
   [3, 13]；fwft 同步 [5, 11]；std 异步 CDC=2 [5, 13]——下限随 `CDC_STAGES`
   抬高、fwft 两端各收 2、上限 ≈ `DEPTH-3`，非法值由 XPM DRC `$error` 并
   打印当时的合法区间。
11. **给 XPM 传条件推导的 `USE_ADV_FEATURES` 时，localparam 不能声明成
   `string`**：XPM 的参数端口和内部 `hstr2bin()` 都按打包位向量处理，显式
   `string` 类型会让 Vivado **综合器**在 `xpm_fifo.sv` 的 `hstr2bin()` 处报
   `bit [127:0] vs string` 类型不匹配（xsim/Questa 仿真器不受影响，属于
   只综合器踩的坑）。本层用无类型 `localparam` + 字符串字面量三元表达式，
   字面量按打包位向量流动正好匹配——实测 xczu48dr 综合通过。
12. **非对称位宽（`RD_DW != DW`，实测 sync 4:1 / async 1:2）**：
   * 宽度比限 **2 的幂**：1:1、2:1、4:1、8:1 及倒数（XPM 模板注释口径）；
     读侧深度 = `DEPTH×DW/RD_DW`，XPM DRC 硬性要求 **≥16**（写窄读宽时
     `DEPTH` 要加大）。
   * **distributed/LUTRAM 根本不支持变宽**——`XPM_MEMORY` DRC 直接报
     "symmetric port widths are required for Distributed RAM"；`"auto"` 也
     只保证等宽行为。所以变宽时 `MEM_TYPE` 只能显式 `"block"` / `"uram"`。
     XPM 的 FIFO 文档只提了 auto 这条 NOTE，distributed 这条要漏到存储层
     才报错——本层预检把两种情况都提前 `$error` 拦下。
   * **拼包顺序是小端**：先写入的字落在宽字低位（实测 32→8 读出字节流
     0,1,2,…；8→16 读出 `{b1,b0}`）。
   * `full`/`almost_full`/`prog_full`/`wr_count` 的单位是**写侧字**，
     `empty`/`almost_empty`/`prog_empty`/`rd_count` 的单位是**读侧字**。
   * 有效深度按写侧字计仍是 `DEPTH-1`（实测 31 个写字节时 `full=1`），
     但**读侧只能凑成完整读字**：写 31 字节（写窄读宽 1:2）只读得出 15 个
     读字 = 30 字节，最后 1 个字节**悬挂不可见**（`empty=1`、`rd_count=0`，
     实测见自检 [10] 的 MEASURE 行）。变宽时的安全容量按
     **⌊(DEPTH−1)×DW/RD_DW⌋ 个读字**算，不要把写侧 (DEPTH−1) 撞满。

## 验证

```bash
# 行为自检: 用 Vivado 自带仿真器 (xvlog/xelab/xsim), 214 项检查
# 已回归版本: 2018.3 / 2022.1 / 2024.2 (三版 MEASURE 实测值一致)
bash sim/run_xsim.sh            # 默认 Vivado 2022.1
bash sim/run_xsim.sh 2018.3     # 换版本 (按 /c/Xilinx/Vivado/<ver> 推导)
VIVADO_ROOT=/d/Xilinx/Vivado/2024.2 bash sim/run_xsim.sh   # 安装在别处时

# 综合检查: 真实器件跑一遍综合 (默认 xczu48dr, 你的 RFSoC)
vivado -mode batch -source synth/synth_check.tcl -tclargs xczu48dr-ffvg1517-2-e
```

两个脚本都会把中间产物放在 `sim/xsim_work/`、`synth/synth_work/`（可随时删）。
综合脚本检查 ERROR / critical warning 数量、`ASYNC_REG` 是否保留，并输出
`util.rpt` / `drc.rpt`。

## 什么时候不要用这层

这层是"日常够用"的薄封装，碰到下面这些情况请直接例化 XPM 原语
（参数合法值仍以安装目录里的 XPM 源码为准：
`<Vivado>/data/ip/xpm/xpm_fifo/hdl/xpm_fifo.sv`、`.../xpm_cdc/hdl/xpm_cdc.sv`）：

* FIFO 的 ECC（`ECC_MODE`）、`sleep` 低功耗、`wr_ack`、AXI-Stream 接口的
  `xpm_fifo_axis`；
* 握手类 CDC（`xpm_cdc_handshake`）、格雷码（`xpm_cdc_gray`）、
  低延迟握手（`xpm_cdc_low_latency_handshake`）；
* 存储器（`xpm_memory_sdpram` / `tdpram` / `spram`）——本层还没包，按同样
  思路加一个 `xpm_sdpram.sv` 即可（这是下一步计划）。

另外记住：**XPM 只支持 Xilinx/AMD 器件**，而且要 `compile_simlib` 或本目录
`sim/run_xsim.sh` 那样的方式把 XPM 源码喂给第三方仿真器；跨厂商复用代码时
基础库要换成 open-logic 之类的厂商无关实现。