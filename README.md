# mylib

个人日常使用的代码与脚本库。按语言 / 工具分目录，每个工具尽量自带用法说明
（脚本头部的 docstring 或同目录的 README）。

## 目录结构

| 目录 | 内容 |
| --- | --- |
| `matlab/` | MATLAB 相关工具 |
| `py/` | Python 脚本 |
| `tcl/` | Tcl 脚本（Vivado 为主） |
| `v_sv/` | Verilog / SystemVerilog 源码 |

## matlab/

### `matlab/gen_wv/`

`[feiq]GenerateWV.exe` —— 生成 `.wv` 波形文件的 Windows 小工具（预编译
二进制，2019 年收的，文件名前缀 `[feiq]` 是飞秋传文件带的，不影响使用）。

## py/

### `py/std_file_to_others/`

SDR 采集的 `.STD` 文件格式转换工具，依赖 `numpy`。

**`std_to_cs16.py`** —— `.STD` → `.cs16`（交织 int16 复数 I/Q）。
按 STD 头 `datatype` 字段正确解析（FS27MHz 系列的 float32 老版本曾被当 int16
读导致频谱全是伪迹），自动判别实/复信号，默认自动 dechirp 补偿载波频偏。

```bash
python std_to_cs16.py input.std -o output.cs16
```

**`std_to_wv.py`** —— `.STD` → R&S `.wv`（A100 信号源导入）。
字节布局对齐 R&S MATLAB Toolkit 的 `rs_generate_wave.m`，写入后自带读回校验。

```bash
python std_to_wv.py input.std -o output.wv
```

两个脚本的详细说明（STD 头 50 字节布局、实/复信号判据、频偏处理策略、下游
用法）都写在文件头部 docstring 里；命令行参数用 `-h` 查看。

## tcl/

### `tcl/export_and_import_module/`

`export_deps.tcl` —— **Vivado 按模块导出依赖**。给源工程的任意一个文件 /
模块，递归解析出全部依赖的源文件和 IP 核，打包成自包含目录；在另一台机器 /
另一个 Vivado 工程里跑包内的 `import_design.tcl` 即可一键导入
（源文件复制进 `imported_sources/`，Xilinx IP 按 `create_ip` + CONFIG 参数重建，
不复制 `.xci` / `.gen` 产物）。

完整用法、实例、生成包结构、依赖分析原理与已知限制见
[`README_export_deps.md`](tcl/export_and_import_module/README_export_deps.md)。

## v_sv/

### `v_sv/xpm_wrappers/`

**Xilinx XPM 常用宏的薄封装**（SystemVerilog）。XPM 是 Vivado 自带的官方基础
库，CDC / FIFO / 复位同步这类基础设施应当直接用它；但 XPM 的接口名跨代稳定、
**参数契约不稳定**（合法参数值、可用特性、默认行为随器件代际和 Vivado 版本
漂移），`USE_ADV_FEATURES` 这类位定义又属于"抄错一个字符就让输出恒零"的暗
知识。这一层把日常最高频的部分固化下来：统一命名、统一"异步置位 / 同步释放"
的复位风格、固化参数与特性位，以后换器件 / 换 Vivado 版本只改这一层。

> **库版本 1.0**（2026-09）：8 模块 + 约束模板；自检 290 项，
> Vivado 2018.3 / 2022.1 / 2024.2 三版本回归。

八个模块：`xpm_cdc_sync`（单 bit / 总线电平同步）、`xpm_rst_sync`（复位桥）、
`xpm_sync_rst`（同步复位同步器，上电即复位可选）、`xpm_pulse_sync`（脉冲 /
事件跨时钟）、`xpm_handshake`（多 bit 数据握手跨时钟）、`xpm_sdpram`（简单
双口 RAM，缓冲 / 延迟线）、`xpm_sync_fifo`、`xpm_async_fifo`。附异步时钟组
约束模板（`constrs/xpm_wrappers.xdc`）。
附自检 testbench（290 项检查，`sim/run_xsim_all.sh` 三版本一键跑）和真实器件综合检查
（`synth/synth_check.tcl`，默认 xczu48dr）。

用法、参数/端口速查、以及实测得到的几条关键结论（XPM 默认 `"0707"` 不含
`almost_*` / `data_valid`；异步 FIFO 有效深度 = `DEPTH`-1；`count` 不能当精确
流控阈值等）见 [`README.md`](v_sv/xpm_wrappers/README.md)。
