# Changelog

## v0.4.0 - first place-and-route run, fixes

First `pnr` run (commit 13e1f24): the accelerator went RTL to GDS in Sky130
and in all three ASAP7 Vt variants; both SoC jobs stopped at floorplan.

- **Fix: activity VCD rejected by OpenSTA** (`STA-0800 unknown vcd
  command`). The test bench dumped the activity window with
  `$dumpoff` / `$dumpon`, which OpenSTA's VCD reader does not support (it
  takes `$dumpvars` and `$dumpall` only). `tb_power` now starts dumping with
  `$dumpvars` at the window start, and `run.py power --activity` cuts the
  file at the closing `$dumpoff` and checks every remaining command against
  the list OpenSTA accepts, so this fails in our job instead of an hour into
  OpenROAD.
- **Readable job summaries**: `flow/scripts/orfs_metrics.py` turns ORFS's
  metric JSON files into a table (setup/hold slack, TNS, area, utilisation,
  power split, DRC count, and the RVT/LVT cell mix for ASAP7). The summary
  previously showed only the last 40 lines of `6_finish.rpt`, which held no
  timing.
- GitHub Actions moved to Node 24 versions (`checkout@v6`,
  `upload-artifact@v6`, `download-artifact@v7`), clearing the deprecation
  warnings.
- `docs/results.md`: area, utilisation, power and IR drop of the four
  accelerator runs.

## v0.3.0 - learning guides

- `docs/theory.md`: digital design, SoC and RISC-V basics, the systolic
  accelerator, power, low-power techniques, PMU sequencing, CDC, UPF,
  verification (constrained random, SVA, coverage, formal, X and gate-level
  power simulation) and physical design, each tied to the files here, with
  self-check questions, interview questions and a glossary.
- `docs/tools.md`: every tool used, with the exact commands for this project,
  what the output means and what to do when it fails.
- `docs/recreate.md`: a phase-by-phase plan to rebuild the project from an
  empty folder in four weeks, with checkpoints and the mistakes made the
  first time.

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
