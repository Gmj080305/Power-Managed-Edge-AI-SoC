# ASAP7 multi-Vt study, variant: rvt (ASAP7_USE_VT = RVT).
# The first Vt listed is the primary library (tie cells, buffers, fill);
# any others are added to the libraries the flow may use. Count the LVT
# cells in the final report to see how many the repair steps picked.
REPO_DIR := $(abspath $(dir $(DESIGN_CONFIG))/../../..)

export PLATFORM           = asap7
export DESIGN_NAME        = mac_accel
export DESIGN_NICKNAME    = mac_accel
export FLOW_VARIANT       = rvt
export ASAP7_USE_VT       = RVT
export WORK_HOME         ?= $(REPO_DIR)/build/orfs
export VERILOG_FILES      = $(addprefix $(REPO_DIR)/rtl/,pkg/soc_pkg.sv common/bus_slave_ack.sv \
                              common/icg.sv cmp/mac_pe.sv cmp/mac_array.sv cmp/mac_accel.sv)
export SDC_FILE           = $(REPO_DIR)/flow/asap7/mac_accel/constraint.sdc
export VERILOG_TOP_PARAMS = N 4

export CORE_UTILIZATION   = 45
export PLACE_DENSITY      = 0.6
export TNS_END_PERCENT    = 100
