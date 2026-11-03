# Windows setup (VS Code, no Linux)

Everything except place and route runs natively on Windows from the VS Code
terminal. Place and route runs in GitHub Actions (see
[physical_design.md](physical_design.md)).

## Tools

| Tool | Used for | Get it |
| --- | --- | --- |
| Vivado (any recent version, simulator only) | xsim: class-based tests, SVA, covergroups, coverage reports, X-aware power test | you already have it |
| Verilator | fast regression, lint | you already have it (needs its C++ toolchain on PATH) |
| Python 3.10+ | `scripts/run.py` | python.org or `winget install Python.Python.3.12` |
| Git | version control | git-scm.com |
| OSS CAD Suite, `windows-x64` build | Yosys (synthesis, crossing check), SymbiYosys (formal), Icarus Verilog | github.com/YosysHQ/oss-cad-suite-build releases; unzip to `C:\eda` (no spaces in the path) |
| xPack RISC-V Embedded GCC | firmware (`riscv-none-elf-gcc`) - only if you change `fw/` | github.com/xpack-dev-tools/riscv-none-elf-gcc-xpack releases; unzip to `C:\eda` |
| KLayout | viewing GDS from the CI artifacts | klayout.de |

The firmware is already compiled into `rtl/cmp/boot_rom.sv`, so the RISC-V
toolchain is optional until you edit the firmware.

## VS Code

Install the recommended extensions when VS Code offers them
(`.vscode/extensions.json`): Verilog-HDL/SystemVerilog, Verible, TerosHDL,
Surfer, VaporView, Python, GitHub Actions, GitHub Codespaces.

Add an "EDA" terminal profile to your **user** settings
(`Ctrl+Shift+P` -> *Preferences: Open User Settings (JSON)*), adjusting the
three paths:

```json
"terminal.integrated.profiles.windows": {
  "EDA": {
    "source": "PowerShell",
    "args": ["-NoExit", "-Command",
      "& 'C:\\eda\\oss-cad-suite\\environment.ps1'; $env:Path = 'C:\\Xilinx\\Vivado\\2024.2\\bin;C:\\eda\\xpack-riscv-none-elf-gcc\\bin;' + $env:Path"]
  }
},
"terminal.integrated.defaultProfile.windows": "EDA"
```

Check it: in a new terminal, `xvlog --version`, `verilator --version`,
`yosys -V` and `python --version` should all answer.

## Daily use

| Do | Command or task |
| --- | --- |
| run one test | `python scripts/run.py sim --test test_wake_race --seed 5` (task: *sim: one test*) |
| same, with waveforms | add `--waves`, open `build/.../tb_soc.vcd` with Surfer or VaporView |
| every test once | `python scripts/run.py regress --quick --seeds 1` |
| full regression + coverage report | `python scripts/run.py regress --seeds 3` -> `build/coverage_n4/` |
| power-aware test | `python scripts/run.py power` |
| prove the PMU | `python scripts/run.py formal` |
| area estimate | `python scripts/run.py synth --fetch-lib` |
| everything | `python scripts/run.py all` |

`run.py` picks xsim when Vivado is on PATH; add `--sim verilator` for speed.

## Cloud options

- **GitHub Actions**: free for public repositories. `verify` runs on every
  push; `pnr` on demand.
- **GitHub Codespaces**: a cloud machine that opens inside VS Code, with
  OpenROAD ready (`.devcontainer/`). Free personal accounts get 120 core-hours a
  month; verified students up to 180 with the GitHub Student Developer Pack
  (apply with your college email).
- **EDA Playground** (browser): rerun a test on Xcelium or Questa to catch
  simulator-specific SystemVerilog behaviour; needs a validated account.
- **BITS lab**: if your account has Cadence Xcelium with low-power support, run
  `upf/soc.upf` through it and compare with the modelled power-off results.
