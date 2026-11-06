#!/usr/bin/env python3
"""Add supply pins to a Yosys Sky130 netlist for power-aware gate-level sim.

The netlist must keep cmp_top, mem_top and aon_top as hierarchy (see
`run.py gls`). Every standard cell gets .VPWR/.VPB tied to the supply of the
module it sits in, and .VGND/.VNB to VSS:

    cmp_top            -> VDD_CMP
    mem_top            -> VDD_MEM
    aon_top, soc_top   -> VDD_AON

Level shifters (lpflow_lsbuf_lh_*) also get .LOWLVPWR(VDD_CMP): their input
side is the low-voltage compute domain. Each module gains input ports
VDD_AON, VDD_CMP, VDD_MEM and VSS, and each instance of a kept module passes
them down, so the test bench drives the three rails on soc_top.

With the Sky130 functional power models (USE_POWER_PINS + FUNCTIONAL) a cell
whose VPWR is 0 drives X, so an unpowered domain behaves like silicon would.

usage: gls_power_pins.py <in.v> <out.v>
"""
import re
import sys

SUPPLIES = ("VDD_AON", "VDD_CMP", "VDD_MEM", "VSS")


def domain_supply(module: str) -> str:
    if "cmp_top" in module:
        return "VDD_CMP"
    if "mem_top" in module:
        return "VDD_MEM"
    return "VDD_AON"


MOD_RE = re.compile(r"^module\s+(\S+?)\s*\(")
CELL_RE = re.compile(r"^(\s+)(sky130_fd_sc_hd__\w+)\s+(.+?)\s*\($")
SUB_RE = re.compile(r"^(\s+)(\S*(?:cmp_top|mem_top|aon_top)\S*)\s+(\S+)\s*\($")


def main() -> int:
    src, dst = sys.argv[1], sys.argv[2]
    out = []
    module = None
    in_header = False
    stats = {}
    with open(src) as f:
        lines = f.read().splitlines()
    for line in lines:
        m = MOD_RE.match(line)
        if m:
            module = m.group(1)
            line = line.replace("(", "(" + ", ".join(SUPPLIES) + ", ", 1)
            in_header = True
        if in_header:
            out.append(line)
            if line.rstrip().endswith(");"):
                in_header = False
                out.extend(f"  input {s};" for s in SUPPLIES)
            continue
        c = CELL_RE.match(line)
        if c and module is not None:
            ind, cell = c.group(1), c.group(2)
            vdd = domain_supply(module)
            pins = f".VPWR({vdd}), .VGND(VSS), .VPB({vdd}), .VNB(VSS), "
            if "lpflow_lsbuf_lh" in cell:
                pins += ".LOWLVPWR(VDD_CMP), "
            out.append(line)
            out.append(ind + "  " + pins)
            stats[vdd] = stats.get(vdd, 0) + 1
            continue
        s = SUB_RE.match(line)
        if s and module is not None:
            out.append(line)
            out.append(s.group(1) + "  " + "".join(f".{p}({p}), " for p in SUPPLIES))
            continue
        out.append(line)
    with open(dst, "w") as f:
        f.write("\n".join(out) + "\n")
    total = sum(stats.values())
    if total == 0:
        print("gls_power_pins: no Sky130 cells found", file=sys.stderr)
        return 1
    print("gls_power_pins: " + ", ".join(f"{k} {v} cells" for k, v in sorted(stats.items())))
    return 0


if __name__ == "__main__":
    sys.exit(main())
