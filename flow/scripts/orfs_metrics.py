#!/usr/bin/env python3
"""Summarise an ORFS run as a Markdown table (for the GitHub job summary).

    orfs_metrics.py --title soc_lp \
        --logs build/orfs/logs/sky130hd/soc_lp/base \
        --results build/orfs/results/sky130hd/soc_lp/base

Reads the metrics ORFS writes per stage (`<logs>/*.json`, the final ones in
6_report.json) and, if present, counts threshold-voltage flavours in the
final netlist (ASAP7 cell names end in _R / _L / _SL). Key names have
changed between OpenROAD versions, so metrics are found by pattern; anything
not found prints as "n/a" rather than failing the job.
"""
import argparse
import json
import pathlib
import re
import sys

ROWS = [  # (label, regex on the metric key, scale, unit)
    ("Setup worst slack", r"^finish__timing__setup__ws$", 1, "ns"),
    ("Setup TNS", r"^finish__timing__setup__tns$", 1, "ns"),
    ("Hold worst slack", r"^finish__timing__hold__ws$", 1, "ns"),
    ("Clock skew (setup)", r"^finish__clock__skew__setup$", 1, "ns"),
    ("Design (std-cell) area", r"^finish__design__instance__area(__stdcell)?$", 1, "um^2"),
    ("Utilisation", r"^finish__design__instance__utilization(__stdcell)?$", 100, "%"),
    ("Instances", r"^finish__design__instance__count(__stdcell)?$", 1, ""),
    ("Total power", r"^finish__power__total$", 1e3, "mW"),
    ("Internal power", r"^finish__power__internal__total$", 1e3, "mW"),
    ("Switching power", r"^finish__power__switching__total$", 1e3, "mW"),
    ("Leakage power", r"^finish__power__leakage__total$", 1e6, "uW"),
    ("Route DRC errors", r"^(detailedroute__route__drc_errors|finish__route__drc_errors)$", 1, ""),
]


def load_metrics(logs: pathlib.Path) -> dict:
    m = {}
    for f in sorted(logs.glob("*.json")):
        try:
            data = json.loads(f.read_text())
        except (ValueError, OSError):
            continue
        if isinstance(data, dict):
            m.update(data)
    return m


def pick(m: dict, pattern: str):
    rx = re.compile(pattern)
    for k, v in m.items():
        if rx.search(k) and isinstance(v, (int, float)):
            return v
    return None


def vt_mix(results: pathlib.Path) -> str | None:
    net = results / "6_final.v"
    if not net.exists():
        return None
    cells = re.findall(r"^\s*(\w+_ASAP7_\w+?_(R|L|SL))\s", net.read_text(), re.M)
    if not cells:
        return None
    n = {"R": 0, "L": 0, "SL": 0}
    for _, vt in cells:
        n[vt] += 1
    tot = sum(n.values())
    return ", ".join(f"{k}VT {v} ({100 * v / tot:.1f} %)" for k, v in n.items() if v)


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--title", required=True)
    ap.add_argument("--logs", type=pathlib.Path, required=True)
    ap.add_argument("--results", type=pathlib.Path)
    ap.add_argument("--time-unit", default="ns", help="library time unit (ASAP7: ps)")
    a = ap.parse_args()
    m = load_metrics(a.logs)
    print(f"## {a.title}\n")
    if not m:
        print(f"no ORFS metrics found in `{a.logs}` (the flow stopped early: see the job log)")
        return 0
    print("| Metric | Value |\n| --- | --- |")
    for label, rx, scale, unit in ROWS:
        v = pick(m, rx)
        unit = a.time_unit if unit == "ns" else unit
        if v is None:
            txt = "n/a"
        elif unit == "" and float(v).is_integer():
            txt = f"{int(v):,}"
        else:
            txt = f"{v * scale:,.4g} {unit}".strip()
        print(f"| {label} | {txt} |")
    if a.results:
        mix = vt_mix(a.results)
        if mix:
            print(f"| Cells by Vt | {mix} |")
    fin = sorted(k for k in m if k.startswith("finish__"))
    if fin:
        print(f"\n<details><summary>all {len(fin)} finish metrics</summary>\n")
        print("\n".join(f"- `{k}`: {m[k]}" for k in fin))
        print("\n</details>")
    return 0


if __name__ == "__main__":
    sys.exit(main())
