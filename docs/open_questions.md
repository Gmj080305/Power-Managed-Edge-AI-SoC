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
8. **The multi-domain layout is experimental** (see physical_design.md).

## Questions worth asking a mentor

1. How would you size the power-switch network and stage turn-on to limit rush
   current, and where would the acknowledge chain come from?
2. Is a shadow register acceptable retention for a few config bits, or would
   you always use retention flops?
3. Which corner would you sign off OPP-L at, and how do you time a path from a
   1.50 V domain into a 1.80 V one?
4. Should the PMU drop clk_sys to f/2 automatically in IDLE/SLEEP to cut
   always-on dynamic power?
