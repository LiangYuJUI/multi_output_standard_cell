#!/usr/bin/env bash
# See docs/SCRIPTS.md
# Phase 3C: hard-replay GradMap Verilog from emap nf_y_multi M/MBIND, then CEC.
#
# Examples:
#   ./scripts/sh/hard_replay_emap_mog.sh --cases adder
#   ./scripts/sh/hard_replay_emap_mog.sh --root output/fair_nf_emap_asap7genlib --jobs 4
#
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
GRADUATE_DIR="${GRADUATE_DIR:-$ROOT_DIR/third_party/GRADUATE}"
BUILD_DIR="${GRADUATE_BUILD:-$GRADUATE_DIR/build_abc_frontend}"
ABC="${GRADUATE_ABC:-$BUILD_DIR/graduate-abc}"
REPLAY="${GRADUATE_HARD_REPLAY:-$BUILD_DIR/graduate-map-hard-replay}"
LIBCELL="${GRADUATE_LIBCELL_MO:-$GRADUATE_DIR/third_party/gradmap_libs/asap7_libcell_info_v2_multi_output.txt}"
GENLIB="${EMAP_GENLIB:-$GRADUATE_DIR/third_party/gradmap_libs/asap7.genlib}"
FAIR_ROOT="${FAIR_ROOT:-$ROOT_DIR/output/fair_nf_emap_asap7genlib}"
EMAP_SUBDIR="${EMAP_SUBDIR:-emap}"
CASES="${CASES:-}"
JOBS="${JOBS:-1}"
TIMEOUT="${TIMEOUT:-600}"

usage() {
  cat <<EOF
Usage: $0 [options]

Hard-replay M/MBIND from emap matches.nf_y_multi.txt → Verilog → CEC vs synth.aig.

Options:
  --root DIR           fair output root [output/fair_nf_emap_asap7genlib]
  --emap-subdir NAME   emap dir under root [emap]
  --cases "a b c"      subset of case names
  --jobs N / --parallel
  --timeout SEC
  -h, --help
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --root) FAIR_ROOT="$2"; shift 2 ;;
    --emap-subdir) EMAP_SUBDIR="$2"; shift 2 ;;
    --cases) CASES="$2"; shift 2 ;;
    --jobs) JOBS="$2"; shift 2 ;;
    --parallel) JOBS="$(nproc)"; shift ;;
    --timeout) TIMEOUT="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown option: $1" >&2; usage >&2; exit 1 ;;
  esac
done

FAIR_ROOT="$(cd "$FAIR_ROOT" && pwd)"
EMAP_DIR="$FAIR_ROOT/$EMAP_SUBDIR"
SYNTH_DIR="$FAIR_ROOT/synth"
OUT_DIR="$FAIR_ROOT/hard_replay"
RESULT_DIR="$OUT_DIR/cec_logs"
REPORT="$OUT_DIR/cec_report.md"
mkdir -p "$OUT_DIR" "$RESULT_DIR"

[[ -x "$ABC" ]] || { echo "missing graduate-abc: $ABC" >&2; exit 1; }
[[ -x "$REPLAY" ]] || { echo "missing hard-replay tool: $REPLAY (build graduate-map-hard-replay)" >&2; exit 1; }
[[ -f "$LIBCELL" ]] || { echo "missing libcell: $LIBCELL" >&2; exit 1; }
[[ -f "$GENLIB" ]] || { echo "missing genlib: $GENLIB" >&2; exit 1; }
[[ -d "$EMAP_DIR" && -d "$SYNTH_DIR" ]] || {
  echo "fair root missing $EMAP_SUBDIR/ or synth/: $FAIR_ROOT" >&2
  exit 1
}

strip_ansi() {
  perl -pe 's/\e\[[0-9;]*[mK]//g'
}

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
  local match="$EMAP_DIR/$case_name/matches.nf_y_multi.txt"
  local synth="$SYNTH_DIR/$case_name/synth.aig"
  local out_v="$OUT_DIR/$case_name/${case_name}_hard_replay.v"
  local log="$RESULT_DIR/${case_name}.log"
  local line="$RESULT_DIR/${case_name}.line"

  echo "[$case_name] start"

  report() {
    local msg="$1"
    printf '%s\n' "$msg" >"$line"
    echo "[$case_name] $msg"
  }

  if [[ ! -f "$match" ]]; then
    report "fail(no match)"
    return 0
  fi
  if [[ ! -s "$synth" ]]; then
    report "fail(no synth)"
    return 0
  fi

  mkdir -p "$OUT_DIR/$case_name"
  set +e
  "$REPLAY" --libcell "$LIBCELL" --matches "$match" --output "$out_v" \
    --module "$case_name" >"$RESULT_DIR/${case_name}.replay.txt" 2>&1
  local rc=$?
  set -e
  if [[ "$rc" != 0 ]]; then
    report "fail(replay)"
    return 0
  fi

  local bind_n
  bind_n="$(awk '/^binding_instances /{print $2}' "$RESULT_DIR/${case_name}.replay.txt" | tail -1)"
  bind_n="${bind_n:-?}"
  echo "[$case_name] replay ok (bind=$bind_n), running cec..."

  set +e
  timeout "$TIMEOUT" bash -c "cd \"$GRADUATE_DIR\" && \"$ABC\" -c \"
    read_genlib \\\"$GENLIB\\\";
    read -m \\\"$out_v\\\";
    ps;
    read_aiger \\\"$synth\\\";
    ps;
    cec
  \"" >"$log" 2>&1
  rc=$?
  set -e

  local plain
  plain="$(strip_ansi < "$log")"
  local status
  if [[ "$rc" == 124 ]]; then
    status="fail(timeout)"
  elif [[ "$rc" != 0 ]]; then
    status="fail(rc=$rc)"
  elif echo "$plain" | grep -qE 'Reading network from file has failed|Cannot open input file|Empty network|Parsing of gate .* has failed'; then
    status="fail(read)"
  elif echo "$plain" | grep -q 'Networks are equivalent'; then
    status="pass"
  elif echo "$plain" | grep -qiE 'not equivalent|Networks are NOT equivalent'; then
    status="fail(neq)"
  else
    status="fail(no-cec-line)"
  fi
  report "$status bind=$bind_n"
}

export -f run_one strip_ansi
export ABC REPLAY LIBCELL GENLIB EMAP_DIR SYNTH_DIR OUT_DIR RESULT_DIR GRADUATE_DIR TIMEOUT

mapfile -t CASE_LIST < <(list_cases)
echo "hard-replay CEC: ${#CASE_LIST[@]} cases, jobs=$JOBS, root=$FAIR_ROOT"
echo "cases: ${CASE_LIST[*]}"

if [[ "$JOBS" -gt 1 ]]; then
  printf '%s\n' "${CASE_LIST[@]}" | xargs -P "$JOBS" -I{} bash -c 'run_one "$@"' _ {}
else
  for c in "${CASE_LIST[@]}"; do
    run_one "$c"
  done
fi

{
  echo "# Hard-replay CEC report"
  echo
  echo "- root: \`$FAIR_ROOT\`"
  echo "- emap subdir: \`$EMAP_SUBDIR\`"
  echo "- tool: \`graduate-map-hard-replay\` (M/MBIND → Verilog)"
  echo "- cec: \`read_genlib; read -m; read_aiger synth; cec\`"
  echo
  echo "| case | status | binding_instances |"
  echo "|------|--------|-------------------|"
  pass=0
  fail=0
  for c in "${CASE_LIST[@]}"; do
    line="$(cat "$RESULT_DIR/$c.line" 2>/dev/null || echo 'fail(missing)')"
    st="${line%% *}"
    bind="?"
    if [[ "$line" == *"bind="* ]]; then
      bind="${line##*bind=}"
    fi
    echo "| $c | $st | $bind |"
    if [[ "$st" == pass ]]; then
      pass=$((pass + 1))
    else
      fail=$((fail + 1))
    fi
  done
  echo
  echo "summary: $pass pass, $fail fail, ${#CASE_LIST[@]} total"
} >"$REPORT"

echo
cat "$REPORT"
[[ "$(grep -c '| pass |' "$REPORT" || true)" -eq "${#CASE_LIST[@]}" ]]
