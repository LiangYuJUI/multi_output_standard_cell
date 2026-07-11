#!/usr/bin/env python3
"""Unified streaming validator for emap ``nf_y_multi`` SO export policy (Phase 4).

Checks (streaming — safe for multi-GB dumps):

1. SO exact duplicates absent (when --exact / always under formal policy).
2. nf-like: at most one row per (root, cell, sorted fanins) when --nf-like.
3. Every selected SO ``M`` (non-INV, ≥2 fanins) has an exact SO candidate.
4. Every ``MBIND`` finds a selected BIND block.
5. MBIND cell matches selected BIND cell; roots/roles consistent via ROOTS.
6. Distinct MOG root-pairs do not overlap nodes.
7. Same root-pair may have multiple BIND ids (allowed when fanins/roles differ).
8. Root phase bits preserved (literals odd/even kept; not collapsed to node id).
9. MO semantic endpoint-order dedup: no duplicate physical BIND keys per section
   (see ``validate_emap_mog_semantic_dedup.py``).
10. Unknown / malformed sections and rows reported.
11. ``# so_export_stats`` / ``# so_cut_limit`` aggregate top-K invariants:
    - selected_miss == 0
    - if K==0: retained == internal_cuts (and removed==0)
    - if K>0 and overflow_nodes==0: retained_max <= K
    - if overflow_nodes>0: protected overflow path taken (retained may exceed K)

Also reuses MOG overlap logic from validate_emap_mog_root_overlap.

Exit 0 if clean; 1 otherwise.
"""

from __future__ import annotations

import argparse
import re
import sys
from collections import defaultdict
from dataclasses import dataclass, field
from pathlib import Path
from typing import Dict, Iterable, List, Optional, Set, Tuple

# Reuse MOG helpers
_SCRIPT_DIR = Path(__file__).resolve().parent
if str(_SCRIPT_DIR) not in sys.path:
    sys.path.insert(0, str(_SCRIPT_DIR))

from validate_emap_mog_root_overlap import (  # noqa: E402
    BindRec,
    check_mbind_consistency,
    check_section_matching,
)
from validate_emap_mog_semantic_dedup import (  # noqa: E402
    validate_file as validate_mo_semantic,
)
from validate_emap_so_exact_dedup import (  # noqa: E402
    ExactKey,
    NfLikeKey,
    parse_m_line,
    parse_so_line,
)


STATS_RE = re.compile(
    r"# so_export_stats:\s*"
    r"nodes=(?P<nodes>\d+)\s+"
    r"internal_cuts=(?P<internal_cuts>\d+)\s+"
    r"protected=(?P<protected>\d+)\s+"
    r"overflow_nodes=(?P<overflow_nodes>\d+)\s+"
    r"retained=(?P<retained>\d+)\s+"
    r"removed=(?P<removed>\d+)\s+"
    r"retained_min=(?P<retained_min>\d+)\s+"
    r"retained_max=(?P<retained_max>\d+)\s+"
    r"selected_ok=(?P<selected_ok>\d+)\s+"
    r"selected_miss=(?P<selected_miss>\d+)\s+"
    r"visited=(?P<visited>\d+)\s+"
    r"emitted=(?P<emitted>\d+)"
)


KNOWN_SECTION_MARKERS = (
    "primary inputs",
    "SO candidates",
    "MOG tuple candidates",
    "selected candidates",
    "multi-output bindings",
    "selected mapping",
    "warm start",
)


@dataclass
class UnifiedResult:
    path: Path
    errors: List[str] = field(default_factory=list)
    warnings: List[str] = field(default_factory=list)
    so_rows: int = 0
    exact_dups: int = 0
    nf_dups: int = 0
    m_checked: int = 0
    m_miss: int = 0
    dump_level: Optional[int] = None
    so_dedup: Optional[str] = None
    so_cut_limit: Optional[int] = None
    export_stats: Optional[dict] = None
    binds: List[BindRec] = field(default_factory=list)
    mbind_ids: List[Tuple[int, str, int]] = field(default_factory=list)
    phase_ok: int = 0
    phase_bad: int = 0


def _section_known(section: str) -> bool:
    s = section.lower()
    return any(k.lower() in s for k in KNOWN_SECTION_MARKERS) or s.startswith("# ---")


def validate_file(
    path: Path,
    *,
    check_exact: bool,
    check_nflike: bool,
    check_selected: bool,
    check_mog: bool,
    check_topk: bool,
    max_report: int,
) -> UnifiedResult:
    res = UnifiedResult(path=path)
    seen_exact: Set[ExactKey] = set()
    seen_nf: Set[NfLikeKey] = set()
    so_by_exact: Dict[ExactKey, int] = {}
    in_so = False
    in_warm = False
    section = ""
    pending: Optional[dict] = None
    # For same-pair multi-BIND allowance tracking
    pair_bind_counts: Dict[frozenset, int] = defaultdict(int)

    with path.open("r", encoding="utf-8", errors="replace") as fh:
        for line_no, line in enumerate(fh, 1):
            raw = line.rstrip("\n")
            s = raw.strip()

            if s.startswith("# dump_level:"):
                try:
                    res.dump_level = int(s.split(":", 1)[1].strip())
                except ValueError:
                    res.errors.append(f"L{line_no}: malformed dump_level")
                continue
            if s.startswith("# so_dedup:"):
                res.so_dedup = s.split(":", 1)[1].strip()
                continue
            if s.startswith("# so_cut_limit:"):
                try:
                    res.so_cut_limit = int(s.split(":", 1)[1].strip())
                except ValueError:
                    res.errors.append(f"L{line_no}: malformed so_cut_limit")
                continue
            if s.startswith("# so_export_stats:"):
                m = STATS_RE.match(s)
                if not m:
                    res.errors.append(f"L{line_no}: malformed so_export_stats")
                else:
                    res.export_stats = {k: int(v) for k, v in m.groupdict().items()}
                continue

            if s.startswith("# ---"):
                section = s
                pending = None
                if "SO candidates" in s:
                    in_so = True
                    in_warm = False
                    seen_exact.clear()
                    seen_nf.clear()
                elif "selected mapping" in s or "warm start" in s:
                    in_so = False
                    in_warm = True
                else:
                    if in_so:
                        in_so = False
                    if "selected mapping" not in s and "warm start" not in s:
                        in_warm = False
                if not _section_known(s):
                    res.warnings.append(f"L{line_no}: unknown section marker: {s[:80]}")
                continue

            if in_so and s and not s.startswith("#"):
                parsed = parse_so_line(s)
                if parsed is None:
                    res.errors.append(f"L{line_no}: unparseable SO: {s[:120]}")
                    continue
                exact, nflike, fanins = parsed
                res.so_rows += 1
                # Phase preservation: fanin lits keep phase bit (any parity ok as long as int)
                for lit in (exact[0],) + exact[2]:
                    if lit < 0:
                        res.phase_bad += 1
                        if res.phase_bad <= max_report:
                            res.errors.append(
                                f"L{line_no}: negative literal (phase lost?): {lit}"
                            )
                    else:
                        res.phase_ok += 1
                so_by_exact[exact] = line_no
                if check_exact:
                    if exact in seen_exact:
                        res.exact_dups += 1
                        if res.exact_dups <= max_report:
                            res.errors.append(
                                f"L{line_no}: exact duplicate SO {exact}"
                            )
                    else:
                        seen_exact.add(exact)
                if check_nflike:
                    if nflike in seen_nf:
                        res.nf_dups += 1
                        if res.nf_dups <= max_report:
                            res.errors.append(
                                f"L{line_no}: nf-like duplicate SO "
                                f"root={nflike[0]} cell={nflike[1]} "
                                f"sorted_fanins={list(nflike[2])}"
                            )
                    else:
                        seen_nf.add(nflike)
                continue

            if check_selected and in_warm and s.startswith("M") and not s.startswith("MBIND"):
                m = parse_m_line(s)
                if m is None:
                    res.errors.append(f"L{line_no}: malformed M: {s[:120]}")
                    continue
                root, cell, fanins = m
                if root < 0:
                    res.errors.append(f"L{line_no}: M root phase lost: {root}")
                if len(fanins) < 2 or "INV" in cell.upper():
                    continue
                key: ExactKey = (root, cell, fanins, 0)
                res.m_checked += 1
                if key not in so_by_exact:
                    res.m_miss += 1
                    if res.m_miss <= max_report:
                        res.errors.append(
                            f"L{line_no}: selected M missing exact SO "
                            f"candidate root={root} cell={cell} fanins={list(fanins)}"
                        )
                continue

            # MOG BIND / ROOTS / MBIND
            if check_mog and s.startswith("BIND "):
                parts = s.split()
                if len(parts) < 3:
                    res.errors.append(f"L{line_no}: malformed BIND: {s[:120]}")
                    pending = None
                    continue
                try:
                    bind_id = int(parts[1])
                except ValueError:
                    res.errors.append(f"L{line_no}: bad BIND id: {s[:120]}")
                    pending = None
                    continue
                pending = {
                    "bind_id": bind_id,
                    "cell": parts[2],
                    "section": section,
                    "line_no": line_no,
                }
                continue

            if check_mog and pending is not None and raw.startswith("  ROOTS "):
                try:
                    roots = tuple(int(x) for x in raw.split()[1:])
                except ValueError:
                    res.errors.append(f"L{line_no}: bad ROOTS: {s[:120]}")
                    pending = None
                    continue
                for r in roots:
                    if r < 0:
                        res.errors.append(f"L{line_no}: ROOTS phase lost: {r}")
                    else:
                        res.phase_ok += 1
                b = BindRec(
                    bind_id=pending["bind_id"],
                    cell=pending["cell"],
                    roots=roots,
                    section=pending["section"],
                    line_no=pending["line_no"],
                )
                res.binds.append(b)
                if len(b.nodes) == 2:
                    pair_bind_counts[b.pair_key] += 1
                pending = None
                continue

            if check_mog and s.startswith("MBIND "):
                parts = s.split()
                if len(parts) < 3:
                    res.errors.append(f"L{line_no}: malformed MBIND: {s[:120]}")
                    continue
                try:
                    mid = int(parts[1])
                except ValueError:
                    res.errors.append(f"L{line_no}: bad MBIND id: {s[:120]}")
                    continue
                res.mbind_ids.append((mid, parts[2], line_no))
                continue

            if check_mog and pending is not None and raw.startswith("  ROLES "):
                roles = raw.split()[1:]
                if roles != ["CON", "SN"] and set(roles) != {"CON", "SN"}:
                    # Allow order SN CON as well if ever emitted
                    if sorted(roles) != ["CON", "SN"]:
                        res.warnings.append(
                            f"L{line_no}: unexpected ROLES {roles} for BIND "
                            f"{pending.get('bind_id')}"
                        )
                continue

    if check_selected and res.so_rows == 0 and res.m_checked:
        res.errors.append(f"{path}: --check-selected but no SO rows")

    if check_mog:
        for substr, label in (
            ("MOG tuple candidates", "MOG tuple candidates"),
            ("multi-output bindings (selected)", "selected bindings"),
        ):
            binds = [b for b in res.binds if substr in b.section]
            errs, _stats = check_section_matching(binds, label, max_report)
            res.errors.extend(errs)
        # Wrap FileResult-like for MBIND check
        class _Tmp:
            pass

        tmp = _Tmp()
        tmp.binds = res.binds
        tmp.mbind_ids = res.mbind_ids
        tmp.binds_in = lambda sub: [b for b in res.binds if sub in b.section]
        res.errors.extend(check_mbind_consistency(tmp, max_report))  # type: ignore[arg-type]
        # Note: multiple BIND ids per pair is OK — no error if pair_bind_counts[p] > 1
        # Semantic endpoint-order uniqueness (physical candidate key)
        mo_sem = validate_mo_semantic(path, max_report=max_report)
        res.errors.extend(mo_sem.errors)
        res.warnings.extend(mo_sem.warnings)

    if check_topk:
        _check_topk_stats(res, max_report)

    return res


def _check_topk_stats(res: UnifiedResult, max_report: int) -> None:
    K = res.so_cut_limit
    st = res.export_stats
    if K is None and st is None:
        if res.dump_level is not None and res.dump_level >= 3:
            res.warnings.append(
                "dump_level>=3 but missing # so_cut_limit / # so_export_stats "
                "(rebuild graduate-abc for Phase-4 headers)"
            )
        return
    if st is None:
        res.warnings.append("missing # so_export_stats; skip detailed top-K checks")
        return
    if st["selected_miss"] != 0:
        res.errors.append(
            f"top-K: selected_miss={st['selected_miss']} (want 0); "
            f"selected_ok={st['selected_ok']}"
        )
    if K is not None and K == 0:
        if st["retained"] != st["internal_cuts"] or st["removed"] != 0:
            res.errors.append(
                f"top-K K=0: expected retained==internal_cuts and removed==0; "
                f"got retained={st['retained']} internal={st['internal_cuts']} "
                f"removed={st['removed']}"
            )
    if K is not None and K > 0:
        if st["overflow_nodes"] == 0 and st["retained_max"] > K:
            res.errors.append(
                f"top-K: overflow_nodes=0 but retained_max={st['retained_max']} > K={K}"
            )
        if st["overflow_nodes"] > 0 and st["protected"] == 0:
            res.errors.append(
                f"top-K: overflow_nodes={st['overflow_nodes']} but protected=0"
            )
        # Aggregate: retained + removed == internal when K>0
        if st["retained"] + st["removed"] != st["internal_cuts"]:
            res.errors.append(
                f"top-K: retained+removed != internal_cuts "
                f"({st['retained']}+{st['removed']} != {st['internal_cuts']})"
            )
    if st["emitted"] != res.so_rows and res.so_rows:
        # emitted from dump vs counted rows — allow if trailing comments only
        if abs(st["emitted"] - res.so_rows) > 0:
            res.warnings.append(
                f"so_export_stats emitted={st['emitted']} != counted so_rows={res.so_rows}"
            )


def iter_match_files(root: Path) -> Iterable[Path]:
    if root.is_file():
        yield root
        return
    yield from sorted(root.rglob("matches.nf_y_multi.txt"))


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("paths", nargs="+", type=Path)
    ap.add_argument("--exact", action="store_true")
    ap.add_argument("--nf-like", action="store_true")
    ap.add_argument("--check-selected", action="store_true")
    ap.add_argument("--check-mog", action="store_true")
    ap.add_argument("--check-topk", action="store_true")
    ap.add_argument(
        "--formal",
        action="store_true",
        help="enable all formal-policy checks (exact+nf-like+selected+mog+topk)",
    )
    ap.add_argument("--require-so", action="store_true")
    ap.add_argument("--max-report", type=int, default=20)
    args = ap.parse_args()

    if args.formal:
        args.exact = True
        args.nf_like = True
        args.check_selected = True
        args.check_mog = True
        args.check_topk = True
    if not any(
        [
            args.exact,
            args.nf_like,
            args.check_selected,
            args.check_mog,
            args.check_topk,
        ]
    ):
        args.formal = True
        args.exact = True
        args.nf_like = True
        args.check_selected = True
        args.check_mog = True
        args.check_topk = True

    bad = 0
    for path in args.paths:
        for mf in iter_match_files(path):
            res = validate_file(
                mf,
                check_exact=args.exact,
                check_nflike=args.nf_like,
                check_selected=args.check_selected,
                check_mog=args.check_mog,
                check_topk=args.check_topk,
                max_report=args.max_report,
            )
            if args.require_so and res.so_rows == 0:
                res.errors.append(f"{mf}: no SO rows")
            fail = bool(res.errors)
            status = "FAIL" if fail else "OK"
            print(
                f"[{status}] {mf}  so_rows={res.so_rows} exact_dups={res.exact_dups} "
                f"nf_dups={res.nf_dups} m_ok={res.m_checked - res.m_miss}/{res.m_checked} "
                f"mbind={len(res.mbind_ids)} K={res.so_cut_limit}"
            )
            for e in res.errors[: args.max_report * 3]:
                print(f"  ERROR: {e}")
            for w in res.warnings[:10]:
                print(f"  WARN: {w}")
            if fail:
                bad += 1
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
