#!/usr/bin/env python3
"""Sum per-instance power (OpenSTA `report_power -instances`) by power domain.

    python flow/scripts/summarize_power.py <power_instances.rpt> [--baseline <rpt>]

Domains are recognised from instance names: u_cmp... -> PD_CMP, u_mem... ->
PD_MEM, everything else -> PD_AON (top-level glue, clock tree, buffers the
tools inserted). OpenSTA does not know a domain is off, so state power is
computed from the parts that stay powered:

    ACTIVE leakage = AON + CMP + MEM
    IDLE   leakage = AON + MEM            (PD_CMP switched off)
    SLEEP  leakage = AON                  (PD_CMP and PD_MEM switched off)

Switch off-state leakage is not included (Sky130 HD has no switch cell; the
switches are ideal) - state that next to any number you quote.
"""
import argparse
import pathlib
import re
import sys

NUM = r"([-+]?[0-9.]+(?:[eE][-+]?[0-9]+)?)"
# OpenSTA prints four numbers and the instance name; accept either order.
ROW_NAME_LAST = re.compile(rf"^\s*{NUM}\s+{NUM}\s+{NUM}\s+{NUM}\s+(\S+)\s*$")
ROW_NAME_FIRST = re.compile(rf"^\s*(\S+)\s+{NUM}\s+{NUM}\s+{NUM}\s+{NUM}\s*$")


def domain(name: str) -> str:
    n = name.lstrip("\\")
    if n.startswith(("u_cmp.", "u_cmp/", "u_cmp_")) or n == "u_cmp":
        return "PD_CMP"
    if n.startswith(("u_mem.", "u_mem/", "u_mem_")) or n == "u_mem":
        return "PD_MEM"
    return "PD_AON"


def load(path: pathlib.Path) -> dict:
    sums = {d: [0.0, 0.0, 0.0, 0.0, 0] for d in ("PD_AON", "PD_CMP", "PD_MEM")}
    for line in path.read_text().splitlines():
        m = ROW_NAME_LAST.match(line)
        if m:
            vals, name = [float(m.group(i)) for i in range(1, 5)], m.group(5)
        else:
            m = ROW_NAME_FIRST.match(line)
            if not m:
                continue
            vals, name = [float(m.group(i)) for i in range(2, 6)], m.group(1)
        s = sums[domain(name)]
        for i in range(4):
            s[i] += vals[i]
        s[4] += 1
    total = sum(v[4] for v in sums.values())
    if total == 0:
        sys.exit(f"no instance rows parsed from {path}")
    # Sanity check: PD_CMP (CPU + accelerator) must hold a large share of the
    # cells. If it does not, instance names lost their hierarchy prefix and
    # the split is meaningless.
    if sums["PD_CMP"][4] < 0.2 * total:
        sys.exit(f"{path}: only {sums['PD_CMP'][4]} of {total} cells look like PD_CMP - "
                 "instance names lost their u_cmp/u_mem prefix (check SYNTH_KEEP_MODULES)")
    return sums


def fmt(w: float) -> str:
    if w < 1e-6:
        return f"{w * 1e9:,.2f} nW"
    return f"{w * 1e6:,.2f} uW" if w < 1e-3 else f"{w * 1e3:,.3f} mW"


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("report", type=pathlib.Path)
    ap.add_argument("--baseline", type=pathlib.Path, help="single-domain run for comparison")
    a = ap.parse_args()
    s = load(a.report)

    print("| Domain | Cells | Internal | Switching | Leakage | Total |")
    print("| --- | --- | --- | --- | --- | --- |")
    for d, v in s.items():
        print(f"| {d} | {v[4]} | {fmt(v[0])} | {fmt(v[1])} | {fmt(v[2])} | {fmt(v[3])} |")

    aon, cmp_, mem = s["PD_AON"][2], s["PD_CMP"][2], s["PD_MEM"][2]
    active, idle, sleep = aon + cmp_ + mem, aon + mem, aon
    print("\n| State | Leakage | vs ACTIVE |")
    print("| --- | --- | --- |")
    for name, val in (("ACTIVE", active), ("IDLE", idle), ("SLEEP", sleep)):
        print(f"| {name} | {fmt(val)} | {100 * (1 - val / active):.1f} % lower |")

    if a.baseline:
        b = load(a.baseline)
        base = sum(v[2] for v in b.values())
        print(f"\nBaseline (single domain, always on) leakage: {fmt(base)}")
        print(f"SLEEP vs baseline: {100 * (1 - sleep / base):.1f} % lower")
        print(f"IDLE  vs baseline: {100 * (1 - idle / base):.1f} % lower")


if __name__ == "__main__":
    main()
