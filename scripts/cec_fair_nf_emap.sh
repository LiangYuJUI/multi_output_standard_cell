#!/usr/bin/env bash
# See docs/SCRIPTS.md
# CEC existing fair-compare mapped Verilog against shared synth.aig.
#
# Checks (per case):
#   nf/<case>/*_nf.v          vs synth/<case>/synth.aig
#   emap/<case>/*_emap.v      vs synth/<case>/synth.aig
#     (emap FA/HA twins merged via scripts/merge_emap_twins.py first)
#
# Does NOT remap; only verifies gate-level netlists already on disk.
#
# Examples:
#   ./scripts/cec_fair_nf_emap.sh
#   ./scripts/cec_fair_nf_emap.sh --root output/fair_nf_emap_asap7genlib --jobs 8
#   ./scripts/cec_fair_nf_emap.sh --emap-subdir emap_l1 --cases "adder square"
#
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GRADUATE_DIR="${GRADUATE_DIR:-$ROOT_DIR/third_party/GRADUATE}"
ABC="${GRADUATE_ABC:-$GRADUATE_DIR/build_abc_frontend/graduate-abc}"
LIBERTY="${GRADUATE_LIBERTY:-$GRADUATE_DIR/third_party/gradmap_libs/asap7.lib}"
GENLIB="${EMAP_GENLIB:-$GRADUATE_DIR/third_party/gradmap_libs/asap7.genlib}"
FAIR_ROOT="${FAIR_ROOT:-$ROOT_DIR/output/fair_nf_emap_asap7genlib}"
EMAP_SUBDIR="${EMAP_SUBDIR:-emap}"
CASES="${CASES:-}"
JOBS="${JOBS:-1}"
TIMEOUT="${TIMEOUT:-600}"
MERGE_PY="$ROOT_DIR/scripts/merge_emap_twins.py"

usage() {
  cat <<EOF
Usage: $0 [options]

CEC mapped Verilog in a fair nf/emap output tree vs shared synth.aig.

Options:
  --root DIR           fair output root [output/fair_nf_emap_asap7genlib]
  --emap-subdir NAME   emap dir under root: emap | emap_l1 [emap]
  --cases "a b c"      subset of case names (default: all under nf/)
  --jobs N / --parallel
  --timeout SEC        per CEC timeout [600]
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
NF_DIR="$FAIR_ROOT/nf"
EMAP_DIR="$FAIR_ROOT/$EMAP_SUBDIR"
SYNTH_DIR="$FAIR_ROOT/synth"
OUT_REPORT="$FAIR_ROOT/cec_report.md"
RESULT_DIR="$FAIR_ROOT/cec_logs"
mkdir -p "$RESULT_DIR"

[[ -x "$ABC" ]] || { echo "missing graduate-abc: $ABC" >&2; exit 1; }
[[ -f "$LIBERTY" ]] || { echo "missing liberty: $LIBERTY" >&2; exit 1; }
[[ -f "$GENLIB" ]] || { echo "missing genlib: $GENLIB" >&2; exit 1; }
[[ -f "$MERGE_PY" ]] || { echo "missing $MERGE_PY" >&2; exit 1; }
[[ -d "$NF_DIR" && -d "$EMAP_DIR" && -d "$SYNTH_DIR" ]] || {
  echo "fair root missing nf/ emap/ synth/: $FAIR_ROOT" >&2
  exit 1
}
if ! [[ "$JOBS" =~ ^[1-9][0-9]*$ ]]; then
  echo "invalid --jobs: $JOBS" >&2
  exit 1
fi

if [[ -z "$CASES" ]]; then
  CASES="$(find "$NF_DIR" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' | sort | tr '\n' ' ')"
fi

find_nf_v() {
  local case_dir="$1" case_name="$2" f
  for f in "$case_dir/${case_name}_nf.v" "$case_dir"/*_nf.v; do
    [[ -f "$f" ]] && { echo "$f"; return 0; }
  done
  return 1
}

find_emap_v() {
  local case_dir="$1" case_name="$2" f
  for f in "$case_dir/${case_name}_emap.v" "$case_dir"/*_emap.v; do
    [[ -f "$f" && "$f" != *_merged.v ]] && { echo "$f"; return 0; }
  done
  return 1
}

strip_ansi() {
  perl -pe 's/\e\[[0-9;]*[mK]//g'
}

# Returns status string: pass | fail(...) 
run_cec_one() {
  local kind="$1" case_name="$2"  # kind=nf|emap
  local log="$RESULT_DIR/${case_name}.${kind}.log"
  local synth="$SYNTH_DIR/$case_name/synth.aig"
  local verilog="" lib_cmd=""

  if [[ ! -s "$synth" ]]; then
    echo "fail(no synth)"
    return 0
  fi

  if [[ "$kind" == nf ]]; then
    verilog="$(find_nf_v "$NF_DIR/$case_name" "$case_name" || true)"
    [[ -n "$verilog" ]] || { echo "fail(no verilog)"; return 0; }
    lib_cmd="read_lib \"$LIBERTY\""
  else
    local raw merged
    raw="$(find_emap_v "$EMAP_DIR/$case_name" "$case_name" || true)"
    [[ -n "$raw" ]] || { echo "fail(no verilog)"; return 0; }
    merged="$EMAP_DIR/$case_name/${case_name}_emap_merged.v"
    # Refresh merge so M3 emap/ also gets a twin-merged netlist for ABC.
    python3 "$MERGE_PY" "$raw" "$merged" >/dev/null
    verilog="$merged"
    lib_cmd="read_genlib \"$GENLIB\""
  fi

  set +e
  timeout "$TIMEOUT" bash -c "cd \"$GRADUATE_DIR\" && \"$ABC\" -c \"
    $lib_cmd;
    read -m \\\"$verilog\\\";
    ps;
    read_aiger \\\"$synth\\\";
    ps;
    cec
  \"" >"$log" 2>&1
  local rc=$?
  set -e

  local plain
  plain="$(strip_ansi < "$log")"

  if [[ "$rc" == 124 ]]; then
    echo "fail(timeout)"
    return 0
  fi
  if [[ "$rc" != 0 ]]; then
    echo "fail(rc=$rc)"
    return 0
  fi
  if echo "$plain" | grep -qE 'Reading network from file has failed|Cannot open input file|Empty network|Parsing of gate .* has failed'; then
    echo "fail(read)"
    return 0
  fi
  if echo "$plain" | grep -q 'Networks are equivalent'; then
    echo "pass"
    return 0
  fi
  if echo "$plain" | grep -qiE 'not equivalent|Networks are NOT equivalent'; then
    echo "fail(neq)"
    return 0
  fi
  echo "fail(no-cec-line)"
}

write_line() {
  printf '%s\n' "$2" > "$RESULT_DIR/$1.line"
}

run_case() {
  local case_name="$1"
  echo "== $case_name =="
  local nf_st em_st
  nf_st="$(run_cec_one nf "$case_name")"
  em_st="$(run_cec_one emap "$case_name")"
  echo "  nf:   $nf_st"
  echo "  emap: $em_st"
  printf '%s\n' "$nf_st" > "$RESULT_DIR/$case_name.nf.status"
  printf '%s\n' "$em_st" > "$RESULT_DIR/$case_name.emap.status"
  write_line "$case_name" "| \`$case_name\` | $nf_st | $em_st |"
}

echo "CEC fair nf/emap vs synth"
echo "  root:        $FAIR_ROOT"
echo "  emap_subdir: $EMAP_SUBDIR"
echo "  jobs:        $JOBS"
echo "  cases:       $CASES"
echo "  report:      $OUT_REPORT"

if [[ "$JOBS" == "1" ]]; then
  for c in $CASES; do run_case "$c"; done
else
  for c in $CASES; do
    while (( $(jobs -rp | wc -l) >= JOBS )); do sleep 0.2; done
    run_case "$c" &
  done
  wait || true
fi

{
  echo "# CEC: mapped Verilog vs shared synth.aig"
  echo
  echo "- date: $(date -Iseconds)"
  echo "- root: \`$FAIR_ROOT\`"
  echo "- emap_subdir: \`$EMAP_SUBDIR\`"
  echo "- abc: \`$ABC\`"
  echo "- nf library: \`read_lib $LIBERTY\`"
  echo "- emap library: \`read_genlib $GENLIB\` (+ twin FA/HA merge)"
  echo "- command: \`read_*; read -m <v>; read_aiger <synth.aig>; cec\`"
  echo "- logs: \`$RESULT_DIR/<case>.{nf,emap}.log\`"
  echo
  echo "| case | nf vs synth | emap vs synth |"
  echo "| --- | --- | --- |"
  for c in $CASES; do
    if [[ -f "$RESULT_DIR/$c.line" ]]; then
      cat "$RESULT_DIR/$c.line"
      rm -f "$RESULT_DIR/$c.line"
    else
      echo "| \`$c\` | missing | missing |"
    fi
  done
  echo
  nf_pass=0; em_pass=0; n=0
  for c in $CASES; do
    n=$((n + 1))
    [[ -f "$RESULT_DIR/$c.nf.status" && "$(tr -d '[:space:]' < "$RESULT_DIR/$c.nf.status")" == pass ]] && nf_pass=$((nf_pass + 1))
    [[ -f "$RESULT_DIR/$c.emap.status" && "$(tr -d '[:space:]' < "$RESULT_DIR/$c.emap.status")" == pass ]] && em_pass=$((em_pass + 1))
  done
  echo "## Summary"
  echo
  echo "| side | pass / total |"
  echo "| --- | --- |"
  echo "| nf | $nf_pass / $n |"
  echo "| emap (\`$EMAP_SUBDIR\`) | $em_pass / $n |"
} > "$OUT_REPORT"

echo
echo "done."
echo "  report: $OUT_REPORT"

fail=0
for c in $CASES; do
  for kind in nf emap; do
    st=""
    [[ -f "$RESULT_DIR/$c.$kind.status" ]] && st="$(tr -d '[:space:]' < "$RESULT_DIR/$c.$kind.status")"
    [[ "$st" == pass ]] || fail=1
  done
done
exit "$fail"
