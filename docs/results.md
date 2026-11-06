# Results

Every number here says where it came from. Place-and-route numbers are from
`pnr` run [42199900847](https://github.com/Gmj080305/Power-Managed-Edge-AI-SoC/actions/runs/42199900847)
(commit 840b73d, 2026-11-06), read from its artifacts: ORFS metric files
(`logs/.../6_report.json`), `6_finish.rpt`, the per-instance power reports and
the corner STA reports. Verification numbers are from `run.py` at v1.0.

## Headline

| | Result |
| --- | --- |
| SLEEP leakage vs an always-on design | **93.7 % lower** (IDLE: 64.4 % lower); ideal switches, Sky130 HD tt |
| Power-management area overhead after place and route | **+0.25 %** std-cell area, +1.3 % cells vs the baseline |
| Timing, typical corner (tt 25 C 1.80 V, 50 MHz) | met, setup +8.17 ns, hold +0.10 ns, 0 DRC errors |
| Multi-Vt (ASAP7, 700 ps) | RVT fails by 80 ps; LVT meets at 5.6x the leakage; **RVT + LVT meets with 20 % LVT cells at 55 % less leakage than all-LVT** |
| Verification | 38/38 regression runs (15,892 checks); 14 PMU properties proved unbounded; gate-level power simulation passes; every injected fault and mutation caught |

## SoC, Sky130 HD, place and route (MAC_N = 4, 20 ns)

| Metric | Baseline (no power management) | Power-managed (`soc_lp`) |
| --- | --- | --- |
| Die / core area | 1.224 / 1.216 mm^2 | 1.226 / 1.217 mm^2 |
| Standard-cell area, utilisation | 481,300 um^2, 39.6 % | 482,500 um^2, 39.7 % |
| Logic cells (excl. fill/tap) | 48,739 | 49,388 |
| Flip-flops / clock gates | 7,916 / 3 | 7,918 / 3 |
| Setup worst slack (tt) | +8.62 ns | +8.17 ns |
| Hold worst slack (tt) | **-0.015 ns** (19 endpoints) | +0.100 ns |
| Clock skew (setup) | 2.54 ns | 2.39 ns |
| Route DRC errors | 0 | 0 |
| Total power, OPP-H* | 31.7 mW | 31.4 mW |
| Worst IR drop (VDD) | 0.07 mV | 0.08 mV |

The baseline's small hold violation was left by the flow (repair at tt only);
the power-managed design closed hold. The soc_lp floorplan report showed a
-9.8 ns path to the PD_CMP flops' asynchronous resets before placement; after
placement buffered the reset net, that recovery path has +14.3 ns at tt.

\* Dynamic power is effectively vectorless: OpenSTA annotated the firmware
VCD on only 2,113 of 126,656 pins (`activity_annotation.rpt`), the rest use
default toggle rates, so 47 % of it is the clock tree and the clock-gating
benefit is not visible in it. See "Limitations" below.

### Per power domain and per state (`summarize_power.py`)

| Domain | Cells | Dynamic* | Leakage |
| --- | --- | --- | --- |
| PD_AON | 2,195 | 2.96 mW | 11.8 nW |
| PD_CMP | 21,401 | 12.1 mW | 120.4 nW |
| PD_MEM | 9,234 | 16.4 mW | 54.4 nW |

| State | Powered | Leakage | vs ACTIVE | vs baseline (185.8 nW) |
| --- | --- | --- | --- | --- |
| ACTIVE | AON + CMP + MEM | 186.6 nW | - | +0.4 % |
| IDLE | AON + MEM | 66.2 nW | 64.5 % lower | 64.4 % lower |
| SLEEP | AON | 11.8 nW | 93.7 % lower | 93.7 % lower |

How to read it: the percentages are the result. The absolute leakage is tiny
because the Sky130 HD Liberty leakage values are; the switches are ideal (no
off-state leakage); clock buffers are assigned to the domain of the clock
they drive, and everything inserted at the top level (CTS dummy loads, I/O
buffers) is counted as always-on, which is pessimistic for SLEEP.

### Multi-corner STA (soc_lp, routed, SPEF; sky130A libraries via ciel)

| Check | Corner | Period | Setup (reg-to-reg) | Hold | Async recovery / removal |
| --- | --- | --- | --- | --- | --- |
| typical | tt 25 C 1.80 V | 20 ns | +8.69 ns | +0.10 ns | +14.28 / +0.22 ns |
| OPP-H sign-off | ss 100 C 1.60 V | 20 ns | **-1.12 ns** | (-0.86 ns**) | +9.95 / +0.42 ns |
| OPP-L sign-off | ss 100 C 1.40 V | 40 ns | +8.63 ns | (-2.83 ns**) | +25.32 / +0.51 ns |
| hold sign-off | ff -40 C 1.95 V | 20 ns | +9.11 ns | **-0.03 ns** | +16.20 / +0.03 ns |

- **OPP-H at the slow corner misses by 1.12 ns** on the accelerator's
  config-to-accumulator path (feed mux, 8x8 multiply, 32-bit add), because
  ORFS optimises at tt only. Worst-case OPP-H frequency as built: 1 / 21.12 ns
  = 47.3 MHz. OPP-L passes with large margin, as DVFS intends.
- **Hold at ff misses by 20-30 ps** on five paths, every one between the
  two flops of a synchroniser (reset, clock-switch status, wake pins, timer
  event): back-to-back flops with almost no wire between them, the classic
  hold case once clock skew grows at the fast corner.
- \*\* The slow-corner hold failures start at input pins timed against an
  ideal virtual clock with no minimum input delay: `vdd_ok` (-0.86 / -2.83 ns)
  and the debug host port (`host_valid`, `host_en`, down to -2.06 ns). The
  `vdd_ok` one exposed a real design gap: the regulator and power-switch
  handshakes reached the PMU unsynchronised. **Fixed in v1.0** (two-flop
  synchronisers, false path in the SDC). The host-port ones are a
  constraint gap: that port is a test interface with no specified external
  timing; give it realistic `-min` input delays (or a launch clock) before
  quoting hold for it. Numbers above are from before v1.0.
- Mixed-voltage paths (PD_CMP at 1.40 V into 1.80 V logic) are approximated:
  one library per run.

Both real misses (OPP-H setup at ss, synchroniser hold at ff) are closed by
flow settings, not RTL: repair with `SETUP_SLACK_MARGIN` /
`HOLD_SLACK_MARGIN`, or with the ss/ff libraries as extra corners. Listed in
`open_questions.md`.

## Accelerator alone, place and route (N = 4)

| | Sky130 HD, 20 ns | ASAP7 RVT, 700 ps | ASAP7 LVT, 700 ps | ASAP7 RVT + LVT, 700 ps |
| --- | --- | --- | --- | --- |
| Setup WNS | +10.82 ns | **-79.7 ps** (TNS -7,650 ps, 151 endpoints) | +6.3 ps | +9.1 ps |
| Hold WNS | +0.24 ns | +1.9 ps | +1.9 ps | +8.0 ps |
| Std-cell area | 152,330 um^2 | 2,371 um^2 | 2,265 um^2 | 2,309 um^2 |
| Logic cells (excl. fill/tap) | 15,905 | 20,930 | 19,986 | 20,374 |
| Timing-repair buffers | 302 | 1,495 | 574 | 944 |
| Leakage | 79 nW | 1.61 uW | 9.05 uW | 4.10 uW |
| Total power* | 5.93 mW | 15.7 mW | 16.4 mW | 15.9 mW |
| Cells by Vt | - | 100 % RVT | 100 % LVT | 79.6 % RVT, **20.4 % LVT** |
| Route DRC errors | 0 | 0 | 0 | 0 |

The multi-Vt result, in one line: RVT alone cannot make 700 ps; LVT
everywhere makes it but leaks 5.6x more; letting the optimiser use LVT only
where needed makes it with 20 % LVT cells and 2.5x RVT leakage, 55 % less
than all-LVT. That is exactly how production flows use Vt flavours.

\* Default toggle rates (no VCD for the accelerator-only runs).

## Gate-level netlist (Yosys 0.33 + ABC, Sky130 HD tt, MAC_N = 4)

From `build/gls/stat.txt` (`run.py gls`): the netlist with all low-power cells
mapped, before place and route, at v1.0.

| Domain module | Cells | Area (um^2) |
| --- | --- | --- |
| PD_CMP (`cmp_top`) | 29,686 | 242,601 |
| PD_MEM (`mem_top`) | 12,315 | 167,125 |
| PD_AON (`aon_top` + top-level isolation and level shifters) | 1,420 | 19,885 |
| Total | 43,421 | 429,612 |

Low-power cells: 691 isolation cells (566 `lpflow_isobufsrc` clamp-0, 125
`lpflow_inputiso1p` clamp-1), 182 level shifters
(`lpflow_lsbuf_lh_isowell_4`), 3 clock gates (`dlclkp`). v1.0 netlist.

## Verification

| Check | Result |
| --- | --- |
| Class-based regression (`run.py regress --seeds 3`) | 38/38 runs, 15,892 checks |
| Power-aware firmware test (X modelling) | pass at N = 4 and 8; isolation fault detected |
| Gate-level power simulation (Sky130 power models) | 5,377 checks pass; PD_CMP X inside on 979/979 off cycles, PD_MEM on 586/586, no X outside; removed isolation detected |
| Formal (abc pdr) | 14/14 PMU properties proved unbounded |
| Mutation tests | 3/3 formal, 3/3 testbench |
| Wake-timer unit test, crossing check, slang elaboration | pass |

Details in [verification.md](verification.md#results-so-far).

## Performance (simulation)

| Metric | Value | Source |
| --- | --- | --- |
| Accelerator job latency | K + 2N + 1 cycles (13 at N = K = 4, 25 at N = K = 8) | `ACC_CYCLES`, checked by `test_matmul_rand` |
| Wake latency, GPIO edge -> first CPU fetch (SLEEP, both domains) | 1.60 us = 40 cycles at 25 MHz (the firmware sleeps at OPP-L), `SEQ_CFG` = 2, switch delay 8 cycles; includes the 2-cycle synchronisers on the switch acknowledges (v1.0; 1.44 us before) | `tb_power` (Icarus) |
| Firmware size | 1,552 B code, 32 B .bss | `riscv64-unknown-elf-size` |

## Area before place and route (Yosys 0.33 + ABC, Sky130 HD tt 1.80 V)

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

## Limitations of these numbers

- **Switching activity barely annotated.** ORFS keeps the three domain
  modules but flattens inside them, renaming internal nets
  (`u_cmp/u_acc.a_w[0][0]` instead of the VCD's `u_cmp/u_acc/a_w`); synthesis
  also merges or removes many RTL signals. An offline check showed even a
  scope-renamed VCD would match only 1,575 of 10,340 signal bits. Dynamic
  power is therefore default-activity. A gate-level VCD (simulate the final
  netlist, `run.py gls`-style) is the proper fix.
- **Switches and regulator are ideal** (Sky130 HD has no switch cell).
- **Single-voltage layout.** The power-managed SoC is placed in one voltage
  area; the true three-supply layout (`soc_multidomain`) is experimental and
  did not complete (see below).
- **Sky130 leakage values are very small** in the open Liberty files; compare
  ratios, not absolute nanowatts.

## Multi-domain layout (experimental)

Run 42199900847 stopped at the power-grid step: `[ERROR ORD-0045] Region
"PD_CMP" not defined`. The domain areas were set after
`initialize_floorplan`, but OpenROAD creates a domain's placement region in
`eval_upf`, which `initialize_floorplan` calls. v1.0 moves `domains.tcl` to
`PRE_FLOORPLAN_TCL` with a fixed die/core area and makes PD_AON the UPF top
domain (`-elements {.}`); not yet re-run.
