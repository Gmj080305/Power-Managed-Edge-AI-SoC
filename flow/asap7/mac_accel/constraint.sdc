# ASAP7 timing for the MAC accelerator (time unit: ps).
# 700 ps is deliberately tight for an all-RVT build so the Vt mix matters;
# move it if every variant passes or fails by a wide margin.
current_design mac_accel
set clk_period 700
create_clock -name core_clk -period $clk_period [get_ports clk]
set_clock_uncertainty 20 [get_clocks core_clk]
create_clock -name vclk -period $clk_period
set_input_delay  [expr {$clk_period * 0.2}] -clock vclk [all_inputs -no_clocks]
set_output_delay [expr {$clk_period * 0.2}] -clock vclk [all_outputs]
