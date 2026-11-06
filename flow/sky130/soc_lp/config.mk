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

# Keep the three power domains as netlist hierarchy. ORFS renames flattened
# logic gates to _NNN_, so without this only flip-flops would keep their
# u_cmp/u_mem prefix and the per-domain power split would be wrong.
# (Wildcards: cmp_top/mem_top are parameter-specialised, e.g. $paramod..\cmp_top.)
export SYNTH_KEEP_MODULES = *cmp_top* *mem_top* *aon_top*

export CORE_UTILIZATION   = 35
export PLACE_DENSITY      = 0.55
export TNS_END_PERCENT    = 100
