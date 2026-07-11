#!/usr/bin/env python3
"""Validate emap nf_y_multi SO candidate dedup (exact and/or nf-like).

Exact key (Phase 1):
  (root_lit, cell_name, ordered fanin_lits..., cover)

Nf-like key (Phase 2):
  (root_lit, cell_name, sorted fanin_lits..., cover)

Also checks that each selected SO ``M`` row (non-MBIND) has an exact
matching SO candidate when dump_level 3 SO section is present.

Streaming — safe for multi-GB dumps.
Exit 0 if clean; 1 otherwise.
"""

from __future__ import annotations

import argparse
import sys
from pathlib import Path
from typing import Dict, Iterable, List, Optional, Set, Tuple


ExactKey = Tuple[int, str, Tuple[int, ...], int]
NfLikeKey = Tuple[int, str, Tuple[int, ...], int]


def parse_so_line(line: str) -> Optional[Tuple[ExactKey, NfLikeKey, List[int]]]:
    parts = line.split()
    if len(parts) < 5:
        return None
    try:
        root = int(parts[0])
        cell = parts[1]
        n_pins = int(parts[3])
    except ValueError:
        return None
    need = 4 + n_pins + 1
    if len(parts) < need:
        return None
    try:
        fanins = [int(parts[4 + i]) for i in range(n_pins)]
        cover = int(parts[4 + n_pins])
    except ValueError:
        return None
    exact: ExactKey = (root, cell, tuple(fanins), cover)
    nflike: NfLikeKey = (root, cell, tuple(sorted(fanins)), cover)
    return exact, nflike, fanins


def parse_m_line(line: str) -> Optional[Tuple[int, str, Tuple[int, ...]]]:
    if not line.startswith("M") or line.startswith("MBIND"):
        return None
    parts = line.split()
    if len(parts) < 3:
        return None
    try:
        root = int(parts[0][1:])
    except ValueError:
        return None
    cell = parts[1]
    # Mroot cell area fanins...   (may include n_pins or not for INV)
    # emap SO dump uses: Mlit cell area nPins fanins... OR Mlit cell area fanin (INV)
    rest = parts[3:]
    fanins: List[int] = []
    if not rest:
        return root, cell, tuple()
    # If first token equals len(rest)-1, treat as n_pins count (emap DumpMatchBody with count)
    try:
        maybe_n = int(rest[0])
        if maybe_n == len(rest) - 1 and maybe_n >= 0:
            fanins = [int(x) for x in rest[1:]]
        else:
            fanins = [int(x) for x in rest]
    except ValueError:
        return None
    return root, cell, tuple(fanins)


def check_file(
    path: Path, *, check_exact: bool, check_nflike: bool, check_selected: bool
) -> Tuple[int, int, int, List[str]]:
    errors: List[str] = []
    seen_exact: Set[ExactKey] = set()
    seen_nf: Set[NfLikeKey] = set()
    so_by_exact: Dict[ExactKey, int] = {}
    so_rows = 0
    exact_dups = 0
    nf_dups = 0
    in_so = False
    in_warm = False
    m_checked = 0
    m_miss = 0

    with path.open("r", encoding="utf-8", errors="replace") as f:
        for line_no, line in enumerate(f, 1):
            s = line.strip()
            if s.startswith("# ---"):
                if "SO candidates" in s:
                    in_so = True
                    in_warm = False
                    seen_exact.clear()
                    seen_nf.clear()
                    continue
                if "selected mapping" in s or "warm start" in s:
                    in_so = False
                    in_warm = True
                    continue
                if in_so:
                    in_so = False
                continue

            if in_so and s and not s.startswith("#"):
                parsed = parse_so_line(s)
                if parsed is None:
                    errors.append(f"{path}:{line_no}: unparseable SO: {s[:120]}")
                    continue
                exact, nflike, _ = parsed
                so_rows += 1
                so_by_exact[exact] = line_no
                if check_exact:
                    if exact in seen_exact:
                        exact_dups += 1
                        if exact_dups <= 20:
                            errors.append(
                                f"{path}:{line_no}: exact duplicate SO {exact}"
                            )
                    else:
                        seen_exact.add(exact)
                if check_nflike:
                    if nflike in seen_nf:
                        nf_dups += 1
                        if nf_dups <= 20:
                            errors.append(
                                f"{path}:{line_no}: nf-like duplicate SO "
                                f"root={nflike[0]} cell={nflike[1]} "
                                f"sorted_fanins={list(nflike[2])}"
                            )
                    else:
                        seen_nf.add(nflike)
                continue

            if check_selected and in_warm and s.startswith("M") and not s.startswith("MBIND"):
                m = parse_m_line(s)
                if m is None:
                    continue
                root, cell, fanins = m
                # INV / 1-pin matches are not emitted in SO cut×cell section
                if len(fanins) < 2 or "INV" in cell.upper():
                    continue
                key: ExactKey = (root, cell, fanins, 0)
                m_checked += 1
                if key not in so_by_exact:
                    m_miss += 1
                    if m_miss <= 20:
                        errors.append(
                            f"{path}:{line_no}: selected M missing exact SO "
                            f"candidate root={root} cell={cell} fanins={list(fanins)}"
                        )

    if check_selected and so_rows == 0 and m_checked:
        errors.append(f"{path}: --check-selected but no SO rows")
    return so_rows, exact_dups, nf_dups, errors


def iter_match_files(root: Path) -> Iterable[Path]:
    if root.is_file():
        yield root
        return
    yield from sorted(root.rglob("matches.nf_y_multi.txt"))


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("paths", nargs="+", type=Path)
    ap.add_argument("--exact", action="store_true", help="forbid exact duplicate SO rows")
    ap.add_argument(
        "--nf-like",
        action="store_true",
        help="forbid nf-like duplicate SO rows (sorted fanins)",
    )
    ap.add_argument(
        "--check-selected",
        action="store_true",
        help="require each SO M line to have exact SO candidate",
    )
    ap.add_argument("--require-so", action="store_true")
    args = ap.parse_args()
    if not args.exact and not args.nf_like and not args.check_selected:
        args.exact = True

    bad = 0
    total_rows = 0
    for path in args.paths:
        for mf in iter_match_files(path):
            rows, ed, nd, errors = check_file(
                mf,
                check_exact=args.exact,
                check_nflike=args.nf_like,
                check_selected=args.check_selected,
            )
            total_rows += rows
            status = "OK"
            if args.require_so and rows == 0:
                status = "FAIL"
                errors.append(f"{mf}: no SO rows")
            if ed or nd or (errors and status == "OK" and (args.exact or args.nf_like or args.check_selected)):
                if ed or nd or any("missing exact SO" in e or "duplicate" in e or "unparseable" in e or "no SO" in e for e in errors):
                    status = "FAIL"
            if errors and status == "OK" and args.check_selected and any("missing" in e for e in errors):
                status = "FAIL"
            if status != "OK" or errors:
                # re-evaluate
                fail = bool(ed or nd) or (args.require_so and rows == 0)
                fail = fail or any(
                    x in e
                    for e in errors
                    for x in ("duplicate", "unparseable", "missing exact SO", "no SO")
                )
                status = "FAIL" if fail else "OK"
            print(
                f"[{status}] {mf}  so_rows={rows} exact_dups={ed} nf_like_dups={nd}"
            )
            for e in errors:
                print(f"  {e}")
            if status != "OK":
                bad += 1
    print(f"summary: so_rows={total_rows} fail={bad}")
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
