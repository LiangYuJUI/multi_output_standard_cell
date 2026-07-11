#!/usr/bin/env bash
# See docs/SCRIPTS.md
# Phase 4 regression for emap SO export policy (no new pruning algorithms).
#
# Covers:
#   1) emap -M 1 / -M 2 / -M 3 K=0 / -M 3 K=16 exact / -M 3 K=16 nf-like
#   2) CEC
#   3) BIND/MBIND/M invariance across SO policies
#   4) &nf -Y smoke (fair reuse)
#   5) GradMap / GradSyn / sequential smokes when binaries exist
#
# Examples:
#   ./scripts/sh/regression_emap_so_export.sh
#   ./scripts/sh/regression_emap_so_export.sh --cases "adder ctrl" --skip-smokes
#
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
GRADUATE_DIR="${GRADUATE_DIR:-$ROOT_DIR/third_party/GRADUATE}"
ABC="${GRADUATE_ABC:-$GRADUATE_DIR/build_abc_frontend/graduate-abc}"
GENLIB="${EMAP_GENLIB:-$GRADUATE_DIR/third_party/gradmap_libs/asap7.genlib}"
LIBERTY="${GRADUATE_LIBERTY:-$GRADUATE_DIR/third_party/gradmap_libs/asap7.lib}"
FAIR_ROOT="${FAIR_ROOT:-$ROOT_DIR/output/fair_nf_emap_asap7genlib}"
OUT_ROOT="${OUT_ROOT:-$ROOT_DIR/output/emap_so_export_regression_$(date +%Y%m%d_%H%M%S)}"
CASES="${CASES:-adder ctrl cavlc}"
MAP_TIMEOUT="${MAP_TIMEOUT:-600}"
SKIP_SMOKES=0
MERGE="$ROOT_DIR/scripts/py/merge_emap_twins.py"
VAL="$ROOT_DIR/scripts/py/validate_emap_nf_y_multi.py"

usage() {
  cat <<EOF
Usage: $0 [options]

Options:
  --root DIR
  --out DIR
  --cases "a b"
  --map-timeout SEC
  --skip-smokes
  -h, --help
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --root) FAIR_ROOT="$2"; shift 2 ;;
    --out) OUT_ROOT="$2"; shift 2 ;;
    --cases) CASES="$2"; shift 2 ;;
    --map-timeout) MAP_TIMEOUT="$2"; shift 2 ;;
    --skip-smokes) SKIP_SMOKES=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown option: $1" >&2; exit 1 ;;
  esac
done

mkdir -p "$OUT_ROOT"
REPORT="$OUT_ROOT/regression.md"
FAIL=0

log_result() {
  echo "| $1 | $2 |" | tee -a "$OUT_ROOT/results.tbl"
}

: >"$OUT_ROOT/results.tbl"
{
  echo "# emap SO export regression (Phase 4)"
  echo
  echo "- fair_root: \`$FAIR_ROOT\`"
  echo "- out: \`$OUT_ROOT\`"
  echo
  echo "| check | status |"
  echo "|-------|--------|"
} >"$REPORT"
cat "$OUT_ROOT/results.tbl" >>"$REPORT" 2>/dev/null || true

emap_run() {
  local case_name="$1" level="$2" d="$3" k="$4" tag="$5"
  local odir="$OUT_ROOT/$tag"
  mkdir -p "$odir"
  local aig="$FAIR_ROOT/synth/$case_name/synth.aig"
  [[ -s "$aig" ]] || { echo "missing $aig"; return 1; }
  cat >"$odir/run.abc" <<EOF
read $aig
strash
read_genlib $GENLIB
emap -a -v -Y $odir/matches.nf_y_multi.txt -M $level -D $d -K $k
write_verilog $odir/${case_name}_emap.v
EOF
  timeout "$MAP_TIMEOUT" bash -c "cd \"$GRADUATE_DIR\" && \"$ABC\" -f \"$odir/run.abc\"" \
    >"$odir/abc.log" 2>&1
}

cec_case() {
  local case_name="$1" tag="$2"
  local v="$OUT_ROOT/$tag/${case_name}_emap.v"
  local merged="$OUT_ROOT/$tag/${case_name}_merged.v"
  local aig="$FAIR_ROOT/synth/$case_name/synth.aig"
  python3 "$MERGE" "$v" -o "$merged" 2>/dev/null || cp "$v" "$merged"
  timeout 120 bash -c "cd \"$GRADUATE_DIR\" && \"$ABC\" -c \"read -m \\\"$merged\\\"; read_aiger \\\"$aig\\\"; cec\"" \
    >"$OUT_ROOT/$tag/cec.log" 2>&1
  grep -q "Networks are equivalent" "$OUT_ROOT/$tag/cec.log"
}

body_md5() {
  python3 -c "
from pathlib import Path
import hashlib
lines=[l for l in Path('$1').read_text().splitlines() if not l.startswith('//')]
print(hashlib.md5(('\n'.join(lines)+'\n').encode()).hexdigest())
"
}

echo "== emap level / policy matrix =="
CASE0=$(echo "$CASES" | awk '{print $1}')

# M1 / M2 on first case
for level in 1 2; do
  tag="M${level}_D1_K0_${CASE0}"
  if emap_run "$CASE0" "$level" 1 0 "$tag" && cec_case "$CASE0" "$tag"; then
    log_result "emap -M $level ($CASE0) + CEC" "pass"
  else
    log_result "emap -M $level ($CASE0) + CEC" "FAIL"
    FAIL=$((FAIL + 1))
  fi
done

# M3 policies on all cases
declare -a TAGS_E=()
for c in $CASES; do
  for spec in "0:0:legacy" "1:0:exactK0" "2:0:nflikeK0" "1:16:exactK16" "2:16:nflikeK16"; do
    IFS=: read -r d k lab <<<"$spec"
    tag="M3_D${d}_K${k}_${lab}_${c}"
    if ! emap_run "$c" 3 "$d" "$k" "$tag"; then
      log_result "$tag" "FAIL(emap)"
      FAIL=$((FAIL + 1))
      continue
    fi
    if ! cec_case "$c" "$tag"; then
      log_result "$tag CEC" "FAIL"
      FAIL=$((FAIL + 1))
    else
      log_result "$tag CEC" "pass"
    fi
    if [[ "$lab" == "nflikeK16" || "$lab" == "nflikeK0" ]]; then
      if python3 "$VAL" --formal --require-so "$OUT_ROOT/$tag/matches.nf_y_multi.txt" \
          >"$OUT_ROOT/$tag/validate.log" 2>&1; then
        log_result "$tag validate" "pass"
      else
        log_result "$tag validate" "FAIL"
        FAIL=$((FAIL + 1))
      fi
    fi
    if [[ "$lab" == "nflikeK16" ]]; then
      TAGS_E+=("$c:$tag")
    fi
  done

  # BIND/MBIND/M invariance: nflikeK0 vs nflikeK16
  if python3 - <<PY
from pathlib import Path
import re
def extract(p):
    mbind=[]; bind=[]; Ms=[]
    for line in Path(p).read_text().splitlines():
        if line.startswith("MBIND "): mbind.append(line)
        elif line.startswith("BIND "): bind.append(line)
        elif re.match(r"^M\d+", line): Ms.append(line)
    return mbind, bind, Ms
a="$OUT_ROOT/M3_D2_K0_nflikeK0_$c/matches.nf_y_multi.txt"
b="$OUT_ROOT/M3_D2_K16_nflikeK16_$c/matches.nf_y_multi.txt"
ma,ba,msa=extract(a); mb,bb,msb=extract(b)
open("$OUT_ROOT/invar_$c.txt","w").write(f"MBIND={ma==mb} BIND={ba==bb} M={msa==msb}\n")
raise SystemExit(0 if (ma==mb and ba==bb and msa==msb) else 1)
PY
  then
    log_result "invariance K0 vs K16 ($c)" "pass"
  else
    log_result "invariance K0 vs K16 ($c)" "FAIL"
    FAIL=$((FAIL + 1))
  fi

  # Verilog body identical across SO policies
  h0=$(body_md5 "$OUT_ROOT/M3_D2_K0_nflikeK0_$c/${c}_emap.v")
  h16=$(body_md5 "$OUT_ROOT/M3_D2_K16_nflikeK16_$c/${c}_emap.v")
  if [[ "$h0" == "$h16" ]]; then
    log_result "verilog body K0==K16 ($c)" "pass"
  else
    log_result "verilog body K0==K16 ($c)" "FAIL"
    FAIL=$((FAIL + 1))
  fi
done

# Determinism: re-run formal once
tag_a="M3_D2_K16_nflikeK16_${CASE0}"
tag_b="M3_D2_K16_nflikeK16_${CASE0}_rerun"
emap_run "$CASE0" 3 2 16 "$tag_b" || true
if python3 - <<PY
from pathlib import Path
a=Path("$OUT_ROOT/$tag_a/matches.nf_y_multi.txt").read_bytes()
b=Path("$OUT_ROOT/$tag_b/matches.nf_y_multi.txt").read_bytes()
raise SystemExit(0 if a==b else 1)
PY
then
  log_result "deterministic match re-dump ($CASE0)" "pass"
else
  log_result "deterministic match re-dump ($CASE0)" "FAIL"
  FAIL=$((FAIL + 1))
fi

  # &nf -Y smoke on first case (reuse synth; needs Liberty)
  if [[ "$SKIP_SMOKES" == 0 ]]; then
  nfdir="$OUT_ROOT/nf_smoke_$CASE0"
  mkdir -p "$nfdir"
  cat >"$nfdir/run.abc" <<EOF
read $FAIR_ROOT/synth/$CASE0/synth.aig
strash
read_lib $LIBERTY
&get
&nf -Y $nfdir/matches.txt
&put
write_verilog $nfdir/${CASE0}_nf.v
EOF
  if timeout 300 bash -c "cd \"$GRADUATE_DIR\" && \"$ABC\" -f \"$nfdir/run.abc\"" >"$nfdir/abc.log" 2>&1 \
     && [[ -s "$nfdir/matches.txt" ]]; then
    log_result "&nf -Y smoke ($CASE0)" "pass"
  else
    log_result "&nf -Y smoke ($CASE0)" "FAIL"
    FAIL=$((FAIL + 1))
  fi

  # GradSyn / GradMap smoke
  if timeout 300 bash -c "cd \"$GRADUATE_DIR\" && \"$ABC\" -c \"read testdata/smoke.aig; st; resyn2; st; gradsyn -fast; st; gradmap -fast; topo; ps\"" \
      >"$OUT_ROOT/grad_smoke.log" 2>&1; then
    log_result "GradSyn+GradMap smoke" "pass"
  else
    log_result "GradSyn+GradMap smoke" "FAIL"
    FAIL=$((FAIL + 1))
  fi

  # Sequential wrapper if present
  if [[ -f "$GRADUATE_DIR/scripts/run_sequential_flow.py" && -f "$GRADUATE_DIR/testdata/seq_and_dff_or.v" ]]; then
    if timeout 300 python3 "$GRADUATE_DIR/scripts/run_sequential_flow.py" flow \
        "$GRADUATE_DIR/testdata/seq_and_dff_or.v" \
        --out "$OUT_ROOT/seq_smoke" >"$OUT_ROOT/seq_smoke.log" 2>&1; then
      log_result "sequential smoke" "pass"
    else
      log_result "sequential smoke" "FAIL (see seq_smoke.log)"
      FAIL=$((FAIL + 1))
    fi
  else
    log_result "sequential smoke" "skip"
  fi
fi

{
  echo "# emap SO export regression (Phase 4)"
  echo
  echo "- fair_root: \`$FAIR_ROOT\`"
  echo "- out: \`$OUT_ROOT\`"
  echo "- fail_count: $FAIL"
  echo
  echo "| check | status |"
  echo "|-------|--------|"
  cat "$OUT_ROOT/results.tbl"
} >"$REPORT"

echo "Report: $REPORT (fail=$FAIL)"
exit "$FAIL"
