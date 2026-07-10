#!/usr/bin/env bash
# See docs/SCRIPTS.md
# ABC balance synthesis (same as run_abc_syn_map.sh --flow balance) + emap -Y mapping.
#
# Synthesis / tech-independent optimization is identical to abc_syn_map_balance.abc.
# Only the mapping step differs: &nf -Y  vs  emap -Y.
#
# Examples:
#   ./scripts/run_abc_emap_map.sh --scale all --parallel
#   ./scripts/run_abc_emap_map.sh --cases "adder ctrl" --dump-level 1 --cec
#   ./scripts/run_abc_emap_map.sh --scale all --jobs 4 --dump-level 1
#
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GRADUATE_DIR="${GRADUATE_DIR:-$ROOT_DIR/third_party/GRADUATE}"
ABC="${GRADUATE_ABC:-$GRADUATE_DIR/build_abc_frontend/graduate-abc}"
LIBERTY="${GRADUATE_LIBERTY:-$GRADUATE_DIR/third_party/gradmap_libs/asap7.lib}"
BENCH_ROOT="${BENCH_ROOT:-$ROOT_DIR/third_party/benchmarks/EPFL}"
SUITE="${SUITE:-}"
SCALE="${SCALE:-}"
OUT_ROOT="${OUT_ROOT:-$ROOT_DIR/output/abc_emap_map_$(date +%Y%m%d_%H%M%S)}"
# Default: same EPFL arithmetic + random_control set as scale=all / prior balance run.
CASES="${CASES:-}"
CASES_EXPLICIT=0
TIMEOUT="${TIMEOUT:-600}"
DEEPSYN_ARGS="${DEEPSYN_ARGS:--T 120}"
USE_REC_START3="${USE_REC_START3:-0}"
REC_LIB="${GRADUATE_REC_LIB:-}"
JOBS="${JOBS:-1}"
GENLIB="${EMAP_GENLIB:-$ROOT_DIR/third_party/mockturtle/experiments/cell_libraries/multioutput.genlib}"
DUMP_LEVEL="${DUMP_LEVEL:-1}"
EMAP_FLAGS="${EMAP_FLAGS:--a -v}"
RUN_CEC=0

usage() {
  cat <<EOF
Usage: $0 [options]

Single ABC script (abc_emap_map.abc):
  1) Same balance synth as abc_syn_map_balance.abc
     (&if -y -K 6; resyn2; &deepsyn -T 120; strash)
  2) write_aiger synth.aig   (shared post-synth snapshot)
  3) emap -Y matches.nf_y_multi.txt -M <level> + write_verilog

Options:
  --scale tiny|small|medium|large|all
                                  [default if no --cases: all]
  --suite NAME                    EPFL subfolder when resolving cases by name
  --cases "a b c"                 benchmark base names (no .aig)
  --out DIR                       output root directory
  --timeout SEC                   per-case timeout [600]
  --jobs N / --parallel
  --rec-start3
  --genlib PATH                   multioutput GENLIB for emap
  --dump-level 1|2|3              emap -M level [1]
  --emap-flags STR                flags before -Y/-M [default: -a -v]
  --cec                           CEC mapped Verilog vs synth.aig
  -h, --help

Environment:
  GRADUATE_ABC, GRADUATE_LIBERTY, GRADUATE_REC_LIB, DEEPSYN_ARGS,
  EMAP_GENLIB, EMAP_FLAGS, BENCH_ROOT, JOBS

Examples:
  ./scripts/run_abc_emap_map.sh --scale all --parallel
  ./scripts/run_abc_emap_map.sh --cases "adder ctrl bar" --dump-level 1 --cec
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --scale) SCALE="$2"; shift 2 ;;
    --suite) SUITE="$2"; shift 2 ;;
    --cases) CASES="$2"; CASES_EXPLICIT=1; shift 2 ;;
    --out) OUT_ROOT="$2"; shift 2 ;;
    --timeout) TIMEOUT="$2"; shift 2 ;;
    --jobs) JOBS="$2"; shift 2 ;;
    --parallel) JOBS="$(nproc)"; shift ;;
    --rec-start3) USE_REC_START3=1; shift ;;
    --genlib) GENLIB="$2"; shift 2 ;;
    --dump-level) DUMP_LEVEL="$2"; shift 2 ;;
    --emap-flags) EMAP_FLAGS="$2"; shift 2 ;;
    --cec) RUN_CEC=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown option: $1" >&2; usage >&2; exit 1 ;;
  esac
done

if [[ "$CASES_EXPLICIT" != "1" ]]; then
  if [[ -z "$SCALE" ]]; then
    SCALE="all"
  fi
  CASES="$("$ROOT_DIR/scripts/list_epfl_benchmarks.sh" "$SCALE" | tr '\n' ' ')"
fi

if [[ ! "$DUMP_LEVEL" =~ ^[123]$ ]]; then
  echo "invalid --dump-level: $DUMP_LEVEL (want 1, 2, or 3)" >&2
  exit 1
fi

if [[ ! -x "$ABC" ]]; then
  echo "missing graduate-abc: $ABC" >&2
  echo "build with: cd $GRADUATE_DIR && ./scripts/build_abc_frontend.sh" >&2
  exit 1
fi
if [[ ! -f "$LIBERTY" ]]; then
  echo "missing liberty: $LIBERTY" >&2
  exit 1
fi
if [[ ! -f "$GENLIB" ]]; then
  echo "missing genlib: $GENLIB" >&2
  exit 1
fi
if ! [[ "$JOBS" =~ ^[1-9][0-9]*$ ]]; then
  echo "invalid --jobs value: $JOBS" >&2
  exit 1
fi

ABC_TEMPLATE="$ROOT_DIR/scripts/abc_emap_map.abc"
[[ -f "$ABC_TEMPLATE" ]] || { echo "missing $ABC_TEMPLATE" >&2; exit 1; }

REC_START3_LINE=""
if [[ "$USE_REC_START3" == "1" ]]; then
  if [[ -z "$REC_LIB" || ! -f "$REC_LIB" ]]; then
    echo "--rec-start3 requires GRADUATE_REC_LIB pointing to an existing .aig" >&2
    exit 1
  fi
  REC_START3_LINE="rec_start3 $REC_LIB"
fi

mkdir -p "$OUT_ROOT"
REPORT="$OUT_ROOT/report.md"

render_abc_script() {
  local input_aig="$1"
  local output_v="$2"
  local match_file="$3"
  local output_aig="$4"
  local rendered="$5"
  sed \
    -e "s|__INPUT_AIG__|$input_aig|g" \
    -e "s|__LIBERTY__|$LIBERTY|g" \
    -e "s|__GENLIB__|$GENLIB|g" \
    -e "s|__OUTPUT_V__|$output_v|g" \
    -e "s|__OUTPUT_AIG__|$output_aig|g" \
    -e "s|__MATCH_FILE__|$match_file|g" \
    -e "s|__DEEPSYN_ARGS__|$DEEPSYN_ARGS|g" \
    -e "s|__REC_START3__|${REC_START3_LINE}|g" \
    -e "s|__EMAP_FLAGS__|$EMAP_FLAGS|g" \
    -e "s|__DUMP_LEVEL__|$DUMP_LEVEL|g" \
    "$ABC_TEMPLATE" > "$rendered"
}

resolve_input() {
  local case_name="$1"
  if [[ -n "$SUITE" ]]; then
    local candidate="$BENCH_ROOT/$SUITE/${case_name}.aig"
    [[ -f "$candidate" ]] && { echo "$candidate"; return 0; }
  fi
  for suite in arithmetic random_control; do
    local candidate="$BENCH_ROOT/$suite/${case_name}.aig"
    [[ -f "$candidate" ]] && { echo "$candidate"; return 0; }
  done
  return 1
}

last_ps_line() {
  local log="$1"
  perl -pe 's/\e\[[0-9;]*[mK]//g' "$log" |
    grep -E 'i/o =|nd =|and =' |
    tail -n1 |
    sed 's/^[[:space:]]*//'
}

# Post-synth AIG stats: last line that still reports "and =" (before mapping).
post_synth_ps_line() {
  local log="$1"
  perl -pe 's/\e\[[0-9;]*[mK]//g' "$log" |
    grep -E 'and =' |
    tail -n1 |
    sed 's/^[[:space:]]*//'
}

write_report_line() {
  printf '%s\n' "$2" > "$OUT_ROOT/$1/report.line"
}

run_one_case() {
  local case_name="$1"
  local input=""
  if ! input="$(resolve_input "$case_name")"; then
    echo "skip $case_name: cannot find .aig under $BENCH_ROOT" >&2
    write_report_line "$case_name" "| \`$case_name\` | missing | | | | | | skip |"
    return 0
  fi

  local case_out="$OUT_ROOT/$case_name"
  mkdir -p "$case_out"
  local abc_script="$case_out/run.abc"
  local log="$case_out/run.log"
  local verilog="$case_out/${case_name}_emap.v"
  local match_file="$case_out/matches.nf_y_multi.txt"
  local synth_aig="$case_out/synth.aig"

  abc_script="$(cd "$(dirname "$abc_script")" && pwd)/$(basename "$abc_script")"
  log="$(cd "$(dirname "$log")" && pwd)/$(basename "$log")"
  verilog="$(cd "$(dirname "$verilog")" && pwd)/$(basename "$verilog")"
  match_file="$(cd "$(dirname "$match_file")" && pwd)/$(basename "$match_file")"
  synth_aig="$(cd "$(dirname "$synth_aig")" && pwd)/$(basename "$synth_aig")"

  echo "== $case_name =="
  render_abc_script "$input" "$verilog" "$match_file" "$synth_aig" "$abc_script"

  set +e
  timeout "$TIMEOUT" bash -c "cd \"$GRADUATE_DIR\" && \"$ABC\" -f \"$abc_script\"" > "$log" 2>&1
  local rc=$?
  set -e

  local n_m=0 n_mbind=0 n_bind=0
  if [[ -f "$match_file" ]]; then
    n_m="$(grep -c '^M[0-9]' "$match_file" || true)"
    n_mbind="$(grep -c '^MBIND ' "$match_file" || true)"
    n_bind="$(grep -c '^BIND ' "$match_file" || true)"
  fi

  local status="pass"
  if [[ "$rc" != 0 ]]; then
    status="fail(rc=$rc)"
  elif [[ ! -s "$verilog" ]]; then
    status="fail(no verilog)"
  elif [[ ! -s "$match_file" ]]; then
    status="fail(no match)"
  elif [[ ! -s "$synth_aig" ]]; then
    status="fail(no synth.aig)"
  fi

  local post_syn post_map
  post_syn="$(post_synth_ps_line "$log")"
  post_map="$(last_ps_line "$log")"

  local cec_status="n/a"
  if [[ "$RUN_CEC" == "1" && "$status" == pass ]]; then
    set +e
    timeout 120 bash -c "cd \"$GRADUATE_DIR\" && \"$ABC\" -c \"read -m \\\"$verilog\\\"; read_aiger \\\"$synth_aig\\\"; cec\"" > "$case_out/cec.log" 2>&1
    local cec_rc=$?
    set -e
    if [[ "$cec_rc" == "0" ]] && grep -q "Networks are equivalent" "$case_out/cec.log"; then
      cec_status="pass"
    else
      cec_status="fail"
      status="fail(cec)"
    fi
  fi

  echo "   status: $status"
  echo "   post-syn: ${post_syn:-n/a}"
  echo "   mapped:   ${post_map:-n/a}"
  echo "   match:    M=$n_m MBIND=$n_mbind BIND=$n_bind"
  if [[ "$RUN_CEC" == "1" ]]; then
    echo "   cec:      $cec_status"
  fi

  write_report_line "$case_name" "| \`$case_name\` | \`$input\` | ${post_syn:-n/a} | M=$n_m MBIND=$n_mbind BIND=$n_bind | ${post_map:-n/a} | \`$match_file\` | \`$verilog\` | $status |"
}

cat > "$REPORT" <<EOF
# ABC balance synth -> emap -Y

- date: $(date -Iseconds)
- compare_baseline: \`run_abc_syn_map.sh --flow balance\` (\`abc_syn_map_balance.abc\`)
- synth_identical: yes (\`&if -y -K 6\` + resyn2 + \`&deepsyn $DEEPSYN_ARGS\`)
- mapping: \`emap $EMAP_FLAGS -Y ... -M $DUMP_LEVEL\`
- scale: \`${SCALE:-<none>}\`
- suite: \`${SUITE:-<auto>}\`
- cases: \`$CASES\`
- jobs: \`$JOBS\`
- abc: \`$ABC\`
- liberty: \`$LIBERTY\`
- genlib: \`$GENLIB\`
- deepsyn: \`$DEEPSYN_ARGS\`
- dump_level: \`$DUMP_LEVEL\`
- out: \`$OUT_ROOT\`

| case | input | post-synth | match counts | post-map | match file | verilog | status |
| --- | --- | --- | --- | --- | --- | --- | --- |
EOF

echo "ABC balance synth -> emap -Y"
echo "  scale:       ${SCALE:-<none>}"
echo "  cases:       $CASES"
echo "  jobs:        $JOBS"
echo "  dump_level:  $DUMP_LEVEL"
echo "  emap_flags:  $EMAP_FLAGS"
echo "  deepsyn:     $DEEPSYN_ARGS"
echo "  out:         $OUT_ROOT"
echo "  abc:         $ABC"

if [[ "$JOBS" == "1" ]]; then
  for case_name in $CASES; do
    run_one_case "$case_name"
  done
else
  for case_name in $CASES; do
    while (( $(jobs -rp | wc -l) >= JOBS )); do
      sleep 0.2
    done
    run_one_case "$case_name" &
  done
  wait || true
fi

for case_name in $CASES; do
  fragment="$OUT_ROOT/$case_name/report.line"
  if [[ -f "$fragment" ]]; then
    cat "$fragment" >> "$REPORT"
  fi
done

echo
echo "report: $REPORT"
cat "$REPORT"
