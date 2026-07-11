#!/usr/bin/env bash
# See docs/SCRIPTS.md
# Fair &nf -Y vs emap -Y comparison on an identical post-synth AIG.
#
# Pipeline per case:
#   1) synth once  -> shared synth.aig   (or reuse existing)
#   2) map-only &nf -Y  from that AIG
#   3) map-only emap -Y from that AIG
#   4) Liberty stime compare via compare_nf_emap_map.sh
#
# Examples:
#   ./scripts/sh/run_fair_nf_emap_compare.sh --cases "adder ctrl" --jobs 4
#   ./scripts/sh/run_fair_nf_emap_compare.sh --scale all --parallel \
#     --reuse-synth-from output/abc_emap_map_20260710_162632
#   ./scripts/sh/run_fair_nf_emap_compare.sh --scale tiny --jobs 4  # fresh deepsyn
#
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
GRADUATE_DIR="${GRADUATE_DIR:-$ROOT_DIR/third_party/GRADUATE}"
ABC="${GRADUATE_ABC:-$GRADUATE_DIR/build_abc_frontend/graduate-abc}"
LIBERTY="${GRADUATE_LIBERTY:-$GRADUATE_DIR/third_party/gradmap_libs/asap7.lib}"
BENCH_ROOT="${BENCH_ROOT:-$ROOT_DIR/third_party/benchmarks/EPFL}"
SUITE="${SUITE:-}"
SCALE="${SCALE:-}"
OUT_ROOT="${OUT_ROOT:-$ROOT_DIR/output/fair_nf_emap_$(date +%Y%m%d_%H%M%S)}"
CASES="${CASES:-}"
CASES_EXPLICIT=0
TIMEOUT="${TIMEOUT:-600}"
SYNTH_TIMEOUT="${SYNTH_TIMEOUT:-}"
MAP_TIMEOUT="${MAP_TIMEOUT:-}"
DEEPSYN_ARGS="${DEEPSYN_ARGS:--T 120}"
USE_REC_START3="${USE_REC_START3:-0}"
REC_LIB="${GRADUATE_REC_LIB:-}"
JOBS="${JOBS:-1}"
GENLIB="${EMAP_GENLIB:-$ROOT_DIR/third_party/mockturtle/experiments/cell_libraries/multioutput.genlib}"
DUMP_LEVEL="${DUMP_LEVEL:-1}"
EMAP_FLAGS="${EMAP_FLAGS:--a -v}"
SO_DEDUP="${SO_DEDUP:-nf-like}"
SO_CUT_TOPK="${SO_CUT_TOPK:-16}"
REUSE_SYNTH_FROM=""
SKIP_COMPARE=0
FORCE_STIME=0
RUN_CEC=0

# shellcheck source=emap_so_policy_lib.sh
source "$ROOT_DIR/scripts/sh/emap_so_policy_lib.sh"

usage() {
  cat <<EOF
Usage: $0 [options]

Fair compare: one shared synth.aig per case, then map-only \`&nf -Y\` and \`emap -Y\`.

Options:
  --scale tiny|small|medium|large|all
                                  [default if no --cases: all]
  --suite NAME                    EPFL subfolder when resolving cases by name
  --cases "a b c"                 benchmark base names (no .aig)
  --out DIR                       output root
  --reuse-synth-from DIR          copy \`<case>/synth.aig\` from a prior run
                                  (skips \`&deepsyn\`; recommended for fair remap)
  --timeout SEC                   default timeout for synth and map [600]
  --synth-timeout SEC             override synth timeout
  --map-timeout SEC               override map timeout
  --jobs N / --parallel
  --rec-start3
  --genlib PATH
  --dump-level 1|2|3              emap -M [1]
  --emap-flags STR                [default: -a -v]
$(emap_so_policy_usage_lines)
  --cec                           CEC each mapped Verilog vs shared synth.aig
  --skip-compare                  skip Liberty stime markdown report
  --force-stime                   re-run stime even if cached
  -h, --help

Layout:
  <out>/synth/<case>/synth.aig
  <out>/nf/<case>/{run.log, <case>_nf.v, <case>.txt, synth.aig, synth_and.txt}
  <out>/emap/<case>/{run.log, <case>_emap.v, matches.nf_y_multi.txt, ...}
  <out>/compare_nf_emap.md

Examples:
  ./scripts/sh/run_fair_nf_emap_compare.sh --cases "adder ctrl" --jobs 4
  ./scripts/sh/run_fair_nf_emap_compare.sh --scale all --parallel \\
    --reuse-synth-from output/abc_emap_map_20260710_162632
  # Formal GradMap M3 policy:
  ./scripts/sh/run_fair_nf_emap_compare.sh --cases adder --dump-level 3 \\
    --reuse-synth-from output/fair_nf_emap_asap7genlib --skip-compare --cec
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --scale) SCALE="$2"; shift 2 ;;
    --suite) SUITE="$2"; shift 2 ;;
    --cases) CASES="$2"; CASES_EXPLICIT=1; shift 2 ;;
    --out) OUT_ROOT="$2"; shift 2 ;;
    --reuse-synth-from) REUSE_SYNTH_FROM="$2"; shift 2 ;;
    --timeout) TIMEOUT="$2"; shift 2 ;;
    --synth-timeout) SYNTH_TIMEOUT="$2"; shift 2 ;;
    --map-timeout) MAP_TIMEOUT="$2"; shift 2 ;;
    --jobs) JOBS="$2"; shift 2 ;;
    --parallel) JOBS="$(nproc)"; shift ;;
    --rec-start3) USE_REC_START3=1; shift ;;
    --genlib) GENLIB="$2"; shift 2 ;;
    --dump-level) DUMP_LEVEL="$2"; shift 2 ;;
    --emap-flags) EMAP_FLAGS="$2"; shift 2 ;;
    --so-dedup) SO_DEDUP="$2"; shift 2 ;;
    --so-cut-topk) SO_CUT_TOPK="$2"; shift 2 ;;
    --cec) RUN_CEC=1; shift ;;
    --skip-compare) SKIP_COMPARE=1; shift ;;
    --force-stime) FORCE_STIME=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown option: $1" >&2; usage >&2; exit 1 ;;
  esac
done

if [[ "$CASES_EXPLICIT" != "1" ]]; then
  if [[ -z "$SCALE" ]]; then
    SCALE="all"
  fi
  CASES="$("$ROOT_DIR/scripts/sh/list_epfl_benchmarks.sh" "$SCALE" | tr '\n' ' ')"
fi

SYNTH_TIMEOUT="${SYNTH_TIMEOUT:-$TIMEOUT}"
MAP_TIMEOUT="${MAP_TIMEOUT:-$TIMEOUT}"

if [[ ! "$DUMP_LEVEL" =~ ^[123]$ ]]; then
  echo "invalid --dump-level: $DUMP_LEVEL" >&2
  exit 1
fi

EMAP_FLAGS="$(emap_so_append_flags "$EMAP_FLAGS" "$SO_DEDUP" "$SO_CUT_TOPK")" || exit 1
if [[ ! -x "$ABC" ]]; then
  echo "missing graduate-abc: $ABC" >&2
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
  echo "invalid --jobs: $JOBS" >&2
  exit 1
fi
if [[ -n "$REUSE_SYNTH_FROM" && ! -d "$REUSE_SYNTH_FROM" ]]; then
  echo "missing --reuse-synth-from dir: $REUSE_SYNTH_FROM" >&2
  exit 1
fi

SYNTH_TEMPLATE="$ROOT_DIR/scripts/abc/abc_syn_balance.abc"
NF_TEMPLATE="$ROOT_DIR/scripts/abc/abc_map_nf_y.abc"
EMAP_TEMPLATE="$ROOT_DIR/scripts/abc/abc_map_emap_y.abc"
for t in "$SYNTH_TEMPLATE" "$NF_TEMPLATE" "$EMAP_TEMPLATE"; do
  [[ -f "$t" ]] || { echo "missing $t" >&2; exit 1; }
done

REC_START3_LINE=""
if [[ "$USE_REC_START3" == "1" ]]; then
  if [[ -z "$REC_LIB" || ! -f "$REC_LIB" ]]; then
    echo "--rec-start3 requires GRADUATE_REC_LIB" >&2
    exit 1
  fi
  REC_START3_LINE="rec_start3 $REC_LIB"
fi

if [[ -n "$REUSE_SYNTH_FROM" ]]; then
  REUSE_SYNTH_FROM="$(cd "$REUSE_SYNTH_FROM" && pwd)"
fi

mkdir -p "$OUT_ROOT"
OUT_ROOT="$(cd "$OUT_ROOT" && pwd)"
SYNTH_ROOT="$OUT_ROOT/synth"
NF_ROOT="$OUT_ROOT/nf"
EMAP_ROOT="$OUT_ROOT/emap"
mkdir -p "$SYNTH_ROOT" "$NF_ROOT" "$EMAP_ROOT"
REPORT="$OUT_ROOT/report.md"

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

abs_path() {
  local p="$1"
  echo "$(cd "$(dirname "$p")" && pwd)/$(basename "$p")"
}

count_and_from_aig() {
  local aig="$1" out_txt="$2"
  local tmp_log
  tmp_log="$(mktemp)"
  set +e
  bash -c "cd \"$GRADUATE_DIR\" && \"$ABC\" -c \"read_aiger \\\"$aig\\\"; strash; ps\"" >"$tmp_log" 2>&1
  local rc=$?
  set -e
  if [[ "$rc" != 0 ]]; then
    rm -f "$tmp_log"
    return 1
  fi
  perl -pe 's/\e\[[0-9;]*[mK]//g' "$tmp_log" | grep -E 'and =' | tail -n1 | \
    sed -n 's/.*and =[[:space:]]*\([0-9][0-9]*\).*/\1/p' > "$out_txt"
  rm -f "$tmp_log"
  [[ -s "$out_txt" ]]
}

ensure_synth() {
  local case_name="$1"
  local synth_dir="$SYNTH_ROOT/$case_name"
  local synth_aig="$synth_dir/synth.aig"
  mkdir -p "$synth_dir"

  if [[ -s "$synth_aig" ]]; then
    echo "  synth: reuse existing $synth_aig"
    return 0
  fi

  if [[ -n "$REUSE_SYNTH_FROM" ]]; then
    local src="$REUSE_SYNTH_FROM/$case_name/synth.aig"
    if [[ -s "$src" ]]; then
      cp -f "$src" "$synth_aig"
      echo "  synth: copied from $src"
      return 0
    fi
    echo "  synth: missing $src (will synthesize)" >&2
  fi

  local input=""
  if ! input="$(resolve_input "$case_name")"; then
    echo "  synth: cannot find input .aig for $case_name" >&2
    return 1
  fi

  local abc_script="$synth_dir/synth.abc"
  local log="$synth_dir/synth.log"
  input="$(abs_path "$input")"
  synth_aig="$(abs_path "$synth_aig")"
  abc_script="$(abs_path "$abc_script")"

  sed \
    -e "s|__INPUT_AIG__|$input|g" \
    -e "s|__OUTPUT_AIG__|$synth_aig|g" \
    -e "s|__LIBERTY__|$LIBERTY|g" \
    -e "s|__DEEPSYN_ARGS__|$DEEPSYN_ARGS|g" \
    -e "s|__REC_START3__|${REC_START3_LINE}|g" \
    "$SYNTH_TEMPLATE" > "$abc_script"

  echo "  synth: running deepsyn ($DEEPSYN_ARGS) ..."
  set +e
  timeout "$SYNTH_TIMEOUT" bash -c "cd \"$GRADUATE_DIR\" && \"$ABC\" -f \"$abc_script\"" > "$log" 2>&1
  local rc=$?
  set -e
  if [[ "$rc" != 0 || ! -s "$synth_aig" ]]; then
    echo "  synth: FAIL rc=$rc (log: $log)" >&2
    return 1
  fi
  echo "  synth: wrote $synth_aig"
  return 0
}

run_map_nf() {
  local case_name="$1" synth_aig="$2" and_count="$3"
  local case_dir="$NF_ROOT/$case_name"
  mkdir -p "$case_dir"
  local abc_script="$case_dir/run.abc"
  local log="$case_dir/run.log"
  local verilog="$case_dir/${case_name}_nf.v"
  local match_file="$case_dir/${case_name}.txt"
  local link_aig="$case_dir/synth.aig"

  cp -f "$synth_aig" "$link_aig"
  printf '%s\n' "$and_count" > "$case_dir/synth_and.txt"

  synth_aig="$(abs_path "$link_aig")"
  verilog="$(abs_path "$verilog")"
  match_file="$(abs_path "$match_file")"
  abc_script="$(abs_path "$abc_script")"

  sed \
    -e "s|__INPUT_AIG__|$synth_aig|g" \
    -e "s|__LIBERTY__|$LIBERTY|g" \
    -e "s|__MATCH_FILE__|$match_file|g" \
    -e "s|__OUTPUT_V__|$verilog|g" \
    "$NF_TEMPLATE" > "$abc_script"

  set +e
  timeout "$MAP_TIMEOUT" bash -c "cd \"$GRADUATE_DIR\" && \"$ABC\" -f \"$abc_script\"" > "$log" 2>&1
  local rc=$?
  set -e

  local status="pass"
  if [[ "$rc" != 0 ]]; then
    status="fail(rc=$rc)"
  elif [[ ! -s "$verilog" ]]; then
    status="fail(no verilog)"
  elif [[ ! -s "$match_file" ]]; then
    status="fail(no match)"
  fi

  if [[ "$RUN_CEC" == "1" && "$status" == pass ]]; then
    set +e
    timeout 120 bash -c "cd \"$GRADUATE_DIR\" && \"$ABC\" -c \"read -m \\\"$verilog\\\"; read_aiger \\\"$synth_aig\\\"; cec\"" \
      > "$case_dir/cec.log" 2>&1
    local cec_rc=$?
    set -e
    if [[ "$cec_rc" != 0 ]] || ! grep -q "Networks are equivalent" "$case_dir/cec.log"; then
      status="fail(cec)"
    fi
  fi
  echo "$status"
}

run_map_emap() {
  local case_name="$1" synth_aig="$2" and_count="$3"
  local case_dir="$EMAP_ROOT/$case_name"
  mkdir -p "$case_dir"
  local abc_script="$case_dir/run.abc"
  local log="$case_dir/run.log"
  local verilog="$case_dir/${case_name}_emap.v"
  local match_file="$case_dir/matches.nf_y_multi.txt"
  local link_aig="$case_dir/synth.aig"

  cp -f "$synth_aig" "$link_aig"
  printf '%s\n' "$and_count" > "$case_dir/synth_and.txt"

  synth_aig="$(abs_path "$link_aig")"
  verilog="$(abs_path "$verilog")"
  match_file="$(abs_path "$match_file")"
  abc_script="$(abs_path "$abc_script")"

  sed \
    -e "s|__INPUT_AIG__|$synth_aig|g" \
    -e "s|__GENLIB__|$GENLIB|g" \
    -e "s|__MATCH_FILE__|$match_file|g" \
    -e "s|__OUTPUT_V__|$verilog|g" \
    -e "s|__EMAP_FLAGS__|$EMAP_FLAGS|g" \
    -e "s|__DUMP_LEVEL__|$DUMP_LEVEL|g" \
    "$EMAP_TEMPLATE" > "$abc_script"

  set +e
  timeout "$MAP_TIMEOUT" bash -c "cd \"$GRADUATE_DIR\" && \"$ABC\" -f \"$abc_script\"" > "$log" 2>&1
  local rc=$?
  set -e

  local status="pass"
  if [[ "$rc" != 0 ]]; then
    status="fail(rc=$rc)"
  elif [[ ! -s "$verilog" ]]; then
    status="fail(no verilog)"
  elif [[ ! -s "$match_file" ]]; then
    status="fail(no match)"
  fi

  if [[ "$RUN_CEC" == "1" && "$status" == pass ]]; then
    set +e
    timeout 120 bash -c "cd \"$GRADUATE_DIR\" && \"$ABC\" -c \"read -m \\\"$verilog\\\"; read_aiger \\\"$synth_aig\\\"; cec\"" \
      > "$case_dir/cec.log" 2>&1
    local cec_rc=$?
    set -e
    if [[ "$cec_rc" != 0 ]] || ! grep -q "Networks are equivalent" "$case_dir/cec.log"; then
      status="fail(cec)"
    fi
  fi
  echo "$status"
}

write_report_line() {
  printf '%s\n' "$2" > "$OUT_ROOT/$1.report.line"
}

run_one_case() {
  local case_name="$1"
  echo "== $case_name =="

  if ! ensure_synth "$case_name"; then
    write_report_line "$case_name" "| \`$case_name\` | | | synth-fail | | |"
    return 0
  fi

  local synth_aig="$SYNTH_ROOT/$case_name/synth.aig"
  local and_file="$SYNTH_ROOT/$case_name/synth_and.txt"
  if [[ ! -s "$and_file" ]]; then
    if ! count_and_from_aig "$synth_aig" "$and_file"; then
      echo "  FAIL: cannot count AND from $synth_aig" >&2
      write_report_line "$case_name" "| \`$case_name\` | | | and-fail | | |"
      return 0
    fi
  fi
  local and_count
  and_count="$(tr -d '[:space:]' < "$and_file")"
  echo "  shared AND: $and_count"

  local nf_status em_status
  nf_status="$(run_map_nf "$case_name" "$synth_aig" "$and_count")"
  em_status="$(run_map_emap "$case_name" "$synth_aig" "$and_count")"
  echo "  nf:   $nf_status"
  echo "  emap: $em_status"

  local mbind=0
  if [[ -f "$EMAP_ROOT/$case_name/matches.nf_y_multi.txt" ]]; then
    mbind="$(grep -c '^MBIND ' "$EMAP_ROOT/$case_name/matches.nf_y_multi.txt" || true)"
  fi

  write_report_line "$case_name" \
    "| \`$case_name\` | $and_count | $mbind | $nf_status | $em_status | \`$synth_aig\` |"
}

cat > "$REPORT" <<EOF
# Fair &nf -Y vs emap -Y (shared synth.aig)

- date: $(date -Iseconds)
- scale: \`${SCALE:-<none>}\`
- cases: \`$CASES\`
- jobs: \`$JOBS\`
- reuse_synth_from: \`${REUSE_SYNTH_FROM:-<none; fresh deepsyn>}\`
- deepsyn: \`$DEEPSYN_ARGS\`
- emap_flags: \`$EMAP_FLAGS\`
- dump_level: \`$DUMP_LEVEL\`
- so_dedup: \`$SO_DEDUP\`
- so_cut_topk: \`$SO_CUT_TOPK\`
- abc: \`$ABC\`
- liberty: \`$LIBERTY\`
- genlib: \`$GENLIB\`
- out: \`$OUT_ROOT\`

| case | shared AND | MBIND | nf status | emap status | synth.aig |
| --- | ---: | ---: | --- | --- | --- |
EOF

echo "Fair nf vs emap compare"
echo "  cases:            $CASES"
echo "  jobs:             $JOBS"
echo "  reuse_synth_from: ${REUSE_SYNTH_FROM:-<none>}"
echo "  out:              $OUT_ROOT"

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
  fragment="$OUT_ROOT/$case_name.report.line"
  if [[ -f "$fragment" ]]; then
    cat "$fragment" >> "$REPORT"
    rm -f "$fragment"
  fi
done

echo
echo "report: $REPORT"

if [[ "$SKIP_COMPARE" != "1" ]]; then
  cmp_args=(
    --nf-dir "$NF_ROOT"
    --emap-dir "$EMAP_ROOT"
    --out "$OUT_ROOT/compare_nf_emap.md"
    --liberty "$LIBERTY"
    --jobs "$JOBS"
    --cases "$CASES"
  )
  if [[ "$FORCE_STIME" == "1" ]]; then
    cmp_args+=(--force-stime)
  fi
  echo "Running Liberty STA compare ..."
  "$ROOT_DIR/scripts/sh/compare_nf_emap_map.sh" "${cmp_args[@]}"
fi

echo
echo "done."
echo "  report:  $REPORT"
echo "  compare: $OUT_ROOT/compare_nf_emap.md"
