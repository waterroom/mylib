#!/usr/bin/env bash
#=============================================================================
# run_xsim.sh -- 用 Vivado 自带仿真器 (xvlog/xelab/xsim) 跑 xpm_wrappers 自检
#
# 用法:
#   bash sim/run_xsim.sh                 # 默认 Vivado 2022.1
#   bash sim/run_xsim.sh 2018.3          # 指定 Vivado 版本
#   VIVADO_BIN=/path/to/bin bash sim/run_xsim.sh    # 直接指定 bin 目录
#
# 说明:
#   - XPM 原语不会随仿真器自动加载, 脚本显式编译 Vivado 安装目录里的 XPM
#     源码 (data/ip/xpm/*/hdl/*.sv, 明文可见);
#   - XPM 源码引用 glbl.GSR 做上电初始化, 所以精化时把 glbl 一起作为顶层
#     (xelab ... glbl);
#   - 中间产物都在 sim/xsim_work/, 可随时删除; 结果同时打印并写入
#     sim/xsim_work/xsim_out.txt。
#=============================================================================
set -e

VIVADO_VER="${1:-2022.1}"
VIVADO_ROOT="${VIVADO_ROOT:-/c/Xilinx/Vivado/${VIVADO_VER}}"
XV="${VIVADO_BIN:-${VIVADO_ROOT}/bin}"

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "${HERE}/.." && pwd)"
WORK="${HERE}/xsim_work"
XPM="${VIVADO_ROOT}/data/ip/xpm"
GLBL="${VIVADO_ROOT}/data/verilog/src/glbl.v"

if [ ! -f "${XV}/xvlog" ]; then
    echo "找不到 ${XV}/xvlog。用 'bash run_xsim.sh <Vivado版本>' 或设 VIVADO_BIN 指定路径。" >&2
    exit 1
fi

mkdir -p "${WORK}"
cd "${WORK}"
rm -rf xsim.dir xvlog.log xelab.log xsim.log xsim_out.txt *.pb

echo "== xvlog (编译 wrapper / tb / XPM 源码) =="
"${XV}/xvlog" -sv \
    "${ROOT}/xpm_cdc_sync.sv"  "${ROOT}/xpm_rst_sync.sv"  "${ROOT}/xpm_pulse_sync.sv" \
    "${ROOT}/xpm_sync_fifo.sv" "${ROOT}/xpm_async_fifo.sv" \
    "${HERE}/tb_xpm_wrappers.sv" \
    "${XPM}/xpm_cdc/hdl/xpm_cdc.sv" \
    "${XPM}/xpm_fifo/hdl/xpm_fifo.sv" \
    "${XPM}/xpm_memory/hdl/xpm_memory.sv" \
    "${GLBL}"

echo "== xelab =="
"${XV}/xelab" tb_xpm_wrappers glbl -s tb_sim --debug typical

echo "== xsim =="
"${XV}/xsim" tb_sim -runall | tee xsim_out.txt

if grep -q "=== ALL PASS ===" xsim_out.txt; then
    echo "== 自检通过 =="
else
    echo "== 自检失败, 完整输出见 ${WORK}/xsim_out.txt ==" >&2
    exit 1
fi