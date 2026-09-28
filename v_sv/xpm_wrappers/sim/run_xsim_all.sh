#!/usr/bin/env bash
#=============================================================================
# run_xsim_all.sh -- 三版本一键回归 (换 Vivado 版本后必跑)
#
# 用法: bash sim/run_xsim_all.sh
# 版本路径在这里维护; 2018.3 / 2022.1 在 C 盘默认路径, 2024.2 装在 D 盘。
#=============================================================================
set -e

HERE="$(cd "$(dirname "$0")" && pwd)"

run() {  # run <标签> <VIVADO_ROOT>
    echo "================ $1 ================"
    VIVADO_ROOT="$2" bash "${HERE}/run_xsim.sh" | grep -E "RESULT|ALL PASS|FAILED|MEASURE"
}

run "Vivado 2018.3" /c/Xilinx/Vivado/2018.3
run "Vivado 2022.1" /c/Xilinx/Vivado/2022.1
run "Vivado 2024.2" /d/Xilinx/Vivado/2024.2

echo "== 三版本回归完成 =="
