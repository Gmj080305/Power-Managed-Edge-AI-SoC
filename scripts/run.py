#!/usr/bin/env python3
"""One entry point for every flow step. Works on Windows (PowerShell / VS Code
tasks) and Linux (CI). Run from anywhere; paths are resolved from the repo.

    python scripts/run.py fw                          build firmware -> boot ROM
    python scripts/run.py lint                        Verilator (+ Verible) lint
    python scripts/run.py crossings                   isolation structure check
    python scripts/run.py unit                        directed unit tests (wake timer)
    python scripts/run.py elab                        slang compile of every TB (xsim code paths)
    python scripts/run.py sim  --test test_wake_race  one class-based test
    python scripts/run.py regress [--quick]           all tests x seeds x N
    python scripts/run.py power [--fault]             power-aware X test (4-state)
    python scripts/run.py formal                      PMU proofs
    python scripts/run.py synth [--lib X.lib]         Yosys area estimate
    python scripts/run.py gls [--fault]               power-aware gate-level sim (Sky130 netlist)
    python scripts/run.py all                         lint+crossings+unit+formal+regress+power
                                                      (+ gls when Yosys and Icarus are present)

Simulator choice (--sim): xsim if Vivado is on PATH, else verilator, else
icarus. Class-based tests need xsim or verilator; the power test needs a
4-state simulator (xsim or icarus) to see X.
"""
from __future__ import annotations

import argparse
import os
import pathlib
import re
import shutil
import subprocess
import sys
import time
import urllib.request

ROOT = pathlib.Path(__file__).resolve().parents[1]
BUILD = ROOT / "build"
IS_WIN = os.name == "nt"

TESTS = {  # name : default iterations
    "test_matmul_rand": 20,
    "test_state_walk": 10,
    "test_sleep_wake_rand": 100,
    "test_wake_race": 121,
    "test_dvfs_switch": 10,
    "test_illegal_req": 20,
    "test_fw_e2e": 1,
}
QUICK_ITERS = {"test_matmul_rand": 5, "test_state_walk": 2, "test_sleep_wake_rand": 10,
               "test_wake_race": 30, "test_dvfs_switch": 3, "test_illegal_req": 10,
               "test_fw_e2e": 1}

TB_CLASS = ["tb/models/regulator_model.sv", "tb/models/pwr_switch_model.sv",
            "tb/models/uart_rx_model.sv", "tb/env/soc_if.sv", "tb/env/tb_pkg.sv",
            "tb/sva/pmu_sva.sv", "tb/sva/mac_sva.sv", "tb/sva/soc_sva.sv",
            "tb/top/tb_soc.sv"]
TB_POWER = ["tb/models/regulator_model.sv", "tb/models/pwr_switch_model.sv",
            "tb/models/uart_rx_model.sv", "tb/power/tb_power.sv"]

SKY130_LIB_URL = ("https://raw.githubusercontent.com/The-OpenROAD-Project/"
                  "OpenROAD-flow-scripts/master/flow/platforms/sky130hd/lib/"
                  "sky130_fd_sc_hd__tt_025C_1v80.lib")
SKY130_MODELS_URL = "https://github.com/google/skywater-pdk-libs-sky130_fd_sc_hd.git"
SKY130_MODELS_REV = "ac7fb61f06e6470b94e8afdf7c25268f62fbd7b1"


# ---------------------------------------------------------------- helpers
def rtl_files() -> list[str]:
    lines = (ROOT / "rtl/files.f").read_text().splitlines()
    return [l.strip() for l in lines if l.strip() and not l.strip().startswith("//")]


def tool(name: str) -> str | None:
    return shutil.which(name)


def cmdline(argv: list[str]) -> list[str]:
    """Windows runs .bat/.cmd tools (Vivado) through cmd.exe."""
    exe = shutil.which(argv[0]) or argv[0]
    if IS_WIN and exe.lower().endswith((".bat", ".cmd")):
        return ["cmd", "/c", exe] + argv[1:]
    return [exe] + argv[1:]


def run(argv: list[str], cwd: pathlib.Path = ROOT, log: pathlib.Path | None = None,
        check: bool = True) -> subprocess.CompletedProcess:
    print("+", " ".join(str(a) for a in argv), flush=True)
    r = subprocess.run(cmdline([str(a) for a in argv]), cwd=cwd, text=True,
                       stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    if log:
        log.parent.mkdir(parents=True, exist_ok=True)
        log.write_text(r.stdout)
    if check and r.returncode != 0:
        print(r.stdout[-4000:])
        sys.exit(f"command failed ({r.returncode}): {argv[0]}")
    return r


def pick_sim(requested: str | None, need_classes: bool, need_4state: bool) -> str:
    if requested:
        return requested
    if tool("xvlog"):
        return "xsim"
    if need_4state and tool("iverilog"):
        return "icarus"
    if tool("verilator") and (need_classes or not need_4state):
        return "verilator"
    if tool("iverilog") and not need_classes:
        return "icarus"
    sys.exit("no suitable simulator on PATH (Vivado xsim, Verilator or Icarus)")


def defines(n: int, pwr: bool, waves: bool, extra: list[str]) -> list[str]:
    d = [f"MAC_N={n}"]
    if pwr:
        d.append("PWR_SIM")
    if waves:
        d.append("WAVES")
    return d + extra


# ---------------------------------------------------------------- build + run
def build(sim: str, top: str, tb: list[str], n: int, pwr: bool, waves: bool,
          extra: list[str], cov: bool = False) -> pathlib.Path:
    tag = f"{sim}_{top}_n{n}" + ("_pwr" if pwr else "") + ("_w" if waves else "") + \
          "".join("_" + e.lower() for e in extra)
    out = BUILD / tag
    out.mkdir(parents=True, exist_ok=True)
    srcs = [str(ROOT / f) for f in rtl_files() + tb]
    defs = defines(n, pwr, waves, extra)

    if sim == "verilator":
        args = ["verilator", "--binary", "--timing", "-j", "0", "-Wno-fatal", "-Wno-lint",
                "-Wno-style", "--timescale", "1ns/1ps", "--top-module", top,
                "--Mdir", out / "obj", "-o", "sim"]
        args += [f"-D{d}" for d in defs]
        args += [ROOT / "scripts/verilator_waivers.vlt"] + srcs
        run(args, log=out / "build.log")
    elif sim == "icarus":
        args = ["iverilog", "-g2012", "-s", top, "-o", out / "sim.vvp"]
        args += [f"-D{d}" for d in defs] + srcs
        run(args, log=out / "build.log")
    elif sim == "xsim":
        args = ["xvlog", "--sv", "--work", "work"]
        for d in defs:
            args += ["--define", d]
        run(args + srcs, cwd=out, log=out / "xvlog.log")
        el = ["xelab", f"work.{top}", "--timescale", "1ns/1ps", "--debug", "typical",
              "-s", f"{top}_snap"]
        if cov:
            el += ["-cc_type", "sbct", "-cc_dir", "codecov", "-cc_db", f"{top}_snap"]
        run(el, cwd=out, log=out / "xelab.log")
    else:
        sys.exit(f"unknown simulator {sim}")
    return out


def simulate(sim: str, out: pathlib.Path, top: str, plusargs: list[str], seed: int,
             log: pathlib.Path, cov_name: str | None = None) -> str:
    if sim == "verilator":
        args = [out / "obj/sim"] + [f"+{p}" for p in plusargs] + [f"+verilator+seed+{seed}"]
    elif sim == "icarus":
        args = ["vvp", "-n", out / "sim.vvp"] + [f"+{p}" for p in plusargs]
    else:
        args = ["xsim", f"{top}_snap", "-R", "-sv_seed", str(seed)]
        for p in plusargs:
            args += ["-testplusarg", p]
        if cov_name:
            args += ["-cov_db_dir", "funccov", "-cov_db_name", cov_name]
    r = run(args, cwd=out, log=log, check=False)
    return r.stdout


def verdict(text: str) -> tuple[bool, str]:
    ok = bool(re.search(r"^TEST PASSED", text, re.M)) and not re.search(
        r"^TEST FAILED|Fatal|Assertion .*failed|ASSERTION FAILED|Error:", text, re.M | re.I)
    m = re.search(r"(\d+) checks, (\d+) errors", text)
    return ok, (f"{m.group(1)} checks" if m else "")


# ---------------------------------------------------------------- commands
def cmd_fw(a) -> None:
    for prefix in ("riscv-none-elf-", "riscv64-unknown-elf-", "riscv32-unknown-elf-",
                   "riscv64-elf-"):
        if tool(prefix + "gcc"):
            break
    else:
        sys.exit("no RISC-V GCC on PATH (xPack riscv-none-elf-gcc on Windows)")
    fw = ROOT / "fw"
    bd = fw / "build"
    bd.mkdir(exist_ok=True)
    run([prefix + "gcc", "-march=rv32imc", "-mabi=ilp32", "-Os", "-ffreestanding",
         "-nostdlib", "-nostartfiles", "-fno-builtin", "-Wall", "-Wextra",
         "-T", fw / "link.ld", "-Wl,--gc-sections", "-o", bd / "firmware.elf",
         fw / "crt0.S", fw / "main.c"])
    run([prefix + "objcopy", "-O", "binary", bd / "firmware.elf", bd / "firmware.bin"])
    lst = run([prefix + "objdump", "-d", bd / "firmware.elf"], check=True)
    (bd / "firmware.lst").write_text(lst.stdout)
    run([sys.executable, ROOT / "scripts/gen_rom.py", bd / "firmware.bin",
         ROOT / "rtl/cmp/boot_rom.sv", "--hex", bd / "firmware.hex"])


def cmd_lint(a) -> None:
    srcs = [str(ROOT / f) for f in rtl_files()]
    bad = 0
    for n in (4, 8):
        r = run(["verilator", "--lint-only", "-Wall", "--top-module", "soc_top",
                 f"-GMAC_N={n}", ROOT / "scripts/verilator_waivers.vlt"] + srcs, check=False)
        msgs = [l for l in r.stdout.splitlines() if l.startswith("%")]
        print("\n".join(msgs) or f"verilator lint N={n}: clean")
        bad += len(msgs)
    if tool("verible-verilog-lint"):
        own = [s for s in srcs if "third_party" not in s and "boot_rom" not in s]
        r = run(["verible-verilog-lint", "--rules=-line-length,-explicit-parameter-storage-type"] + own,
                check=False)
        print(r.stdout or "verible lint: clean")
    if bad:
        sys.exit(f"lint: {bad} message(s)")


def cmd_crossings(a) -> None:
    r = run([sys.executable, ROOT / "scripts/check_crossings.py"], check=False)
    print(r.stdout)
    if r.returncode:
        sys.exit("crossing check failed")


UNIT_TESTS = {  # top : files
    "tb_wake_timer": ["rtl/common/sync_2ff.sv", "rtl/common/pulse_sync.sv",
                      "rtl/aon/wake_timer.sv", "tb/unit/tb_wake_timer.sv"],
}


def cmd_unit(a) -> None:
    sim = pick_sim(a.sim, need_classes=False, need_4state=True)
    if sim == "verilator":
        sim = "icarus" if tool("iverilog") else sim
    fails = 0
    for top, files in UNIT_TESTS.items():
        out = BUILD / f"unit_{sim}_{top}"
        out.mkdir(parents=True, exist_ok=True)
        srcs = [str(ROOT / f) for f in files]
        if sim == "icarus":
            run(["iverilog", "-g2012", "-s", top, "-o", out / "sim.vvp"] + srcs)
            text = run(["vvp", "-n", out / "sim.vvp"], cwd=out, check=False).stdout
        else:
            run(["xvlog", "--sv"] + srcs, cwd=out)
            run(["xelab", top, "-s", f"{top}_snap"], cwd=out)
            text = run(["xsim", f"{top}_snap", "-R"], cwd=out, check=False).stdout
        ok = f"TEST PASSED {top}" in text and "ERROR" not in text
        fails += not ok
        print(("PASS " if ok else "FAIL ") + top)
        if not ok:
            print(text[-2000:])
    sys.exit(1 if fails else 0)


def cmd_elab(a) -> None:
    r = run([sys.executable, ROOT / "scripts/slang_check.py"], check=False)
    print(r.stdout)
    sys.exit(r.returncode)


def cmd_sim(a) -> None:
    sim = pick_sim(a.sim, need_classes=True, need_4state=a.pwr)
    out = build(sim, "tb_soc", TB_CLASS, a.n, a.pwr, a.waves, [])
    iters = a.iters or TESTS.get(a.test, 10)
    text = simulate(sim, out, "tb_soc", [f"TEST={a.test}", f"ITERS={iters}"], a.seed,
                    out / f"{a.test}_s{a.seed}.log")
    print(text[-3000:])
    ok, _ = verdict(text)
    if a.waves:
        print(f"waves: {out / 'tb_soc.vcd'}  (open with Surfer / VaporView in VS Code)")
    sys.exit(0 if ok else 1)


def cmd_regress(a) -> None:
    sim = pick_sim(a.sim, need_classes=True, need_4state=False)
    seeds = list(range(1, a.seeds + 1))
    rows, fails = [], 0
    t0 = time.time()
    for n in a.n:
        cov = sim == "xsim"
        out = build(sim, "tb_soc", TB_CLASS, n, False, False, [], cov=cov)
        for test, it in TESTS.items():
            iters = QUICK_ITERS[test] if a.quick else it
            for s in seeds if test != "test_fw_e2e" else seeds[:1]:
                name = f"{test}_n{n}_s{s}"
                text = simulate(sim, out, "tb_soc", [f"TEST={test}", f"ITERS={iters}"], s,
                                out / f"{name}.log", cov_name=name if cov else None)
                ok, info = verdict(text)
                fails += not ok
                rows.append((test, n, s, "PASS" if ok else "FAIL", info))
                print(f"{'PASS' if ok else 'FAIL'} {name} {info}", flush=True)
        if cov:
            run(["xcrg", "-dir", out / "funccov", "-report_dir", BUILD / f"coverage_n{n}/functional",
                 "-report_format", "html"], cwd=out, check=False)
            run(["xcrg", "-cc_dir", out / "codecov", "-cc_db", "tb_soc_snap",
                 "-cc_report", BUILD / f"coverage_n{n}/code"], cwd=out, check=False)
    md = ["| Test | N | Seed | Result | Checks |", "| --- | --- | --- | --- | --- |"]
    md += [f"| {t} | {n} | {s} | {r} | {i} |" for t, n, s, r, i in rows]
    md.append(f"\n{len(rows) - fails}/{len(rows)} passed with {sim} in {time.time() - t0:.0f} s")
    BUILD.mkdir(exist_ok=True)
    (BUILD / "regress_summary.md").write_text("\n".join(md) + "\n")
    print("\n".join(md[-1:]))
    print(f"summary: {BUILD / 'regress_summary.md'}")
    sys.exit(1 if fails else 0)


def cmd_power(a) -> None:
    sim = pick_sim(a.sim, need_classes=False, need_4state=True)
    if sim == "verilator":
        print("note: Verilator is 2-state, so X checks are skipped; use xsim or icarus")
    extra = (["FAULT_NO_ISO"] if a.fault else []) + (["ACTIVITY"] if a.activity else [])
    # Activity for power analysis is dumped without X modelling.
    out = build(sim, "tb_power", TB_POWER, a.n, sim != "verilator" and not a.activity,
                a.waves, extra)
    text = simulate(sim, out, "tb_power", [], 1, out / "tb_power.log")
    print("\n".join(l for l in text.splitlines() if "ERROR" not in l)[-3000:])
    nerr = text.count("ERROR")
    ok, _ = verdict(text)
    if a.activity:
        print(f"activity: {out / 'activity.vcd'}  (ORFS: VCD_FILE=..., POWER_FILE_SCOPE=tb_power/dut)")
    if a.fault:
        # With isolation removed the test MUST fail, otherwise the checks are dead.
        print(f"fault injection: {nerr} errors detected" if not ok else "fault NOT detected")
        sys.exit(0 if not ok else 1)
    sys.exit(0 if ok else 1)


def cmd_formal(a) -> None:
    if tool("sby") and not a.no_sby:
        tasks = a.tasks or []
        r = run(["sby", "-f", "formal/pmu.sby"] + tasks, check=False)
        print("\n".join(l for l in r.stdout.splitlines() if "summary" in l.lower() or "DONE" in l))
        sys.exit(r.returncode)
    (BUILD / "formal").mkdir(parents=True, exist_ok=True)
    run(["yosys", "-q", "formal/pdr.ys"])
    r = run(["yosys-abc", "-c",
             "read_aiger -c build/formal/pmu.aig; fold; strash; pdr"], check=False)
    print(r.stdout.strip().splitlines()[-1] if r.stdout.strip() else r.stdout)
    sys.exit(0 if "Property proved" in r.stdout else 1)


def fetch_sky130_lib() -> pathlib.Path:
    lib = BUILD / "lib/sky130_fd_sc_hd__tt_025C_1v80.lib"
    if not lib.exists():
        lib.parent.mkdir(parents=True, exist_ok=True)
        print("downloading", SKY130_LIB_URL)
        urllib.request.urlretrieve(SKY130_LIB_URL, lib)
    return lib


def fetch_sky130_models() -> pathlib.Path:
    """Sparse, pinned clone of the SkyWater HD library: Verilog models only."""
    d = BUILD / "sky130_fd_sc_hd"
    if not (d / "models").is_dir():
        if d.exists():
            shutil.rmtree(d)
        run(["git", "clone", "--filter=blob:none", "--no-checkout", "--quiet", SKY130_MODELS_URL, d])
        run(["git", "-C", d, "sparse-checkout", "set", "--no-cone", "/models/", "/cells/*/*.v",
             "!/cells/*/*.tb.v", "!/cells/*/*symbol*.v", "!/cells/*/*blackbox*.v"])
        run(["git", "-C", d, "checkout", "--quiet", SKY130_MODELS_REV])
    return d


def cmd_gls(a) -> None:
    """Power-aware gate-level simulation of the Sky130 netlist (see tb/gls)."""
    tag = "gls_fault" if a.fault else "gls"
    out = BUILD / tag
    out.mkdir(parents=True, exist_ok=True)
    lib = (a.lib or fetch_sky130_lib()).resolve()
    models = fetch_sky130_models()
    p = lambda x: str(x).replace("\\", "/")
    srcs = " ".join(p(ROOT / f) for f in rtl_files())
    defs = "-DSKY130_CELLS -DSKY130_ISO -DSKY130_LS" + (" -DFAULT_NO_ISO" if a.fault else "")
    net = out / "soc_netlist.v"
    ys = [f"read_liberty -lib {p(lib)}",
          f"read_verilog -sv {defs} {srcs}",
          "hierarchy -check -top soc_top -chparam MAC_N 4",
          "proc",
          # one netlist module per power domain; everything below is flattened
          "setattr -mod -set keep_hierarchy 1 *cmp_top* *mem_top* *aon_top*",
          "synth -top soc_top -flatten",
          f"dfflibmap -liberty {p(lib)}",
          f"abc -liberty {p(lib)}",
          "opt_clean",
          "setundef -zero",
          "hilomap -hicell sky130_fd_sc_hd__conb_1 HI -locell sky130_fd_sc_hd__conb_1 LO",
          f"tee -o {p(out / 'stat.txt')} stat -liberty {p(lib)}",
          f"write_verilog -noattr -noexpr {p(net)}"]
    (out / "synth.ys").write_text("\n".join(ys) + "\n")
    run(["yosys", "-q", "-l", out / "yosys.log", out / "synth.ys"])
    run([sys.executable, ROOT / "scripts/gls_power_pins.py", net, out / "soc_netlist_pg.v"])

    cells = sorted(set(re.findall(r"\b(sky130_fd_sc_hd__\w+?_\d+)\s", net.read_text())))
    files = []
    for c in cells:
        base = c[len("sky130_fd_sc_hd__"):].rsplit("_", 1)[0]
        f = models / "cells" / base / f"{c}.v"
        if not f.exists():
            sys.exit(f"no model for {c}: {f}")
        files.append(p(f))
    files += [p(out / "soc_netlist_pg.v")] + [p(ROOT / f) for f in
              ("tb/models/regulator_model.sv", "tb/models/pwr_switch_model.sv", "tb/gls/tb_gls.sv")]
    (out / "files.f").write_text("\n".join(files) + "\n")
    print(f"netlist: {len(cells)} cell types; models from {models}")
    run(["iverilog", "-g2012", "-grelative-include", "-DUSE_POWER_PINS", "-DFUNCTIONAL",
         "-DUNIT_DELAY=#1", "-s", "tb_gls", "-o", out / "gls.vvp", "-c", out / "files.f"])
    text = run(["vvp", "-n", out / "gls.vvp"] + (["+vcd"] if a.waves else []),
               cwd=out, log=out / "sim.log", check=False).stdout
    print("\n".join(l for l in text.splitlines() if not l.startswith("VCD"))[-3000:])
    passed = "TEST PASSED tb_gls" in text
    if a.fault:
        print("fault detected: PASS" if not passed else "fault NOT detected: FAIL")
        sys.exit(0 if not passed else 1)
    sys.exit(0 if passed else 1)


def cmd_synth(a) -> None:
    out = BUILD / f"synth_{a.top}_n{a.n}"
    out.mkdir(parents=True, exist_ok=True)
    lib = a.lib
    if a.fetch_lib:
        lib = fetch_sky130_lib()
    srcs = " ".join(str(ROOT / f).replace("\\", "/") for f in rtl_files())
    param = "MAC_N" if a.top == "soc_top" else "N"
    defs = "-DSKY130_CELLS -DSKY130_ISO" if lib else ""
    if a.baseline:
        defs = ("-DSKY130_CELLS " if lib else "") + "-DNO_ISOLATION"
    lines = [f"read_verilog -sv {defs} {srcs}",
             f"hierarchy -check -top {a.top} -chparam {param} {a.n}"]
    if lib:
        libp = str(lib).replace("\\", "/")
        lines = [f"read_liberty -lib {libp}"] + lines + [
            f"synth -top {a.top}", f"dfflibmap -liberty {libp}", f"abc -liberty {libp}",
            "opt_clean", f"tee -o {(out / 'area.txt').as_posix()} stat -liberty {libp}"]
    else:
        lines += [f"synth -top {a.top}", f"tee -o {(out / 'area.txt').as_posix()} stat"]
    (out / "synth.ys").write_text("\n".join(lines) + "\n")
    run(["yosys", "-q", "-l", out / "yosys.log", out / "synth.ys"])
    txt = (out / "area.txt").read_text()
    for l in txt.splitlines():
        if "Chip area" in l or "Number of cells" in l:
            print(l.strip())
    print(f"report: {out / 'area.txt'}")


def cmd_all(a) -> None:
    steps = [["lint"], ["crossings"], ["unit"], ["formal"], ["regress", "--quick", "--seeds", "1"],
             ["power"], ["power", "--fault"]]
    if tool("yosys") and tool("iverilog") and not a.no_gls:
        steps += [["gls"], ["gls", "--fault"]]
    failed = []
    for s in steps:
        r = subprocess.run([sys.executable, __file__] + s, cwd=ROOT)
        if r.returncode:
            failed.append(" ".join(s))
    print("ALL PASSED" if not failed else "FAILED: " + ", ".join(failed))
    sys.exit(1 if failed else 0)


# ---------------------------------------------------------------- CLI
def main() -> None:
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = p.add_subparsers(dest="cmd", required=True)

    sub.add_parser("fw").set_defaults(func=cmd_fw)
    sub.add_parser("lint").set_defaults(func=cmd_lint)
    sub.add_parser("crossings").set_defaults(func=cmd_crossings)

    sub.add_parser("elab").set_defaults(func=cmd_elab)

    u = sub.add_parser("unit")
    u.add_argument("--sim", choices=["xsim", "icarus"])
    u.set_defaults(func=cmd_unit)

    s = sub.add_parser("sim")
    s.add_argument("--test", default="test_matmul_rand", choices=list(TESTS))
    s.add_argument("--sim", choices=["xsim", "verilator", "icarus"])
    s.add_argument("--seed", type=int, default=1)
    s.add_argument("--iters", type=int)
    s.add_argument("--n", type=int, default=4, choices=[2, 3, 4, 5, 6, 7, 8])
    s.add_argument("--pwr", action="store_true", help="power-aware X modelling (4-state sims)")
    s.add_argument("--waves", action="store_true", help="dump tb_soc.vcd")
    s.set_defaults(func=cmd_sim)

    r = sub.add_parser("regress")
    r.add_argument("--sim", choices=["xsim", "verilator"])
    r.add_argument("--seeds", type=int, default=3)
    r.add_argument("--n", type=int, nargs="+", default=[4, 8])
    r.add_argument("--quick", action="store_true", help="fewer iterations")
    r.set_defaults(func=cmd_regress)

    w = sub.add_parser("power")
    w.add_argument("--sim", choices=["xsim", "icarus", "verilator"])
    w.add_argument("--n", type=int, default=4)
    w.add_argument("--fault", action="store_true", help="remove isolation; test must fail")
    w.add_argument("--waves", action="store_true")
    w.add_argument("--activity", action="store_true",
                   help="dump activity.vcd of the DUT for power analysis")
    w.set_defaults(func=cmd_power)

    f = sub.add_parser("formal")
    f.add_argument("tasks", nargs="*", help="sby tasks: prove bmc cover")
    f.add_argument("--no-sby", action="store_true", help="use the Yosys+ABC flow")
    f.set_defaults(func=cmd_formal)

    y = sub.add_parser("synth")
    y.add_argument("--top", default="soc_top", choices=["soc_top", "mac_accel"])
    y.add_argument("--n", type=int, default=4)
    y.add_argument("--lib", type=pathlib.Path, help="Liberty file (e.g. Sky130 tt)")
    y.add_argument("--fetch-lib", action="store_true", help="download the Sky130 tt Liberty")
    y.add_argument("--baseline", action="store_true", help="no isolation logic")
    y.set_defaults(func=cmd_synth)

    g = sub.add_parser("gls")
    g.add_argument("--lib", type=pathlib.Path, help="Sky130 tt Liberty (default: download)")
    g.add_argument("--fault", action="store_true", help="netlist without isolation; test must fail")
    g.add_argument("--waves", action="store_true", help="dump tb_gls.vcd (top-level signals)")
    g.set_defaults(func=cmd_gls)

    al = sub.add_parser("all")
    al.add_argument("--no-gls", action="store_true", help="skip the gate-level steps")
    al.set_defaults(func=cmd_all)

    a = p.parse_args()
    a.func(a)


if __name__ == "__main__":
    main()
