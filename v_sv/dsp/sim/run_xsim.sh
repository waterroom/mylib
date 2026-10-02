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

echo "== xvlog (编译 dsp 源码 / tb / 库内 xpm_sdpram) =="
"${XV}/xvlog" -sv \
    "${ROOT}/dsp_cordic.sv"     "${ROOT}/dsp_cic_decim.sv"  "${ROOT}/dsp_pfir.sv" \
    "${ROOT}/dsp_fft.sv" \
    "${ROOT}/../xpm_wrappers/xpm_sdpram.sv" \
    "${HERE}/tb_dsp_cordic.sv"  "${HERE}/tb_dsp_cic_decim.sv"  "${HERE}/tb_dsp_pfir.sv"  "${HERE}/tb_dsp_fft.sv" \
    "${VIVADO_ROOT}/data/ip/xpm/xpm_memory/hdl/xpm_memory.sv" \
    "${VIVADO_ROOT}/data/verilog/src/glbl.v"

echo "== xelab =="
"${XV}/xelab" tb_dsp_cordic     glbl -s tb_dsp_cordic     --debug typical
"${XV}/xelab" tb_dsp_cic_decim  glbl -s tb_dsp_cic_decim  --debug typical
"${XV}/xelab" tb_dsp_pfir        glbl -s tb_dsp_pfir        --debug typical
"${XV}/xelab" tb_dsp_fft         glbl -s tb_dsp_fft         --debug typical

echo "== xsim =="
rm -f xsim_out.txt
"${XV}/xsim" tb_dsp_cordic    -runall | tee    xsim_out.txt
"${XV}/xsim" tb_dsp_cic_decim -runall | tee -a xsim_out.txt
"${XV}/xsim" tb_dsp_pfir        -runall | tee -a xsim_out.txt
"${XV}/xsim" tb_dsp_fft         -runall | tee -a xsim_out.txt

N_PASS=$(grep -c "=== ALL PASS ===" xsim_out.txt || true)
if [ "${N_PASS}" -ge 4 ] && ! grep -qE "^Error:" xsim_out.txt; then
    echo "== 自检通过 (4/4 top) =="
else
    echo "== 自检失败, 完整输出见 ${WORK}/xsim_out.txt ==" >&2
    exit 1
fi
