#!/usr/bin/env bash
# See docs/SCRIPTS.md
# Re-run emap -Y in-place on an existing fair tree (reuse synth.aig only).
# Use after fixing graduate-abc emap dump so hard-replay match files are consistent.
#
# Examples:
#   ./scripts/sh/redump_emap_y_fair.sh --jobs 8
#   ./scripts/sh/redump_emap_y_fair.sh --cases "sin voter div" --dump-level 1
#   ./scripts/sh/redump_emap_y_fair.sh --dump-level 3 --map-timeout 1800 --jobs 4
#   ./scripts/sh/redump_emap_y_fair.sh --dump-level 3 --so-dedup nf-like --so-cut-topk 16 --jobs 4
#
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
GRADUATE_DIR="${GRADUATE_DIR:-$ROOT_DIR/third_party/GRADUATE}"
ABC="${GRADUATE_ABC:-$GRADUATE_DIR/build_abc_frontend/graduate-abc}"
GENLIB="${EMAP_GENLIB:-$GRADUATE_DIR/third_party/gradmap_libs/asap7.genlib}"
FAIR_ROOT="${FAIR_ROOT:-$ROOT_DIR/output/fair_nf_emap_asap7genlib}"
EMAP_SUBDIR="${EMAP_SUBDIR:-emap}"
DUMP_LEVEL="${DUMP_LEVEL:-1}"
EMAP_FLAGS="${EMAP_FLAGS:--a -v}"
SO_DEDUP="${SO_DEDUP:-nf-like}"
SO_CUT_TOPK="${SO_CUT_TOPK:-16}"
CASES="${CASES:-}"
JOBS="${JOBS:-1}"
MAP_TIMEOUT="${MAP_TIMEOUT:-900}"
TEMPLATE="$ROOT_DIR/scripts/abc/abc_map_emap_y.abc"

# shellcheck source=emap_so_policy_lib.sh
source "$ROOT_DIR/scripts/sh/emap_so_policy_lib.sh"

usage() {
  cat <<EOF
Usage: $0 [options]

Re-dump emap -Y match files under a fair output tree (does not re-synth).

Options:
  --root DIR           fair root [output/fair_nf_emap_asap7genlib]
  --emap-subdir NAME   [emap]
  --cases "a b c"
  --dump-level 1|2|3   [1]  (1 is enough for hard-replay; 3 = full candidates)
  --emap-flags STR     [ -a -v ]
$(emap_so_policy_usage_lines)
  --genlib PATH
  --map-timeout SEC    [900]
  --jobs N / --parallel
  -h, --help

Examples:
  ./scripts/sh/redump_emap_y_fair.sh --jobs 8
  ./scripts/sh/redump_emap_y_fair.sh --cases "sin voter div" --dump-level 1
  ./scripts/sh/redump_emap_y_fair.sh --dump-level 3 --map-timeout 1800 --jobs 4
  ./scripts/sh/redump_emap_y_fair.sh --dump-level 3 --so-dedup nf-like --so-cut-topk 16 --jobs 4
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --root) FAIR_ROOT="$2"; shift 2 ;;
    --emap-subdir) EMAP_SUBDIR="$2"; shift 2 ;;
    --cases) CASES="$2"; shift 2 ;;
    --dump-level) DUMP_LEVEL="$2"; shift 2 ;;
    --emap-flags) EMAP_FLAGS="$2"; shift 2 ;;
    --so-dedup) SO_DEDUP="$2"; shift 2 ;;
    --so-cut-topk) SO_CUT_TOPK="$2"; shift 2 ;;
    --genlib) GENLIB="$2"; shift 2 ;;
    --map-timeout) MAP_TIMEOUT="$2"; shift 2 ;;
    --jobs) JOBS="$2"; shift 2 ;;
    --parallel) JOBS="$(nproc)"; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown option: $1" >&2; usage >&2; exit 1 ;;
  esac
done

FAIR_ROOT="$(cd "$FAIR_ROOT" && pwd)"
EMAP_DIR="$FAIR_ROOT/$EMAP_SUBDIR"
SYNTH_DIR="$FAIR_ROOT/synth"
LOG_DIR="$FAIR_ROOT/redump_emap_logs"
mkdir -p "$LOG_DIR"

[[ -x "$ABC" ]] || { echo "missing graduate-abc: $ABC" >&2; exit 1; }
[[ -f "$GENLIB" ]] || { echo "missing genlib: $GENLIB" >&2; exit 1; }
[[ -f "$TEMPLATE" ]] || { echo "missing $TEMPLATE" >&2; exit 1; }
[[ -d "$EMAP_DIR" && -d "$SYNTH_DIR" ]] || {
  echo "fair root missing $EMAP_SUBDIR/ or synth/: $FAIR_ROOT" >&2
  exit 1
}
if ! [[ "$DUMP_LEVEL" =~ ^[123]$ ]]; then
  echo "invalid --dump-level: $DUMP_LEVEL" >&2
  exit 1
fi

EMAP_FLAGS="$(emap_so_append_flags "$EMAP_FLAGS" "$SO_DEDUP" "$SO_CUT_TOPK")" || exit 1

list_cases() {
  if [[ -n "$CASES" ]]; then
    # shellcheck disable=SC2086
    printf '%s\n' $CASES
    return
  fi
  find "$EMAP_DIR" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' | sort
}

run_one() {
  local case_name="$1"
  local synth="$SYNTH_DIR/$case_name/synth.aig"
  local case_dir="$EMAP_DIR/$case_name"
  local match="$case_dir/matches.nf_y_multi.txt"
  local verilog="$case_dir/${case_name}_emap.v"
  local abc_script="$LOG_DIR/${case_name}.abc"
  local log="$LOG_DIR/${case_name}.log"
  local line="$LOG_DIR/${case_name}.line"

  echo "[$case_name] start"

  if [[ ! -s "$synth" ]]; then
    echo "[$case_name] fail(no synth)" | tee "$line"
    return 0
  fi
  mkdir -p "$case_dir"

  local synth_abs match_abs verilog_abs genlib_abs
  synth_abs="$(cd "$(dirname "$synth")" && pwd)/$(basename "$synth")"
  match_abs="$(cd "$case_dir" && pwd)/matches.nf_y_multi.txt"
  verilog_abs="$(cd "$case_dir" && pwd)/${case_name}_emap.v"
  genlib_abs="$(cd "$(dirname "$GENLIB")" && pwd)/$(basename "$GENLIB")"

  sed \
    -e "s|__INPUT_AIG__|$synth_abs|g" \
    -e "s|__GENLIB__|$genlib_abs|g" \
    -e "s|__MATCH_FILE__|$match_abs|g" \
    -e "s|__OUTPUT_V__|$verilog_abs|g" \
    -e "s|__EMAP_FLAGS__|$EMAP_FLAGS|g" \
    -e "s|__DUMP_LEVEL__|$DUMP_LEVEL|g" \
    "$TEMPLATE" > "$abc_script"

  set +e
  timeout "$MAP_TIMEOUT" bash -c "cd \"$GRADUATE_DIR\" && \"$ABC\" -f \"$abc_script\"" \
    >"$log" 2>&1
  local rc=$?
  set -e

  local status
  if [[ "$rc" == 124 ]]; then
    status="fail(timeout)"
  elif [[ "$rc" != 0 ]]; then
    status="fail(rc=$rc)"
  elif [[ ! -s "$match_abs" ]]; then
    status="fail(no match)"
  elif [[ ! -s "$verilog_abs" ]]; then
    status="fail(no verilog)"
  else
    local mbind
    mbind="$(grep -c '^MBIND ' "$match_abs" || true)"
    status="pass mbind=$mbind"
  fi
  echo "[$case_name] $status" | tee "$line"
}

export -f run_one
export ABC GENLIB EMAP_DIR SYNTH_DIR LOG_DIR TEMPLATE GRADUATE_DIR DUMP_LEVEL EMAP_FLAGS MAP_TIMEOUT

mapfile -t CASE_LIST < <(list_cases)
echo "redump emap -Y: ${#CASE_LIST[@]} cases, jobs=$JOBS, dump_level=$DUMP_LEVEL so_dedup=$SO_DEDUP so_cut_topk=$SO_CUT_TOPK"
echo "root=$FAIR_ROOT genlib=$GENLIB"
echo "cases: ${CASE_LIST[*]}"

if [[ "$JOBS" -gt 1 ]]; then
  printf '%s\n' "${CASE_LIST[@]}" | xargs -P "$JOBS" -I{} bash -c 'run_one "$@"' _ {}
else
  for c in "${CASE_LIST[@]}"; do
    run_one "$c"
  done
fi

pass=0
fail=0
{
  echo "# emap -Y redump"
  echo
  echo "- root: \`$FAIR_ROOT\`"
  echo "- dump_level: $DUMP_LEVEL"
  echo "- so_dedup: $SO_DEDUP"
  echo "- so_cut_topk: $SO_CUT_TOPK"
  echo "- emap_flags: \`$EMAP_FLAGS\`"
  echo "- genlib: \`$GENLIB\`"
  echo
  echo "| case | status |"
  echo "|------|--------|"
  for c in "${CASE_LIST[@]}"; do
    line="$(cat "$LOG_DIR/$c.line" 2>/dev/null || echo 'fail(missing)')"
    # strip [case] prefix
    st="${line#\[*\] }"
    echo "| $c | $st |"
    if [[ "$st" == pass* ]]; then
      pass=$((pass + 1))
    else
      fail=$((fail + 1))
    fi
  done
  echo
  echo "summary: $pass pass, $fail fail, ${#CASE_LIST[@]} total"
} | tee "$LOG_DIR/summary.md"

[[ "$fail" -eq 0 ]]
