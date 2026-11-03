# Progress (as of 2026-11-03, v0.1.0)

## Done

| Step | What | Verified how |
| --- | --- | --- |
| 1 Setup | `scripts/run.py`, VS Code tasks/extensions, `verify` + `pnr` workflows, Codespaces container | ran on Ubuntu 24.04 (same tools as CI) |
| 2 Spec | `docs/spec.md`: states, crossings, register maps, sequences | - |
| 3 MAC array | INT8 N x N systolic accelerator, clock-gated, ReLU, cycle counter | random tests N = 4, 8 |
| 4 CPU + firmware | PicoRV32, boot ROM, firmware: self-test, DVFS, IDLE, SLEEP, warm boot | firmware prints DONE PASS |
| 5 PMU / DVFS / wake | PMU sequencer, glitch-free clock switch, 32 kHz timer, GPIO/host wake | tests + formal |
| 6 Power modelling | iso/LS/ICG wrappers mapped to Sky130 cells, X corruption model, UPF | X-aware test, fault injection, crossing check |
| 7 Verification | class-based SV env (7 tests), SVA, formal (14 properties, unbounded) | 38/38 runs, 15,892 checks; 6/6 mutations caught |
| 8 Synthesis | Yosys area for SoC and accelerator, baseline vs power-managed | `run.py synth` |
| 9-10 Flow files | ORFS configs (baseline, LP, accelerator, ASAP7 RVT/LVT/mixed, experimental multi-domain), power + STA scripts | written, **not yet run** |

## Left (next session)

1. **Run in xsim on Windows** (never run there yet): `python scripts/run.py regress --quick --seeds 1`.
   Fix any xsim-only syntax issue; the riskiest parts are the covergroups in
   `tb/env/tb_pkg.sv` and the `##` sequences in `tb/sva/pmu_sva.sv`. Then the
   full regression to get coverage reports (`build/coverage_n4/`).
2. **Push and check the `verify` workflow** goes green on GitHub.
3. **Run the `pnr` workflow** (Actions -> pnr): fix any ORFS config issues in
   `flow/sky130/*/config.mk` and `flow/asap7/`, then fill `docs/results.md`
   (area, slack, per-domain leakage, SLEEP vs baseline, ASAP7 multi-Vt table).
4. **Multi-domain layout** (`flow/sky130/soc_multidomain`, experimental): iterate on
   `domains.tcl` / `pdn.tcl`, IR drop with PDNSim.
5. **Corner STA**: get Sky130 corner libs (open_pdks/ciel), run
   `flow/scripts/sta_corners.tcl` for OPP-H ss, OPP-L ss 1.40 V, hold ff.
6. **Power-down gate-level simulation** on the routed netlist with Sky130
   power-pin models (testbench not written yet).
7. Optional: SymbiYosys `cover` task on Windows, wake-timer disarm fix
   (`docs/open_questions.md` #7), stretch goals (UVM port, FPGA demo, Ibex).
8. Fill in the resume entry only with numbers from step 3 reports.

## Where things were tested

Ubuntu 24.04 sandbox: Verilator 5.020, Icarus 12, Yosys 0.33 (+ABC), riscv64
GCC 13. Not available there: Vivado, SymbiYosys, OpenROAD.
