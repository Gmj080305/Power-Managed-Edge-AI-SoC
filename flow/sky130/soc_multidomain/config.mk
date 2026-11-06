# EXPERIMENTAL - three physical power domains with separate supplies.
#   PD_AON  VDD_AON  core area outside the two regions
#   PD_CMP  VDD_CMP  region, DVFS supply (1.80 / ~1.50 V), level shifters
#   PD_MEM  VDD_MEM  region
# Sky130 HD has no power-switch cell, so each switched domain gets its own
# supply pin (an ideal off-chip switch), and the level shifters' LOWLVPWR
# pins are tied to VDD_CMP. Expect to iterate on domains.tcl / pdn.tcl:
# OpenROAD's multi-domain support is partial (see docs/physical_design.md).
include $(dir $(DESIGN_CONFIG))/../common.mk

export DESIGN_NAME        = soc_top
export DESIGN_NICKNAME    = soc_multidomain
export VERILOG_FILES      = $(addprefix $(REPO_DIR)/,$(RTL_FILES))
export SDC_FILE           = $(REPO_DIR)/flow/sky130/soc.sdc
export VERILOG_DEFINES    = -DSKY130_CELLS -DSKY130_ISO -DSKY130_LS
export VERILOG_TOP_PARAMS = MAC_N 4
export SYNTH_KEEP_MODULES = *cmp_top* *mem_top* *aon_top*
export OPENROAD_HIERARCHICAL = 1

# Fixed die/core (about 30 % utilisation) instead of CORE_UTILIZATION:
# domains.tcl needs the core coordinates before the floorplan exists.
export DIE_AREA           = 0 0 1240 1240
export CORE_AREA          = 10 10 1230 1230
export PLACE_DENSITY      = 0.5
export TNS_END_PERCENT    = 100

export PRE_FLOORPLAN_TCL  = $(REPO_DIR)/flow/sky130/soc_multidomain/domains.tcl
export PDN_TCL            = $(REPO_DIR)/flow/sky130/soc_multidomain/pdn.tcl
