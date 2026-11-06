# soc.sdc - timing constraints for soc_top (Sky130, OPP-H sign-off).
#
# clk_in drives clk_sys directly at OPP-H. At OPP-L the same paths run from
# clk_in/2, i.e. twice the period at the lower voltage: that check is a
# separate STA run (flow/scripts/sta_corners.tcl) with the low-voltage
# library, so the divided clock is not modelled here.
current_design soc_top

set clk_period 20.0            ;# 50 MHz at 1.80 V
set io_pct     0.2

create_clock -name core_clk -period $clk_period [get_ports clk_in]
create_clock -name clk_32k  -period 30517.6     [get_ports clk_32k]
set_clock_groups -asynchronous -group {core_clk} -group {clk_32k}
set_clock_uncertainty 0.25 [get_clocks core_clk]

create_clock -name vclk -period $clk_period
set_input_delay  [expr {$clk_period * $io_pct}] -clock vclk [all_inputs -no_clocks]
set_output_delay [expr {$clk_period * $io_pct}] -clock vclk [all_outputs]

# Asynchronous pins: each enters through a 2-flop synchroniser (the
# regulator and power-switch handshakes since v1.0, see aon_top.sv).
set_false_path -from [get_ports {por_n gpio_wake host_wake test_en vdd_ok sw_ack_cmp sw_ack_mem}]
