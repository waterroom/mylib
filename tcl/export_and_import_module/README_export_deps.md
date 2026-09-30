# export_deps.tcl — 按模块导出依赖（源码复制 + IP 参数化重建）

对任意 Vivado 工程里的**一个文件（模块）**，递归找出它依赖的全部源文件和 IP 核，
打包成一个自包含目录；在另一台机器 / 另一个 Vivado 工程里运行包内的
`import_design.tcl` 即可一键导入：

- 源文件（.v/.sv/.vhd/头文件）→ **复制**进目标工程（`<工程目录>/imported_sources/`）
- Xilinx IP 核 → **按参数重建**（每个 IP 一份 `write_ip_tcl` 脚本，
  `create_ip` + 全部 CONFIG 参数，不复制 .xci/.gen 输出产品）
- IP 引用的外部数据文件（.coe 等）：2022.1 的 write_ip_tcl 会把系数直接
  内嵌进重建脚本（天然自包含）；未内嵌的版本由导出脚本复制到
  `ip/<IP名>/files/` 并把脚本中的引用改指到本地副本

## 导出（在源工程的 Vivado 里）

通用形式：

```
vivado -mode batch -source tcl/export_and_import_module/export_deps.tcl [-log xx.log] [-journal xx.jou] -tclargs <工程.xpr|-> <文件或模块名> [输出目录] [-xdc]
```

- **`-tclargs` 之后的所有内容都会原样传给脚本**，所以 `-log` / `-journal`
  必须放在 `-tclargs` 之前；不加的话 `vivado.log` / `vivado.jou` 会生成在
  当前目录。
- `-source tcl/export_and_import_module/export_deps.tcl` 是相对路径时，先
  `cd` 到本仓库（mylib）根目录。
- 工程参数写 `-` 表示用当前已打开的工程。
- 文件参数支持：绝对路径、子路径（如 `sources_1/new/ZU48_TOP.v`）、
  工程内唯一的文件名（如 `da_data_gen.sv`）、或直接写模块名/IP名。
- `-xdc`（可选）：把工程里所有启用的 XDC 一并导出。

### 实例（cmd / PowerShell，反斜杠路径）

```bat
cd /d D:\prj\f24013_7
C:\Xilinx\Vivado\2022.1\bin\vivado.bat -mode batch -source D:\mylib\tcl\export_and_import_module\export_deps.tcl -log exp.log -journal exp.jou -tclargs ZU48_F1_V100_4p8G_sync_260910\ZU48_F1_V100.xpr da_data_gen.sv D:\exp
```

### 实例（Git Bash，必须全部用 `/`，否则反斜杠会被 bash 吃掉）

```bash
cd /d/prj/f24013_7
/c/Xilinx/Vivado/2022.1/bin/vivado.bat -mode batch -source /d/mylib/tcl/export_and_import_module/export_deps.tcl \
  -log exp.log -journal exp.jou \
  -tclargs ZU48_F1_V100_4p8G_sync_260910/ZU48_F1_V100.xpr da_data_gen.sv D:/exp
```

### 实例（Vivado GUI 的 Tcl 控制台）

```tcl
source D:/mylib/tcl/export_and_import_module/export_deps.tcl
export_deps::run - da_data_gen.sv D:/exp
```

## 导入（在目标 Vivado 里）

**A. 新建工程导入** —— 不打开任何工程直接运行，自动新建工程 `deps_import`（配置在脚本开头可改）：

```bat
:: cmd
C:\Xilinx\Vivado\2022.1\bin\vivado.bat -mode batch -source D:\exp\import_design.tcl
```

```bash
# Git Bash
/c/Xilinx/Vivado/2022.1/bin/vivado.bat -mode batch -source /d/exp/import_design.tcl
```

**B. 导入到已存在的工程（批处理）** —— 把目标 .xpr 作为 `-tclargs` 参数传入，脚本会先 `open_project` 再导入：

```bat
:: cmd
C:\Xilinx\Vivado\2022.1\bin\vivado.bat -mode batch -source D:\exp\import_design.tcl -tclargs D:\path\to\target.xpr
```

```bash
# Git Bash
/c/Xilinx/Vivado/2022.1/bin/vivado.bat -mode batch -source /d/exp/import_design.tcl -tclargs /d/path/to/target.xpr
```

**C. GUI 导入** —— 打开目标工程 → Tcl 控制台 `source D:/exp/import_design.tcl`
（导入进当前打开的工程；不打开工程则走 A 的新建逻辑）。

三种方式都**不会改动任何原始文件**（源工程只读；导入是把文件复制进
`<目标工程目录>/imported_sources/` 再加入 sources_1），也只生成**本次新建的 IP**
的输出产品，不会碰目标工程原有 IP。

**关于 top 模块**：仅当目标工程当前没有 top（即 A 方式新建的工程）才自动
设置；导入到**已有工程时保持其原 top 不变**，日志会提示如何手动切换。

导入脚本开头有配置变量：`new_project_name` / `new_project_dir` / `part` /
`top_module`（仅当目标工程没有 top 时设置，见上）/ `generate_targets`
（**默认 0**：导入时不生成 IP 输出产品，编译综合时 Vivado 会自动按需生成；
改成 1 则在导入后立即预生成，慢且吃内存）。

### GUI 导入弹 "GUI Out of Memory" 怎么办

一次性重建几十个 IP 在 GUI 里也比较吃内存（16GB 的机器容易顶不住）。
现在导入**默认不再预生成 IP 输出产品**（`generate_targets 0`，编译时自动按需生成），
一般不会再 OOM；如果仍然紧张，按推荐顺序：

1. **改用批处理导入**（本工具在 87 个 IP 的工程上批处理验证过，见上面 B 两种方式）。
2. 导入前关掉其他 Vivado 实例/工程（每个打开的工程都要吃几个 GB）。
3. 一次只导一个模块的包，别把多个包的导入叠在同一次会话里。

导入只会触碰**本次新建的 IP**，不会重新生成目标工程里原有的 IP 的输出产品。

## 生成的包结构

```
deps_export_ZU48_TOP_时间戳/
├── src/                 所有依赖源文件（保持原目录结构）
├── data/                $readmemh/$readmemb 引用的数据文件（如有）
├── ip/<IP名>/<IP名>.tcl 每个 IP 的参数化重建脚本
├── import_design.tcl    一键导入脚本
├── report.txt           导出清单 + 未解析引用列表
└── sources.f            源文件相对路径清单（可供 ModelSim xsim 等使用）
```

## 依赖分析原理与边界

- 通过解析 RTL 文本（`module` / `interface` / `package` / `entity` 的定义与
  实例化、`` `include``、`$readmem*`、SV `import pkg::`）递归闭包，不跑综合，
  秒级完成、对 GBK/带中文注释的源码安全。
- 以下内容**不会**被当成用户源码：IP/BD 的生成产物（`*_sim_netlist.*`、
  `*_stub.*`、`*_rfs.*`、`/bd/` 与 `/ .gen/` 路径下的文件）。
- **Block design 不在范围内**（按需求，BD 可用 Vivado 自带
  `write_bd_tcl` 单独导出）。若目标模块依赖 BD，会在日志里明确警告。
- 宏拼接等纯文本技巧产生的实例化看不到；所有解析不到的实例化名字会列在
  `report.txt` 的 unresolved 列表里（Xilinx unisim 原语已过滤），导出后
  建议检查一眼。
- 同名模块在 sources_1 和 sim_1 都存在时，优先取 sources_1 的那份。
- IP 名与 xci 文件名不一致、同一 xci 多副本等情况按 `get_ips` 的模块名处理。

## 已知限制

- 需要在与源工程相同/兼容的 Vivado 版本下使用（目标版本更新时，导入脚本会
  自动对 locked IP 尝试 `upgrade_ip`）。
- XDC 默认不导出（需要加 `-xdc`）。
- 本脚本只读取源工程，不修改任何原始文件。
- 延迟形式实例化 `mod #10 u (...)` 不识别（`#(参数)` 形式没问题）。
- 同一个 IP 引用两个不同目录下的同名 .coe 时，补丁只保留第一份内容（罕见；
  2022.1 的 write_ip_tcl 直接内嵌系数，通常不触发此路径）。
- 若一个模块名出现在多个被导出的文件里（重复定义），导出时会打 WARNING，
  导入后综合会报重复定义，按警告处理源文件即可。
