#!/usr/bin/env bash
# See docs/SCRIPTS.md
# Compare ABC-native emap results: standalone third_party/abc vs graduate-abc.
#
# Verifies that emap integrated into GRADUATE bundled ABC produces identical
# mapping logs, print_stats lines, and normalized BLIF netlists.
#
# Examples:
#   ./scripts/compare_graduate_abc_emap.sh
#   ./scripts/compare_graduate_abc_emap.sh --cases adder c1355 multiplier
#   ./scripts/compare_graduate_abc_emap.sh --scale tiny
#
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STANDALONE_ABC="${STANDALONE_ABC:-$ROOT_DIR/third_party/abc/abc}"
GRADUATE_DIR="${GRADUATE_DIR:-$ROOT_DIR/third_party/GRADUATE}"
GRADUATE_ABC="${GRADUATE_ABC:-$GRADUATE_DIR/build_abc_frontend/graduate-abc}"
GENLIB="${EMAP_GENLIB:-$ROOT_DIR/third_party/mockturtle/experiments/cell_libraries/multioutput.genlib}"
BENCH_ROOT="${BENCH_ROOT:-$ROOT_DIR/third_party/mockturtle/experiments/benchmarks}"
SCALE="${SCALE:-}"
CASES="${CASES:-adder c1355 c6288 multiplier sqrt}"
EMAP_FLAGS="${EMAP_FLAGS:--av}"
OUT_ROOT="${OUT_ROOT:-$ROOT_DIR/output/emap_equiv_$(date +%Y%m%d_%H%M%S)}"

usage() {
  cat <<EOF
Usage: $0 [options]

Compare standalone ABC emap vs graduate-abc emap on the same AIG + GENLIB.

Options:
  --cases "a b"           benchmark base names (no .aig)
  --scale tiny|small|...  load cases from data/epfl/<scale>.yaml
  --bench-root DIR        directory containing <case>.aig files
  --genlib PATH           GENLIB for emap [multioutput.genlib]
  --emap-flags STR        emap flags [default: -av]
  --standalone PATH       standalone abc binary [third_party/abc/abc]
  --graduate-abc PATH     graduate-abc binary
  --out DIR               output directory for BLIF/logs
  -h, --help              show this help
EOF
}

require_exe() {
  if [[ ! -x "$1" ]]; then
    echo "missing or not executable: $1" >&2
    exit 1
  fi
}

resolve_cases_from_scale() {
  local scale="$1"
  local yaml="$ROOT_DIR/data/epfl/${scale}.yaml"
  if [[ ! -f "$yaml" ]]; then
    echo "missing scale yaml: $yaml" >&2
    exit 1
  fi
  CASES="$(
    awk '
      /^benchmarks:/ { in_list=1; next }
      in_list && /^  - id:/ { next }
      in_list && /^    name:/ {
        sub(/^    name:[[:space:]]*/, "")
        print
        next
      }
      in_list && /^[^ ]/ { exit }
    ' "$yaml" | tr '\n' ' '
  )"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --cases)
      CASES="${2:-}"
      shift 2
      ;;
    --scale)
      SCALE="${2:-}"
      shift 2
      ;;
    --bench-root)
      BENCH_ROOT="${2:-}"
      shift 2
      ;;
    --genlib)
      GENLIB="${2:-}"
      shift 2
      ;;
    --emap-flags)
      EMAP_FLAGS="${2:-}"
      shift 2
      ;;
    --standalone)
      STANDALONE_ABC="${2:-}"
      shift 2
      ;;
    --graduate-abc)
      GRADUATE_ABC="${2:-}"
      shift 2
      ;;
    --out)
      OUT_ROOT="${2:-}"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "unknown option: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
done

if [[ -n "$SCALE" ]]; then
  resolve_cases_from_scale "$SCALE"
fi

require_exe "$STANDALONE_ABC"
require_exe "$GRADUATE_ABC"
[[ -f "$GENLIB" ]] || { echo "missing GENLIB: $GENLIB" >&2; exit 1; }

mkdir -p "$OUT_ROOT"

strip_ansi() {
  sed 's/\x1b\[[0-9;]*m//g'
}

normalize_blif() {
  local src="$1" dst="$2"
  grep -v '^# Benchmark' "$src" > "$dst"
}

run_emap() {
  local bin="$1" tag="$2" aig="$3" base="$4"
  local blif="$OUT_ROOT/${base}_${tag}.blif"
  local log="$OUT_ROOT/${base}_${tag}.log"
  "$bin" -c "read_aiger $aig; strash; read_genlib $GENLIB; emap $EMAP_FLAGS; print_stats; write_blif $blif" \
    >"$log" 2>&1
  echo "$log|$blif"
}

pass=0
fail=0
missing=0

echo "Standalone ABC: $STANDALONE_ABC"
echo "Graduate ABC:   $GRADUATE_ABC"
echo "GENLIB:         $GENLIB"
echo "emap flags:     $EMAP_FLAGS"
echo "Output:         $OUT_ROOT"
echo

for case_name in $CASES; do
  aig="$BENCH_ROOT/${case_name}.aig"
  if [[ ! -f "$aig" ]]; then
    echo "SKIP $case_name (missing $aig)"
    missing=$((missing + 1))
    continue
  fi

  IFS='|' read -r s_log s_blif <<<"$(run_emap "$STANDALONE_ABC" standalone "$aig" "$case_name")"
  IFS='|' read -r g_log g_blif <<<"$(run_emap "$GRADUATE_ABC" graduate "$aig" "$case_name")"

  s_map=$(grep 'ABC-native emap mapped' "$s_log" | strip_ansi | head -1)
  g_map=$(grep 'ABC-native emap mapped' "$g_log" | strip_ansi | head -1)
  s_stats=$(grep 'i/o =' "$s_log" | strip_ansi | tail -1 | sed 's/.*: //')
  g_stats=$(grep 'i/o =' "$g_log" | strip_ansi | tail -1 | sed 's/.*: //')

  s_norm="$OUT_ROOT/${case_name}_standalone.norm.blif"
  g_norm="$OUT_ROOT/${case_name}_graduate.norm.blif"
  normalize_blif "$s_blif" "$s_norm"
  normalize_blif "$g_blif" "$g_norm"

  if [[ "$s_map" == "$g_map" && "$s_stats" == "$g_stats" ]] && diff -q "$s_norm" "$g_norm" >/dev/null; then
    echo "PASS $case_name"
    pass=$((pass + 1))
  else
    echo "FAIL $case_name"
    [[ "$s_map" == "$g_map" ]] || {
      echo "  emap log differs"
      echo "    standalone: $s_map"
      echo "    graduate:   $g_map"
    }
    [[ "$s_stats" == "$g_stats" ]] || {
      echo "  stats differ"
      echo "    standalone: $s_stats"
      echo "    graduate:   $g_stats"
    }
    diff -q "$s_norm" "$g_norm" >/dev/null || echo "  normalized BLIF differs (see $OUT_ROOT)"
    fail=$((fail + 1))
  fi
done

echo
echo "Summary: $pass passed, $fail failed, $missing skipped"
[[ "$fail" -eq 0 ]]
