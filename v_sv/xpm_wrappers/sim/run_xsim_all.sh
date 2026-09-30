#!/usr/bin/env bash
#=============================================================================
# run_xsim_all.sh -- 三版本一键回归 (换 Vivado 版本后必跑)
#
# 用法: bash sim/run_xsim_all.sh
# 版本路径在这里维护; 2018.3 / 2022.1 在 C 盘默认路径, 2024.2 装在 D 盘。
#
# 退出码: 三个版本全跑完, 任一失败则整体 exit 1。必须开 pipefail 并对每个
# run 用 "|| 计数" 保护: 不带 pipefail 时管道退出码取自 grep, run_xsim.sh
# 的失败 (如 Error 门拦截) 会被完全掩盖 -- 表面三版本全绿, 实际有版本没过。
#=============================================================================
set -e
set -o pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"

fails=0

run() {  # run <标签> <VIVADO_ROOT>
    echo "================ $1 ================"
    VIVADO_ROOT="$2" bash "${HERE}/run_xsim.sh" | grep -E "RESULT|ALL PASS|FAILED|MEASURE"
}

run "Vivado 2018.3" /c/Xilinx/Vivado/2018.3 || fails=$((fails + 1))
run "Vivado 2022.1" /c/Xilinx/Vivado/2022.1 || fails=$((fails + 1))
run "Vivado 2024.2" /d/Xilinx/Vivado/2024.2 || fails=$((fails + 1))

if [ "$fails" -ne 0 ]; then
    echo "== 三版本回归完成: ${fails} 个版本未通过 =="
    exit 1
fi
echo "== 三版本回归完成, 全部通过 =="
