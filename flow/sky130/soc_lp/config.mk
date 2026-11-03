# Power-managed SoC in one physical voltage area: real Sky130 isolation
# cells (lpflow_isobufsrc / inputiso1p) and clock gates; the logical domains
# stay visible as instance prefixes (u_aon, u_cmp, u_mem), which is what the
# per-domain power report uses. CI implements this configuration.
include $(dir $(DESIGN_CONFIG))/../common.mk

export DESIGN_NAME        = soc_top
export DESIGN_NICKNAME    = soc_lp
export VERILOG_FILES      = $(addprefix $(REPO_DIR)/,$(RTL_FILES))
export SDC_FILE           = $(REPO_DIR)/flow/sky130/soc.sdc
export VERILOG_DEFINES    = -DSKY130_CELLS -DSKY130_ISO
export VERILOG_TOP_PARAMS = MAC_N 4

export CORE_UTILIZATION   = 35
export PLACE_DENSITY      = 0.55
export TNS_END_PERCENT    = 100
