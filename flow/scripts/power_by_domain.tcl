# power_by_domain.tcl - per-instance power of a finished ORFS run, for the
# per-domain summary (summarize_power.py). Run with OpenROAD:
#
#   LIBS="<lib files>" ODB=.../6_final.odb SDC=.../6_final.sdc \
#   [SPEF=.../6_final.spef] [VCD=activity.vcd SCOPE=tb_power/dut] OUT=<dir> \
#   openroad -exit -no_init flow/scripts/power_by_domain.tcl
#
# Without a VCD, OpenSTA uses default toggle rates: leakage is still exact,
# dynamic power is only an estimate.
foreach lib $::env(LIBS) { read_liberty $lib }
read_db  $::env(ODB)
read_sdc $::env(SDC)
if {[info exists ::env(SPEF)] && [file exists $::env(SPEF)]} {
  read_spef $::env(SPEF)
}
if {[info exists ::env(VCD)] && [file exists $::env(VCD)]} {
  read_vcd -scope $::env(SCOPE) $::env(VCD)
  report_activity_annotation > $::env(OUT)/activity_annotation.rpt
}
report_power > $::env(OUT)/power_total.rpt
report_power -instances [get_cells *] > $::env(OUT)/power_instances.rpt
puts "power_by_domain: reports in $::env(OUT)"
