# Results

Every number here says where it came from. Fill the "pending" rows from the
`pnr` workflow artifacts; do not quote a number you cannot trace to a report.

## Verification

See [verification.md](verification.md#results-so-far): 38/38 regression runs,
15,892 checks; power-aware firmware test passes at N = 4 and 8; isolation
fault detected; 14 PMU properties proved unbounded; 3/3 formal and 3/3
testbench mutations caught; gate-level power simulation on the Sky130 netlist
passes (5,367 checks) and catches removed isolation. `verify` passed on GitHub
Actions.

## Gate-level netlist (Yosys 0.33 + ABC, Sky130 HD tt, MAC_N = 4)

From `build/gls/stat.txt` (`run.py gls`): the netlist with all low-power cells
mapped, before place and route.

| Domain module | Cells | Area (um^2) |
| --- | --- | --- |
| PD_CMP (`cmp_top`) | 29,666 | 242,406 |
| PD_MEM (`mem_top`) | 12,317 | 167,129 |
| PD_AON (`aon_top` + top-level isolation and level shifters) | 1,440 | 19,771 |
| Total | 43,420 | 429,307 |

Low-power cells: 713 isolation cells (585 `lpflow_isobufsrc`, 128
`lpflow_inputiso1p`), 182 level shifters (`lpflow_lsbuf_lh_isowell_4`),
3 clock gates (`dlclkp`).

## Performance (simulation)

| Metric | Value | Source |
| --- | --- | --- |
| Accelerator job latency | K + 2N + 1 cycles (13 at N = K = 4, 25 at N = K = 8) | `ACC_CYCLES`, checked by `test_matmul_rand` |
| Wake latency, GPIO edge -> first CPU fetch (SLEEP, both domains) | 1.44 us = 36 cycles at 25 MHz (the firmware sleeps at OPP-L), `SEQ_CFG` = 2, switch delay 8 cycles | `tb_power` (Icarus) |
| Firmware size | 1,552 B code, 32 B .bss | `riscv64-unknown-elf-size` |

## Area (Yosys 0.33 + ABC, Sky130 HD tt 1.80 V, before place and route)

These come from `python scripts/run.py synth`, a quick pre-layout estimate;
ORFS numbers after place and route will differ.

| Design | Cells | Area |
| --- | --- | --- |
| SoC, MAC_N = 4, power-managed | 40,452 | 0.429 mm^2 |
| SoC, MAC_N = 4, baseline (no isolation) | 40,144 | 0.428 mm^2 |
| SoC, MAC_N = 8, power-managed | 89,752 | 0.858 mm^2 |
| Accelerator alone, N = 4 | - | 0.136 mm^2 |
| Accelerator alone, N = 8 | - | 0.565 mm^2 |

Breakdown at MAC_N = 4: scratch RAM (flops) 0.161 mm^2 (38 %), accelerator
0.136 mm^2 (32 %), PicoRV32 + multiplier 0.089 mm^2 (21 %), boot ROM
0.010 mm^2. Power-management overhead: isolation cells 1,900 um^2 (0.4 %);
PMU, AON registers and wake timer about 13,400 um^2 (3.1 %).

## Place and route: first `pnr` run (2026-11-06, commit 13e1f24)

The accelerator completed RTL to GDS in all four configurations. The two SoC
jobs stopped at floorplan because OpenSTA could not read the activity VCD
(fixed in v0.4, see CHANGELOG). Source: the job logs of
[run 42173088641](https://github.com/Gmj080305/Power-Managed-Edge-AI-SoC/actions/runs/42173088641)
(final-report section of each "RTL to GDS" step).

| Accelerator, N = 4 | Design area | Utilisation | Cells (incl. fill/tap) | Flip-flops | Total power* | Worst IR drop (VDD) |
| --- | --- | --- | --- | --- | --- | --- |
| Sky130 HD, 20 ns | 152,330 um^2 | 44 % | 46,472 | 1,555 | 5.93 mW | 0.10 mV (0.01 %) |
| ASAP7 RVT, 700 ps | 2,371 um^2 | 50 % | 45,625 | 1,556 | 15.7 mW | 4.5 mV (0.59 %) |
| ASAP7 LVT, 700 ps | 2,265 um^2 | 48 % | 44,753 | 1,556 | 16.4 mW | - |
| ASAP7 RVT + LVT, 700 ps | 2,309 um^2 | 49 % | 45,230 | 1,556 | 15.9 mW | - |

\* Default toggle rates (no VCD for the accelerator-only runs), so the power
column compares the configurations with each other, not with silicon. Slack,
leakage and the LVT share are not printed in the logs; from the next run the
job summary lists them (`flow/scripts/orfs_metrics.py`).

Observation from the soc_lp floorplan log: before placement, the worst setup
path (-9.8 ns) ends on the asynchronous reset pins of the ~2,500 PD_CMP
flops. That's the unbuffered domain-reset net; placement's `repair_design`
buffers it, so check the post-placement slack in the next run before
reading anything into it.

## Pending (from the `pnr` workflow)

| Metric | Baseline | Power-managed |
| --- | --- | --- |
| Area after place and route (um^2) | | |
| Worst setup slack at 50 MHz, tt (ns) | | |
| Power during firmware matmul, OPP-H (mW) | | |
| Leakage ACTIVE / IDLE / SLEEP (uW) | always on | |
| SLEEP leakage vs baseline (% lower) | - | |
| OPP-H setup slack, ss 100 C 1.60 V, 20 ns | - | |
| OPP-L setup slack, ss 100 C 1.40 V, 40 ns | - | |
| Hold slack, ff -40 C 1.95 V | - | |

| ASAP7 accelerator, 700 ps | RVT | LVT | RVT + LVT |
| --- | --- | --- | --- |
| WNS (ps) | | | |
| Leakage (uW) | | | |
| Area (um^2) | 2,371 | 2,265 | 2,309 |
| LVT cells (%) | 0 | 100 | |
