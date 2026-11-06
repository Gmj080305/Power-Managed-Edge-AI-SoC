# Changelog

## v0.2.0 - gate-level power simulation, CDC fix, CI hardening

- **Power-aware gate-level simulation** (`run.py gls`, `tb/gls/tb_gls.sv`):
  the Sky130 netlist (real isolation, level-shifter and clock-gate cells, one
  module per power domain) gets supply pins (`scripts/gls_power_pins.py`) and
  runs on SkyWater's functional power models, so an unpowered domain goes X
  because the cell library says so. Host-driven walk through ACTIVE_H, IDLE,
  ACTIVE_L and SLEEP with accelerator jobs and retention checks: 5,367 checks
  pass, PD_CMP is X inside on every one of its 975 off cycles, and nothing
  outside it sees an X. `gls --fault` (isolation removed) must fail, and does.
- **Wake-timer fix** (open question #7): an expiry already in flight through
  the 32 kHz -> clk_sys synchroniser when the timer was re-armed could wake the
  next power-down immediately. Expiries now carry the arm generation and stale
  ones are dropped. New unit test `tb/unit/tb_wake_timer.sv` re-arms exactly on
  an expiry; it fails on v0.1 and passes now (`run.py unit`).
- **Per-domain power naming**: ORFS flattening renamed logic gates to `_NNN_`,
  so only flip-flops kept their `u_cmp` / `u_mem` prefix and the per-domain
  split would have put most PD_CMP logic in PD_AON. The SoC configs now keep
  `cmp_top`, `mem_top`, `aon_top` as hierarchy (`SYNTH_KEEP_MODULES`);
  `power_by_domain.tcl` reports leaf cells only, and `summarize_power.py`
  refuses a report where PD_CMP holds under 20 % of the cells.
- **Strict elaboration** (`run.py elab`): every testbench configuration,
  including the xsim-only code (covergroups, constraints, `##` sequences), is
  compiled by slang (pyslang) in CI, so xsim-path syntax errors show up on
  every push even though CI has no Vivado.
- **Corner STA in `pnr`**: the `soc_lp` job installs a sky130 PDK with ciel and
  times OPP-H (ss 1.60 V, 20 ns), OPP-L (ss 1.40 V, 40 ns), hold (ff 1.95 V)
  and typical on the routed design; results go to the job summary.
- `verify` workflow: added elab, unit and GLS steps. First push of v0.1 passed
  on GitHub Actions.

## v0.1.0 - initial import

First complete version of the 10-step plan.

- RTL: 3-domain SoC (PD_AON, PD_CMP, PD_MEM) with PicoRV32, INT8 systolic MAC
  accelerator (N = 2..8), PMU with power gating, retention and 2-point DVFS,
  32 kHz wake timer, GPIO and host wake, isolation / level-shifter / clock-gate
  wrappers mapped to Sky130 low-power cells.
- Firmware covering cold boot, self-test, illegal requests, DVFS, IDLE and
  SLEEP with warm boot.
- Verification: class-based SystemVerilog environment (7 tests), bound SVA,
  power-aware X testbench with fault injection, formal proof of 14 PMU
  properties, structural crossing check.
- Physical design: ORFS configs for Sky130 (baseline, power-managed,
  accelerator, experimental multi-domain) and ASAP7 multi-Vt; per-domain power
  and corner STA scripts; UPF power intent.
- Automation: `scripts/run.py`, VS Code tasks, `verify` and `pnr` GitHub
  workflows, Codespaces dev container.

Bugs the verification flow caught while building it:

- Accelerator ReLU bit and BOOT_REASON fields packed into the wrong bit
  positions (Verilator lint width warnings).
- PMU sampled the previous `PMU_CTRL` value: register update and request pulse
  happened in the same cycle (firmware illegal-request check failed).
- Power-up released reset with the clock gated; PicoRV32's synchronous reset
  never took effect and the CPU resumed its old loop after wake (firmware
  stalled after IDLE). Sequence changed to clock-on before reset release.
- The 32 kHz domain missed power-on reset when POR was shorter than a slow
  clock period (wake timer never fired) - testbench POR now covers it; a real
  POR circuit must too.
