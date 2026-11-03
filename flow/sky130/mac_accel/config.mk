# The MAC accelerator on its own: quick runs for clock-gating and
# array-size (N) experiments.
include $(dir $(DESIGN_CONFIG))/../common.mk

export DESIGN_NAME        = mac_accel
export DESIGN_NICKNAME    = mac_accel
export VERILOG_FILES      = $(addprefix $(REPO_DIR)/rtl/,pkg/soc_pkg.sv common/bus_slave_ack.sv \
                              common/icg.sv cmp/mac_pe.sv cmp/mac_array.sv cmp/mac_accel.sv)
export SDC_FILE           = $(REPO_DIR)/flow/sky130/mac_accel.sdc
export VERILOG_DEFINES    = -DSKY130_CELLS
export VERILOG_TOP_PARAMS = N 4

export CORE_UTILIZATION   = 40
export PLACE_DENSITY      = 0.6
export TNS_END_PERCENT    = 100
