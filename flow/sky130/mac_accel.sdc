# mac_accel.sdc - the accelerator alone at the SoC's OPP-H clock.
current_design mac_accel
set clk_period 20.0
create_clock -name core_clk -period $clk_period [get_ports clk]
set_clock_uncertainty 0.25 [get_clocks core_clk]
create_clock -name vclk -period $clk_period
set_input_delay  [expr {$clk_period * 0.2}] -clock vclk [all_inputs -no_clocks]
set_output_delay [expr {$clk_period * 0.2}] -clock vclk [all_outputs]
