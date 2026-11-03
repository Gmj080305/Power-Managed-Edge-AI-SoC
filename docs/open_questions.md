# Limitations and open questions

## Known limitations

1. **Power switches and regulator are modelled.** Sky130 HD has no power-switch
   cell; switch acknowledge and regulator `vdd_ok` come from testbench models
   (`tb/models/`). Sleep leakage numbers exclude switch off-state leakage.
2. **Power-aware simulation is modelled in RTL**, not driven by UPF: `pd_out`
   drives X from unpowered domains, and memories / the CPU register file are
   explicitly corrupted at power-off. A commercial power-aware simulator would
   corrupt every register from `upf/soc.upf`. Comparing the two (BITS lab
   Xcelium) is a good exercise.
3. **Retention is a shadow register in PD_AON**, not retention flops, so save
   must come before isolation (see spec). The UPF `set_retention` describes the
   intent a retention-flop flow would implement.
4. **OPP-L timing needs corner libraries** ORFS does not ship (open_pdks).
   Mixed-voltage paths are approximated by single-corner STA.
5. **Flop-based memories** dominate area and leakage.
6. **Verilator 5.0x** (the Ubuntu package used in CI) ignores constraints and
   covergroups: constraint-solving and coverage are exercised in xsim.
7. **The wake timer can be re-armed while a stale expiry is still in the
   synchronisers** (a few clk_sys cycles after a wake from another source). In
   that window an old expiry could cause an immediate wake from the next
   power-down. Harmless (a spurious wake), but worth a disarm handshake.
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
