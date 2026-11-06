# Progress (2026-11-06, v1.0.0: complete)

The project is complete: every step of the plan is built, verified and, for
physical design, run through place and route with results in
[results.md](results.md).

## Done

| Step | What | Verified how |
| --- | --- | --- |
| 1 Setup | `scripts/run.py`, VS Code tasks/extensions, `verify` + `pnr` workflows, Codespaces container | `verify` passes on GitHub Actions |
| 2 Spec | `docs/spec.md`: states, crossings, register maps, sequences | - |
| 3 MAC array | INT8 N x N systolic accelerator, clock-gated, ReLU, cycle counter | random tests N = 4, 8 |
| 4 CPU + firmware | PicoRV32, boot ROM, firmware: self-test, DVFS, IDLE, SLEEP, warm boot | firmware prints DONE PASS |
| 5 PMU / DVFS / wake | PMU sequencer, glitch-free clock switch, 32 kHz timer, GPIO/host wake, synchronised regulator/switch handshakes | tests + formal + wake-timer unit test |
| 6 Power modelling | iso/LS/ICG wrappers mapped to Sky130 cells, X corruption model, UPF | RTL X test, fault injection, crossing check |
| 7 Verification | class-based SV env (7 tests), SVA, formal (14 properties, unbounded), slang elaboration of every TB | 38/38 runs, 15,892 checks; 6/6 mutations caught |
| 8 Synthesis + GLS | Yosys area; power-aware gate-level simulation on Sky130 power models | 5,377 GLS checks pass; removed isolation detected |
| 9 Place and route | ORFS: baseline and power-managed SoC, accelerator, ASAP7 RVT/LVT/mixed | GDS for all 6, 0 DRC errors (`pnr` run 42199900847) |
| 10 Power and timing sign-off | per-domain and per-state power, four-corner STA, multi-Vt study | SLEEP leakage -93.7 % vs baseline; corner table and Vt study in results.md |
| Learning guides | `theory.md`, `tools.md`, `recreate.md` | - |

## Bugs the flow found (all fixed)

| Found by | Bug |
| --- | --- |
| lint | ReLU bit and BOOT_REASON fields in the wrong bit positions |
| tests | PMU sampled the previous PMU_CTRL value; CPU not reset on wake (clock gated during sync reset); 32 kHz domain missed short POR |
| directed CDC unit test | stale wake-timer expiry could wake the next power-down |
| first `pnr` run | activity VCD used commands OpenSTA rejects |
| corner STA | regulator / power-switch handshakes reached the PMU unsynchronised |
| first power report | per-domain summary diluted by filler/tap cells |

## Optional next steps

None of these are needed for the project to be complete; each is a good
extension or interview talking point (details in `open_questions.md`).

1. **Close the two corner misses** with `SETUP_SLACK_MARGIN` /
   `HOLD_SLACK_MARGIN` or multi-corner repair, and re-run `pnr`.
2. **Re-run with *multidomain* ticked** to try the fixed three-supply layout.
3. **Gate-level VCD** for accurate dynamic power.
4. **Run the regression in xsim on Windows** for the coverage report
   (`python scripts/run.py regress --seeds 3`).
5. Stretch goals: UVM port of the environment, FPGA demo on the lab board,
   Ibex instead of PicoRV32, SRAM macro with retention.

## Where things were tested

Ubuntu 24.04 sandbox: Verilator 5.020, Icarus 12, Yosys 0.33 (+ABC), riscv64
GCC 13, pyslang 12. GitHub Actions: `verify` on every push; `pnr` with the
`openroad/orfs` image (ORFS + OpenROAD), sky130A corner libraries via ciel.
Not run: Vivado xsim (CI has none; slang compiles the xsim-only code),
SymbiYosys (the same proof runs through Yosys + ABC).
