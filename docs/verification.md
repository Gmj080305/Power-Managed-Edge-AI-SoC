# Verification

Four independent layers, each catching a different class of bug:

| Layer | Where | Runs on | Finds |
| --- | --- | --- | --- |
| Class-based constrained-random tests + bound SVA | `tb/env`, `tb/top`, `tb/sva` | xsim, Verilator | functional bugs in data path, PMU, retention, DVFS |
| Power-aware firmware test with X modelling | `tb/power` | xsim, Icarus | isolation gaps, missing resets, lost state |
| Formal proof of PMU safety rules | `formal/` | SymbiYosys, or Yosys + ABC | sequencing bugs under any input timing |
| Structural crossing check | `scripts/check_crossings.py` | Yosys | a new domain-crossing signal without isolation |

## Class-based environment

`tb/env/tb_pkg.sv`, selected with `+TEST=<name>` and `+ITERS=<n>`:

| Class | Role |
| --- | --- |
| `host_driver` | bus master on the debug host port; drives and samples on the falling edge of `clk_sys` |
| `mat_job` | random K, ReLU, corner-value bias and seed; computes the expected C |
| `pwr_req_item` | random target, wake source, wake delay, timer ticks, illegal-request knob |
| `pmu_model` | predicts whether a request is accepted, flagged or a no-op, and the resulting state |
| `scoreboard` | counts checks and errors |
| `soc_cov` | covergroups: state transitions, wake source x state, wake timing, K x ReLU |
| `base_test` + 7 tests | shared helpers (run a job, DVFS, power down and wake with retention checks) |

| Test | What it proves |
| --- | --- |
| `test_matmul_rand` | random jobs correct, cycle count = K + 2N + 1, random OPP changes between jobs |
| `test_state_walk` | every legal transition, then a random walk, with retention checks after each wake |
| `test_sleep_wake_rand` | random IDLE/SLEEP cycles, random wake source and delay |
| `test_wake_race` | wake arrives at every cycle offset 0..120 into the power-down sequence |
| `test_dvfs_switch` | OPP flips between jobs; clock and voltage always match the OPP |
| `test_illegal_req` | undefined targets and missing wake masks are refused and flagged; no-ops are not |
| `test_fw_e2e` | the real firmware: cold boot -> IDLE -> SLEEP -> PASS on the UART |

After every wake the tests check: accelerator config restored, AON scratch
intact, wake count +1, BOOT_REASON records the right state and a source within
the enabled mask, and (IDLE only) RAM unchanged.

**Constraints.** xsim honours the `constraint` blocks. Verilator 5.0x ignores
them, so under `VERILATOR` each class maps its random values into the same
legal space in `fixup()`; `legal()` is checked either way. Covergroups and
`##` sequences are compiled only where supported (`ifndef VERILATOR`).

### Assertions (bound with `bind`)

`pmu_sva` - the formal properties on every simulated cycle: switched-off or
not-yet-powered domains are isolated, CMP-on/MEM-off never requested, no clock
and reset held while off, save/restore only in safe conditions, isolation
released only after power-good and restore, full speed only at full voltage,
frequency raised only after the voltage is confirmed.
`mac_sva` - array clock gated whenever idle; `done` rises exactly when a job ends.
`soc_sva` - isolated inputs sit at their clamp value; UART pin idles high while
PD_MEM is isolated; under `PWR_SIM`, no X on control signals entering a
powered domain.

## Power-aware test

`tb/power/tb_power.sv` runs the firmware with `+define+PWR_SIM`: outputs of an
unpowered domain go X (`pd_out`), and memories and the CPU register file are
corrupted when their domain is reset for power-off. It checks that powered
receivers see no X and that isolated signals sit at their clamp, that the
corruption model is live, that RAM survives IDLE and is lost in SLEEP, and the
sequencing rules. It also reports the GPIO-to-first-fetch wake latency.

`python scripts/run.py power --fault` rebuilds with `FAULT_NO_ISO` (isolation
removed): the test **must fail**, which proves the checks are not dead.

## Formal

`formal/pmu_formal.sv` drives the PMU with unconstrained requests, wake events
and acknowledge timing, plus small environment models (switches, regulator,
clock switch respond after any delay). 14 assertions, 6 covers.

- `sby -f formal/pmu.sby` - `prove` (abc pdr, unbounded), `bmc` (depth 40),
  `cover` (reachability)
- `python scripts/run.py formal --no-sby` - same proof via Yosys -> AIGER ->
  `abc pdr` (used in CI)

## Results so far

From the sandbox used to build the repo (Ubuntu 24.04: Verilator 5.020, Icarus
12, Yosys 0.33), same commands as CI:

| Check | Result |
| --- | --- |
| Class-based regression (`run.py regress --seeds 3`) | 38/38 pass: 6 tests x N = 4, 8 x 3 seeds + firmware test per N; 15,892 checks |
| Power-aware firmware test | pass at N = 4 and 8 (Icarus with X, and Verilator) |
| Isolation fault injection | detected (1,254 errors) |
| Formal (PDR) | all 14 properties proved unbounded in ~0.2 s |
| Formal mutation test | 3/3 injected PMU bugs found (isolation never set, frequency before voltage, wake skipping PD_MEM) |
| Testbench mutation test | 3/3 injected RTL bugs found (no restore, wrong ReLU, wake lost mid power-down) |
| Crossing check | 216 crossing bits checked; a deliberate bypass is reported |
| Bounded model check (Yosys SAT) | all properties hold to depth 30 |

Functional and code coverage are collected when the regression runs in xsim
(`build/coverage_n*/`); Verilator 5.0x has no covergroup support.

Bugs the flow found while the repo was built are listed in `CHANGELOG.md`.
