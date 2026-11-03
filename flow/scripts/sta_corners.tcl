# sta_corners.tcl - one STA corner on a routed design (one run per corner,
# because OpenSTA here holds a single library set at a time).
#
#   LIB=<corner .lib> ODB=.../6_final.odb SDC=flow/sky130/soc.sdc \
#   [SPEF=...] PERIOD=<ns> TAG=<name> OUT=<dir> \
#   openroad -exit -no_init flow/scripts/sta_corners.tcl
#
# Corners for this SoC (libraries from an open_pdks / ciel sky130A install,
# $PDK_ROOT/sky130A/libs.ref/sky130_fd_sc_hd/lib/):
#   OPP-H setup  sky130_fd_sc_hd__ss_100C_1v60.lib   PERIOD=20
#   OPP-L setup  sky130_fd_sc_hd__ss_100C_1v40.lib   PERIOD=40  (clk_in/2)
#   hold         sky130_fd_sc_hd__ff_n40C_1v95.lib   PERIOD=20
#   typ power    sky130_fd_sc_hd__tt_025C_1v80.lib   PERIOD=20
read_liberty $::env(LIB)
read_db $::env(ODB)
read_sdc $::env(SDC)
if {[info exists ::env(PERIOD)]} {
  create_clock -name core_clk -period $::env(PERIOD) [get_ports clk_in]
  create_clock -name vclk -period $::env(PERIOD)
}
if {[info exists ::env(SPEF)] && [file exists $::env(SPEF)]} { read_spef $::env(SPEF) }
set_propagated_clock [all_clocks]
set f $::env(OUT)/sta_$::env(TAG).rpt
report_checks -path_delay max -group_path_count 5 > $f
report_checks -path_delay min -group_path_count 5 >> $f
report_tns >> $f
report_wns >> $f
report_worst_slack -max >> $f
report_worst_slack -min >> $f
puts "sta_corners: $::env(TAG) -> $f"
