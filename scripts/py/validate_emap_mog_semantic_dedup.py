#!/usr/bin/env python3
"""Validate MO BIND semantic endpoint-order exact dedup in emap nf_y_multi.

Export policy (graduate-abc ``emap -Y``, dump_level >= 2):

  MO semantic exact dedup (NOT nf-like):
    key = (cell, ordered_fanins, frozenset/sorted (role, root_lit), cover)
  - FANINS order is part of the key (Liberty pin mapping) — never sorted.
  - Full ABC literals keep phase (174 != 175).
  - ROOTS/ROLES list order is canonicalized by sorting endpoints on role name
    (then root_lit). Swapped listing of the same role→root map must not appear
    twice in the same section.
  - True CON↔SN assignment swap remains two candidates.
  - Different cells remain distinct.

Checks (streaming — safe for multi-GB dumps):
  1) Within each BIND section, semantic keys are unique.
  2) BIND ids unique within a section.
  3) BIND:<id> endpoint rows resolve to a BIND block in that file.
  4) MBIND ids exist among selected BIND blocks; cell matches.
  5) Ordered fanins / phase / cell differences are NOT flagged as duplicates.
  6) Optional: ``# mo_dedup_stats`` unique == BIND count in MOG tuple section.

Does NOT replace ``validate_emap_mog_root_overlap.py`` (pair overlap vs
semantic duplicate are different invariants).

Exit 0 if clean; 1 otherwise.
"""

from __future__ import annotations

import argparse
import re
import sys
from collections import defaultdict
from dataclasses import dataclass, field
from pathlib import Path
from typing import Dict, Iterable, List, Optional, Sequence, Set, Tuple

BIND_REF_RE = re.compile(r"\bBIND:(\d+)\b")
MO_STATS_RE = re.compile(
    r"# mo_dedup_stats:\s*"
    r"visited=(?P<visited>\d+)\s+"
    r"unique=(?P<unique>\d+)\s+"
    r"removed=(?P<removed>\d+)\s+"
    r"selected_aliases=(?P<selected_aliases>\d+)"
)


def mo_semantic_key(
    cell: str,
    fanins: Sequence[int],
    roles: Sequence[str],
    roots: Sequence[int],
    cover: int = 0,
) -> Tuple:
    """Canonical semantic key matching ``Emap_DumpMoSemanticKey`` in emapCore.c.

    Endpoints sorted by (role_name, root_lit). Fanins keep dump order.
    """
    if len(roles) != len(roots):
        raise ValueError(f"roles/roots length mismatch: {roles!r} vs {roots!r}")
    endpoints = sorted(zip(roles, roots), key=lambda er: (er[0], er[1]))
    return (cell, tuple(fanins), tuple(endpoints), int(cover))


@dataclass
class MoBindRec:
    bind_id: int
    cell: str
    roots: Tuple[int, ...]
    roles: Tuple[str, ...]
    fanins: Tuple[int, ...]
    cover: int
    section: str
    line_no: int

    @property
    def semantic_key(self) -> Tuple:
        return mo_semantic_key(self.cell, self.fanins, self.roles, self.roots, self.cover)


@dataclass
class FileResult:
    path: Path
    binds: List[MoBindRec] = field(default_factory=list)
    bind_refs: List[Tuple[int, int, str]] = field(default_factory=list)  # id, line, section
    mbinds: List[Tuple[int, str, int]] = field(default_factory=list)
    mo_stats: Optional[dict] = None
    errors: List[str] = field(default_factory=list)
    warnings: List[str] = field(default_factory=list)


def parse_nf_y_multi(path: Path) -> FileResult:
    res = FileResult(path=path)
    section = ""
    pending: Optional[dict] = None

    def flush_pending() -> None:
        nonlocal pending
        if pending is None:
            return
        if "roots" not in pending or "roles" not in pending or "fanins" not in pending:
            res.errors.append(
                f"L{pending['line_no']}: BIND {pending['bind_id']} incomplete "
                f"(need ROOTS/ROLES/FANINS) in {pending['section'][:60]}"
            )
            pending = None
            return
        res.binds.append(
            MoBindRec(
                bind_id=pending["bind_id"],
                cell=pending["cell"],
                roots=pending["roots"],
                roles=pending["roles"],
                fanins=pending["fanins"],
                cover=pending.get("cover", 0),
                section=pending["section"],
                line_no=pending["line_no"],
            )
        )
        pending = None

    with path.open("r", encoding="utf-8", errors="replace") as fh:
        for line_no, line in enumerate(fh, 1):
            raw = line.rstrip("\n")
            s = raw.strip()

            if s.startswith("# mo_dedup_stats:"):
                m = MO_STATS_RE.match(s)
                if not m:
                    res.errors.append(f"L{line_no}: malformed mo_dedup_stats")
                else:
                    res.mo_stats = {k: int(v) for k, v in m.groupdict().items()}
                continue

            if s.startswith("# ---"):
                flush_pending()
                section = s
                continue

            mref = BIND_REF_RE.search(s)
            if mref and not s.startswith("BIND ") and not s.startswith("MBIND "):
                res.bind_refs.append((int(mref.group(1)), line_no, section))

            if s.startswith("BIND "):
                flush_pending()
                parts = s.split()
                if len(parts) < 5:
                    res.errors.append(f"L{line_no}: malformed BIND: {s[:120]}")
                    continue
                try:
                    bind_id = int(parts[1])
                    n_pins = int(parts[4])
                except ValueError:
                    res.errors.append(f"L{line_no}: bad BIND header: {s[:120]}")
                    continue
                # BIND id cell area nPins fanins[nPins] roots...
                fanins_from_hdr: Optional[Tuple[int, ...]] = None
                if len(parts) >= 5 + n_pins:
                    try:
                        fanins_from_hdr = tuple(int(x) for x in parts[5 : 5 + n_pins])
                    except ValueError:
                        fanins_from_hdr = None
                pending = {
                    "bind_id": bind_id,
                    "cell": parts[2],
                    "n_pins": n_pins,
                    "fanins_hdr": fanins_from_hdr,
                    "section": section,
                    "line_no": line_no,
                }
                continue

            if pending is not None and raw.startswith("  ROOTS "):
                try:
                    pending["roots"] = tuple(int(x) for x in raw.split()[1:])
                except ValueError:
                    res.errors.append(f"L{line_no}: bad ROOTS: {s[:120]}")
                    pending = None
                continue

            if pending is not None and raw.startswith("  ROLES "):
                pending["roles"] = tuple(raw.split()[1:])
                continue

            if pending is not None and raw.startswith("  FANINS"):
                try:
                    fanins = tuple(int(x) for x in raw.split()[1:])
                except ValueError:
                    res.errors.append(f"L{line_no}: bad FANINS: {s[:120]}")
                    pending = None
                    continue
                pending["fanins"] = fanins
                if pending.get("fanins_hdr") is not None and pending["fanins_hdr"] != fanins:
                    res.errors.append(
                        f"L{line_no}: FANINS {list(fanins)} != BIND header "
                        f"fanins {list(pending['fanins_hdr'])}"
                    )
                continue

            if pending is not None and raw.startswith("  COVER "):
                try:
                    pending["cover"] = int(raw.split()[1])
                except (ValueError, IndexError):
                    res.errors.append(f"L{line_no}: bad COVER: {s[:120]}")
                    pending = None
                    continue
                flush_pending()
                continue

            if s.startswith("MBIND "):
                parts = s.split()
                if len(parts) < 3:
                    res.errors.append(f"L{line_no}: malformed MBIND: {s[:120]}")
                    continue
                try:
                    mid = int(parts[1])
                except ValueError:
                    res.errors.append(f"L{line_no}: bad MBIND id: {s[:120]}")
                    continue
                res.mbinds.append((mid, parts[2], line_no))

        flush_pending()

    return res


def check_semantic_uniqueness(
    binds: List[MoBindRec],
    section_label: str,
    max_report: int,
) -> List[str]:
    errors: List[str] = []
    by_key: Dict[Tuple, List[MoBindRec]] = defaultdict(list)
    by_id: Dict[int, List[MoBindRec]] = defaultdict(list)
    for b in binds:
        by_key[b.semantic_key].append(b)
        by_id[b.bind_id].append(b)

    for bid, group in sorted(by_id.items()):
        if len(group) > 1:
            lines = [g.line_no for g in group]
            errors.append(
                f"{section_label}: BIND id {bid} appears {len(group)} times "
                f"(lines {lines[:max_report]})"
            )

    for key, group in by_key.items():
        if len(group) > 1:
            ids = [g.bind_id for g in group]
            lines = [g.line_no for g in group]
            errors.append(
                f"{section_label}: semantic duplicate key (endpoint-order) "
                f"bind_ids={ids} lines={lines[:max_report]} key={key!r}"
            )
            if len(errors) >= max_report:
                errors.append(f"{section_label}: … further semantic dups truncated")
                break
    return errors


def check_refs_and_mbind(res: FileResult, max_report: int) -> List[str]:
    errors: List[str] = []
    all_ids = {b.bind_id for b in res.binds}
    selected = [b for b in res.binds if "multi-output bindings" in b.section]
    selected_by_id = {b.bind_id: b for b in selected}

    for bid, line_no, section in res.bind_refs:
        if bid not in all_ids:
            errors.append(
                f"L{line_no}: dangling BIND:{bid} in {section[:50]} "
                f"(no BIND block)"
            )
            if len(errors) >= max_report:
                break

    for mid, cell, line_no in res.mbinds:
        b = selected_by_id.get(mid)
        if b is None:
            # Fall back: any BIND with that id (trial ids should not be in MBIND)
            any_b = next((x for x in res.binds if x.bind_id == mid), None)
            if any_b is None:
                errors.append(f"L{line_no}: MBIND {mid} has no BIND block")
            else:
                errors.append(
                    f"L{line_no}: MBIND {mid} not in selected bindings "
                    f"(found in {any_b.section[:40]})"
                )
            continue
        if b.cell != cell and not (cell in b.cell or b.cell in cell):
            # Twin gates may use either endpoint cell name; require prefix match soft
            if cell.split("_")[0] != b.cell.split("_")[0]:
                errors.append(
                    f"L{line_no}: MBIND cell {cell} != selected BIND {mid} cell {b.cell}"
                )
    return errors


def validate_file(path: Path, *, max_report: int = 20) -> FileResult:
    res = parse_nf_y_multi(path)
    for substr, label in (
        ("MOG tuple candidates", "MOG tuple candidates"),
        ("multi-output bindings", "selected bindings"),
    ):
        binds = [b for b in res.binds if substr in b.section]
        res.errors.extend(check_semantic_uniqueness(binds, label, max_report))
    res.errors.extend(check_refs_and_mbind(res, max_report))

    if res.mo_stats is not None:
        mog = [b for b in res.binds if "MOG tuple candidates" in b.section]
        if res.mo_stats["unique"] != len(mog):
            res.errors.append(
                f"mo_dedup_stats unique={res.mo_stats['unique']} != "
                f"MOG BIND count {len(mog)}"
            )
        if res.mo_stats["visited"] < res.mo_stats["unique"]:
            res.errors.append(
                f"mo_dedup_stats visited={res.mo_stats['visited']} < "
                f"unique={res.mo_stats['unique']}"
            )
        if (
            res.mo_stats["visited"]
            != res.mo_stats["unique"] + res.mo_stats["removed"]
        ):
            res.warnings.append(
                f"mo_dedup_stats visited != unique+removed "
                f"({res.mo_stats['visited']} != "
                f"{res.mo_stats['unique']}+{res.mo_stats['removed']})"
            )
    return res


def iter_match_files(root: Path) -> Iterable[Path]:
    if root.is_file():
        yield root
        return
    yield from sorted(root.rglob("matches.nf_y_multi.txt"))


def _self_test() -> int:
    """Fixture checks for acceptance cases B–F (no file I/O)."""
    fails = 0

    def expect(name: str, cond: bool) -> None:
        nonlocal fails
        if not cond:
            print(f"FAIL self-test: {name}")
            fails += 1
        else:
            print(f"OK   self-test: {name}")

    # B: endpoint-order duplicate → same key
    k1 = mo_semantic_key("HA", [2, 5], ["CON", "SN"], [193, 174], 0)
    k2 = mo_semantic_key("HA", [2, 5], ["SN", "CON"], [174, 193], 0)
    expect("B endpoint-order same key", k1 == k2)

    # C: input permutation → different keys
    k3 = mo_semantic_key("HA", [5, 2], ["CON", "SN"], [193, 174], 0)
    expect("C fanins order distinct", k1 != k3)

    # D: true output-role swap
    k4 = mo_semantic_key("HA", [2, 5], ["CON", "SN"], [174, 193], 0)
    expect("D role assignment swap distinct", k1 != k4)

    # E: literal phase
    k5 = mo_semantic_key("HA", [2, 5], ["CON", "SN"], [193, 175], 0)
    expect("E phase distinct", k1 != k5)

    # F: cell difference
    k6 = mo_semantic_key("FA", [2, 5], ["CON", "SN"], [193, 174], 0)
    expect("F cell distinct", k1 != k6)

    return 1 if fails else 0


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("paths", nargs="*", type=Path)
    ap.add_argument("--self-test", action="store_true", help="run fixture key tests")
    ap.add_argument("--max-report", type=int, default=20)
    args = ap.parse_args()

    rc = 0
    if args.self_test:
        rc = _self_test()

    if not args.paths:
        if args.self_test:
            return rc
        ap.error("paths required unless --self-test")

    bad = 0
    for path in args.paths:
        for mf in iter_match_files(path):
            res = validate_file(mf, max_report=args.max_report)
            fail = bool(res.errors)
            status = "FAIL" if fail else "OK"
            mog_n = sum(1 for b in res.binds if "MOG tuple" in b.section)
            sel_n = sum(1 for b in res.binds if "multi-output bindings" in b.section)
            stats = ""
            if res.mo_stats:
                s = res.mo_stats
                stats = (
                    f" visited={s['visited']} unique={s['unique']} "
                    f"removed={s['removed']}"
                )
            print(
                f"[{status}] {mf}  mog_bind={mog_n} selected_bind={sel_n} "
                f"mbind={len(res.mbinds)}{stats}"
            )
            for e in res.errors[: args.max_report]:
                print(f"  ERROR: {e}")
            for w in res.warnings[:5]:
                print(f"  WARN: {w}")
            if fail:
                bad += 1
    return 1 if (bad or rc) else 0


if __name__ == "__main__":
    sys.exit(main())
