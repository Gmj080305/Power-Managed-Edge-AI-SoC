# domains.tcl - EXPERIMENTAL (POST_FLOORPLAN_TCL): power domains and their
# placement regions, from the OpenROAD-readable subset of the power intent.
# The core is split left to right: PD_CMP 50 %, PD_MEM 30 %, PD_AON the rest.
set repo [file normalize [file dirname [info script]]/../../..]
read_upf -file $repo/upf/soc_openroad.upf

set core [ord::get_core_area]
lassign $core cx0 cy0 cx1 cy1
set w [expr {$cx1 - $cx0}]
set cmp_x1 [expr {$cx0 + 0.50 * $w}]
set mem_x1 [expr {$cx0 + 0.80 * $w}]

# Keep a gap of a few rows between regions for the domain boundaries.
set gap 10.0
set_domain_area PD_CMP -area [list $cx0 $cy0 [expr {$cmp_x1 - $gap}] $cy1]
set_domain_area PD_MEM -area [list [expr {$cmp_x1 + $gap}] $cy0 [expr {$mem_x1 - $gap}] $cy1]
puts "domains.tcl: PD_CMP x < [format %.1f $cmp_x1], PD_MEM to [format %.1f $mem_x1], PD_AON beyond"
