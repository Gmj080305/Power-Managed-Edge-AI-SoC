#!/usr/bin/env python3
"""Elaborate every testbench with slang (pip install pyslang), a strict
IEEE 1800 compiler. Vivado xsim compiles the code that Verilator skips
(constraints, covergroups, `##` sequences under `ifndef VERILATOR`); slang
checks those paths on any machine, including CI.

    python scripts/slang_check.py
"""
import pathlib
import sys

try:
    from pyslang import DiagnosticEngine
    from pyslang.driver import Driver
except ImportError:
    sys.exit("pyslang not installed: pip install pyslang")

ROOT = pathlib.Path(__file__).resolve().parents[1]
RTL = [l.strip() for l in (ROOT / "rtl/files.f").read_text().splitlines()
       if l.strip() and not l.strip().startswith("//")]
MODELS = ["tb/models/regulator_model.sv", "tb/models/pwr_switch_model.sv",
          "tb/models/uart_rx_model.sv"]
CLASS_TB = ["tb/env/soc_if.sv", "tb/env/tb_pkg.sv", "tb/sva/pmu_sva.sv",
            "tb/sva/mac_sva.sv", "tb/sva/soc_sva.sv", "tb/top/tb_soc.sv"]

CONFIGS = [  # (name, top, defines, files)
    ("class TB, N=4", "tb_soc", ["MAC_N=4"], RTL + MODELS + CLASS_TB),
    ("class TB, N=8, PWR_SIM", "tb_soc", ["MAC_N=8", "PWR_SIM"], RTL + MODELS + CLASS_TB),
    ("power TB, PWR_SIM", "tb_power", ["MAC_N=4", "PWR_SIM", "ACTIVITY"],
     RTL + MODELS + ["tb/power/tb_power.sv"]),
    ("wake timer unit", "tb_wake_timer", [],
     ["rtl/common/sync_2ff.sv", "rtl/common/pulse_sync.sv", "rtl/aon/wake_timer.sv",
      "tb/unit/tb_wake_timer.sv"]),
]


def elaborate(top, defines, files):
    d = Driver()
    d.addStandardArgs()
    args = ["slang", "--top", top, "--timescale", "1ns/1ps"]
    args += [f"-D{x}" for x in defines]
    args += [str(ROOT / f).replace("\\", "/") for f in files]
    if not (d.parseCommandLine(" ".join(args)) and d.processOptions() and d.parseAllSources()):
        return None, "could not parse"
    comp = d.createCompilation()
    diags = comp.getAllDiagnostics()
    errors = [x for x in diags if x.isError()]
    return len(errors), DiagnosticEngine.reportAll(d.sourceManager, errors) if errors else ""


def main() -> int:
    bad = 0
    for name, top, defs, files in CONFIGS:
        n, text = elaborate(top, defs, files)
        ok = n == 0
        bad += not ok
        print(f"{'PASS' if ok else 'FAIL'} slang: {name} ({top})" + ("" if ok else f": {n} errors"))
        if text:
            print(text)
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
