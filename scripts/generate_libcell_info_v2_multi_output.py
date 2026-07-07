#!/usr/bin/env python3
"""Generate libcell_info_v2_multi_output from Liberty.

Extends GRADUATE's ``generate_libcell_info_v2.py`` to keep cells with multiple
logic output pins (for example ASAP7 ``FAx1`` / ``HAxp5``).  Each output pin
stores its own Boolean function; timing arcs remain one record per Liberty
``timing()`` group with an explicit ``output_pin``.
"""

from __future__ import annotations

import argparse
import dataclasses
import math
import re
import sys
from pathlib import Path
from typing import Iterable

FORMAT_NAME = "libcell_info_v2_multi_output"
TIMING_TYPES = ("cell_rise", "cell_fall", "rise_transition", "fall_transition")
VALID_SENSES = {"positive_unate", "negative_unate", "non_unate"}
POWER_GROUND_FUNCTION = "(!VDD) + (VSS)"


@dataclasses.dataclass
class Attr:
    name: str
    values: list[str]


@dataclasses.dataclass
class Group:
    name: str
    args: list[str]
    attrs: list[Attr] = dataclasses.field(default_factory=list)
    groups: list["Group"] = dataclasses.field(default_factory=list)

    def attr(self, name: str) -> str | None:
        for attr in reversed(self.attrs):
            if attr.name == name:
                return " ".join(attr.values).strip()
        return None

    def child_groups(self, name: str) -> list["Group"]:
        return [group for group in self.groups if group.name == name]

    def child_group(self, name: str) -> "Group | None":
        for group in self.groups:
            if group.name == name:
                return group
        return None


@dataclasses.dataclass
class Lut:
    timing_type: str
    index1: list[float]
    index2: list[float]
    values: list[list[float]]


@dataclasses.dataclass
class TimingArc:
    input_pin: str
    output_pin: str
    timing_sense: str
    luts: dict[str, Lut]


@dataclasses.dataclass
class InputPin:
    name: str
    rise_cap: float
    fall_cap: float

    @property
    def cap(self) -> float:
        return max(self.rise_cap, self.fall_cap)


@dataclasses.dataclass
class OutputPin:
    name: str
    function: str


@dataclasses.dataclass
class LibCell:
    name: str
    area: float
    leakage: float
    input_pins: list[InputPin]
    output_pins: list[OutputPin]
    timing_arcs: list[TimingArc]

    @property
    def is_multi_output(self) -> bool:
        return len(self.output_pins) > 1


class LibertyParseError(RuntimeError):
    pass


class TokenStream:
    def __init__(self, text: str) -> None:
        self.tokens = self._tokenize(text)
        self.index = 0

    @staticmethod
    def _tokenize(text: str) -> list[str]:
        tokens: list[str] = []
        i = 0
        while i < len(text):
            ch = text[i]
            if ch.isspace():
                i += 1
                continue
            if text.startswith("/*", i):
                end = text.find("*/", i + 2)
                if end < 0:
                    raise LibertyParseError("unterminated /* */ comment")
                i = end + 2
                continue
            if text.startswith("//", i):
                end = text.find("\n", i + 2)
                i = len(text) if end < 0 else end + 1
                continue
            if ch in "{}():;,":
                tokens.append(ch)
                i += 1
                continue
            if ch == '"':
                i += 1
                out: list[str] = []
                while i < len(text):
                    ch = text[i]
                    if ch == '"':
                        i += 1
                        break
                    if ch == "\\" and i + 1 < len(text):
                        nxt = text[i + 1]
                        if nxt == "\n":
                            i += 2
                            continue
                        out.append(nxt)
                        i += 2
                        continue
                    out.append(ch)
                    i += 1
                else:
                    raise LibertyParseError("unterminated string")
                tokens.append("".join(out))
                continue
            start = i
            while i < len(text) and not text[i].isspace() and text[i] not in "{}():;,":
                if text.startswith("/*", i) or text.startswith("//", i):
                    break
                i += 1
            tokens.append(text[start:i])
        return tokens

    def peek(self) -> str | None:
        return None if self.index >= len(self.tokens) else self.tokens[self.index]

    def peek_offset(self, offset: int) -> str | None:
        index = self.index + offset
        return None if index >= len(self.tokens) else self.tokens[index]

    def pop(self) -> str:
        token = self.peek()
        if token is None:
            raise LibertyParseError("unexpected end of file")
        self.index += 1
        return token

    def expect(self, expected: str) -> None:
        actual = self.pop()
        if actual != expected:
            raise LibertyParseError(f"expected {expected!r}, got {actual!r}")


def parse_arg_list(stream: TokenStream) -> list[str]:
    stream.expect("(")
    args: list[str] = []
    current: list[str] = []
    depth = 1
    while depth > 0:
        token = stream.pop()
        if token == "(":
            depth += 1
            current.append(token)
        elif token == ")":
            depth -= 1
            if depth == 0:
                if current:
                    args.append(" ".join(current).strip())
                break
            current.append(token)
        elif token == "," and depth == 1:
            args.append(" ".join(current).strip())
            current = []
        else:
            current.append(token)
    return [arg for arg in args if arg != ""]


def parse_items(stream: TokenStream, stop_at_rbrace: bool = False) -> tuple[list[Attr], list[Group]]:
    attrs: list[Attr] = []
    groups: list[Group] = []
    while stream.peek() is not None:
        if stream.peek() == "}":
            if not stop_at_rbrace:
                raise LibertyParseError("unexpected }")
            stream.pop()
            break

        name = stream.pop()
        if stream.peek() == ":":
            stream.pop()
            values: list[str] = []
            while True:
                token = stream.peek()
                if token is None:
                    raise LibertyParseError(f"unterminated attribute {name!r}")
                if token == ";":
                    stream.pop()
                    break
                if token == "}" and values:
                    break
                if values and stream.peek_offset(1) in {":", "("}:
                    break
                values.append(stream.pop())
            attrs.append(Attr(name, values))
            continue

        if stream.peek() == "(":
            args = parse_arg_list(stream)
            if stream.peek() == "{":
                stream.pop()
                child_attrs, child_groups = parse_items(stream, stop_at_rbrace=True)
                groups.append(Group(name, args, child_attrs, child_groups))
            elif stream.peek() == ";":
                stream.pop()
                attrs.append(Attr(name, args))
            else:
                raise LibertyParseError(f"unexpected token after {name}(...): {stream.peek()!r}")
            continue

        raise LibertyParseError(f"unexpected token after {name!r}: {stream.peek()!r}")
    return attrs, groups


def parse_liberty_file(path: Path) -> list[Group]:
    stream = TokenStream(path.read_text())
    _, groups = parse_items(stream)
    return groups


def first_float(text: str | None, default: float | None = None) -> float:
    if text is None:
        if default is None:
            raise ValueError("missing numeric attribute")
        return default
    try:
        value = float(text)
    except ValueError as exc:
        raise ValueError(f"invalid numeric attribute: {text}") from exc
    if not math.isfinite(value):
        raise ValueError(f"non-finite numeric attribute: {text}")
    return value


def numbers_from_text(text: str | None) -> list[float]:
    if text is None:
        return []
    values = [
        float(match)
        for match in re.findall(
            r"[-+]?(?:\d+\.\d*|\.\d+|\d+)(?:[eE][-+]?\d+)?",
            text,
        )
    ]
    if not all(math.isfinite(value) for value in values):
        return []
    return values


def parse_lut(group: Group, timing_type: str) -> Lut | None:
    index1 = numbers_from_text(group.attr("index_1"))
    index2 = numbers_from_text(group.attr("index_2"))
    flat_values = numbers_from_text(group.attr("values"))
    if not index1 or not index2 or not flat_values:
        return None
    expected = len(index1) * len(index2)
    if len(flat_values) != expected:
        raise ValueError(
            f"{timing_type} has {len(flat_values)} values, expected {expected}"
        )
    values = [
        flat_values[row * len(index2):(row + 1) * len(index2)]
        for row in range(len(index1))
    ]
    return Lut(timing_type, index1, index2, values)


def attr_is_direction(pin: Group, direction: str) -> bool:
    value = pin.attr("direction")
    return value is not None and value.lower() == direction


def is_logic_function(function: str | None) -> bool:
    if function is None:
        return False
    function = function.strip()
    if not function:
        return False
    return function != POWER_GROUND_FUNCTION


def parse_timing_arcs(
    output_pin: Group,
    output_name: str,
    input_names: set[str],
) -> list[TimingArc]:
    arcs: list[TimingArc] = []
    for timing in output_pin.child_groups("timing"):
        related = timing.attr("related_pin")
        if related is None:
            continue
        related = related.strip('"')
        if related not in input_names:
            continue
        sense = timing.attr("timing_sense") or "non_unate"
        if sense not in VALID_SENSES:
            sense = "non_unate"
        luts: dict[str, Lut] = {}
        for timing_type in TIMING_TYPES:
            lut_group = timing.child_group(timing_type)
            if lut_group is None:
                continue
            lut = parse_lut(lut_group, timing_type)
            if lut is not None:
                luts[timing_type] = lut
        if all(timing_type in luts for timing_type in TIMING_TYPES):
            arcs.append(TimingArc(related, output_name, sense, luts))
    return arcs


def parse_cell(cell_group: Group, *, include_tie_cells: bool) -> LibCell | None:
    if not cell_group.args:
        return None
    name = cell_group.args[0]
    area = first_float(cell_group.attr("area"))
    leakage = first_float(cell_group.attr("cell_leakage_power"), 0.0)

    input_pins: list[InputPin] = []
    output_pin_groups: list[Group] = []
    for pin in cell_group.child_groups("pin"):
        if not pin.args:
            continue
        if attr_is_direction(pin, "input"):
            rise = pin.attr("rise_capacitance")
            fall = pin.attr("fall_capacitance")
            cap = pin.attr("capacitance")
            if rise is None and cap is not None:
                rise = cap
            if fall is None and cap is not None:
                fall = cap
            if rise is None or fall is None:
                raise ValueError(f"missing rise/fall capacitance for input pin {pin.args[0]}")
            input_pins.append(InputPin(pin.args[0], first_float(rise), first_float(fall)))
        elif attr_is_direction(pin, "output"):
            output_pin_groups.append(pin)

    logic_outputs: list[OutputPin] = []
    for pin in output_pin_groups:
        function = pin.attr("function")
        if is_logic_function(function):
            logic_outputs.append(OutputPin(pin.args[0], function.strip()))

    if not logic_outputs:
        return None

    is_tie_cell = not input_pins and len(logic_outputs) == 1
    if is_tie_cell and not include_tie_cells:
        return None
    if not input_pins and not is_tie_cell:
        return None

    input_names = {pin.name for pin in input_pins}
    timing_arcs: list[TimingArc] = []
    for output_group in output_pin_groups:
        if not output_group.args:
            continue
        output_name = output_group.args[0]
        if not any(out.name == output_name for out in logic_outputs):
            continue
        timing_arcs.extend(parse_timing_arcs(output_group, output_name, input_names))

    if not timing_arcs and not is_tie_cell:
        return None

    return LibCell(name, area, leakage, input_pins, logic_outputs, timing_arcs)


def parse_lib_files(
    paths: Iterable[Path],
    *,
    include_tie_cells: bool,
) -> tuple[dict[str, LibCell], dict[str, int]]:
    cells: dict[str, LibCell] = {}
    stats = {
        "libraries": 0,
        "raw_cells": 0,
        "kept_cells": 0,
        "single_output_cells": 0,
        "multi_output_cells": 0,
        "tie_cells": 0,
        "skipped_cells": 0,
        "timing_arcs": 0,
    }
    for path in paths:
        groups = parse_liberty_file(path)
        stats["libraries"] += 1
        for lib in groups:
            for cell_group in lib.child_groups("cell"):
                stats["raw_cells"] += 1
                try:
                    cell = parse_cell(cell_group, include_tie_cells=include_tie_cells)
                except Exception as exc:
                    cell_name = cell_group.args[0] if cell_group.args else "?"
                    print(f"warning: skipping cell {cell_name}: {exc}", file=sys.stderr)
                    cell = None
                if cell is None:
                    stats["skipped_cells"] += 1
                    continue
                cells[cell.name] = cell
                if not cell.input_pins and len(cell.output_pins) == 1:
                    stats["tie_cells"] += 1
                elif cell.is_multi_output:
                    stats["multi_output_cells"] += 1
                else:
                    stats["single_output_cells"] += 1
        stats["kept_cells"] = len(cells)
        stats["timing_arcs"] = sum(len(cell.timing_arcs) for cell in cells.values())
    return cells, stats


def fmt(value: float) -> str:
    return f"{value:.12g}"


def write_lut(out, arc: TimingArc, lut: Lut) -> None:
    out.write("lut:\n")
    out.write(f"input_pin: {arc.input_pin}\n")
    out.write(f"output_pin: {arc.output_pin}\n")
    out.write(f"timing_type: {lut.timing_type}\n")
    out.write(f"index1_size: {len(lut.index1)}\n")
    out.write(" ".join(fmt(value) for value in lut.index1) + "\n")
    out.write(f"index2_size: {len(lut.index2)}\n")
    out.write(" ".join(fmt(value) for value in lut.index2) + "\n")
    rows = len(lut.values)
    cols = len(lut.values[0]) if rows else 0
    out.write(f"values_size: {rows} {cols}\n")
    for row in lut.values:
        out.write(" ".join(fmt(value) for value in row) + "\n")
    out.write("\n")


def write_multi_output_v2(path: Path, cells: dict[str, LibCell]) -> None:
    with path.open("w") as out:
        out.write(f"format: {FORMAT_NAME}\n\n")
        for name in sorted(cells):
            cell = cells[name]
            out.write(f"libcell: {cell.name}\n")
            out.write(f"area: {fmt(cell.area)}\n")
            out.write(f"max_leakage: {fmt(cell.leakage)}\n")
            out.write(f"input_pins_num: {len(cell.input_pins)}\n")
            for pin in cell.input_pins:
                out.write(
                    f"pin: {pin.name} rise_cap {fmt(pin.rise_cap)} "
                    f"fall_cap {fmt(pin.fall_cap)} cap {fmt(pin.cap)}\n"
                )
            out.write(f"outputs_num: {len(cell.output_pins)}\n")
            for output in cell.output_pins:
                out.write("output:\n")
                out.write(f"pin: {output.name}\n")
                out.write(f"function: {output.function}\n")
            out.write(f"timing_arcs_num: {len(cell.timing_arcs)}\n\n")
            for arc in cell.timing_arcs:
                out.write("arc:\n")
                out.write(f"input_pin: {arc.input_pin}\n")
                out.write(f"output_pin: {arc.output_pin}\n")
                out.write(f"timing_sense: {arc.timing_sense}\n")
                out.write(f"luts_num: {len(arc.luts)}\n")
                for timing_type in TIMING_TYPES:
                    write_lut(out, arc, arc.luts[timing_type])
            out.write("\n")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("libs", nargs="+", type=Path, help="Input Liberty file(s)")
    parser.add_argument(
        "-o",
        "--output",
        type=Path,
        required=True,
        help="Output libcell_info_v2_multi_output path",
    )
    parser.add_argument(
        "--include-tie-cells",
        action="store_true",
        help="Keep constant tie-high / tie-low cells with no timing arcs",
    )
    args = parser.parse_args()

    cells, stats = parse_lib_files(args.libs, include_tie_cells=args.include_tie_cells)
    if not cells:
        print("error: no usable cells parsed", file=sys.stderr)
        return 1

    args.output.parent.mkdir(parents=True, exist_ok=True)
    write_multi_output_v2(args.output, cells)
    print(
        f"generated {FORMAT_NAME}: "
        f"cells={len(cells)} "
        f"single_output={stats['single_output_cells']} "
        f"multi_output={stats['multi_output_cells']} "
        f"tie_cells={stats['tie_cells']} "
        f"arcs={stats['timing_arcs']} "
        f"raw_cells={stats['raw_cells']} "
        f"skipped={stats['skipped_cells']} "
        f"output={args.output}"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
