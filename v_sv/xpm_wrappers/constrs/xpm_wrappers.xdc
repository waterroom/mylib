#=============================================================================
# xpm_wrappers.xdc -- 本库 CDC 模块的时序约束模板
#
# 为什么需要这个文件:
#   本库所有 wrapper 的 CDC 正确性 = ASYNC_REG (XPM 原语自带, 综合后
#   synth_check.tcl 会确认保留) + **用户声明的时钟组** (XPM 不会自动
#   豁免跨时钟路径)。时钟组不声明, 静态时序分析会把同步器第一拍当作
#   普通跨域路径去收敛, 报大量假违例, 或者更糟 -- 用户为了消违例随手
#   set_false_path 把所有跨域路径全豁免, 连真正该收敛的数据路径一起豁免。
#
# 用法: 把下面的 set_clock_groups 行按工程的时钟对补全后,
#   - 加进工程的约束集 (add_files -fileset constrs_1), 或
#   - 只拷贝需要的行进工程自己的 xdc。
#
# 哪些时钟对要声明为异步 (对应本库模块):
#   - xpm_async_fifo:        wr_clk 与 rd_clk 不同源/不同频时
#   - xpm_sdpram:            CLOCKING_MODE="independent_clock" 时 clka/clkb
#   - xpm_cdc_sync / xpm_pulse_sync / xpm_handshake / xpm_rst_sync /
#     xpm_sync_rst:          src 时钟与 dest 时钟不同源/不同频时
#
# 什么时候不用写:
#   - 两个时钟同源 (同一个 MMCM 输出), 工具已知相位关系 -- 别声明异步,
#     否则域内/相关路径的时序检查会被错误豁免;
#   - xpm_async_fifo 的 RELATED_CLOCKS=1 本来就是为同源时钟设计的,
#     此时也不要写下面的约束。
#
# ASYNC_REG 无需用户重复约束: XPM 原语内部已带, 见 synth/synth_check.tcl
# 的 ASYNC_REG 单元计数检查。
#=============================================================================

#-----------------------------------------------------------------------------
# 1) 异步 FIFO: 写时钟 vs 读时钟 (每个异步 FIFO 实例一对, 同一对时钟多实例
#    只写一次)
#-----------------------------------------------------------------------------
# set_clock_groups -asynchronous \
#     -group [get_clocks -include_generated_clocks clk_100m] \
#     -group [get_clocks -include_generated_clocks clk_57m]

#-----------------------------------------------------------------------------
# 2) 独立时钟 sdpram: 写时钟 vs 读时钟 (CLOCKING_MODE="independent_clock" 的
#    实例; "common_clock" 的不要写)
#-----------------------------------------------------------------------------
# set_clock_groups -asynchronous \
#     -group [get_clocks -include_generated_clocks clk_adc] \
#     -group [get_clocks -include_generated_clocks clk_dsp]

#-----------------------------------------------------------------------------
# 3) CDC 同步器类 (xpm_cdc_sync / xpm_pulse_sync / xpm_handshake /
#    xpm_rst_sync / xpm_sync_rst): 源时钟 vs 目的时钟。同上, 每对写一次。
#-----------------------------------------------------------------------------
# set_clock_groups -asynchronous \
#     -group [get_clocks -include_generated_clocks clk_mmcm] \
#     -group [get_clocks -include_generated_clocks clk_100m]

#-----------------------------------------------------------------------------
# 4) (可选) 自检: 综合后确认 ASYNC_REG 没被优化掉, 用法同 synth_check.tcl
#-----------------------------------------------------------------------------
# report_property [lindex [get_cells -hier -quiet -filter {ASYNC_REG == "TRUE"}] 0] ASYNC_REG
