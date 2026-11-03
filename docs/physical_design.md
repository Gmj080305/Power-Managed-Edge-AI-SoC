# Physical design

OpenROAD is Linux-only, so RTL-to-GDS runs in GitHub Actions inside the
official OpenROAD-flow-scripts (ORFS) Docker image. You trigger it from the
Actions tab (or the GitHub Actions extension in VS Code), then download the
reports, GDS and power summaries as artifacts. For interactive debugging, open
the repo in a GitHub Codespace: `.devcontainer/` uses the same ORFS image.

## Configurations

| Config | Design | What it is for |
| --- | --- | --- |
| `flow/sky130/soc_baseline` | SoC, `NO_ISOLATION` | single always-on domain: the reference every saving is measured against |
| `flow/sky130/soc_lp` | SoC, real Sky130 isolation + clock-gate cells | power-managed SoC in one voltage area; per-domain power by instance prefix |
| `flow/sky130/mac_accel` | accelerator only | quick runs: clock gating, N = 4 vs 8 |
| `flow/asap7/mac_accel/config_{rvt,lvt,mixed}.mk` | accelerator only | multi-Vt study (`ASAP7_USE_VT` = RVT / LVT / "RVT LVT") |
| `flow/sky130/soc_multidomain` | SoC, + level shifters | **experimental**: three supplies, domain regions, per-domain power grids |

Cell mapping is chosen by Verilog defines: `SKY130_CELLS` (clock gates),
`SKY130_ISO` (isolation), `SKY130_LS` (level shifters), `NO_ISOLATION`
(baseline).

## Running

```text
GitHub -> Actions -> pnr -> Run workflow   (tick "multidomain" to try it)
```

Locally (Linux, Codespace, or WSL if you ever want it):

```bash
docker run --rm -v "$PWD:/work" -w /OpenROAD-flow-scripts/flow openroad/orfs:latest \
  make DESIGN_CONFIG=/work/flow/sky130/soc_lp/config.mk WORK_HOME=/work/build/orfs
```

Outputs: `build/orfs/{results,reports,logs}/<platform>/<design>/<variant>/`.
Open `6_final.gds` in KLayout on Windows.

## Power analysis

1. **Activity.** `python scripts/run.py power --activity` dumps
   `activity.vcd`: 20,000 cycles of the firmware running the accelerator at
   OPP-H (DUT scope `tb_power/dut`). The `pnr` workflow passes it to ORFS as
   `VCD_FILE` / `POWER_FILE_SCOPE`, so the final report uses real switching
   activity instead of default toggle rates. RTL register names match the
   netlist; `activity_annotation.rpt` shows how much was annotated.
2. **Per domain.** `flow/scripts/power_by_domain.tcl` writes per-instance power;
   `flow/scripts/summarize_power.py` sums it by domain (`u_cmp*` -> PD_CMP,
   `u_mem*` -> PD_MEM, everything else -> PD_AON).
3. **Per state.** OpenSTA does not know a domain is off, so state leakage is
   built from the parts that stay powered:

| State | Leakage |
| --- | --- |
| ACTIVE | AON + CMP + MEM |
| IDLE | AON + MEM |
| SLEEP | AON |

Switch off-state leakage is not included (ideal switches): say so next to any
number you quote. Compare against `soc_baseline`, which leaks everything all
the time: `summarize_power.py soc_lp.rpt --baseline soc_baseline.rpt`.

4. **Average power for a duty cycle** D (fraction of time active):
   P_avg = D x P_active + (1 - D) x P_sleep.

## Multi-corner STA

`flow/sky130/soc.sdc` signs off OPP-H at the library ORFS ships (tt, 1.80 V).
For the other corners run `flow/scripts/sta_corners.tcl` once per corner on the
routed design, with libraries from an open_pdks / ciel `sky130A` install
(`$PDK_ROOT/sky130A/libs.ref/sky130_fd_sc_hd/lib/`):

| Check | Library | PERIOD |
| --- | --- | --- |
| OPP-H setup | `ss_100C_1v60` | 20 ns |
| OPP-L setup | `ss_100C_1v40` | 40 ns (clk_in / 2) |
| Hold | `ff_n40C_1v95` | 20 ns |

OpenSTA times one library set per run, so paths that cross from PD_CMP at
1.50 V into 1.80 V logic are approximated: keep margin on them and say so.

## Multi-Vt (ASAP7)

Three runs of the accelerator at a 700 ps clock, deliberately tight for an
all-RVT build: RVT only, LVT only, and RVT with LVT available. Compare maximum
frequency (WNS), leakage, area and LVT cell share from each `6_finish.rpt`.
Move the clock in `flow/asap7/mac_accel/constraint.sdc` if all three pass or
all three fail by a wide margin.

## Multi-domain layout (experimental)

`flow/sky130/soc_multidomain` adds `domains.tcl` (reads
`upf/soc_openroad.upf`, sets domain areas: PD_CMP left 50 %, PD_MEM next 30 %)
and `pdn.tcl` (supplies `VDD_AON`, `VDD_CMP`, `VDD_MEM`, a grid per domain,
level-shifter `LOWLVPWR` on `VDD_CMP`). Points that will likely need work:

- OpenROAD's UPF support is partial; check the log for commands it ignored.
- Domain membership depends on hierarchical names surviving synthesis
  (`SYNTH_HIERARCHICAL=1`, `OPENROAD_HIERARCHICAL=1`).
- `lpflow_lsbuf_lh_isowell_4` is a double-height cell: if detailed placement
  rejects it, pre-place the level shifters along the PD_CMP edge.
- There is no power-switch cell in Sky130 HD, so each switched domain gets its
  own supply pin (an ideal off-chip switch). LVS of a multi-supply design with
  Netgen is a stretch goal.
