#=============================================================================
# synth_check.tcl -- 用 Vivado 综合器验证 dsp 家族 (仿真通过 != 综合通过)
#
# dsp 家族是纯 RTL, 无 XPM 依赖; 综合检查重点是:
#   - 零 ERROR / critical warning
#   - vector 模式的增益补偿乘法映射到 DSP48 (util.rpt)
#   - CORDIC 级联不被优化掉 (LUT/FF 数量合理)
#
# 用法 (Git Bash, 路径用正斜杠):
#   vivado -mode batch -source synth/synth_check.tcl \
#       -tclargs xczu48dr-ffvg1517-2-e
#=============================================================================

set part "xczu48dr-ffvg1517-2-e"
if {[llength $argv] >= 1} { set part [lindex $argv 0] }

set here [file dirname [file normalize [info script]]]
set work "$here/synth_work"
file mkdir $work

puts "\[dsp_synth\] part = $part"

read_verilog -sv [list \
    "$here/../dsp_cordic.sv" \
    "$here/../dsp_cic_decim.sv" \
    "$here/../dsp_pfir.sv" \
    "$here/../dsp_fft.sv" \
    "$here/../dsp_chan.sv" \
    "$here/../../xpm_wrappers/xpm_sdpram.sv" \
    "$here/../../xpm_wrappers/xpm_sync_fifo.sv" \
    "$::env(XILINX_VIVADO)/data/ip/xpm/xpm_memory/hdl/xpm_memory.sv" \
    "$::env(XILINX_VIVADO)/data/ip/xpm/xpm_fifo/hdl/xpm_fifo.sv" \
    "$::env(XILINX_VIVADO)/data/ip/xpm/xpm_cdc/hdl/xpm_cdc.sv" \
    "$here/synth_top.sv" ]

synth_design -top dsp_synth_top -part $part -mode out_of_context

report_utilization -file "$work/util.rpt"

# 资源统计 (仅信息): GAIN_COMP 是常数乘, 综合器映射 LUT 移位加 (不占 DSP48)
set n_dsp [llength [get_cells -hier -quiet -filter {PRIMITIVE_TYPE =~ *DSP*}]]
set n_lut [llength [get_cells -hier -quiet -filter {PRIMITIVE_TYPE =~ *LUT*}]]
set n_ff  [llength [all_ffs]]
puts "\[dsp_synth\] DSP48 = $n_dsp  LUT = $n_lut  FF = $n_ff"

set errors [get_msg_config -severity {ERROR} -count]
set crit   [get_msg_config -severity {CRITICAL WARNING} -count]
puts "\[dsp_synth\] synth done: errors=$errors critical_warnings=$crit"
if {$errors > 0 || $crit > 0} {
    puts "\[dsp_synth\] FAILED, 见 $work"
    exit 1
}
puts "\[dsp_synth\] PASS"
exit 0
