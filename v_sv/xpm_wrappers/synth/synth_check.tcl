#=============================================================================
# synth_check.tcl -- 用 Vivado 综合器验证 xpm_wrappers (仿真通过 != 综合通过)
#
# XPM 在综合时走的是另一套参数检查 (合法值、器件代际支持、原语映射), 所以除了
# 行为仿真, 再用真实器件把全部 8 个 wrapper 按典型配置综合一遍。默认器件用 xczu48dr
# (RFSoC ZU48, UltraScale+), 也可以用 -tclargs 换成别的已安装器件。
#
# 用法 (Git Bash, 路径用正斜杠):
#   vivado -mode batch -source synth/synth_check.tcl \
#       -tclargs xczu48dr-ffvg1517-2-e
#
# 输出: synth/synth_work/ 下的综合日志与 report_utilization。
# 期望: 综合完成且没有 ERROR / critical warning; 报告里能看到:
#   - 两个 FIFO 各自映射到 BRAM / LUTRAM (RAMB36 / RAM32M 等)
#   - 异步 FIFO 的指针 CDC 有 ASYNC_REG 属性
#=============================================================================

set part "xczu48dr-ffvg1517-2-e"
if {[llength $argv] >= 1} { set part [lindex $argv 0] }

set here [file dirname [file normalize [info script]]]
set root [file dirname $here]
set work "$here/synth_work"
file mkdir $work

puts "\[synth_check\] part = $part"
puts "\[synth_check\] sources = $root/*.sv"

read_verilog -sv [list \
    "$root/xpm_cdc_sync.sv" \
    "$root/xpm_rst_sync.sv" \
    "$root/xpm_pulse_sync.sv" \
    "$root/xpm_sync_fifo.sv" \
    "$root/xpm_async_fifo.sv" \
    "$root/xpm_sync_rst.sv" \
    "$root/xpm_sdpram.sv" \
    "$root/xpm_handshake.sv" \
    "$here/synth_top.sv" ]

# 纯 RTL 检查, 不需要完整器件布线资源
synth_design -top synth_top -part $part -mode out_of_context

report_utilization -file "$work/util.rpt"
report_drc -file "$work/drc.rpt"

# 同步器寄存器必须带 ASYNC_REG (XPM 原语自带, 这里确认综合后没丢)
set n_async [llength [get_cells -hier -quiet -filter {ASYNC_REG == "TRUE"}]]
puts "\[synth_check\] ASYNC_REG cells = $n_async"

set errors [get_msg_config -severity {ERROR} -count]
set crit   [get_msg_config -severity {CRITICAL WARNING} -count]
puts "\[synth_check\] synth done: errors=$errors critical_warnings=$crit async_reg_cells=$n_async"
if {$errors > 0 || $crit > 0} {
    puts "\[synth_check\] FAILED: 综合有 ERROR 或 critical warning, 见 $work/runme.log"
    exit 1
}
if {$n_async < 10} {
    puts "\[synth_check\] FAILED: ASYNC_REG 单元只有 $n_async 个, 同步器约束可能丢了"
    exit 1
}
puts "\[synth_check\] PASS"
exit 0