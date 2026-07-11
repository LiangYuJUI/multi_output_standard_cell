#!/usr/bin/env bash
# See docs/SCRIPTS.md
# Phase 4: quantify emap SO export policies A–F on fair ASAP7 synth AIGs.
#
# Policies:
#   A legacy     -D 0 -K 0   (all pin-perms, no dump pruning)
#   B exact      -D 1 -K 0
#   C nf-like    -D 2 -K 0
#   D top16exact -D 1 -K 16
#   E top16nflike -D 2 -K 16   ← formal GradMap policy
#   F top32nflike -D 2 -K 32
#
# Examples:
#   ./scripts/sh/run_emap_so_policy_compare.sh --cases "adder ctrl cavlc sin" --cec
#   ./scripts/sh/run_emap_so_policy_compare.sh --policies "C E F" --cases adder
#
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
GRADUATE_DIR="${GRADUATE_DIR:-$ROOT_DIR/third_party/GRADUATE}"
ABC="${GRADUATE_ABC:-$GRADUATE_DIR/build_abc_frontend/graduate-abc}"
GENLIB="${EMAP_GENLIB:-$GRADUATE_DIR/third_party/gradmap_libs/asap7.genlib}"
FAIR_ROOT="${FAIR_ROOT:-$ROOT_DIR/output/fair_nf_emap_asap7genlib}"
OUT_ROOT="${OUT_ROOT:-$ROOT_DIR/output/emap_so_policy_$(date +%Y%m%d_%H%M%S)}"
CASES="${CASES:-adder ctrl cavlc sin}"
POLICIES="${POLICIES:-A B C D E F}"
MAP_TIMEOUT="${MAP_TIMEOUT:-900}"
RUN_CEC=0
MERGE="$ROOT_DIR/scripts/py/merge_emap_twins.py"
VAL="$ROOT_DIR/scripts/py/validate_emap_nf_y_multi.py"

# shellcheck source=emap_so_policy_lib.sh
source "$ROOT_DIR/scripts/sh/emap_so_policy_lib.sh"

usage() {
  cat <<EOF
Usage: $0 [options]

Quantify SO export policies A–F on shared fair synth.aig (map-only emap -M 3).

Options:
  --root DIR           fair root with synth/<case>/synth.aig
  --out DIR            output root
  --cases "a b c"      [adder ctrl cavlc sin]
  --policies "A B E"   subset of A–F [all]
  --map-timeout SEC    [900]
  --genlib PATH
  --cec                CEC each mapped Verilog vs synth.aig
  -h, --help
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --root) FAIR_ROOT="$2"; shift 2 ;;
    --out) OUT_ROOT="$2"; shift 2 ;;
    --cases) CASES="$2"; shift 2 ;;
    --policies) POLICIES="$2"; shift 2 ;;
    --map-timeout) MAP_TIMEOUT="$2"; shift 2 ;;
    --genlib) GENLIB="$2"; shift 2 ;;
    --cec) RUN_CEC=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown option: $1" >&2; usage >&2; exit 1 ;;
  esac
done

[[ -x "$ABC" ]] || { echo "missing $ABC" >&2; exit 1; }
[[ -f "$GENLIB" ]] || { echo "missing $GENLIB" >&2; exit 1; }
[[ -d "$FAIR_ROOT/synth" ]] || { echo "missing $FAIR_ROOT/synth" >&2; exit 1; }

policy_flags() {
  case "$1" in
    A) echo "none 0 legacy" ;;
    B) echo "exact 0 exact_only" ;;
    C) echo "nf-like 0 nflike_only" ;;
    D) echo "exact 16 top16_exact" ;;
    E) echo "nf-like 16 top16_nflike" ;;
    F) echo "nf-like 32 top32_nflike" ;;
    *) echo "bad policy $1" >&2; return 1 ;;
  esac
}

mkdir -p "$OUT_ROOT"
CSV="$OUT_ROOT/policy_compare.csv"
REPORT="$OUT_ROOT/policy_compare.md"

echo "case,policy,dedup,K,roots,internal_cuts,protected,retained,overflow_nodes,so_visited,so_emitted,mog_tuples,bind,mbind,M,file_bytes,dump_s,peak_rss_kb,cands_per_root,warm_match,cec,status" > "$CSV"

peak_rss_kb() {
  # Best-effort: /usr/bin/time -f %M if available; else 0
  local log="$1"
  if grep -qE '^[0-9]+$' "$log.rss" 2>/dev/null; then
    cat "$log.rss"
  else
    echo 0
  fi
}

run_one() {
  local case_name="$1" pol="$2"
  local meta dedup topk label
  meta="$(policy_flags "$pol")"
  read -r dedup topk label <<<"$meta"
  local tag="${case_name}_${pol}_${label}"
  local odir="$OUT_ROOT/$tag"
  mkdir -p "$odir"
  local aig="$FAIR_ROOT/synth/$case_name/synth.aig"
  if [[ ! -s "$aig" ]]; then
    echo "[$tag] skip(no synth)" | tee "$odir/status.txt"
    return 0
  fi
  local match="$odir/matches.nf_y_multi.txt"
  local verilog="$odir/${case_name}_emap.v"
  local log="$odir/abc.log"
  local dnum
  dnum="$(emap_so_dedup_to_num "$dedup")"
  cat >"$odir/run.abc" <<EOF
read $aig
strash
read_genlib $GENLIB
emap -a -v -Y $match -M 3 -D $dnum -K $topk
write_verilog $verilog
EOF
  local t0 t1 wall rc
  t0=$(date +%s.%N)
  set +e
  if command -v /usr/bin/time >/dev/null 2>&1; then
    /usr/bin/time -f '%M' -o "$log.rss" timeout "$MAP_TIMEOUT" \
      bash -c "cd \"$GRADUATE_DIR\" && \"$ABC\" -f \"$odir/run.abc\"" \
      >"$log" 2>&1
    rc=$?
  else
    echo 0 >"$log.rss"
    timeout "$MAP_TIMEOUT" bash -c "cd \"$GRADUATE_DIR\" && \"$ABC\" -f \"$odir/run.abc\"" \
      >"$log" 2>&1
    rc=$?
  fi
  set -e
  t1=$(date +%s.%N)
  wall=$(python3 -c "print(round($t1-$t0,3))")

  local status="pass"
  [[ "$rc" == 0 && -s "$match" && -s "$verilog" ]] || status="fail(rc=$rc)"

  local cec="n/a"
  if [[ "$RUN_CEC" == 1 && "$status" == pass ]]; then
    local merged="$odir/${case_name}_emap_merged.v"
    python3 "$MERGE" "$verilog" -o "$merged" 2>/dev/null || cp "$verilog" "$merged"
    set +e
    timeout 180 bash -c "cd \"$GRADUATE_DIR\" && \"$ABC\" -c \"read -m \\\"$merged\\\"; read_aiger \\\"$aig\\\"; cec\"" \
      >"$odir/cec.log" 2>&1
    local crc=$?
    set -e
    if [[ "$crc" == 0 ]] && grep -q "Networks are equivalent" "$odir/cec.log"; then
      cec="pass"
    else
      cec="fail"
      status="fail(cec)"
    fi
  fi

  local warm="n/a"
  if [[ -s "$match" ]]; then
    set +e
    local val_args=(--check-selected --check-mog --check-topk --require-so)
    case "$dedup" in
      none) val_args+=() ;;  # no SO dedup uniqueness required
      exact) val_args+=(--exact) ;;
      nf-like) val_args+=(--exact --nf-like) ;;
    esac
    python3 "$VAL" "${val_args[@]}" "$match" >"$odir/validate.log" 2>&1
    local vrc=$?
    set -e
    if [[ "$vrc" == 0 ]]; then
      warm="100%"
    else
      warm="fail"
      [[ "$status" == pass ]] && status="fail(validate)"
    fi
  fi

  python3 - <<PY >>"$CSV"
import re
from pathlib import Path
from collections import Counter

case = ${case_name@Q}
pol = ${pol@Q}
dedup = ${dedup@Q}
K = $topk
match = Path(${match@Q})
log = Path(${log@Q})
status = ${status@Q}
cec = ${cec@Q}
warm = ${warm@Q}
wall = float(${wall@Q})
rss = int(Path(${log@Q} + ".rss").read_text().strip() or "0")
bytes_ = match.stat().st_size if match.exists() else 0

text = match.read_text(encoding="utf-8", errors="replace") if match.exists() else ""
stats = {}
m = re.search(r"# so_export_stats: ([^\n]+)", text)
if m:
    for kv in m.group(1).split():
        if "=" in kv:
            k, v = kv.split("=", 1)
            try:
                stats[k] = int(v)
            except ValueError:
                pass

so = 0
inside = False
roots = Counter()
for line in text.splitlines():
    if line.startswith("# --- SO candidates"):
        inside = True
        continue
    if line.startswith("# ---") and inside:
        break
    if inside and line.strip() and not line.startswith("#"):
        so += 1
        roots[line.split()[0]] += 1
cpr = (sum(roots.values()) / len(roots)) if roots else 0.0

mog = bind = mbind = M = 0
for line in log.read_text(encoding="utf-8", errors="replace").splitlines() if log.exists() else []:
    if "emap -Y wrote" in line and "MO_tuple=" in line:
        def grab(key, line=line):
            mm = re.search(rf"{key}=(\d+)", line)
            return int(mm.group(1)) if mm else 0
        mog = grab("MO_tuple")
        bind = grab("BIND")
        mbind = grab("MBIND")
        M = grab("M")

print(",".join(str(x) for x in [
    case, pol, dedup, K,
    stats.get("nodes", ""),
    stats.get("internal_cuts", ""),
    stats.get("protected", ""),
    stats.get("retained", ""),
    stats.get("overflow_nodes", ""),
    stats.get("visited", ""),
    stats.get("emitted", so),
    mog, bind, mbind, M,
    bytes_, wall, rss, f"{cpr:.2f}", warm, cec, status,
]))
PY
  echo "[$tag] $status wall=${wall}s cec=$cec warm=$warm size=$(du -h "$match" 2>/dev/null | awk '{print $1}')"
}

for pol in $POLICIES; do
  for c in $CASES; do
    run_one "$c" "$pol"
  done
done

python3 - <<PY
from pathlib import Path
import csv
csv_path=Path("$CSV")
rows=list(csv.DictReader(csv_path.open()))
md=["# emap SO export policy compare (Phase 4)", "",
    f"- fair_root: \`$FAIR_ROOT\`",
    f"- genlib: \`$GENLIB\`",
    f"- cases: $CASES",
    f"- policies: $POLICIES",
    "",
    "| case | policy | dedup | K | SO emitted | file MB | dump s | BIND | MBIND | warm | CEC | status |",
    "|------|--------|-------|---|------------|---------|--------|------|-------|------|-----|--------|"]
for r in rows:
    mb=f"{int(r['file_bytes'])/1e6:.2f}" if r['file_bytes'] else ""
    md.append(
        f"| {r['case']} | {r['policy']} | {r['dedup']} | {r['K']} | {r['so_emitted']} | {mb} | {r['dump_s']} | "
        f"{r['bind']} | {r['mbind']} | {r['warm_match']} | {r['cec']} | {r['status']} |"
    )
# Shrink vs legacy A when both present
md += ["", "## Shrink vs policy A (legacy)", ""]
from collections import defaultdict
by=defaultdict(dict)
for r in rows:
    by[r['case']][r['policy']]=r
md.append("| case | E/A SO rows | E/A file size |")
md.append("|------|-------------|---------------|")
for case, d in sorted(by.items()):
    if "A" in d and "E" in d and d["A"]["so_emitted"] and d["E"]["so_emitted"]:
        try:
            ra=int(d["A"]["so_emitted"]); re=int(d["E"]["so_emitted"])
            fa=int(d["A"]["file_bytes"]); fe=int(d["E"]["file_bytes"])
            md.append(f"| {case} | {re}/{ra} ({100*re/ra:.1f}%) | {fe/1e6:.2f}/{fa/1e6:.2f} MB ({100*fe/fa:.1f}%) |")
        except Exception:
            pass
Path("$REPORT").write_text("\n".join(md)+"\n")
print("wrote", "$REPORT")
PY

echo "CSV: $CSV"
echo "Report: $REPORT"
