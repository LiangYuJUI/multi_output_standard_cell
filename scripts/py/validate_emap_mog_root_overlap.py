#!/usr/bin/env python3
"""Validate that emap nf_y_multi MOG (FA/HA) root pairs do not overlap.

A multi-output cell claims two root literals. Distinct MOG bindings must form a
matching on AIG nodes: no shared node across different root pairs, e.g.

  [a, b] -> FA  and  [b, c] -> HA   # INVALID (node b claimed twice)

Same root pair with different BIND ids (pin permutations / configs) is OK.

Checks (per file, streaming — safe for multi-GB dumps):
  1) MOG tuple candidate BIND blocks
  2) selected multi-output BIND blocks
  3) MBIND warm-start lines vs selected BIND ids / roots

Exit 0 if all clean; 1 if any overlap or parse inconsistency.
"""

from __future__ import annotations

import argparse
import sys
from collections import defaultdict
from dataclasses import dataclass, field
from pathlib import Path
from typing import Dict, Iterable, List, Optional, Set, Tuple


def lit_to_node(lit: int) -> int:
    """ABC literal -> node id (strip phase bit)."""
    return lit >> 1


@dataclass
class BindRec:
    bind_id: int
    cell: str
    roots: Tuple[int, ...]  # literals
    section: str
    line_no: int

    @property
    def nodes(self) -> frozenset:
        return frozenset(lit_to_node(r) for r in self.roots)

    @property
    def pair_key(self) -> frozenset:
        return self.nodes


@dataclass
class FileResult:
    path: Path
    binds: List[BindRec] = field(default_factory=list)
    mbind_ids: List[Tuple[int, str, int]] = field(default_factory=list)  # id, cell, line
    errors: List[str] = field(default_factory=list)
    warnings: List[str] = field(default_factory=list)

    def binds_in(self, section_substr: str) -> List[BindRec]:
        return [b for b in self.binds if section_substr in b.section]


def parse_nf_y_multi(path: Path) -> FileResult:
    res = FileResult(path=path)
    section = ""
    pending: Optional[dict] = None

    with path.open("r", encoding="utf-8", errors="replace") as fh:
        for line_no, line in enumerate(fh, 1):
            if line.startswith("# ---"):
                section = line.strip()
                pending = None
                continue

            if line.startswith("BIND "):
                parts = line.split()
                if len(parts) < 3:
                    res.errors.append(f"L{line_no}: malformed BIND: {line.strip()}")
                    pending = None
                    continue
                try:
                    bind_id = int(parts[1])
                except ValueError:
                    res.errors.append(f"L{line_no}: bad BIND id: {line.strip()}")
                    pending = None
                    continue
                pending = {
                    "bind_id": bind_id,
                    "cell": parts[2],
                    "section": section,
                    "line_no": line_no,
                }
                continue

            if pending is not None and line.startswith("  ROOTS "):
                try:
                    roots = tuple(int(x) for x in line.split()[1:])
                except ValueError:
                    res.errors.append(f"L{line_no}: bad ROOTS: {line.strip()}")
                    pending = None
                    continue
                res.binds.append(
                    BindRec(
                        bind_id=pending["bind_id"],
                        cell=pending["cell"],
                        roots=roots,
                        section=pending["section"],
                        line_no=pending["line_no"],
                    )
                )
                pending = None
                continue

            if line.startswith("MBIND "):
                parts = line.split()
                if len(parts) < 3:
                    res.errors.append(f"L{line_no}: malformed MBIND: {line.strip()}")
                    continue
                try:
                    mid = int(parts[1])
                except ValueError:
                    res.errors.append(f"L{line_no}: bad MBIND id: {line.strip()}")
                    continue
                res.mbind_ids.append((mid, parts[2], line_no))

    return res


def check_section_matching(
    binds: List[BindRec],
    section_label: str,
    max_report: int,
) -> Tuple[List[str], dict]:
    """Return (errors, stats) for one BIND section."""
    errors: List[str] = []
    if not binds:
        return errors, {
            "section": section_label,
            "bind_entries": 0,
            "unique_pairs": 0,
            "conflict_nodes": 0,
        }

    # Structural checks per BIND
    for b in binds:
        if len(b.roots) != 2:
            errors.append(
                f"{section_label}: BIND {b.bind_id} @L{b.line_no} has "
                f"{len(b.roots)} roots {b.roots} (want 2)"
            )
        if len(b.nodes) != 2:
            errors.append(
                f"{section_label}: BIND {b.bind_id} @L{b.line_no} roots "
                f"{b.roots} map to same node(s) {sorted(b.nodes)}"
            )

    # Group alternatives that share the exact same root-node pair
    pair_to_binds: Dict[frozenset, List[BindRec]] = defaultdict(list)
    for b in binds:
        if len(b.nodes) == 2:
            pair_to_binds[b.pair_key].append(b)

    # Node -> set of distinct pairs that claim it
    node_to_pairs: Dict[int, Set[frozenset]] = defaultdict(set)
    for pair in pair_to_binds:
        for n in pair:
            node_to_pairs[n].add(pair)

    conflict_nodes = {n: ps for n, ps in node_to_pairs.items() if len(ps) > 1}
    for n, pairs in sorted(conflict_nodes.items()):
        pair_list = sorted(tuple(sorted(p)) for p in pairs)
        # representative cells / bind ids
        detail_parts = []
        for p in pair_list[: max_report + 1]:
            reps = pair_to_binds[frozenset(p)]
            cells = sorted({r.cell for r in reps})
            ids = sorted({r.bind_id for r in reps})[:6]
            detail_parts.append(
                f"pair={list(p)} cell={cells} bind_ids={ids}"
                + ("…" if len(reps) > 6 else "")
            )
        msg = (
            f"{section_label}: node {n} claimed by {len(pairs)} distinct MOG "
            f"root-pairs (overlap like [a,b]+[b,c]): "
            + "; ".join(detail_parts[:max_report])
        )
        if len(pair_list) > max_report:
            msg += f" … (+{len(pair_list) - max_report} more pairs)"
        errors.append(msg)
        if len(errors) >= max_report * 3:
            errors.append(
                f"{section_label}: … further overlap errors truncated "
                f"({len(conflict_nodes)} conflict nodes total)"
            )
            break

    stats = {
        "section": section_label,
        "bind_entries": len(binds),
        "unique_pairs": len(pair_to_binds),
        "conflict_nodes": len(conflict_nodes),
    }
    return errors, stats


def check_mbind_consistency(res: FileResult, max_report: int) -> List[str]:
    errors: List[str] = []
    selected = res.binds_in("multi-output bindings (selected)")
    by_id = {b.bind_id: b for b in selected}
    if not res.mbind_ids:
        return errors

    # MBIND should reference selected BIND ids; roots of those BINDs must match
    seen_nodes: Dict[int, int] = {}  # node -> bind_id
    for mid, cell, line_no in res.mbind_ids:
        if mid not in by_id:
            errors.append(
                f"MBIND {mid} @L{line_no} ({cell}): no matching selected BIND block"
            )
            if len(errors) >= max_report:
                break
            continue
        b = by_id[mid]
        if b.cell != cell:
            errors.append(
                f"MBIND {mid} @L{line_no}: cell {cell} != selected BIND cell {b.cell}"
            )
        for n in b.nodes:
            if n in seen_nodes and seen_nodes[n] != mid:
                errors.append(
                    f"MBIND overlap: node {n} in MBIND {seen_nodes[n]} and MBIND {mid} "
                    f"(roots {by_id[seen_nodes[n]].roots} vs {b.roots})"
                )
            else:
                seen_nodes[n] = mid
        if len(errors) >= max_report:
            errors.append("… further MBIND errors truncated")
            break
    return errors


def validate_file(path: Path, max_report: int) -> Tuple[bool, FileResult, List[dict]]:
    res = parse_nf_y_multi(path)
    stats_list: List[dict] = []

    sections = [
        ("MOG tuple candidates", "MOG tuple candidates"),
        ("multi-output bindings (selected)", "selected bindings"),
    ]
    for substr, label in sections:
        binds = res.binds_in(substr)
        errs, stats = check_section_matching(binds, label, max_report)
        res.errors.extend(errs)
        stats_list.append(stats)

    res.errors.extend(check_mbind_consistency(res, max_report))

    # If file has no MOG at all, that is OK (pass with empty stats)
    ok = len(res.errors) == 0
    return ok, res, stats_list


def discover_match_files(root: Path) -> List[Path]:
    if root.is_file():
        return [root]
    files = sorted(root.rglob("matches.nf_y_multi.txt"))
    # Prefer top-level emap/ over emap_l1/ when both exist under same parent layout
    return files


def main(argv: Optional[Iterable[str]] = None) -> int:
    ap = argparse.ArgumentParser(
        description=(
            "Validate emap nf_y_multi MOG candidates/bindings have no overlapping "
            "root nodes across distinct FA/HA pairs."
        )
    )
    ap.add_argument(
        "paths",
        nargs="+",
        type=Path,
        help="matches.nf_y_multi.txt file(s) or directories to search recursively",
    )
    ap.add_argument(
        "--max-report",
        type=int,
        default=20,
        help="max overlap details to print per section [20]",
    )
    ap.add_argument(
        "--include-l1",
        action="store_true",
        help="also check paths under emap_l1/ (default: skip *emap_l1*)",
    )
    args = ap.parse_args(list(argv) if argv is not None else None)

    files: List[Path] = []
    for p in args.paths:
        files.extend(discover_match_files(p))
    if not args.include_l1:
        files = [f for f in files if "emap_l1" not in f.parts]
    # de-dup preserve order
    seen: Set[Path] = set()
    uniq: List[Path] = []
    for f in files:
        rp = f.resolve()
        if rp not in seen:
            seen.add(rp)
            uniq.append(f)
    files = uniq

    if not files:
        print("no matches.nf_y_multi.txt found", file=sys.stderr)
        return 1

    n_fail = 0
    n_ok = 0
    for path in files:
        ok, res, stats_list = validate_file(path, args.max_report)
        case = path.parent.name
        if ok:
            n_ok += 1
            bits = []
            for st in stats_list:
                if st["bind_entries"]:
                    bits.append(
                        f"{st['section']}: entries={st['bind_entries']} "
                        f"pairs={st['unique_pairs']} conflicts=0"
                    )
            detail = "; ".join(bits) if bits else "no MOG bindings"
            print(f"OK  {case:12s}  {detail}")
        else:
            n_fail += 1
            print(f"FAIL {case:12s}  {path}")
            for e in res.errors[: args.max_report]:
                print(f"  - {e}")
            if len(res.errors) > args.max_report:
                print(f"  - … +{len(res.errors) - args.max_report} more")

    print()
    print(f"summary: {n_ok} ok, {n_fail} fail, {len(files)} files")
    return 1 if n_fail else 0


if __name__ == "__main__":
    sys.exit(main())
