#!/usr/bin/env python3
"""Sum per-instance power (OpenSTA `report_power -instances`) by power domain.

    python flow/scripts/summarize_power.py <power_instances.rpt> [--baseline <rpt>]

Domains are recognised from instance names: u_cmp... -> PD_CMP, u_mem... ->
PD_MEM. Cells the tools insert at the top level are assigned by the net they
were built for: clock-tree buffers of clk_cmp / mac_clk (named
clkbuf_..._clk_cmp_regs, ..._u_cmp/u_acc.mac_clk) -> PD_CMP, of clk_mem ->
PD_MEM; everything else (clk_sys / clk_in / clk_32k trees, CTS dummy loads,
I/O buffers, top-level isolation) -> PD_AON, which is the pessimistic choice
for SLEEP. Physical-only cells (tap, filler, decap, antenna diodes) are
counted separately and left out of the domain and state sums. OpenSTA does not know a domain is off, so state power is
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


PHYSICAL = re.compile(r"^(FILLER|TAP|PHY|ANTENNA|DECAP|decap|fill|tap)", re.I)


def domain(name: str) -> str:
    n = name.lstrip("\\").replace("\\", "")
    if PHYSICAL.match(n):
        return "physical"
    if n.startswith(("u_cmp.", "u_cmp/", "u_cmp_")) or n == "u_cmp":
        return "PD_CMP"
    if n.startswith(("u_mem.", "u_mem/", "u_mem_")) or n == "u_mem":
        return "PD_MEM"
    # top-level cells inserted by the tools, named after the net they serve
    if re.search(r"clk_cmp|u_cmp/|u_cmp\.", n):
        return "PD_CMP"
    if re.search(r"clk_mem|u_mem/|u_mem\.", n):
        return "PD_MEM"
    return "PD_AON"


def load(path: pathlib.Path) -> dict:
    sums = {d: [0.0, 0.0, 0.0, 0.0, 0] for d in ("PD_AON", "PD_CMP", "PD_MEM", "physical")}
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
    phys = sums.pop("physical")
    total = sum(v[4] for v in sums.values())
    if total == 0:
        sys.exit(f"no instance rows parsed from {path}")
    # Sanity check: PD_CMP (CPU + accelerator) must hold a large share of the
    # cells. If it does not, instance names lost their hierarchy prefix and
    # the split is meaningless.
    if sums["PD_CMP"][4] < 0.2 * total:
        sys.exit(f"{path}: only {sums['PD_CMP'][4]} of {total} cells look like PD_CMP - "
                 "instance names lost their u_cmp/u_mem prefix (check SYNTH_KEEP_MODULES)")
    sums["physical"] = phys
    return sums


def fmt(w: float) -> str:
    if w < 1e-9:
        return f"{w * 1e12:,.1f} pW"
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
        label = "physical-only (tap, filler, antenna; not summed)" if d == "physical" else d
        print(f"| {label} | {v[4]:,} | {fmt(v[0])} | {fmt(v[1])} | {fmt(v[2])} | {fmt(v[3])} |")

    aon, cmp_, mem = s["PD_AON"][2], s["PD_CMP"][2], s["PD_MEM"][2]
    active, idle, sleep = aon + cmp_ + mem, aon + mem, aon
    print("\n| State | Leakage | vs ACTIVE |")
    print("| --- | --- | --- |")
    for name, val in (("ACTIVE", active), ("IDLE", idle), ("SLEEP", sleep)):
        print(f"| {name} | {fmt(val)} | {100 * (1 - val / active):.1f} % lower |")

    if a.baseline:
        b = load(a.baseline)
        base = sum(v[2] for d, v in b.items() if d != "physical")
        print(f"\nBaseline (single domain, always on) leakage: {fmt(base)}")
        print(f"SLEEP vs baseline: {100 * (1 - sleep / base):.1f} % lower")
        print(f"IDLE  vs baseline: {100 * (1 - idle / base):.1f} % lower")


if __name__ == "__main__":
    main()
