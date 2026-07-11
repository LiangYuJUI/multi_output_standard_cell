#!/usr/bin/env python3
"""Merge twin FA/HA Verilog instances for ABC read -m / stime / cec.

emap often emits separate CON-only and SN-only instances of the same FA/HA.
ABC multi-output parse expects one instance with both outputs. Also rewrites
genlib-only cells used by emap dumps to Liberty-friendly aliases when needed.
"""

from __future__ import annotations

import argparse
import re
import sys
from collections import defaultdict
from pathlib import Path


INST_RE = re.compile(r"^(\s*)([A-Za-z0-9_]+)\s+(\w+)\(([^;]*)\);\s*$")
MOG_CELLS = {"FAx1_ASAP7_75t_R", "HAxp5_ASAP7_75t_R"}


def parse_pins(s: str) -> dict:
    return {a: b for a, b in re.findall(r"\.(\w+)\(([^)]*)\)", s)}


def fmt_inst(indent: str, cell: str, name: str, pins: dict, order: list) -> str:
    order = [k for k in order if k in pins]
    for k in sorted(pins):
        if k not in order:
            order.append(k)
    body = ", ".join(f".{k}({pins[k]})" for k in order)
    return f"{indent}{cell}     {name}({body});\n"


def merge_emap_twins(src: Path, dst: Path) -> int:
    text = src.read_text(encoding="utf-8", errors="replace")
    lines = text.splitlines(True)

    entries = []
    for i, line in enumerate(lines):
        m = INST_RE.match(line)
        if not m:
            continue
        cell = m.group(2)
        if cell not in MOG_CELLS:
            continue
        pins = parse_pins(m.group(4))
        entries.append((i, m.group(1), cell, m.group(3), pins))

    groups = defaultdict(list)
    for e in entries:
        i, indent, cell, name, pins = e
        inputs = tuple(sorted((k, v) for k, v in pins.items() if k not in ("CON", "SN")))
        groups[(cell, inputs)].append(e)

    replace = {}
    dummy_wires = []
    n_merged = 0
    for (cell, inputs), members in groups.items():
        outs = {}
        keep = members[0]
        for i, indent, c, name, pins in members:
            for o in ("CON", "SN"):
                if o in pins:
                    outs[o] = pins[o]
            replace[i] = None
        indent, name = keep[1], keep[3]
        pins = dict(inputs)
        pins.update(outs)
        for o in ("CON", "SN"):
            if o not in pins:
                w = f"_emap_sta_unused_{name}_{o}"
                pins[o] = w
                dummy_wires.append(w)
        order = ["A", "B", "CI", "CON", "SN"]
        replace[keep[0]] = [fmt_inst(indent, cell, name, pins, order)]
        if len(members) > 1 or len(outs) < 2:
            n_merged += 1

    out_lines = []
    inserted_wires = False
    wire_decl = ""
    if dummy_wires:
        uniq = sorted(set(dummy_wires))
        parts = []
        cur = "  wire "
        for w in uniq:
            item = w + ","
            if len(cur) + len(item) > 100:
                parts.append(cur.rstrip(",") + ";\n")
                cur = "  wire " + item
            else:
                cur += item + " "
        parts.append(cur.rstrip(", ") + ";\n")
        wire_decl = "".join(parts)

    for i, line in enumerate(lines):
        if i in replace:
            rep = replace[i]
            if rep is None:
                continue
            if not inserted_wires and wire_decl:
                out_lines.append(wire_decl)
                inserted_wires = True
            out_lines.extend(rep)
            continue
        m = INST_RE.match(line)
        if m:
            indent, cell, name, pinstr = m.group(1), m.group(2), m.group(3), m.group(4)
            pins = parse_pins(pinstr)
            if cell == "MAJIx2_ASAP7_75t_R":
                if not inserted_wires and wire_decl:
                    out_lines.append(wire_decl)
                    inserted_wires = True
                out_lines.append(
                    fmt_inst(indent, "MAJIxp5_ASAP7_75t_R", name, pins, ["A", "B", "C", "Y"])
                )
                continue
            if cell == "XNOR3x1_ASAP7_75t_R":
                mid = f"_emap_sta_xnor3_{name}"
                out_lines.append(f"{indent}wire {mid};\n")
                out_lines.append(
                    fmt_inst(
                        indent,
                        "XNOR2x1_ASAP7_75t_R",
                        name + "_0",
                        {"A": pins["A"], "B": pins["B"], "Y": mid},
                        ["A", "B", "Y"],
                    )
                )
                out_lines.append(
                    fmt_inst(
                        indent,
                        "XNOR2x1_ASAP7_75t_R",
                        name + "_1",
                        {"A": mid, "B": pins["C"], "Y": pins["Y"]},
                        ["A", "B", "Y"],
                    )
                )
                continue
        if not inserted_wires and wire_decl and re.match(r"^\s*[A-Za-z0-9_]+\s+\w+\(", line):
            out_lines.append(wire_decl)
            inserted_wires = True
        out_lines.append(line)

    dst.parent.mkdir(parents=True, exist_ok=True)
    dst.write_text("".join(out_lines), encoding="utf-8")
    return n_merged


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("src", type=Path)
    ap.add_argument("dst", type=Path)
    args = ap.parse_args()
    n = merge_emap_twins(args.src, args.dst)
    print(n)
    return 0


if __name__ == "__main__":
    sys.exit(main())
