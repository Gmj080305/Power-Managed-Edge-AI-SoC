# Progress (as of 2026-11-06, v0.2.0)

## Done

| Step | What | Verified how |
| --- | --- | --- |
| 1 Setup | `scripts/run.py`, VS Code tasks/extensions, `verify` + `pnr` workflows, Codespaces container | `verify` passed on GitHub Actions (v0.1) |
| 2 Spec | `docs/spec.md`: states, crossings, register maps, sequences | - |
| 3 MAC array | INT8 N x N systolic accelerator, clock-gated, ReLU, cycle counter | random tests N = 4, 8 |
| 4 CPU + firmware | PicoRV32, boot ROM, firmware: self-test, DVFS, IDLE, SLEEP, warm boot | firmware prints DONE PASS |
| 5 PMU / DVFS / wake | PMU sequencer, glitch-free clock switch, 32 kHz timer, GPIO/host wake | tests + formal + wake-timer unit test |
| 6 Power modelling | iso/LS/ICG wrappers mapped to Sky130 cells, X corruption model, UPF | RTL X test, fault injection, crossing check |
| 7 Verification | class-based SV env (7 tests), SVA, formal (14 properties, unbounded), slang elaboration of every TB | 38/38 runs, 15,892 checks; 6/6 mutations caught |
| 8 Synthesis | Yosys area for SoC and accelerator, baseline vs power-managed | `run.py synth` |
| 8b Gate-level power sim | Sky130 netlist + SkyWater power models, host-driven IDLE/SLEEP walk | 5,367 checks pass; fault (no isolation) detected |
| 9-10 Flow files | ORFS configs (baseline, LP, accelerator, ASAP7 RVT/LVT/mixed, experimental multi-domain), per-domain power, corner STA in CI | written; **needs a `pnr` run** |

v0.2 also fixed the wake-timer stale-expiry race (open question #7) and the
per-domain power naming after ORFS flattening (see CHANGELOG).

## Left (these need your machine or GitHub, not code changes)

1. **Run the `pnr` workflow** (GitHub -> Actions -> pnr -> Run workflow, 1-3 h).
   Fix any ORFS config issue it reports, then fill the "Pending" tables in
   `docs/results.md` from the job summaries and artifacts: area, slack,
   per-domain power, SLEEP vs baseline, corner STA, ASAP7 multi-Vt.
2. **Run in xsim on Windows**: `python scripts/run.py regress --quick --seeds 1`,
   then `python scripts/run.py regress --seeds 3` for the coverage report in
   `build/coverage_n4/`. slang already compiles the xsim code paths in CI, so
   expect at most simulator-specific runtime differences.
3. Optional: tick *multidomain* in the `pnr` run and iterate on
   `flow/sky130/soc_multidomain` (experimental); IR drop with PDNSim.
4. Optional stretch goals: UVM port of the environment, FPGA demo on the lab
   board (Vivado), Ibex instead of PicoRV32, SymbiYosys `cover` on Windows.
5. Write the resume entry only with numbers traced to `docs/results.md`.

## Where things were tested

Ubuntu 24.04 sandbox: Verilator 5.020, Icarus 12, Yosys 0.33 (+ABC), riscv64
GCC 13, pyslang 12. GitHub Actions `verify` (v0.1): passed. Not available in
the sandbox: Vivado, SymbiYosys, OpenROAD.
