# Results

Every number here says where it came from. Fill the "pending" rows from the
`pnr` workflow artifacts; do not quote a number you cannot trace to a report.

## Verification

See [verification.md](verification.md#results-so-far): 38/38 regression runs,
15,892 checks; power-aware firmware test passes at N = 4 and 8; isolation
fault detected; 14 PMU properties proved unbounded; 3/3 formal and 3/3
testbench mutations caught.

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

## Pending (from the `pnr` workflow)

| Metric | Baseline | Power-managed |
| --- | --- | --- |
| Area after place and route (um^2) | | |
| Worst setup slack at 50 MHz, tt (ns) | | |
| Power during firmware matmul, OPP-H (mW) | | |
| Leakage ACTIVE / IDLE / SLEEP (uW) | always on | |
| SLEEP leakage vs baseline (% lower) | - | |
| OPP-L timing at ss 1.40 V, 25 MHz (needs corner libs) | - | |

| ASAP7 accelerator, 700 ps | RVT | LVT | RVT + LVT |
| --- | --- | --- | --- |
| WNS (ps) | | | |
| Leakage (uW) | | | |
| Area (um^2) | | | |
| LVT cells (%) | 0 | 100 | |
