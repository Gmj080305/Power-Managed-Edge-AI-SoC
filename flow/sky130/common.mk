# common.mk - shared settings for every Sky130 design config in this repo.
# Included by flow/sky130/<design>/config.mk. ORFS passes DESIGN_CONFIG as
# an absolute path, so everything is located relative to it.
REPO_DIR    := $(abspath $(dir $(DESIGN_CONFIG))/../../..)
RTL_FILES   := $(shell grep -v '^//' $(REPO_DIR)/rtl/files.f)

export PLATFORM    = sky130hd
export WORK_HOME  ?= $(REPO_DIR)/build/orfs
