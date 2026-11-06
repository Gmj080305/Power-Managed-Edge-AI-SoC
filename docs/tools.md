# Tools

How to use every tool in this project, for this project. For installing them
on Windows see [windows_setup.md](windows_setup.md); this page assumes they
are on your PATH and starts from "now what do I type".

| Tool | Job in this project | Runs where |
| --- | --- | --- |
| [VS Code](#1-vs-code) | editor, terminal, task runner, waveform viewer | Windows |
| [Git and GitHub](#2-git-and-github) | version control, applying the diffs, CI | Windows + cloud |
| [Python and `run.py`](#3-python-and-scriptsrunpy) | one command for every step | Windows |
| [Vivado xsim](#4-vivado-simulator-xsim) | full SystemVerilog: classes, constraints, covergroups, coverage | Windows |
| [Verilator](#5-verilator) | lint, fast regression | Windows / CI |
| [Icarus Verilog](#6-icarus-verilog) | 4-state X simulation, unit test, gate-level sim | Windows / CI |
| [Yosys](#7-yosys) | synthesis, area, netlists, crossing check, formal front end | Windows / CI |
| [ABC and SymbiYosys](#8-formal-abc-pdr-and-symbiyosys) | formal proofs | Windows / CI |
| [slang (pyslang)](#9-slang-pyslang) | strict compile of every testbench | Windows / CI |
| [RISC-V GCC](#10-risc-v-gcc-firmware) | firmware | Windows / CI |
| [Waveform viewers](#11-waveform-viewers) | debugging | Windows |
| [GitHub Actions](#12-github-actions) | `verify` on every push, `pnr` on demand | cloud |
| [OpenROAD-flow-scripts](#13-openroad-flow-scripts-orfs) | RTL to GDS, timing, power | cloud (Docker) |
| [KLayout](#14-klayout) | viewing the layout | Windows |
| [Codespaces, EDA Playground, ciel](#15-other-services) | cloud machine, commercial simulators, PDK install | cloud |

A rule for the whole page: **run everything from the repository root** in the
VS Code terminal (the "EDA" profile from `windows_setup.md`). Every path below
is relative to it.

---

## 1. VS Code

### Daily use

| Do | How |
| --- | --- |
| open the project | *File -> Open Folder* -> the repo folder |
| terminal | `` Ctrl+` `` (use the "EDA" profile so the tools are on PATH) |
| run a task | `Ctrl+Shift+P` -> *Tasks: Run Task* -> pick one (defined in `.vscode/tasks.json`) |
| default task (one test) | `Ctrl+Shift+B` |
| find a file | `Ctrl+P`, type part of the name |
| search the whole repo | `Ctrl+Shift+F` (try `cmp_iso` to see every place isolation is used) |
| jump to a module | `F12` on its name (with the Verilog extension) |

Tasks in `.vscode/tasks.json` all call `python scripts/run.py ...`, so a task
does exactly what the same command in the terminal does. The *sim: one test*
task asks for a test name, seed and N from drop-down lists.

### Extensions (recommended in `.vscode/extensions.json`)

| Extension | What you use it for |
| --- | --- |
| Verilog-HDL/SystemVerilog (`mshr-h.veriloghdl`) | syntax highlighting, go-to-definition; it can also run a linter on save (set `verilog.linting.linter` to `verilator` in settings) |
| Verible (`chipsalliance.verible`) | formatter and language server; needs the Verible binaries from github.com/chipsalliance/verible releases on PATH |
| TerosHDL | module diagrams, FSM viewer (open `pmu_fsm.sv` and look at the state graph), documentation |
| Surfer, VaporView | open `.vcd` waveforms inside VS Code |
| Python | runs and debugs `scripts/*.py` |
| GitHub Actions | see workflow runs and logs without leaving VS Code |
| GitHub Codespaces | open the repo on a cloud Linux machine (section 15) |

---

## 2. Git and GitHub

### What you need to know

- A **commit** is a snapshot. `main` is the branch everyone sees on GitHub.
- `origin` is the GitHub copy; `git push` sends your commits there, `git pull`
  fetches others'.
- Each push runs the `verify` workflow automatically.

### Applying a diff from Claude (the method used for every release)

```powershell
cd C:\path\to\Power-Managed-Edge-AI-SoC
git status                      # must say "nothing to commit, working tree clean"
git pull                        # be on the latest main
git apply --index "$HOME\Downloads\edge_ai_soc_v0.3.diff"
git status                      # shows the new and changed files, already staged
git commit -m "v0.3: theory, tools and recreate guides"
git push origin main
```

`--index` applies the change to both your files and the staging area, so the
commit includes new files without a separate `git add`.

If `git apply` says **"patch does not apply"**: your copy isn't at the
commit the diff was made against (you edited a file, or skipped a release).
Run `git log --oneline -3` and compare with the base named in the release
note; `git stash` puts local edits aside. `git apply --check <diff>` tests
without changing anything.

### Everyday commands

| Command | Use |
| --- | --- |
| `git status` | what changed |
| `git diff` | the changes themselves |
| `git log --oneline -10` | recent commits |
| `git add <file>` then `git commit -m "msg"` | save your own change |
| `git restore <file>` | throw away your edits to a file |
| `git switch -c my-experiment` | a branch for trying something; `git switch main` to go back |
| `git revert <commit>` | undo a pushed commit safely (new commit that reverses it) |

`.gitattributes` keeps line endings as LF in the repo even on Windows, and
`.gitignore` keeps `build/` (everything generated) out of Git.

---

## 3. Python and `scripts/run.py`

`run.py` is the single entry point. It finds the tools, builds into `build/`,
runs, and decides PASS/FAIL. You never need to remember tool flags.

| Command | What it runs | Pass means |
| --- | --- | --- |
| `python scripts/run.py fw` | RISC-V GCC on `fw/`, then `gen_rom.py` -> `rtl/cmp/boot_rom.sv` | builds |
| `python scripts/run.py lint` | Verilator `--lint-only -Wall` at N = 4 and 8 (+ Verible if present) | no messages |
| `python scripts/run.py crossings` | `check_crossings.py` (Yosys) | 0 problems |
| `python scripts/run.py unit` | wake-timer unit test (Icarus or xsim) | `PASS tb_wake_timer` |
| `python scripts/run.py elab` | slang compile of 4 testbench configs | 4 x PASS |
| `python scripts/run.py sim --test T --seed S --n N [--iters I] [--waves] [--pwr]` | one class-based test | `TEST PASSED` |
| `python scripts/run.py regress [--quick] [--seeds 3] [--n 4 8]` | every test x seeds x N; coverage in xsim | `38/38 passed` |
| `python scripts/run.py power [--fault] [--activity] [--n 8]` | firmware with X modelling | pass; with `--fault`, "fault injection: N errors detected" |
| `python scripts/run.py formal [--no-sby]` | PMU proofs | `Property proved` |
| `python scripts/run.py synth --fetch-lib [--baseline] [--top mac_accel --n 8]` | Yosys area at Sky130 tt | prints area |
| `python scripts/run.py gls [--fault] [--waves]` | gate-level power sim | `TEST PASSED tb_gls`; with `--fault`, "fault detected: PASS" |
| `python scripts/run.py all [--no-gls]` | lint, crossings, unit, formal, quick regression, power (+fault), gls (+fault) | `ALL PASSED` |

Add `--sim xsim|verilator|icarus` to choose a simulator; by default it picks
xsim when Vivado is on PATH. Every command prints the exact tool command lines
it runs (lines starting with `+`), so you can copy one and run it by hand.

Where the output goes:

| Path | Contains |
| --- | --- |
| `build/<sim>_<top>_n<N>[_pwr][_w]/` | one simulator build; `*.log` per test run |
| `build/regress_summary.md` | the regression table |
| `build/coverage_n4/` | xsim coverage reports (HTML) |
| `build/synth_<top>_n<N>/area.txt` | Yosys area report |
| `build/gls/` | netlist, `stat.txt`, `sim.log`; `build/sky130_fd_sc_hd/` is the cell-model download |
| `fw/build/` | `firmware.elf`, `.bin`, `.lst` (disassembly) |

---

## 4. Vivado simulator (xsim)

You only use Vivado's **simulator**, from the command line; no Vivado project
is needed. xsim supports the full SystemVerilog this project uses: classes,
constraint solving, covergroups, concurrent assertions and code coverage.

### The three steps (what `run.py` does)

```powershell
mkdir build\manual; cd build\manual
xvlog --sv --define MAC_N=4 ..\..\rtl\pkg\soc_pkg.sv  <...all files in rtl/files.f...>  ..\..\tb\top\tb_soc.sv
xelab work.tb_soc --timescale 1ns/1ps --debug typical -s tb_soc_snap
xsim tb_soc_snap -R -sv_seed 5 -testplusarg TEST=test_wake_race -testplusarg ITERS=30
```

1. `xvlog` **compiles** source files into the `work` library.
2. `xelab` **elaborates** (builds the design hierarchy) into a snapshot.
   `--debug typical` keeps signal visibility for waveforms.
3. `xsim` **runs** the snapshot. `-R` = run to the end and exit.

Easier: `python scripts/run.py sim --test test_wake_race --seed 5 --sim xsim`.

### Waveforms in the Vivado GUI

```powershell
cd build\xsim_tb_soc_n4
xsim tb_soc_snap -gui
```

In the GUI: select signals in the *Scope* and *Objects* panes, right-click ->
*Add to Wave Window*, then *Run All*. Good signals to start with:
`tb_soc/dut/u_aon/u_pmu/state`, `pstate`, `cmp_iso`, `cmp_sw_en`,
`tb_soc/sw_ack_cmp`. Or use `--waves` with `run.py sim` for a VCD and view it
in VS Code (section 11).

### Coverage

`python scripts/run.py regress --seeds 3` (with xsim) collects functional and
code coverage and runs `xcrg` to write HTML reports to `build/coverage_n4/`
and `build/coverage_n8/`. Open them in a browser and look for uncovered bins:
those are scenarios the random tests never produced.

### If something fails

- `'xvlog' is not recognized`: Vivado's `bin` folder is not on PATH. Find it
  by right-clicking the Vivado Start-menu shortcut -> *Open file location*,
  and fix the EDA terminal profile.
- Errors in `xvlog.log` / `xelab.log` in the build folder. `run.py elab`
  (slang) compiles the same xsim-only code paths, so syntax problems usually
  show up there first.

---

## 5. Verilator

Verilator compiles SystemVerilog to C++ and then to a fast executable. It is
**2-state** (no X) and in version 5.0x ignores constraints and covergroups,
so this project uses it for **lint** and for **fast regressions**; the X and
coverage work happens in xsim and Icarus.

```powershell
python scripts/run.py lint                      # verilator --lint-only -Wall
python scripts/run.py regress --sim verilator   # 38 runs in seconds
```

What `run.py` runs to build a simulation:

```
verilator --binary --timing -j 0 -Wno-fatal --top-module tb_soc -DMAC_N=4 \
          scripts/verilator_waivers.vlt <rtl files> <tb files>
build/verilator_tb_soc_n4/obj/sim +TEST=test_matmul_rand +ITERS=20 +verilator+seed+3
```

- `--binary --timing` builds a standalone executable that supports `#delay`
  and `@(event)` in testbenches.
- `scripts/verilator_waivers.vlt` silences known, reviewed warnings (e.g.
  everything in third-party PicoRV32). Add a waiver only after reading the
  warning; lint caught two real bugs in this project.
- Reading a lint message: `%Warning-WIDTHTRUNC: rtl/x.sv:42:...` gives rule,
  file, line. Look up the rule name in the Verilator manual.

Things Verilator does differently, and how the code copes (all in the
CHANGELOG): no `default disable iff` (the `CHK` macro), no latch-based clock
gates (the flop-based ICG model), constraints ignored (`fixup()`).

---

## 6. Icarus Verilog

Icarus is a small event-driven **4-state** simulator: it shows X, which the
power-aware tests need. Two commands:

```powershell
iverilog -g2012 -s tb_wake_timer -o build\t.vvp rtl\common\sync_2ff.sv rtl\common\pulse_sync.sv rtl\aon\wake_timer.sv tb\unit\tb_wake_timer.sv
vvp -n build\t.vvp
```

- `iverilog` compiles; `-g2012` enables SystemVerilog-2012 features, `-s`
  names the top module, `-D NAME` defines a macro.
- `vvp` runs; `-n` makes `$stop` exit instead of opening a prompt.
- For the gate-level run, `run.py gls` also passes `-grelative-include` (so
  the Sky130 model files find their `include`s), `-DUSE_POWER_PINS
  -DFUNCTIONAL -DUNIT_DELAY=#1`, and a file list with `-c files.f`.

Icarus doesn't support classes, so it runs the plain-SV testbenches:
`tb/power`, `tb/unit`, `tb/gls`.

---

## 7. Yosys

Yosys is an open-source synthesis tool. You drive it with a script of
commands (`.ys`) or interactively.

### Interactive tour (good way to learn)

```powershell
yosys
```
```
yosys> read_verilog -sv rtl/pkg/soc_pkg.sv rtl/aon/pmu_fsm.sv
yosys> hierarchy -top pmu_fsm
yosys> proc              # processes (always blocks) -> flops and muxes
yosys> stat              # count of generic cells
yosys> synth -top pmu_fsm
yosys> stat              # after optimisation
yosys> ls                # modules in the design
yosys> exit
```

`show` draws the netlist as a graph (needs Graphviz; try it on `mac_pe`, not
on the whole SoC).

### Synthesis to Sky130 (what `run.py synth` writes to `build/synth_*/synth.ys`)

```
read_liberty -lib sky130_fd_sc_hd__tt_025C_1v80.lib    # know the cells
read_verilog -sv -DSKY130_CELLS -DSKY130_ISO <files>    # RTL with real LP cells
hierarchy -check -top soc_top -chparam MAC_N 4          # elaborate, set N
synth -top soc_top                                      # generic synthesis
dfflibmap -liberty <lib>                                # flops -> Sky130 flops
abc -liberty <lib>                                      # logic -> Sky130 gates
stat -liberty <lib>                                     # cell count and area
```

Read `area.txt`: `Number of cells` and `Chip area` per module and in total.
The gate-level flow (`build/gls/synth.ys`) adds `setattr -mod -set
keep_hierarchy 1 *cmp_top* ...` (keep one module per power domain),
`hilomap` (tie cells for constants) and `write_verilog` (the netlist).

Yosys 0.33 quirks met here: no `int'()` casts, no package `import` inside
modules (use `soc_pkg::NAME`).

`scripts/check_crossings.py` uses Yosys to dump the elaborated design as JSON
and walks the connections in Python. `formal/pdr.ys` uses it to convert the
formal harness into an AIGER circuit.

---

## 8. Formal: ABC PDR and SymbiYosys

### Without SymbiYosys (what CI uses)

```powershell
python scripts/run.py formal --no-sby
```

That runs `yosys -q formal/pdr.ys` (harness -> `build/formal/pmu.aig`) and
then `yosys-abc -c "read_aiger -c build/formal/pmu.aig; fold; strash; pdr"`.
`Property proved` = all 14 assertions hold for all time. On failure ABC
reports which output failed; switch to SymbiYosys for a trace.

### With SymbiYosys (included in OSS CAD Suite)

```powershell
sby -f formal/pmu.sby            # prove, bmc and cover
sby -f formal/pmu.sby prove      # one task
```

Each task writes a folder `formal/pmu_<task>/`. On a failure, the
counterexample is a VCD under `formal/pmu_<task>/engine_0/`: open it in a
waveform viewer and you see the exact input sequence that breaks the
property, usually a few dozen cycles. The `cover` task produces one trace per
`cover` statement, showing how each scenario is reached.

To experiment: break the PMU on purpose (e.g. in `pmu_fsm.sv` move
`cmp_iso <= 1'b1` from `S_C_ISO` to `S_C_RST`), run the proof, read the
counterexample, then undo. That's the mutation test done by hand.

---

## 9. slang (pyslang)

slang is a very strict SystemVerilog compiler; `pyslang` is its Python
package. Here it compiles every testbench, including the code only xsim runs.

```powershell
python -m pip install pyslang
python scripts/run.py elab
```

`scripts/slang_check.py` lists the four configurations (files and defines);
add a new testbench there when you write one. Errors come out like a
compiler's: `file:line:col: error: ...`.

---

## 10. RISC-V GCC (firmware)

Only needed when you change `fw/`. On Windows the xPack build provides
`riscv-none-elf-gcc`; CI uses Ubuntu's `riscv64-unknown-elf-gcc`. `run.py fw`
accepts either.

```powershell
python scripts/run.py fw
```

runs:

```
riscv-none-elf-gcc -march=rv32imc -mabi=ilp32 -Os -ffreestanding -nostdlib -nostartfiles \
   -T fw/link.ld -Wl,--gc-sections -o fw/build/firmware.elf fw/crt0.S fw/main.c
riscv-none-elf-objcopy -O binary fw/build/firmware.elf fw/build/firmware.bin
riscv-none-elf-objdump -d fw/build/firmware.elf  > fw/build/firmware.lst
python scripts/gen_rom.py fw/build/firmware.bin rtl/cmp/boot_rom.sv
```

| Flag | Why |
| --- | --- |
| `-march=rv32imc -mabi=ilp32` | match PicoRV32's configuration |
| `-ffreestanding -nostdlib -nostartfiles` | no operating system, no C library, our own `crt0` |
| `-T fw/link.ld` | our memory map |
| `-Os` | small code (4 KB ROM) |

`riscv-none-elf-size fw/build/firmware.elf` shows code and data size.
`firmware.lst` is the disassembly: when a simulation shows the CPU stuck at
some PC, look that address up there. Commit the regenerated
`rtl/cmp/boot_rom.sv` together with the C change.

---

## 11. Waveform viewers

Waveforms are how you debug. Getting one:

| From | Command | File |
| --- | --- | --- |
| class-based test | `python scripts/run.py sim --test test_state_walk --waves` | `build/<sim>_tb_soc_n4_w/tb_soc.vcd` |
| power test | `python scripts/run.py power --waves` | in `build/icarus_tb_power_*` or the xsim folder |
| gate-level test | `python scripts/run.py gls --waves` | `build/gls/tb_gls.vcd` (top-level signals) |
| formal counterexample | `sby -f formal/pmu.sby` | `formal/pmu_*/engine_0/*.vcd` |

Open a `.vcd` with **Surfer** or **VaporView** in VS Code (right-click ->
*Open With...*), or with the Vivado GUI for xsim runs. GTKWave (in OSS CAD
Suite) also works.

What to look at first in a power bug: `pstate`, the PMU `state`, `cmp_iso`,
`cmp_sw_en`, `sw_ack_cmp`, `cmp_clk_en`, `cmp_rst_n`, and the signal that
went X. Find the first cycle it went X, then walk backwards to its source.

---

## 12. GitHub Actions

Two workflows in `.github/workflows/`:

| Workflow | When | Takes | Does |
| --- | --- | --- | --- |
| `verify` | every push | ~10-15 min | firmware, lint, crossings, slang, unit, formal, Verilator regression (3 seeds), power tests, GLS, synthesis |
| `pnr` | when you click *Run workflow* | 1-3 h | switching activity, ORFS for 3 Sky130 designs + 3 ASAP7 variants, per-domain power, corner STA, optional multi-domain |

### Running `pnr`

GitHub -> your repo -> **Actions** -> **pnr** (left list) -> **Run workflow**
-> branch `main` -> (optionally tick *multidomain*) -> **Run workflow**.

### Reading results

- Click a run, then a job (e.g. *sky130 soc_lp*) to see each step's log.
  A red X shows the failing step; expand it and scroll to the first error.
- The **Summary** page of the run collects the tables the jobs write: final
  area and slack (`6_finish.rpt` tail), per-domain power, the corner STA
  table.
- **Artifacts** (bottom of the Summary page) are zip files: reports, logs,
  GDS, netlist, power reports. Download, unzip, open.
- *Re-run failed jobs* (top right) after a fix, or push again.

In VS Code, the GitHub Actions extension shows the same runs and logs.

---

## 13. OpenROAD-flow-scripts (ORFS)

ORFS is a set of Makefiles that drives Yosys and OpenROAD through the whole
flow. It runs inside the Docker image `openroad/orfs:latest` (Linux), which
is why it runs in GitHub Actions or a Codespace, not natively on Windows.

### A design config

Each design is a `config.mk` (e.g. `flow/sky130/soc_lp/config.mk`):

| Variable | Meaning |
| --- | --- |
| `PLATFORM` | `sky130hd` or `asap7` (set in `flow/sky130/common.mk`) |
| `DESIGN_NAME` | top module |
| `VERILOG_FILES`, `VERILOG_DEFINES`, `VERILOG_TOP_PARAMS` | what to read, which defines, top parameters |
| `SDC_FILE` | timing constraints |
| `SYNTH_KEEP_MODULES` | modules not flattened (domain hierarchy for the power report) |
| `CORE_UTILIZATION` | % of core area filled with cells (sets die size) |
| `PLACE_DENSITY` | how tightly placement packs cells |
| `ASAP7_USE_VT` | threshold-voltage flavours allowed (ASAP7 only) |

### Running it (in a Codespace or any Linux machine with Docker)

```bash
docker run --rm -v "$PWD:/work" -w /OpenROAD-flow-scripts/flow openroad/orfs:latest \
  make DESIGN_CONFIG=/work/flow/sky130/mac_accel/config.mk WORK_HOME=/work/build/orfs
```

Stages can be run one at a time: `make ... synth`, `floorplan`, `place`,
`cts`, `route`, `finish`; `make ... clean_all` starts over. Start with
`mac_accel` (minutes) before the full SoC (hours).

### Outputs

```
build/orfs/logs/sky130hd/soc_lp/base/       one log per step: read these when a step fails
build/orfs/reports/sky130hd/soc_lp/base/    2_*.rpt ... 6_finish.rpt: timing, area, power
build/orfs/results/sky130hd/soc_lp/base/    6_final.gds, 6_final.v (netlist), .odb, .sdc, .spef
```

In `6_finish.rpt` look for: `report_tns` / `report_wns` (negative = timing
failure), `report_design_area` (area and utilisation), `report_power`
(internal, switching, leakage, total).

### The extra scripts

- `flow/scripts/power_by_domain.tcl`: run with OpenROAD on the final
  database; writes per-instance power. Then
  `python flow/scripts/summarize_power.py power_instances.rpt [--baseline other.rpt]`
  gives the per-domain and per-state table.
- `flow/scripts/sta_corners.tcl`: one STA corner per run, given `LIB`,
  `ODB`, `SDC`, `PERIOD`; the `pnr` workflow loops it over the corners.

---

## 14. KLayout

KLayout views layouts on Windows. Download `6_final.gds` from a `pnr`
artifact, then *File -> Open*. For proper layer colours load the Sky130 layer
properties (*File -> Load Layer Properties*, `sky130hd.lyp` from ORFS's
`flow/platforms/sky130hd/`). Zoom in until you see standard-cell rows, the
power straps, and the clock-gate and isolation cells among them.

---

## 15. Other services

- **GitHub Codespaces**: a Linux machine in the browser or in VS Code, with
  ORFS ready (`.devcontainer/devcontainer.json` uses the same image). Use it
  to rerun one ORFS stage interactively instead of waiting for CI. Free
  monthly hours; more with the GitHub Student Developer Pack. Stop the
  codespace when done, since it uses your hours while running.
- **EDA Playground** (edaplayground.com): run a testbench on commercial
  simulators (Xcelium, Questa, VCS) in the browser. Good for checking that a
  class or assertion behaves the same as in xsim.
- **ciel** (`pip install ciel`): downloads open PDKs (here, Sky130 with all
  timing corners). The `pnr` workflow uses it for corner STA; you won't need
  it on Windows.
- **BITS lab tools**: if the lab has Cadence Xcelium with low-power support,
  `upf/soc.upf` can drive a real UPF-based power-aware simulation, a good
  comparison with `run.py power` and `run.py gls`.

---

## Typical workflows

**I changed some RTL.** `run.py lint` -> `run.py sim --test <closest test>`
-> `run.py regress --quick --seeds 1` -> `run.py power` -> if PMU:
`run.py formal` -> if a boundary: `run.py crossings` -> commit, push, watch
`verify`.

**A test fails.** Read the first `ERROR` line in the test log; rerun that
test and seed with `--waves`; open the VCD; find the first wrong cycle; work
backwards.

**I changed the firmware.** `run.py fw` -> `run.py sim --test test_fw_e2e`
-> `run.py power` -> commit `fw/` and `rtl/cmp/boot_rom.sv` together.

**I want new layout numbers.** Push, then run `pnr`, then copy numbers from
the Summary page into `docs/results.md`, each with its source.
