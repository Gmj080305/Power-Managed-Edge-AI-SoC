# domains.tcl - EXPERIMENTAL (PRE_FLOORPLAN_TCL): power domains and their
# placement regions, from the OpenROAD-readable subset of the power intent.
#
# Must run BEFORE initialize_floorplan: that command calls upf::eval_upf,
# which turns each power domain with an area into an exclusive placement
# region of the same name (needed by pdn.tcl's add_global_connection
# -region). Run after the floorplan (v0.4), the regions were never created
# and the PDN step stopped with "ORD-0045 Region PD_CMP not defined".
#
# The core area is fixed in config.mk (CORE_AREA = 10 10 1230 1230), so the
# split can be computed here: PD_CMP the left 50 %, PD_MEM the next 30 %,
# PD_AON (the top domain) the rest, with a 10 um gap at each boundary.
set repo [file normalize [file dirname [info script]]/../../..]
read_upf -file $repo/upf/soc_openroad.upf

lassign $::env(CORE_AREA) cx0 cy0 cx1 cy1
set w [expr {$cx1 - $cx0}]
set cmp_x1 [expr {$cx0 + 0.50 * $w}]
set mem_x1 [expr {$cx0 + 0.80 * $w}]
set gap 10.0
set_domain_area PD_CMP -area [list $cx0 $cy0 [expr {$cmp_x1 - $gap}] $cy1]
set_domain_area PD_MEM -area [list [expr {$cmp_x1 + $gap}] $cy0 [expr {$mem_x1 - $gap}] $cy1]
puts "domains.tcl: PD_CMP x < [format %.1f $cmp_x1], PD_MEM to [format %.1f $mem_x1], PD_AON beyond"
