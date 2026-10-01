#!/usr/bin/env bash
#=============================================================================
# run_xsim.sh -- 用 Vivado 自带仿真器 (xvlog/xelab/xsim) 跑 dsp 家族自检
#
# 用法:
#   bash sim/run_xsim.sh                 # 默认 Vivado 2022.1
#   bash sim/run_xsim.sh 2018.3          # 指定 Vivado 版本
#   VIVADO_ROOT=/d/Xilinx/Vivado/2024.2 bash sim/run_xsim.sh
#
# 说明: dsp 家族是纯 RTL (无 XPM 依赖), 不需要编译 XPM 源码和 glbl。
#=============================================================================
set -e

VIVADO_VER="${1:-2022.1}"
VIVADO_ROOT="${VIVADO_ROOT:-/c/Xilinx/Vivado/${VIVADO_VER}}"
XV="${VIVADO_BIN:-${VIVADO_ROOT}/bin}"

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "${HERE}/.." && pwd)"
WORK="${HERE}/xsim_work"

if [ ! -f "${XV}/xvlog" ]; then
    echo "找不到 ${XV}/xvlog。用 'bash run_xsim.sh <Vivado版本>' 或设 VIVADO_ROOT 指定路径。" >&2
    exit 1
fi

mkdir -p "${WORK}"
cd "${WORK}"
rm -rf xsim.dir xvlog.log xelab.log xsim.log xsim_out.txt

echo "== xvlog (编译 dsp 源码 / tb) =="
"${XV}/xvlog" -sv \
    "${ROOT}/dsp_cordic.sv" \
    "${HERE}/tb_dsp_cordic.sv"

echo "== xelab =="
"${XV}/xelab" tb_dsp_cordic -s tb_dsp --debug typical

echo "== xsim =="
"${XV}/xsim" tb_dsp -runall | tee xsim_out.txt

if grep -q "=== ALL PASS ===" xsim_out.txt; then
    if grep -qE "^Error:" xsim_out.txt; then
        echo "== 仿真输出含 Error, 完整输出见 ${WORK}/xsim_out.txt ==" >&2
        exit 1
    fi
    echo "== 自检通过 =="
else
    echo "== 自检失败, 完整输出见 ${WORK}/xsim_out.txt ==" >&2
    exit 1
fi
