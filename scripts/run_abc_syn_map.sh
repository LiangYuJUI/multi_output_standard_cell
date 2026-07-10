#!/usr/bin/env bash
# See docs/SCRIPTS.md
# Run ABC synthesis -> technology mapping on EPFL (or other) .aig benchmarks.
#
# Flows:
#   resyn2   traditional ABC resyn2 + &nf mapping (Verilog baseline)
#   deepsyn  &deepsyn + &nf mapping (Verilog baseline)
#   balance  legacy balance flow: &if + resyn2 + deepsyn + &nf -Y match dump + Verilog
#
# Examples:
#   ./scripts/run_abc_syn_map.sh --flow balance --scale all --parallel
#   ./scripts/run_abc_syn_map.sh --flow balance --scale tiny --jobs 4
#   ./scripts/run_abc_syn_map.sh --flow resyn2 --cases "adder bar"
#
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GRADUATE_DIR="${GRADUATE_DIR:-$ROOT_DIR/third_party/GRADUATE}"
ABC="${GRADUATE_ABC:-$GRADUATE_DIR/build_abc_frontend/graduate-abc}"
LIBERTY="${GRADUATE_LIBERTY:-$GRADUATE_DIR/third_party/gradmap_libs/asap7.lib}"
BENCH_ROOT="${BENCH_ROOT:-$ROOT_DIR/third_party/benchmarks/EPFL}"
SUITE="${SUITE:-}"
FLOW="${FLOW:-resyn2}"
SCALE="${SCALE:-}"
OUT_ROOT="${OUT_ROOT:-$ROOT_DIR/output/abc_syn_map_$(date +%Y%m%d_%H%M%S)}"
CASES="${CASES:-adder bar ctrl}"
CASES_EXPLICIT=0
TIMEOUT="${TIMEOUT:-600}"
DEEPSYN_ARGS="${DEEPSYN_ARGS:-}"
USE_REC_START3="${USE_REC_START3:-0}"
USE_IF_PREPROCESS="${USE_IF_PREPROCESS:-0}"
REC_LIB="${GRADUATE_REC_LIB:-}"
JOBS="${JOBS:-1}"

usage() {
  cat <<EOF
Usage: $0 [options]

Flows:
  resyn2    traditional resyn2 synthesis + &nf mapping
  deepsyn   &deepsyn synthesis + &nf mapping
  balance   legacy balance flow: &if + resyn2 + deepsyn + &nf -Y match dump + Verilog

Options:
  --flow resyn2|deepsyn|balance   synthesis/mapping backend [resyn2]
  --scale tiny|small|medium|large|all
                                  load case names from data/epfl/<scale>.yaml
  --suite NAME                    EPFL subfolder when resolving cases by name
  --cases "a b c"                 benchmark base names (no .aig)
  --out DIR                       output root directory
  --timeout SEC                   per-case command timeout [600]
  --jobs N                        run up to N cases in parallel [1]
  --parallel                      shorthand for --jobs <nproc>
  --rec-start3                    enable rec_start3 before mapping
  --if-preprocess                 deepsyn only: &if + resyn2 before &deepsyn
  -h, --help                      show this help

Environment:
  GRADUATE_ABC, GRADUATE_LIBERTY, GRADUATE_REC_LIB, DEEPSYN_ARGS, BENCH_ROOT, JOBS

Examples:
  ./scripts/run_abc_syn_map.sh --flow balance --scale all --parallel
  ./scripts/run_abc_syn_map.sh --flow balance --scale tiny --jobs 4
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --flow) FLOW="$2"; shift 2 ;;
    --scale) SCALE="$2"; shift 2 ;;
    --suite) SUITE="$2"; shift 2 ;;
    --cases) CASES="$2"; CASES_EXPLICIT=1; shift 2 ;;
    --out) OUT_ROOT="$2"; shift 2 ;;
    --timeout) TIMEOUT="$2"; shift 2 ;;
    --jobs) JOBS="$2"; shift 2 ;;
    --parallel) JOBS="$(nproc)"; shift ;;
    --rec-start3) USE_REC_START3=1; shift ;;
    --if-preprocess) USE_IF_PREPROCESS=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown option: $1" >&2; usage >&2; exit 1 ;;
  esac
done

if [[ -n "$SCALE" && "$CASES_EXPLICIT" != "1" ]]; then
  CASES="$("$ROOT_DIR/scripts/list_epfl_benchmarks.sh" "$SCALE" | tr '\n' ' ')"
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
if ! [[ "$JOBS" =~ ^[1-9][0-9]*$ ]]; then
  echo "invalid --jobs value: $JOBS" >&2
  exit 1
fi

case "$FLOW" in
  resyn2) ABC_TEMPLATE="$ROOT_DIR/scripts/abc_syn_map_resyn2.abc" ;;
  deepsyn) ABC_TEMPLATE="$ROOT_DIR/scripts/abc_syn_map_deepsyn.abc" ;;
  balance) ABC_TEMPLATE="$ROOT_DIR/scripts/abc_syn_map_balance.abc" ;;
  *)
    echo "unsupported flow: $FLOW (use resyn2, deepsyn, or balance)" >&2
    exit 1
    ;;
esac

if [[ -z "$DEEPSYN_ARGS" ]]; then
  case "$FLOW" in
    balance) DEEPSYN_ARGS="-T 120" ;;
    deepsyn) DEEPSYN_ARGS="-I 1 -M 10 -S 0" ;;
  esac
fi

if [[ ! -f "$ABC_TEMPLATE" ]]; then
  echo "missing abc script: $ABC_TEMPLATE" >&2
  exit 1
fi

REC_START3_LINE=""
if [[ "$USE_REC_START3" == "1" ]]; then
  if [[ -z "$REC_LIB" || ! -f "$REC_LIB" ]]; then
    echo "--rec-start3 requires GRADUATE_REC_LIB pointing to an existing .aig" >&2
    exit 1
  fi
  REC_START3_LINE="rec_start3 $REC_LIB"
fi

PRE_DEEPSYN_LINE=""
if [[ "$USE_IF_PREPROCESS" == "1" ]]; then
  PRE_DEEPSYN_LINE="&if -y -K 6; &put; resyn2; resyn2; &get"
fi

mkdir -p "$OUT_ROOT"
REPORT="$OUT_ROOT/report.md"
DUMP_MATCH=0
if [[ "$FLOW" == "balance" ]]; then
  DUMP_MATCH=1
fi

render_abc_script() {
  local input_aig="$1"
  local output_v="$2"
  local match_file="$3"
  local rendered="$4"
  local output_aig="${5:-}"
  sed \
    -e "s|__INPUT_AIG__|$input_aig|g" \
    -e "s|__LIBERTY__|$LIBERTY|g" \
    -e "s|__OUTPUT_V__|$output_v|g" \
    -e "s|__OUTPUT_AIG__|${output_aig}|g" \
    -e "s|__MATCH_FILE__|$match_file|g" \
    -e "s|__DEEPSYN_ARGS__|$DEEPSYN_ARGS|g" \
    -e "s|__REC_START3__|${REC_START3_LINE}|g" \
    -e "s|__PRE_DEEPSYN__|${PRE_DEEPSYN_LINE}|g" \
    "$ABC_TEMPLATE" > "$rendered"
}

resolve_input() {
  local case_name="$1"
  if [[ -n "$SUITE" ]]; then
    local candidate="$BENCH_ROOT/$SUITE/${case_name}.aig"
    if [[ -f "$candidate" ]]; then
      echo "$candidate"
      return 0
    fi
  fi
  for suite in arithmetic random_control; do
    local candidate="$BENCH_ROOT/$suite/${case_name}.aig"
    if [[ -f "$candidate" ]]; then
      echo "$candidate"
      return 0
    fi
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

last_stime_line() {
  local log="$1"
  perl -pe 's/\e\[[0-9;]*[mK]//g' "$log" |
    grep -E 'Gates =|Area =|Delay =' |
    tail -n1 |
    sed 's/^[[:space:]]*//'
}

write_report_line() {
  local case_name="$1"
  local line="$2"
  local fragment="$OUT_ROOT/$case_name/report.line"
  printf '%s\n' "$line" > "$fragment"
}

run_one_case() {
  local case_name="$1"

  if ! input="$(resolve_input "$case_name")"; then
    echo "skip $case_name: cannot find .aig under $BENCH_ROOT" >&2
    if [[ "$DUMP_MATCH" == "1" ]]; then
      write_report_line "$case_name" "| \`$case_name\` | missing | | | | | skip |"
    else
      write_report_line "$case_name" "| \`$case_name\` | missing | | | | skip |"
    fi
    return 0
  fi

  local case_out="$OUT_ROOT/$case_name"
  mkdir -p "$case_out"
  local abc_script="$case_out/run.abc"
  local log="$case_out/run.log"
  local verilog="$case_out/${case_name}_${FLOW}.v"
  local match_file="$case_out/${case_name}.txt"
  local synth_aig="$case_out/synth.aig"

  abc_script="$(cd "$(dirname "$abc_script")" && pwd)/$(basename "$abc_script")"
  log="$(cd "$(dirname "$log")" && pwd)/$(basename "$log")"
  verilog="$(cd "$(dirname "$verilog")" && pwd)/$(basename "$verilog")"
  match_file="$(cd "$(dirname "$match_file")" && pwd)/$(basename "$match_file")"
  synth_aig="$(cd "$(dirname "$synth_aig")" && pwd)/$(basename "$synth_aig")"

  echo "== $case_name =="
  render_abc_script "$input" "$verilog" "$match_file" "$abc_script" "$synth_aig"

  set +e
  timeout "$TIMEOUT" bash -c "cd \"$GRADUATE_DIR\" && \"$ABC\" -f \"$abc_script\"" > "$log" 2>&1
  local rc=$?
  set -e

  local status="pass"
  if [[ "$rc" != 0 ]]; then
    status="fail(rc=$rc)"
  elif [[ ! -s "$verilog" ]]; then
    status="fail(no verilog)"
  elif [[ "$DUMP_MATCH" == "1" && ! -s "$match_file" ]]; then
    status="fail(no match)"
  fi

  local post_syn mapped
  post_syn="$(last_ps_line "$log" | head -n1)"
  mapped="$(last_stime_line "$log")"
  echo "   status: $status"
  echo "   mapped: ${mapped:-n/a}"
  if [[ "$DUMP_MATCH" == "1" ]]; then
    echo "   match:  $match_file"
    write_report_line "$case_name" "| \`$case_name\` | \`$input\` | ${post_syn:-n/a} | ${mapped:-n/a} | \`$match_file\` | \`$verilog\` | $status |"
  else
    write_report_line "$case_name" "| \`$case_name\` | \`$input\` | ${post_syn:-n/a} | ${mapped:-n/a} | \`$verilog\` | $status |"
  fi
}

if [[ "$DUMP_MATCH" == "1" ]]; then
  REPORT_HEADER="| case | input | post-synth | mapped (stime) | match | verilog | status |"
  REPORT_SEP="| --- | --- | --- | --- | --- | --- | --- |"
else
  REPORT_HEADER="| case | input | post-synth | mapped (stime) | verilog | status |"
  REPORT_SEP="| --- | --- | --- | --- | --- | --- |"
fi

cat > "$REPORT" <<EOF
# ABC synthesis -> mapping

- date: $(date -Iseconds)
- flow: \`$FLOW\`
- scale: \`${SCALE:-<none>}\`
- suite: \`${SUITE:-<auto>}\`
- cases: \`$CASES\`
- jobs: \`$JOBS\`
- abc: \`$ABC\`
- liberty: \`$LIBERTY\`
- deepsyn: \`${DEEPSYN_ARGS:-<n/a>}\`
- out: \`$OUT_ROOT\`

$REPORT_HEADER
$REPORT_SEP
EOF

echo "ABC syn -> map"
echo "  flow:    $FLOW"
echo "  scale:   ${SCALE:-<none>}"
echo "  suite:   ${SUITE:-<auto>}"
echo "  cases:   $CASES"
echo "  jobs:    $JOBS"
echo "  out:     $OUT_ROOT"
echo "  abc:     $ABC"
if [[ -n "$DEEPSYN_ARGS" ]]; then
  echo "  deepsyn: $DEEPSYN_ARGS"
fi

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
