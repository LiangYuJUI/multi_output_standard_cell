#!/usr/bin/env bash
# See docs/SCRIPTS.md
# ABC balance synthesis -> mockturtle emap multi-output technology mapping.
#
# Phase 1: graduate-abc balance synth only (no &nf), writes synth.aig
# Phase 2: mo_techmap maps synth.aig with multioutput.genlib -> mapped.v
#
# This matches run_abc_syn_map.sh --flow balance minus the &nf -Y mapping step.
#
# Examples:
#   ./scripts/run_abc_mockturtle_map.sh --cases adder
#   ./scripts/run_abc_mockturtle_map.sh --scale tiny --parallel
#   ./scripts/run_abc_mockturtle_map.sh --build-mo-techmap --cases adder bar
#
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GRADUATE_DIR="${GRADUATE_DIR:-$ROOT_DIR/third_party/GRADUATE}"
ABC="${GRADUATE_ABC:-$GRADUATE_DIR/build_abc_frontend/graduate-abc}"
LIBERTY="${GRADUATE_LIBERTY:-$GRADUATE_DIR/third_party/gradmap_libs/asap7.lib}"
BENCH_ROOT="${BENCH_ROOT:-$ROOT_DIR/third_party/benchmarks/EPFL}"
SUITE="${SUITE:-}"
SCALE="${SCALE:-}"
OUT_ROOT="${OUT_ROOT:-$ROOT_DIR/output/abc_mockturtle_map_$(date +%Y%m%d_%H%M%S)}"
CASES="${CASES:-adder bar ctrl}"
CASES_EXPLICIT=0
TIMEOUT="${TIMEOUT:-600}"
DEEPSYN_ARGS="${DEEPSYN_ARGS:--T 120}"
USE_REC_START3="${USE_REC_START3:-0}"
REC_LIB="${GRADUATE_REC_LIB:-}"
JOBS="${JOBS:-1}"
MO_TECHMAP="${MO_TECHMAP:-$ROOT_DIR/build/mo_techmap}"
GENLIB="${MO_GENLIB:-$ROOT_DIR/third_party/mockturtle/experiments/cell_libraries/multioutput.genlib}"
BUILD_MO_TECHMAP=0
SKIP_SYNTH=0
MAP_ONLY=0
DELAY_ORIENTED=0
NO_MULTIOUTPUT=0
RUN_CEC=0

usage() {
  cat <<EOF
Usage: $0 [options]

Pipeline:
  1) ABC balance synthesis -> synth.aig (no &nf mapping)
  2) mockturtle emap (mo_techmap) -> mapped.v + stats.txt

Options:
  --scale tiny|small|medium|large|all
                                  load case names from data/epfl/<scale>.yaml
  --suite NAME                    EPFL subfolder when resolving cases by name
  --cases "a b c"                 benchmark base names (no .aig) [adder bar ctrl]
  --out DIR                       output root directory
  --timeout SEC                   per-case ABC timeout [600]
  --jobs N                        run up to N cases in parallel [1]
  --parallel                      shorthand for --jobs <nproc>
  --rec-start3                    enable rec_start3 before synthesis
  --build-mo-techmap              cmake/build mo_techmap if missing
  --mo-techmap PATH               mo_techmap binary [build/mo_techmap]
  --genlib PATH                   GENLIB for emap [mockturtle multioutput.genlib]
  --skip-synth                    skip ABC if synth.aig already exists
  --map-only                      only run mo_techmap (requires existing synth.aig)
  --delay-oriented                delay-oriented emap (default: area-oriented)
  --no-multioutput                disable multi-output cell mapping
  --cec                           run graduate-abc cec after mapping
  -h, --help                      show this help

Environment:
  GRADUATE_ABC, GRADUATE_LIBERTY, GRADUATE_REC_LIB, DEEPSYN_ARGS, BENCH_ROOT,
  MO_TECHMAP, MO_GENLIB, JOBS

Examples:
  ./scripts/run_abc_mockturtle_map.sh --build-mo-techmap --cases adder
  ./scripts/run_abc_mockturtle_map.sh --scale tiny --parallel
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
    --build-mo-techmap) BUILD_MO_TECHMAP=1; shift ;;
    --mo-techmap) MO_TECHMAP="$2"; shift 2 ;;
    --genlib) GENLIB="$2"; shift 2 ;;
    --skip-synth) SKIP_SYNTH=1; shift ;;
    --map-only) MAP_ONLY=1; SKIP_SYNTH=1; shift ;;
    --delay-oriented) DELAY_ORIENTED=1; shift ;;
    --no-multioutput) NO_MULTIOUTPUT=1; shift ;;
    --cec) RUN_CEC=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown option: $1" >&2; usage >&2; exit 1 ;;
  esac
done

if [[ -n "$SCALE" && "$CASES_EXPLICIT" != "1" ]]; then
  CASES="$("$ROOT_DIR/scripts/list_epfl_benchmarks.sh" "$SCALE" | tr '\n' ' ')"
fi

if [[ "$MAP_ONLY" != "1" ]]; then
  if [[ ! -x "$ABC" ]]; then
    echo "missing graduate-abc: $ABC" >&2
    echo "build with: cd $GRADUATE_DIR && ./scripts/build_abc_frontend.sh" >&2
    exit 1
  fi
  if [[ ! -f "$LIBERTY" ]]; then
    echo "missing liberty: $LIBERTY" >&2
    exit 1
  fi
fi

if [[ ! -f "$GENLIB" ]]; then
  echo "missing genlib: $GENLIB" >&2
  exit 1
fi

if [[ ! -x "$MO_TECHMAP" ]]; then
  if [[ "$BUILD_MO_TECHMAP" == "1" ]]; then
    echo "building mo_techmap..."
    cmake -S "$ROOT_DIR" -B "$ROOT_DIR/build" -DCMAKE_BUILD_TYPE=Release
    cmake --build "$ROOT_DIR/build" -j"$(nproc)" --target mo_techmap
    MO_TECHMAP="$ROOT_DIR/build/mo_techmap"
  else
    echo "missing mo_techmap: $MO_TECHMAP" >&2
    echo "build with: cmake -S $ROOT_DIR -B $ROOT_DIR/build && cmake --build $ROOT_DIR/build -j mo_techmap" >&2
    echo "or pass --build-mo-techmap" >&2
    exit 1
  fi
fi

if ! [[ "$JOBS" =~ ^[1-9][0-9]*$ ]]; then
  echo "invalid --jobs value: $JOBS" >&2
  exit 1
fi

ABC_TEMPLATE="$ROOT_DIR/scripts/abc_syn_balance.abc"
if [[ "$MAP_ONLY" != "1" && ! -f "$ABC_TEMPLATE" ]]; then
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

mkdir -p "$OUT_ROOT"
REPORT="$OUT_ROOT/report.md"

render_abc_script() {
  local input_aig="$1"
  local output_aig="$2"
  local rendered="$3"
  sed \
    -e "s|__INPUT_AIG__|$input_aig|g" \
    -e "s|__LIBERTY__|$LIBERTY|g" \
    -e "s|__OUTPUT_AIG__|$output_aig|g" \
    -e "s|__DEEPSYN_ARGS__|$DEEPSYN_ARGS|g" \
    -e "s|__REC_START3__|${REC_START3_LINE}|g" \
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

read_stats_field() {
  local stats_file="$1"
  local key="$2"
  if [[ -f "$stats_file" ]]; then
    grep -E "^${key}=" "$stats_file" | tail -n1 | cut -d= -f2-
  fi
}

write_report_line() {
  local case_name="$1"
  local line="$2"
  printf '%s\n' "$line" > "$OUT_ROOT/$case_name/report.line"
}

run_one_case() {
  local case_name="$1"
  local case_out="$OUT_ROOT/$case_name"
  mkdir -p "$case_out"

  local input=""
  if [[ "$MAP_ONLY" != "1" ]]; then
    if ! input="$(resolve_input "$case_name")"; then
      echo "skip $case_name: cannot find .aig under $BENCH_ROOT" >&2
      write_report_line "$case_name" "| \`$case_name\` | missing | | | | | | skip |"
      return 0
    fi
  fi

  local synth_aig="$case_out/synth.aig"
  local mapped_v="$case_out/${case_name}_mo_mapped.v"
  local stats="$case_out/stats.txt"
  local abc_script="$case_out/synth.abc"
  local synth_log="$case_out/synth.log"
  local map_log="$case_out/map.log"

  synth_aig="$(cd "$(dirname "$synth_aig")" && pwd)/$(basename "$synth_aig")"
  mapped_v="$(cd "$(dirname "$mapped_v")" && pwd)/$(basename "$mapped_v")"
  stats="$(cd "$(dirname "$stats")" && pwd)/$(basename "$stats")"

  echo "== $case_name =="

  local synth_status="skip"
  local post_syn="n/a"
  if [[ "$SKIP_SYNTH" != "1" || ! -s "$synth_aig" ]]; then
    render_abc_script "$input" "$synth_aig" "$abc_script"
    set +e
    timeout "$TIMEOUT" bash -c "cd \"$GRADUATE_DIR\" && \"$ABC\" -f \"$abc_script\"" > "$synth_log" 2>&1
    local synth_rc=$?
    set -e
    post_syn="$(last_ps_line "$synth_log" | head -n1)"
    if [[ "$synth_rc" != "0" ]]; then
      synth_status="fail(rc=$synth_rc)"
    elif [[ ! -s "$synth_aig" ]]; then
      synth_status="fail(no synth.aig)"
    else
      synth_status="pass"
    fi
    echo "   synth:  $synth_status (${post_syn:-n/a})"
  else
    synth_status="cached"
    echo "   synth:  cached ($synth_aig)"
  fi

  local map_status="skip"
  local area_after delay_after mo_gates runtime_sec
  if [[ "$synth_status" == pass* || "$synth_status" == cached ]]; then
    local map_args=(
      "$MO_TECHMAP"
      --aig "$synth_aig"
      --genlib "$GENLIB"
      --out "$mapped_v"
      --stats "$stats"
    )
    if [[ "$DELAY_ORIENTED" == "1" ]]; then
      map_args+=(--delay-oriented)
    fi
    if [[ "$NO_MULTIOUTPUT" == "1" ]]; then
      map_args+=(--no-multioutput)
    fi

    set +e
    "${map_args[@]}" > "$map_log" 2>&1
    local map_rc=$?
    set -e

    area_after="$(read_stats_field "$stats" area_after)"
    delay_after="$(read_stats_field "$stats" delay_after)"
    mo_gates="$(read_stats_field "$stats" multioutput_gates)"
    runtime_sec="$(read_stats_field "$stats" runtime_sec)"

    if [[ "$map_rc" != "0" ]]; then
      map_status="fail(rc=$map_rc)"
    elif [[ ! -s "$mapped_v" ]]; then
      map_status="fail(no verilog)"
    else
      map_status="pass"
    fi
    echo "   map:    $map_status (mo=$mo_gates area=${area_after:-n/a} delay=${delay_after:-n/a})"
  fi

  local cec_status="n/a"
  if [[ "$RUN_CEC" == "1" && "$map_status" == pass ]]; then
    set +e
    timeout 120 bash -c "cd \"$GRADUATE_DIR\" && \"$ABC\" -c \"read -m \\\"$mapped_v\\\"; read_aiger \\\"$synth_aig\\\"; cec\"" > "$case_out/cec.log" 2>&1
    local cec_rc=$?
    set -e
    if [[ "$cec_rc" == "0" ]] && grep -q "Networks are equivalent" "$case_out/cec.log"; then
      cec_status="pass"
    else
      cec_status="fail"
    fi
    echo "   cec:    $cec_status"
  fi

  local overall="$map_status"
  if [[ "$synth_status" != pass* && "$synth_status" != cached ]]; then
    overall="$synth_status"
  elif [[ "$map_status" != pass ]]; then
    overall="$map_status"
  elif [[ "$RUN_CEC" == "1" && "$cec_status" != pass ]]; then
    overall="fail(cec)"
  fi

  write_report_line "$case_name" "| \`$case_name\` | \`${input:-cached}\` | ${post_syn:-n/a} | \`$synth_aig\` | ${area_after:-n/a} | ${delay_after:-n/a} | ${mo_gates:-n/a} | ${runtime_sec:-n/a} | \`$mapped_v\` | $overall |"
}

cat > "$REPORT" <<EOF
# ABC balance synth -> mockturtle emap

- date: $(date -Iseconds)
- scale: \`${SCALE:-<none>}\`
- suite: \`${SUITE:-<auto>}\`
- cases: \`$CASES\`
- jobs: \`$JOBS\`
- abc: \`$ABC\`
- liberty: \`$LIBERTY\`
- deepsyn: \`$DEEPSYN_ARGS\`
- mo_techmap: \`$MO_TECHMAP\`
- genlib: \`$GENLIB\`
- map_multioutput: \`$([[ "$NO_MULTIOUTPUT" == "1" ]] && echo false || echo true)\`
- area_oriented: \`$([[ "$DELAY_ORIENTED" == "1" ]] && echo false || echo true)\`
- out: \`$OUT_ROOT\`

| case | input | post-synth | synth.aig | area | delay | mo_gates | map_sec | verilog | status |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
EOF

echo "ABC balance synth -> mockturtle emap"
echo "  scale:   ${SCALE:-<none>}"
echo "  cases:   $CASES"
echo "  jobs:    $JOBS"
echo "  out:     $OUT_ROOT"
echo "  abc:     $ABC"
echo "  mo_map:  $MO_TECHMAP"
echo "  genlib:  $GENLIB"

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
