# Limitations and open questions

## Known limitations

1. **Power switches and regulator are modelled.** Sky130 HD has no power-switch
   cell; switch acknowledge and regulator `vdd_ok` come from testbench models
   (`tb/models/`). Sleep leakage numbers exclude switch off-state leakage.
2. **Power-aware RTL simulation is modelled**, not driven by UPF: `pd_out`
   drives X from unpowered domains, and memories / the CPU register file are
   explicitly corrupted at power-off. The gate-level run (`run.py gls`) closes
   most of that gap, since every cell there corrupts from its own supply pin,
   but it is zero-delay (unit-delay flops) with ideal rails. A commercial
   power-aware simulator reading `upf/soc.upf` (BITS lab Xcelium) is the next
   comparison.
3. **Retention is a shadow register in PD_AON**, not retention flops, so save
   must come before isolation (see spec). The UPF `set_retention` describes the
   intent a retention-flop flow would implement.
4. **OPP-L timing uses corner libraries** ORFS does not ship; the `pnr`
   workflow installs them with ciel. Mixed-voltage paths are still
   approximated by single-corner STA (one library set per run).
5. **Flop-based memories** dominate area and leakage.
6. **Verilator 5.0x** (the Ubuntu package used in CI) ignores constraints and
   covergroups: constraint-solving and coverage are exercised in xsim.
7. ~~The wake timer can be re-armed while a stale expiry is still in the
   synchronisers.~~ Fixed in v0.2: expiries carry the arm generation and stale
   ones are dropped (`rtl/aon/wake_timer.sv`, `tb/unit/tb_wake_timer.sv`).
8. **The multi-domain layout is experimental** (see physical_design.md). The
   first run stopped at the PDN step (region not created); v1.0 moves the
   domain setup before `initialize_floorplan`, not yet re-run.
9. **OPP-H misses timing at the slow corner** (ss 100 C 1.60 V, -1.12 ns on
   the accelerator's multiply-accumulate path) and **hold misses by 20-30 ps
   at the fast corner** on synchroniser flop pairs, because ORFS repairs at
   tt only. Next step: `SETUP_SLACK_MARGIN` / `HOLD_SLACK_MARGIN`, or
   multi-corner repair with the ss/ff libraries.
10. **Switching activity barely annotates** (2,113 of 126,656 pins): ORFS
    renames nets inside the kept domain modules and synthesis removes many
    RTL signals, so dynamic power is default-activity. Next step: a
    gate-level VCD from simulating the routed netlist.
11. **Debug host port I/O timing is unconstrained for hold**: its inputs are
    timed against an ideal virtual clock with no minimum input delay, which
    shows up as hold "violations" at the slow corners. Give it a realistic
    `-min` input delay or a source-synchronous clock before quoting it.
12. ~~The regulator and power-switch handshakes were unsynchronised.~~ Fixed
    in v1.0 (found by corner STA): two-flop synchronisers in `aon_top.sv`,
    false path in `soc.sdc`.

## Questions worth asking a mentor

1. How would you size the power-switch network and stage turn-on to limit rush
   current, and where would the acknowledge chain come from?
2. Is a shadow register acceptable retention for a few config bits, or would
   you always use retention flops?
3. Which corner would you sign off OPP-L at, and how do you time a path from a
   1.50 V domain into a 1.80 V one?
4. Should the PMU drop clk_sys to f/2 automatically in IDLE/SLEEP to cut
   always-on dynamic power?
5. Would you close OPP-H at the slow corner with margins in a tt-only flow,
   or insist on multi-corner optimisation, and how would you pipeline the
   MAC's multiply-add if it still misses?
