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

Verilog / SystemVerilog 源码目录，待填充。
