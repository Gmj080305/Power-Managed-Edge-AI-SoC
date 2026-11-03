#!/usr/bin/env python3
"""Structural check of the power-domain crossings.

Elaborates the RTL with Yosys (hierarchy kept), then checks that every bit
of every input port listed in CROSSINGS reaches nothing except the `d` input
of the expected protection cell (level shifter and/or isolation). A new
signal added to a domain boundary without isolation fails this check.

    python scripts/check_crossings.py            (needs yosys on PATH)
"""
import json
import pathlib
import subprocess
import sys
import tempfile

ROOT = pathlib.Path(__file__).resolve().parents[1]

# module : { input port : allowed first-stage cell type }
# (Isolation goes in the RECEIVING domain; signals that may arrive from the
# low-voltage PD_CMP go through ls_lh first, then iso_clamp*.)
CROSSINGS = {
    "mem_top": {  # from PD_CMP
        "valid": "ls_lh", "addr": "ls_lh", "wdata": "ls_lh", "wstrb": "ls_lh",
    },
    "aon_top": {  # from PD_CMP
        "cmp_valid": "ls_lh", "cmp_addr": "ls_lh", "cmp_wdata": "ls_lh",
        "cmp_wstrb": "ls_lh", "cmp_pwr_ack_raw": "ls_lh", "ret_cfg_raw": "ls_lh",
        "cmp_trap_raw": "ls_lh",
    },
    "cmp_top": {  # from PD_MEM (fixed 1.80 V: isolation only)
        "mem_rdata": "iso_clamp0", "mem_ready": "iso_clamp0",
    },
}
# soc_top nets driven by a switchable domain that leave the chip
TOP_NETS = {
    "mem_uart_tx": "iso_clamp1",
    "host_rdata_raw": "ls_lh",
    "host_ready_raw": "ls_lh",
}
# A level shifter must feed an isolation cell
LS_TO_ISO = True


def base_type(t: str) -> str:
    """'$paramod\\iso_clamp0\\W=...' -> 'iso_clamp0'"""
    if t.startswith("$paramod"):
        t = t.split("\\")[1]
    return t.lstrip("\\")


def sinks(module: dict, bits: list) -> set:
    """(cell type, port) pairs that read any of the given net bits."""
    want = set(b for b in bits if isinstance(b, int))
    out = set()
    for cell in module["cells"].values():
        dirs = cell.get("port_directions", {})
        for port, conn in cell["connections"].items():
            if dirs.get(port, "input") != "output" and want & set(conn):
                out.add((base_type(cell["type"]), port))
    for name, port in module["ports"].items():
        if port["direction"] == "output" and want & set(port["bits"]):
            out.add(("<output port>", name))
    return out


def main() -> int:
    files = [l.strip() for l in (ROOT / "rtl/files.f").read_text().splitlines()
             if l.strip() and not l.strip().startswith("//")]
    with tempfile.TemporaryDirectory() as td:
        js = pathlib.Path(td) / "d.json"
        script = (f"read_verilog -sv {' '.join(str(ROOT / f) for f in files)}; "
                  "hierarchy -check -top soc_top; proc; opt_clean; "
                  f"write_json {js.as_posix()}")
        r = subprocess.run(["yosys", "-q", "-p", script], capture_output=True, text=True)
        if r.returncode:
            print(r.stdout, r.stderr)
            return 2
        design = json.loads(js.read_text())["modules"]

    def mod(name):
        for k, v in design.items():
            if base_type(k) == name:
                return v
        raise KeyError(name)

    errors = 0
    checked = 0
    for mname, ports in CROSSINGS.items():
        m = mod(mname)
        for pname, cell in ports.items():
            got = sinks(m, m["ports"][pname]["bits"])
            checked += len(m["ports"][pname]["bits"])
            if got != {(cell, "d")}:
                errors += 1
                print(f"FAIL {mname}.{pname}: drives {sorted(got)}, expected only {cell}.d")
    top = mod("soc_top")
    for net, cell in TOP_NETS.items():
        got = sinks(top, top["netnames"][net]["bits"])
        got = {g for g in got if g[0] not in ("cmp_top", "mem_top", "aon_top")}
        checked += len(top["netnames"][net]["bits"])
        if got != {(cell, "d")}:
            errors += 1
            print(f"FAIL soc_top.{net}: drives {sorted(got)}, expected only {cell}.d")
    if LS_TO_ISO:
        for mname in list(CROSSINGS) + ["soc_top"]:
            m = mod(mname)
            for cname, c in m["cells"].items():
                if base_type(c["type"]) == "ls_lh":
                    got = sinks(m, c["connections"]["q"])
                    if not got or any(t not in ("iso_clamp0", "iso_clamp1") for t, _ in got):
                        errors += 1
                        print(f"FAIL {mname}.{cname}: level shifter output drives {sorted(got)}")
    print(f"check_crossings: {checked} crossing bits checked, {errors} problem(s)")
    return 1 if errors else 0


if __name__ == "__main__":
    sys.exit(main())
