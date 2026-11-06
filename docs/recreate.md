# Recreate this project from scratch

A build order for writing the whole project yourself, starting from an empty
folder. Each phase says what to build, the decisions that matter, how to
test it before moving on, and the mistakes this project actually made.

How to use it:

- **Write each file yourself first**, then compare it with the repo's
  version: `git diff --no-index my_version.sv rtl/common/sync_2ff.sv`. The
  repo is the answer key, not the starting point.
- **Don't move on until the checkpoint passes.** Bugs found in a 30-line
  block take minutes; the same bug found in the full SoC takes a day.
- Read the matching part of [theory.md](theory.md) before each phase, and
  keep [tools.md](tools.md) open for commands.

Size, for orientation: about 1,600 lines of RTL (excluding PicoRV32 and the
generated ROM), 1,400 lines of testbench, 330 lines of firmware, and about
1,000 lines of Python and Tcl scripts, plus the flow configs.

## Four-week plan

| Week | Phases | Result at the end of the week |
| --- | --- | --- |
| 1 | 0-4 | repo skeleton, spec, common cells, accelerator and PD_MEM, each unit-tested |
| 2 | 5-8 | PD_CMP with the CPU, firmware, PD_AON with PMU, full SoC running firmware to `DONE PASS` |
| 3 | 9-12 | class-based environment, SVA, power-aware test, formal proof, static checks |
| 4 | 13-17 | synthesis, gate-level power sim, UPF, ORFS configs, CI, results and docs |

Week 2 is the hardest (the PMU). If you slip, take time from week 4's
multi-domain layout, which is experimental anyway.

---

## Phase 0 - Repository skeleton (half a day)

1. Create the GitHub repo, clone it, and make the folders:

   ```
   rtl/{pkg,common,cmp,mem,aon,top,third_party}  fw  tb/{env,top,sva,models,power,unit,gls}
   formal  upf  flow/{sky130,asap7,scripts}  scripts  docs  .vscode  .github/workflows
   ```

2. `.gitignore`: `build/`, `fw/build/`, `formal/pmu_prove/`, `formal/pmu_bmc/`,
   `formal/pmu_cover/`, `*.vcd`, `__pycache__/`. Be precise with the formal
   folders: a pattern like `formal/pmu_*` would also ignore your harness
   `formal/pmu_formal.sv` (this happened).
3. `.gitattributes`: `* text=auto eol=lf` so Windows and CI see the same file
   contents.
4. `README.md` (one paragraph for now) and `LICENSE` (MIT).
5. `rtl/files.f`: the RTL file list in compile order. Every tool and script
   reads this one list, so you never maintain two.

**Checkpoint:** first commit pushed.

---

## Phase 1 - Write the spec before any RTL (1 day)

Write `docs/spec.md` with these decisions. Everything later follows from it.

| Decide | This project's answer | Why it matters |
| --- | --- | --- |
| power domains | AON (always on), CMP (CPU + accelerator, DVFS), MEM (RAM + UART) | every boundary needs protection cells |
| power states | ACTIVE_H, ACTIVE_L, IDLE, SLEEP; CMP-on/MEM-off illegal | the PMU's state space |
| OPPs | 1.80 V at f, ~1.50 V at f/2 | DVFS ordering, level shifters |
| clocks | one root `clk_sys` + gated copies; 32 kHz only for the wake timer | keeps the bus synchronous: very few CDCs |
| crossings | table of every signal crossing every boundary, with its LS / ISO cell and clamp | becomes `check_crossings.py` |
| sequences | step list for each transition | becomes `pmu_fsm.sv` |
| retention | what survives each state and how | shadow register, `.noinit`, scratch |
| address map + registers | ROM 0x0, RAM 0x1, ACC 0x2, AON 0x3, UART 0x4 | firmware header and RTL package |
| bus | valid/ready, 32-bit, byte strobes, one wait state | every slave |

Then put the constants in `rtl/pkg/soc_pkg.sv` (states, wake bits, regions,
register offsets) as plain `localparam`s.

**Checkpoint:** you can explain every row of the crossing table and every
step of every sequence (theory.md Parts 5-6).

---

## Phase 2 - Common cells (1 day)

Small, reusable, and every one has a reason to exist. Write each with a
two-minute test (a tiny testbench in Icarus) before moving on.

| File | Does | Key detail |
| --- | --- | --- |
| `sync_2ff.sv` | 2-flop synchroniser | parameter for width and reset value |
| `rst_sync.sv` | async assert, sync de-assert | two flops, D tied high |
| `pulse_sync.sv` | toggle in, one-cycle pulse out | `sync_2ff` + XOR with a delayed copy |
| `icg.sv` | clock gate | `` `ifdef SKY130_CELLS `` -> `dlclkp_1`, else falling-edge flop + AND |
| `clk_switch.sv` | glitch-free 2:1 clock mux | each side's enable in its own clock domain, break before make |
| `iso_clamp0.sv` / `iso_clamp1.sv` | isolation | defines: `FAULT_NO_ISO`, `NO_ISOLATION`, `SKY130_ISO`, behavioural default |
| `ls_lh.sv` | level shifter | `SKY130_LS` -> `lpflow_lsbuf_lh_isowell_4`, else a wire |
| `pd_out.sv` | marks a domain output | `PWR_SIM`: X when power-good is low; otherwise a wire |
| `bus_slave_ack.sv` | one-wait-state handshake | `fire = valid & ~ready` |

The isolation wrapper pattern, which lets one RTL serve simulation,
synthesis, the baseline and fault injection:

```systemverilog
module iso_clamp0 #(parameter int W = 1) (
  input logic iso, input logic [W-1:0] d, output logic [W-1:0] q);
`ifdef FAULT_NO_ISO
  assign q = d;                      // deliberately broken, the test must fail
`elsif NO_ISOLATION
  assign q = d;                      // baseline: one always-on domain
`elsif SKY130_ISO
  for (genvar i = 0; i < W; i++) begin : g_bit
    (* keep *) sky130_fd_sc_hd__lpflow_isobufsrc_1 u_iso (.A(d[i]), .SLEEP(iso), .X(q[i]));
  end
`else
  assign q = iso ? '0 : d;           // behavioural
`endif
endmodule
```

Mistake made here: a latch-based ICG model would not simulate in Verilator
(it cannot settle a latch in a clock path), hence the falling-edge-flop model.

**Checkpoint:** `verilator --lint-only -Wall` clean on each file; each unit
test passes in Icarus.

---

## Phase 3 - The accelerator (2 days)

Build bottom-up: PE, then array, then the memory-mapped wrapper.

1. **`mac_pe.sv`**: `acc <= acc + a_in * b_in`, forward `a` right and `b`
   down, synchronous `clr`. Declare operands `signed`, or the multiply is
   unsigned. Test: feed a few pairs by hand.
2. **`mac_array.sv`**: generate loops creating N x N PEs; arrays `a_bus[i][j]`
   and `b_bus[i][j]` for the wires between them. Test: inject a skewed 2x2
   problem by hand (the worked example in theory.md 3.4) and check C.
3. **`mac_accel.sv`**:
   - register map: CTRL, STATUS, CFG (K, ReLU), CYCLES, INFO, A, B, C
   - A/B stored as bytes packed 4 per word, byte-lane writes
   - FSM `S_IDLE -> S_CLR -> S_RUN (t = 0 .. K+2N-3) -> S_LATCH`
   - the skewed operand feed (row i gets `A[i][t-i]`, zero outside range)
   - ICG on the array clock, enabled only in `S_CLR` and `S_RUN`
   - CFG is the register that will be **retained**: give it `cfg_q` out,
     `restore` and `cfg_ret` in, from day one
   - CYCLES counter, so tests can check `K + 2N + 1`
4. Write a small directed testbench: random A and B, K from 1 to N, ReLU on
   and off, compare with a reference loop, check CYCLES.

Mistake made here: the ReLU bit was packed into the wrong position of CFG;
Verilator's width warnings found it. Run lint early, not at the end.

**Checkpoint:** directed test passes at N = 2, 4 and 8.

---

## Phase 4 - PD_MEM (half a day)

- `scratch_ram.sv`: flop array, byte enables, no reset (contents are lost at
  power-off anyway).
- `uart_tx.sv`: 8N1 shift register, divider register, busy flag.
- `mem_top.sv`: decodes RAM vs UART; every input from PD_CMP goes through
  `ls_lh` then `iso_clamp0` **here, in the receiving domain**, controlled by
  `cmp_iso`; outputs leave through `pd_out`.

**Checkpoint:** a small test writes and reads RAM through `mem_top` and sends
one UART byte; with `cmp_iso = 1` a write has no effect.

---

## Phase 5 - PD_CMP with the CPU (2 days)

1. **Get PicoRV32**: clone github.com/YosysHQ/picorv32, copy `picorv32.v` and
   its licence (`COPYING`) into `rtl/third_party/picorv32/`. Instantiate it
   with: compressed ISA on, multiplier on, divider off, IRQs off, counters
   on, catch misaligned/illegal instructions, reset address 0.
2. **Master mux**: `host_en` selects the debug host port as bus master and
   holds the CPU in reset.
3. **Decoder** on `addr[31:28]`: ROM and accelerator are local; RAM/UART and
   AON are remote; anything else answers `0xDEADBEEF`.
4. **Fence (quiesce)**: when the PMU raises `pwr_req`, stop issuing new
   remote transfers once none is in flight; `pwr_ack = fence & ~acc_busy`.
5. **Operand isolation**: remote address/data are zero unless a remote
   access is active.
6. **Boundary**: outputs through `pd_out`; inputs from PD_MEM through
   `iso_clamp0` (`mem_iso`), no level shifter (high to low is safe).
7. **Boot ROM**: start with a hand-written ROM of a few instructions, or go
   straight to Phase 6 and generate it.

**Checkpoint:** lint clean; with a tiny ROM program that writes a RAM word,
the write appears in `mem_top`.

---

## Phase 6 - Firmware (1 day)

1. `fw/soc.h`: the register map from the spec as `#define`s (must match
   `soc_pkg.sv`).
2. `fw/link.ld`: ROM 4 KB at 0, RAM 512 B at 0x1000_0000, `.noinit` section,
   stack at the top of RAM, and an `ASSERT` forbidding initialised `.data`.
3. `fw/crt0.S`: clear x1-x31 (no hardware reset of the register file), set
   `sp`, clear `.bss` but not `.noinit`, `call main`.
4. `scripts/gen_rom.py`: binary -> `rtl/cmp/boot_rom.sv` as a `case`.
5. `fw/main.c`, step by step:
   - first just `puts("hello")` over the UART;
   - then the accelerator self-test;
   - later (after Phase 7) illegal requests, DVFS, IDLE, SLEEP and the
     `BOOT_REASON` dispatch (theory.md 2.4).
6. A UART receiver model (`tb/models/uart_rx_model.sv`) for the testbench,
   watching for "PASS" / "FAIL".

**Checkpoint:** a simulation of the SoC prints `hello` (needs Phase 8's top
level; a temporary top with PD_CMP + PD_MEM is fine).

---

## Phase 7 - PD_AON and the PMU (3 days, the core of the project)

1. **`clk_rst_ctrl.sv`**: divide-by-2, `clk_switch`, synchronised switch
   status (`freq_lo_ack`, `freq_hi_ack`), `rst_sync` for clk_sys, two ICGs for
   `clk_cmp` and `clk_mem`, domain resets = system reset AND PMU reset.
2. **`wake_timer.sv`**: toggle synchroniser both ways, 24-bit counter on
   clk_32k, quasi-static period. Add the arm-echo check from the start
   (theory.md 7.6): otherwise you will rediscover the stale-expiry bug.
3. **`pmu_fsm.sv`**: write the sequence table from the spec as an enum of
   step states, then:
   - `always_comb`: request legality (`req_ok`, `err_pulse`), next step
     (`nxt`) and when to advance (`adv = waited & <ack>`);
   - `always_ff`: on `adv`, move and change exactly one registered output;
     the step counter `cnt` loaded from `SEQ_CFG`;
   - wake latching: events during a power-down set `wake_pend`; a wake starts
     from `S_STABLE` when not active;
   - `pstate` updates only at the end of a sequence.
4. **`aon_regs.sv`**: PMU_CTRL (write = request; latch the **written** value,
   not the old register), STATUS, WAKE_TIMER, WAKE_MASK, SEQ_CFG,
   BOOT_REASON, WAKE_CNT, RET_ACC, 4 scratch words.
5. **`aon_top.sv`**: everything from PD_CMP through `ls_lh` then
   `iso_clamp0`; the retention shadow loaded on `cmp_save`; the wake pin
   synchronisers and edge detectors; and two-flop synchronisers on
   `vdd_ok`, `sw_ack_cmp`, `sw_ack_mem` (they come from analog blocks with
   no clock: this project forgot them until corner STA found it).

Mistakes made here, all caught by tests:

- The PMU sampled the **previous** PMU_CTRL value, because the register
  update and the request pulse happened in the same cycle. Pass `wdata`
  straight to the PMU as the target.
- Reset was released with the clock still gated, so PicoRV32 (synchronous
  reset) was never reset. Clock on first.
- The 32 kHz domain missed power-on reset when POR was shorter than one slow
  clock period. The testbench holds POR for three slow periods; a real POR
  circuit must too.

**Checkpoint:** a directed testbench drives the PMU ports directly and walks
H -> L -> H -> IDLE -> wake -> SLEEP -> wake, checking the order of every
output change against the spec table.

---

## Phase 8 - SoC top and first full-system run (1 day)

1. `soc_top.sv`: instantiate `u_aon`, `u_cmp`, `u_mem`; pad-side isolation on
   the UART pin (`iso_clamp1`, clamp high) and on the host read path
   (`ls_lh` + `iso_clamp0`).
2. Environment models in `tb/models/`: `regulator_model.sv` (`vdd_ok` low for
   SETTLE cycles after a change), `pwr_switch_model.sv` (ack after DELAY
   cycles).
3. A first plain testbench: clocks, POR, models, UART receiver; run the full
   firmware.

**Checkpoint:** the firmware prints `DONE PASS` through cold boot, IDLE with
timer wake and SLEEP with GPIO wake.

---

## Phase 9 - Class-based verification environment (3 days)

Build `tb/env/tb_pkg.sv` in this order, running something at each step:

1. `soc_if.sv`: an interface with the pins (clock as an interface port).
2. `host_driver`: `write32`, `read32`, `pulse`, `wait_stable`; drive and
   sample on the **falling** edge.
3. `scoreboard`: `check(ok, msg)`, counts.
4. `mat_job`: random `k`, `relu`, `corners`, `seed`; constraints;
   `post_randomize` computes expected C; `fixup()` for Verilator.
5. `base_test` with `run_job`, then the first test `test_matmul_rand`, and
   `tb/top/tb_soc.sv` with `+TEST` / `+ITERS` and a `create_test` factory.
   **Run it now.**
6. `pwr_req_item` and `pmu_model`, then `request`, `dvfs`, `sleep_wake` with
   the retention checks after every wake.
7. The remaining tests: `test_state_walk`, `test_sleep_wake_rand`,
   `test_wake_race` (wake at every offset into power-down),
   `test_dvfs_switch`, `test_illegal_req`, `test_fw_e2e`.
8. `soc_cov`: covergroups (state transitions, wake source x state, K x ReLU),
   guarded with `` `ifndef VERILATOR ``.
9. Assertions in `tb/sva/` (`pmu_sva`, `mac_sva`, `soc_sva`) attached with
   `bind`.

Mistakes made here (simulator portability, mostly Verilator):

- A virtual-interface clock and combinational host feedback made Verilator
  fail to converge: make `clk_sys` an interface **port**, and sample host
  outputs on the falling edge in `tb_soc`.
- `default disable iff` unsupported: use a `CHK` macro.
- Constraints ignored: the `fixup()` fallback, with `legal()` checked either
  way.

**Checkpoint:** `run.py regress --seeds 3`: every test passes for N = 4 and 8.

---

## Phase 10 - Power-aware simulation (1 day)

1. With `PWR_SIM`: `pd_out` drives X when its domain's power-good is low;
   `mac_accel` and `cmp_top` corrupt their unreset storage (buffers, CPU
   register file) on the falling edge of the domain reset.
2. `tb/power/tb_power.sv`: runs the firmware and checks every cycle that no
   X reaches a powered receiver, that isolated signals sit at their clamp,
   that the corruption model is live (X really appears), RAM survives IDLE
   and is lost in SLEEP, and the sequencing rules hold.
3. Fault injection: build with `FAULT_NO_ISO`; the test **must fail**.

Mistake made here: Icarus's `$isunknown` misbehaved on hierarchical
concatenations; the `HAS_X` macro (`^(v) === 1'bx`) works everywhere.

**Checkpoint:** `run.py power` passes and `run.py power --fault` reports
errors.

---

## Phase 11 - Formal proof of the PMU (2 days)

1. `formal/pmu_formal.sv`: instantiate `pmu_fsm` with **free** inputs.
   Environment models: switches and regulator acknowledge only what was
   asked, after any delay. `assume (seq_wait <= 2)` keeps the depth small.
2. Assertions (immediate `assert` in clocked blocks, which the open-source
   front end supports): off implies isolated; power-good low implies
   isolated; CMP on implies MEM on; off implies clock and reset held; save
   and restore only in safe conditions; isolation released only after
   power-good and restore; full speed only at full voltage; frequency up only
   after voltage confirmed. 14 in all.
3. Covers for every state and wake, so you know the assumptions aren't too
   strong.
4. `formal/pdr.ys` (Yosys -> AIGER) + `abc pdr`; `formal/pmu.sby` for
   SymbiYosys with prove, bmc and cover tasks.
5. Mutation test: break the PMU three ways and confirm the proof fails each
   time.

Mistake made here: the SMT-based engine choked on this harness; the AIGER +
PDR route needed `setundef` and `dffunmap` steps in `pdr.ys`.

**Checkpoint:** `Property proved`; three mutations each produce a
counterexample.

---

## Phase 12 - Static checks and unit tests (1 day)

- `scripts/verilator_waivers.vlt`: waive only reviewed warnings.
- `scripts/check_crossings.py`: Yosys JSON of the hierarchy; for each
  boundary input listed, every bit must drive only the expected
  `ls_lh` / `iso_clamp*` first. Test it by adding a bypass on purpose.
- `tb/unit/tb_wake_timer.sv`: re-arm exactly on an expiry
  (`@(dut.match_tgl)`); exactly one event expected.
- `scripts/slang_check.py`: pyslang compile of each testbench config.

**Checkpoint:** all four pass; the deliberate crossing bypass is reported.

---

## Phase 13 - Synthesis and gate-level power simulation (2 days)

1. `run.py synth`: Yosys with the Sky130 tt Liberty; record area for the
   power-managed SoC, the `NO_ISOLATION` baseline, and the accelerator at
   N = 4 and 8.
2. Gate-level flow (`run.py gls`):
   - synthesise with `SKY130_CELLS SKY130_ISO SKY130_LS`, keeping
     `cmp_top`, `mem_top`, `aon_top` as hierarchy, `hilomap` for constants,
     `write_verilog -noattr -noexpr`;
   - `scripts/gls_power_pins.py`: add `VPWR/VGND/VPB/VNB` (and `LOWLVPWR` on
     level shifters) to every cell from its module's domain, and pass
     `VDD_AON, VDD_CMP, VDD_MEM, VSS` down the hierarchy;
   - fetch SkyWater's cell models (sparse git clone, pinned commit);
   - `tb/gls/tb_gls.sv`: rails = switch enabled AND acknowledged; host-driven
     walk with per-cycle X checks and post-wake retention checks;
   - compile with `-DUSE_POWER_PINS -DFUNCTIONAL -DUNIT_DELAY=#1`;
   - rebuild with `FAULT_NO_ISO`: must fail.

**Checkpoint:** `TEST PASSED tb_gls`, and the fault build fails.

---

## Phase 14 - UPF (half a day)

Write `upf/soc.upf` from your spec tables: domains, supply ports/nets/sets,
switches, isolation (clamp 0, plus the UART clamp-1 exception), level
shifters on PD_CMP outputs, retention of the accelerator config, power
states (with CMP-on/MEM-off left out). Then `upf/soc_openroad.upf`, the
subset OpenROAD reads. You can't simulate it with open tools; review it
against the RTL line by line.

---

## Phase 15 - Physical design configs (2 days, mostly waiting for CI)

1. `flow/sky130/soc.sdc`: 20 ns clock, 32 kHz clock asynchronous, I/O
   delays at 20 %, false paths on async pins.
2. `flow/sky130/common.mk` (repo paths, RTL list from `rtl/files.f`), then
   one `config.mk` per design: `mac_accel` (fast), `soc_baseline`
   (`NO_ISOLATION`), `soc_lp` (real cells, `SYNTH_KEEP_MODULES`),
   `soc_multidomain` (experimental: `domains.tcl`, `pdn.tcl`).
3. `flow/asap7/mac_accel/config_{rvt,lvt,mixed}.mk` with a tight 700 ps clock.
4. `flow/scripts/power_by_domain.tcl` + `summarize_power.py` (per domain,
   per state, vs baseline), `sta_corners.tcl` (one corner per run).
5. Run `mac_accel` first and fix config errors there; then the SoC.

Mistake made here: ORFS's default flattening renamed most logic gates, so
the per-domain power split would have been wrong; keep the domain modules
(`SYNTH_KEEP_MODULES`) and make the summariser refuse an implausible split.

**Checkpoint:** `pnr` produces `6_final.gds` and finish reports for all
designs.

---

## Phase 16 - Automation and CI (1 day, grow it throughout)

- `scripts/run.py`: start it in Phase 2 with just `lint` and `sim`, and add a
  subcommand each time you add a step. One script that works on Windows and
  in CI is what keeps the project reproducible.
- `.vscode/tasks.json` (each task = one `run.py` command),
  `.vscode/extensions.json`, `.devcontainer/devcontainer.json`.
- `.github/workflows/verify.yml` (Ubuntu packages: verilator, iverilog,
  yosys, RISC-V GCC; pip: pyslang) running the same `run.py` commands.
- `.github/workflows/pnr.yml`: activity VCD job, ORFS jobs in the
  `openroad/orfs` container, artifact upload, summaries, corner STA.

**Checkpoint:** a push turns `verify` green.

---

## Phase 17 - Results and documentation (1 day)

- `docs/results.md`: every number with its source report. No number you
  can't trace.
- `docs/verification.md`, `physical_design.md`, `use_case.md`,
  `open_questions.md` (be honest about what is modelled), `CHANGELOG.md`
  (including the bugs your flow caught: that's the best evidence it works).
- README with the block diagram and the status table.

---

## Before you call it done: self-review

- [ ] Every crossing in the spec table appears in `check_crossings.py`.
- [ ] Every sequencing rule is an SVA assertion **and** a formal property.
- [ ] Every test passes with a non-zero check count; fault injection fails
      the power test and the GLS.
- [ ] The firmware runs end to end at N = 4 and 8.
- [ ] Lint is clean with only reviewed waivers.
- [ ] `run.py all` passes on a fresh clone.
- [ ] Every number in `results.md` has a source.
- [ ] You can narrate theory.md Part 11 with the code open.
