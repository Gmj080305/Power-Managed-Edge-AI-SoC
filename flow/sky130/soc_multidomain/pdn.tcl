# pdn.tcl - EXPERIMENTAL (PDN_TCL): one supply net and grid per domain.
# Cells inside a region connect to that region's supply; everything else to
# VDD_AON. Level shifters (PD_CMP -> PD_AON/PD_MEM) take the low supply on
# LOWLVPWR. Compare with platforms/sky130hd/pdn.tcl (single domain).

# ---------------------------------------------------------- connections
foreach {net region} {VDD_CMP PD_CMP VDD_MEM PD_MEM} {
  add_global_connection -net $net -region $region -inst_pattern {.*} -pin_pattern {^VPWR$} -power
  add_global_connection -net $net -region $region -inst_pattern {.*} -pin_pattern {^VPB$}
}
add_global_connection -net VDD_AON -inst_pattern {.*} -pin_pattern {^VPWR$} -power
add_global_connection -net VDD_AON -inst_pattern {.*} -pin_pattern {^VPB$}
add_global_connection -net VDD_CMP -inst_pattern {.*} -pin_pattern {^LOWLVPWR$}
add_global_connection -net VSS -inst_pattern {.*} -pin_pattern {^VGND$} -ground
add_global_connection -net VSS -inst_pattern {.*} -pin_pattern {^VNB$}
global_connect

# ---------------------------------------------------------- domains
set_voltage_domain -name CORE   -power VDD_AON -ground VSS
set_voltage_domain -name PD_CMP -region PD_CMP -power VDD_CMP -ground VSS
set_voltage_domain -name PD_MEM -region PD_MEM -power VDD_MEM -ground VSS

# ---------------------------------------------------------- grids
foreach dom {CORE PD_CMP PD_MEM} {
  define_pdn_grid -name grid_$dom -voltage_domains $dom -pins {met5}
  add_pdn_stripe -grid grid_$dom -layer met1 -width 0.48 -pitch 5.44 -offset 0 -followpins
  add_pdn_stripe -grid grid_$dom -layer met4 -width 1.600 -pitch 27.140 -offset 13.570
  add_pdn_stripe -grid grid_$dom -layer met5 -width 1.600 -pitch 27.200 -offset 13.600
  add_pdn_connect -grid grid_$dom -layers {met1 met4}
  add_pdn_connect -grid grid_$dom -layers {met4 met5}
}
