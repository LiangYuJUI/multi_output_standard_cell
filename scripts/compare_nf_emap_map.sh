#!/usr/bin/env bash
# See docs/SCRIPTS.md
# Compare &nf -Y (balance) vs emap -Y mapping results with the SAME Liberty STA
# (ABC stime on asap7.lib) and write a markdown report.
#
# For emap Verilog, twin FA/HA instances (separate CON/SN gates) are merged into
# single multi-output instances so ABC can read -m + stime under Liberty.
#
# Examples:
#   ./scripts/compare_nf_emap_map.sh \
#     --nf-dir output/abc_syn_map_20260709_201016 \
#     --emap-dir output/abc_emap_map_20260710_162632
#
#   ./scripts/compare_nf_emap_map.sh \
#     --nf-dir output/abc_syn_map_20260709_201016 \
#     --emap-dir output/abc_emap_map_20260710_162632 \
#     --force-stime --jobs 8
#
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GRADUATE_DIR="${GRADUATE_DIR:-$ROOT_DIR/third_party/GRADUATE}"
ABC="${GRADUATE_ABC:-$GRADUATE_DIR/build_abc_frontend/graduate-abc}"
LIBERTY="${GRADUATE_LIBERTY:-$GRADUATE_DIR/third_party/gradmap_libs/asap7.lib}"
NF_DIR=""
EMAP_DIR=""
OUT_MD=""
CASES=""
FORCE_STIME=0
JOBS="${JOBS:-1}"

usage() {
  cat <<EOF
Usage: $0 --nf-dir DIR --emap-dir DIR [options]

Compare balance \`&nf -Y\` vs \`emap -Y\` using the same Liberty \`stime\` units.

Required:
  --nf-dir DIR      output of run_abc_syn_map.sh --flow balance
  --emap-dir DIR    output of run_abc_emap_map.sh

Options:
  --out FILE        markdown report path
                    [default: <emap-dir>/compare_nf_emap.md]
  --cases "a b c"   subset of cases (default: intersection of both dirs)
  --liberty PATH    Liberty for stime [asap7.lib]
  --force-stime     re-run stime even if cached stime_asap7.txt exists
  --jobs N          parallel stime jobs [1]
  -h, --help

STA method:
  1) Optionally merge emap twin FA/HA Verilog instances -> *_merged.v
  2) graduate-abc: read_lib <liberty>; read -m <verilog>; topo; stime
  3) Cache result as <case>/stime_asap7.txt
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --nf-dir) NF_DIR="$2"; shift 2 ;;
    --emap-dir) EMAP_DIR="$2"; shift 2 ;;
    --out) OUT_MD="$2"; shift 2 ;;
    --cases) CASES="$2"; shift 2 ;;
    --liberty) LIBERTY="$2"; shift 2 ;;
    --force-stime) FORCE_STIME=1; shift ;;
    --jobs) JOBS="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown option: $1" >&2; usage >&2; exit 1 ;;
  esac
done

[[ -n "$NF_DIR" && -d "$NF_DIR" ]] || { echo "missing --nf-dir" >&2; usage >&2; exit 1; }
[[ -n "$EMAP_DIR" && -d "$EMAP_DIR" ]] || { echo "missing --emap-dir" >&2; usage >&2; exit 1; }
[[ -x "$ABC" ]] || { echo "missing graduate-abc: $ABC" >&2; exit 1; }
[[ -f "$LIBERTY" ]] || { echo "missing liberty: $LIBERTY" >&2; exit 1; }
if ! [[ "$JOBS" =~ ^[1-9][0-9]*$ ]]; then
  echo "invalid --jobs: $JOBS" >&2
  exit 1
fi

NF_DIR="$(cd "$NF_DIR" && pwd)"
EMAP_DIR="$(cd "$EMAP_DIR" && pwd)"
OUT_MD="${OUT_MD:-$EMAP_DIR/compare_nf_emap.md}"
LIBERTY="$(cd "$(dirname "$LIBERTY")" && pwd)/$(basename "$LIBERTY")"

strip_ansi() {
  perl -pe 's/\e\[[0-9;]*[mK]//g'
}

parse_and() {
  # Prefer shared post-synth AND written by run_fair_nf_emap_compare.sh.
  local case_dir="$1" log="$2"
  if [[ -s "$case_dir/synth_and.txt" ]]; then
    tr -d '[:space:]' < "$case_dir/synth_and.txt"
    return
  fi
  [[ -f "$log" ]] || { echo ""; return; }
  # Legacy full-flow logs: last "and =" is post-synth (before/around mapping).
  # Map-only fair logs usually have a single "and =" after reading synth.aig.
  strip_ansi < "$log" | grep -E 'and =' | tail -n1 | \
    sed -n 's/.*and =[[:space:]]*\([0-9][0-9]*\).*/\1/p'
}

parse_stime_line() {
  local file="$1"
  [[ -f "$file" ]] || { echo "|||"; return; }
  local line
  line="$(strip_ansi < "$file" | grep -E 'Gates =.*Area =.*Delay =' | tail -n1 || true)"
  if [[ -z "$line" ]]; then
    echo "|||"
    return
  fi
  local gates area delay
  gates="$(echo "$line" | sed -n 's/.*Gates =[[:space:]]*\([0-9][0-9]*\).*/\1/p')"
  area="$(echo "$line" | sed -n 's/.*Area =[[:space:]]*\([0-9.][0-9.]*\).*/\1/p')"
  delay="$(echo "$line" | sed -n 's/.*Delay =[[:space:]]*\([0-9.][0-9.]*\).*/\1/p')"
  echo "${gates}|${area}|${delay}"
}

parse_emap_mbind() {
  local match="$1"
  if [[ -f "$match" ]]; then
    grep -c '^MBIND ' "$match" 2>/dev/null || true
  else
    echo 0
  fi
}

find_nf_verilog() {
  local case_dir="$1" case_name="$2"
  local f
  for f in \
    "$case_dir/${case_name}_balance.v" \
    "$case_dir/${case_name}_nf.v" \
    "$case_dir/${case_name}.v" \
    "$case_dir"/*_balance.v \
    "$case_dir"/*_nf.v
  do
    [[ -f "$f" ]] && { echo "$f"; return 0; }
  done
  return 1
}

find_emap_verilog() {
  local case_dir="$1" case_name="$2"
  local f
  for f in "$case_dir/${case_name}_emap.v" "$case_dir"/*_emap.v; do
    [[ -f "$f" ]] && { echo "$f"; return 0; }
  done
  return 1
}

# Merge twin FA/HA instances (CON-only + SN-only) into one multi-output instance,
# fill missing MOG outputs with dummy wires, and rewrite genlib-only cells to
# Liberty-available equivalents for asap7 stime.
merge_emap_twins() {
  local src="$1" dst="$2"
  python3 - "$src" "$dst" <<'PY'
import re, sys
from collections import defaultdict

src, dst = sys.argv[1], sys.argv[2]
text = open(src).read()
lines = text.splitlines(True)

inst_re = re.compile(
    r"^(\s*)([A-Za-z0-9_]+)\s+(\w+)\(([^;]*)\);\s*$"
)

def parse_pins(s):
    return {a: b for a, b in re.findall(r"\.(\w+)\(([^)]*)\)", s)}

def fmt_inst(indent, cell, name, pins, order):
    order = [k for k in order if k in pins]
    # keep any unexpected pins stably
    for k in sorted(pins):
        if k not in order:
            order.append(k)
    body = ", ".join(f".{k}({pins[k]})" for k in order)
    return f"{indent}{cell}     {name}({body});\n"

# Pass 1: collect FA/HA twin candidates by (cell, inputs)
mog_cells = {"FAx1_ASAP7_75t_R", "HAxp5_ASAP7_75t_R"}
entries = []  # (line_idx, indent, cell, name, pins)
for i, line in enumerate(lines):
    m = inst_re.match(line)
    if not m:
        continue
    cell = m.group(2)
    if cell not in mog_cells:
        continue
    pins = parse_pins(m.group(4))
    entries.append((i, m.group(1), cell, m.group(3), pins))

groups = defaultdict(list)
for e in entries:
    i, indent, cell, name, pins = e
    inputs = tuple(sorted((k, v) for k, v in pins.items() if k not in ("CON", "SN")))
    groups[(cell, inputs)].append(e)

replace = {}  # line_idx -> list of output lines (or None to delete)
dummy_wires = []
for (cell, inputs), members in groups.items():
    outs = {}
    keep = members[0]
    for i, indent, c, name, pins in members:
        for o in ("CON", "SN"):
            if o in pins:
                outs[o] = pins[o]
        replace[i] = None  # delete originals by default
    indent, name = keep[1], keep[3]
    pins = dict(inputs)
    pins.update(outs)
    # Ensure both outputs exist for ABC multi-output parse.
    for o in ("CON", "SN"):
        if o not in pins:
            w = f"_emap_sta_unused_{name}_{o}"
            pins[o] = w
            dummy_wires.append(w)
    order = ["A", "B", "CI", "CON", "SN"]
    replace[keep[0]] = [fmt_inst(indent, cell, name, pins, order)]

out_lines = []
# Insert dummy wire decls after first 'wire ' block or before first gate.
inserted_wires = False
wire_decl = ""
if dummy_wires:
    uniq = sorted(set(dummy_wires))
    # chunk for readability
    parts = []
    cur = "  wire "
    for w in uniq:
        item = (w + ",")
        if len(cur) + len(item) > 100:
            parts.append(cur.rstrip(",") + ";\n")
            cur = "  wire " + item
        else:
            cur += item + " "
    parts.append(cur.rstrip(", ") + ";\n")
    wire_decl = "".join(parts)

for i, line in enumerate(lines):
    if i in replace:
        rep = replace[i]
        if rep is None:
            continue
        if not inserted_wires and wire_decl:
            out_lines.append(wire_decl)
            inserted_wires = True
        out_lines.extend(rep)
        continue
    # Liberty aliases / expansions for genlib-only cells
    m = inst_re.match(line)
    if m:
        indent, cell, name, pinstr = m.group(1), m.group(2), m.group(3), m.group(4)
        pins = parse_pins(pinstr)
        if cell == "MAJIx2_ASAP7_75t_R":
            if not inserted_wires and wire_decl:
                out_lines.append(wire_decl)
                inserted_wires = True
            out_lines.append(fmt_inst(indent, "MAJIxp5_ASAP7_75t_R", name, pins, ["A", "B", "C", "Y"]))
            continue
        if cell == "XNOR3x1_ASAP7_75t_R":
            # XNOR3(A,B,C) ~= XNOR2(XNOR2(A,B), C) for Liberty STA availability.
            mid = f"_emap_sta_xnor3_{name}"
            if not inserted_wires:
                # ensure mid wire declared
                pass
            # declare mid wire near use
            out_lines.append(f"{indent}wire {mid};\n")
            out_lines.append(fmt_inst(indent, "XNOR2x1_ASAP7_75t_R", name + "_0",
                                      {"A": pins["A"], "B": pins["B"], "Y": mid}, ["A", "B", "Y"]))
            out_lines.append(fmt_inst(indent, "XNOR2x1_ASAP7_75t_R", name + "_1",
                                      {"A": mid, "B": pins["C"], "Y": pins["Y"]}, ["A", "B", "Y"]))
            continue
    if not inserted_wires and wire_decl and re.match(r"^\s*[A-Za-z0-9_]+\s+\w+\(", line):
        out_lines.append(wire_decl)
        inserted_wires = True
    out_lines.append(line)

open(dst, "w").writelines(out_lines)
print(sum(1 for v in replace.values() if v))
PY
}

run_liberty_stime() {
  local verilog="$1" out_txt="$2" label="$3"
  local log="${out_txt}.log"
  set +e
  timeout 600 bash -c "cd \"$GRADUATE_DIR\" && \"$ABC\" -c \"read_lib \\\"$LIBERTY\\\"; read -m \\\"$verilog\\\"; topo; stime\"" \
    >"$log" 2>&1
  local rc=$?
  set -e
  if [[ "$rc" != 0 ]]; then
    echo "stime failed ($label, rc=$rc): $log" >&2
    return 1
  fi
  if ! strip_ansi < "$log" | grep -qE 'Gates =.*Area =.*Delay ='; then
    echo "stime produced no Gates/Area/Delay ($label): $log" >&2
    return 1
  fi
  strip_ansi < "$log" | grep -E 'Gates =.*Area =.*Delay =' | tail -n1 > "$out_txt"
  return 0
}

ensure_stime() {
  local kind="$1" case_name="$2"  # kind = nf|emap
  local case_dir out_txt verilog merged
  if [[ "$kind" == nf ]]; then
    case_dir="$NF_DIR/$case_name"
  else
    case_dir="$EMAP_DIR/$case_name"
  fi
  out_txt="$case_dir/stime_asap7.txt"
  if [[ "$FORCE_STIME" != "1" && -s "$out_txt" ]]; then
    return 0
  fi

  if [[ "$kind" == nf ]]; then
    verilog="$(find_nf_verilog "$case_dir" "$case_name" || true)"
    [[ -n "$verilog" ]] || { echo "skip $case_name nf: no verilog" >&2; return 1; }
    run_liberty_stime "$verilog" "$out_txt" "nf/$case_name"
  else
    verilog="$(find_emap_verilog "$case_dir" "$case_name" || true)"
    [[ -n "$verilog" ]] || { echo "skip $case_name emap: no verilog" >&2; return 1; }
    merged="$case_dir/${case_name}_emap_merged.v"
    merge_emap_twins "$verilog" "$merged" >/dev/null
    run_liberty_stime "$merged" "$out_txt" "emap/$case_name"
  fi
}

pct_delta() {
  local old="$1" new="$2"
  if [[ -z "$old" || -z "$new" || "$old" == "0" ]]; then
    echo "n/a"
    return
  fi
  awk -v o="$old" -v n="$new" 'BEGIN { printf "%+.1f%%", (n-o)/o*100 }'
}

list_cases() {
  if [[ -n "$CASES" ]]; then
    echo "$CASES"
    return
  fi
  local c
  for c in $(ls -1 "$NF_DIR" 2>/dev/null); do
    [[ -d "$NF_DIR/$c" && -d "$EMAP_DIR/$c" ]] || continue
    echo "$c"
  done | sort
}

CASES_LIST="$(list_cases)"
[[ -n "$CASES_LIST" ]] || { echo "no overlapping cases found" >&2; exit 1; }

echo "Comparing with Liberty stime: $LIBERTY"
echo "  nf_dir:   $NF_DIR"
echo "  emap_dir: $EMAP_DIR"
echo "  cases:    $(echo $CASES_LIST | wc -w)"
echo "  jobs:     $JOBS"
echo

# Run / cache stime for all cases
STIME_PIDS=()
run_stime_job() {
  local kind="$1" case_name="$2"
  ensure_stime "$kind" "$case_name" && echo "  ok  $kind/$case_name" || echo "  FAIL $kind/$case_name"
}

if [[ "$JOBS" == "1" ]]; then
  for case_name in $CASES_LIST; do
    run_stime_job nf "$case_name"
    run_stime_job emap "$case_name"
  done
else
  for case_name in $CASES_LIST; do
    for kind in nf emap; do
      while (( $(jobs -rp | wc -l) >= JOBS )); do
        sleep 0.2
      done
      run_stime_job "$kind" "$case_name" &
    done
  done
  wait || true
fi

n_cases=0
n_emap_better_area=0
n_emap_better_delay=0
n_emap_better_gates=0
n_with_mog=0
n_stime_ok=0

{
  echo "# &nf -Y vs emap -Y mapping comparison (same Liberty STA)"
  echo
  echo "- date: $(date -Iseconds)"
  echo "- nf_dir (\`&nf -Y\` / balance): \`$NF_DIR\`"
  echo "- emap_dir (\`emap -Y\`): \`$EMAP_DIR\`"
  echo "- liberty (STA): \`$LIBERTY\`"
  echo "- sta_command: \`read_lib; read -m <verilog>; topo; stime\`"
  echo "- cases: \`$(echo $CASES_LIST)\`"
  echo
  echo "## Notes"
  echo
  echo "- **All Gates / Area / Delay below use the same ASAP7 Liberty \`stime\`**."
  echo "- emap Verilog prep for Liberty STA:"
  echo "  - merge twin FA/HA instances; pad unused CON/SN with dummy wires"
  echo "  - \`MAJIx2\` → \`MAJIxp5\` (same function; genlib-only drive strength)"
  echo "  - \`XNOR3x1\` → \`XNOR2x1\` cascade (Liberty-available equivalent)"
  echo "- Post-synth AND: prefer \`synth_and.txt\` (fair shared AIG); else first \`and =\` in \`run.log\`."
  echo "- If AND differs across dirs, the two runs did **not** share the same synth.aig (e.g. separate \`&deepsyn -T\`)."
  echo "- **Δ%** = \`(emap - nf) / nf × 100\` (negative ⇒ emap better for that metric)."
  echo "- Cached per-case STA: \`<case>/stime_asap7.txt\`"
  echo
  echo "## Per-case results (Liberty stime)"
  echo
  echo "| case | nf AND | emap AND | ΔAND% | nf gates | emap gates | Δgates% | nf area | emap area | Δarea% | nf delay | emap delay | Δdelay% | MBIND |"
  echo "| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |"
} > "$OUT_MD"

for case_name in $CASES_LIST; do
  nf_log="$NF_DIR/$case_name/run.log"
  em_log="$EMAP_DIR/$case_name/run.log"
  nf_stime="$NF_DIR/$case_name/stime_asap7.txt"
  em_stime="$EMAP_DIR/$case_name/stime_asap7.txt"
  em_match="$EMAP_DIR/$case_name/matches.nf_y_multi.txt"

  nf_and="$(parse_and "$NF_DIR/$case_name" "$nf_log")"
  em_and="$(parse_and "$EMAP_DIR/$case_name" "$em_log")"
  IFS='|' read -r nf_gates nf_area nf_delay <<<"$(parse_stime_line "$nf_stime")"
  IFS='|' read -r em_gates em_area em_delay <<<"$(parse_stime_line "$em_stime")"
  mbind="$(parse_emap_mbind "$em_match")"
  mbind="${mbind:-0}"

  d_and="$(pct_delta "${nf_and:-}" "${em_and:-}")"
  d_gates="$(pct_delta "${nf_gates:-}" "${em_gates:-}")"
  d_area="$(pct_delta "${nf_area:-}" "${em_area:-}")"
  d_delay="$(pct_delta "${nf_delay:-}" "${em_delay:-}")"

  printf '| `%s` | %s | %s | %s | %s | %s | %s | %s | %s | %s | %s | %s | %s | %s |\n' \
    "$case_name" \
    "${nf_and:-n/a}" "${em_and:-n/a}" "$d_and" \
    "${nf_gates:-n/a}" "${em_gates:-n/a}" "$d_gates" \
    "${nf_area:-n/a}" "${em_area:-n/a}" "$d_area" \
    "${nf_delay:-n/a}" "${em_delay:-n/a}" "$d_delay" \
    "$mbind" \
    >> "$OUT_MD"

  n_cases=$((n_cases + 1))
  if [[ -n "${nf_gates:-}" && -n "${em_gates:-}" ]]; then
    n_stime_ok=$((n_stime_ok + 1))
    if awk -v a="$em_gates" -v b="$nf_gates" 'BEGIN { exit !(a+0 < b+0) }'; then
      n_emap_better_gates=$((n_emap_better_gates + 1))
    fi
    if awk -v a="$em_area" -v b="$nf_area" 'BEGIN { exit !(a+0 < b+0) }'; then
      n_emap_better_area=$((n_emap_better_area + 1))
    fi
    if awk -v a="$em_delay" -v b="$nf_delay" 'BEGIN { exit !(a+0 < b+0) }'; then
      n_emap_better_delay=$((n_emap_better_delay + 1))
    fi
  fi
  if [[ "$mbind" -gt 0 ]]; then
    n_with_mog=$((n_with_mog + 1))
  fi
done

{
  echo
  echo "## Summary"
  echo
  echo "| metric | value |"
  echo "| --- | --- |"
  echo "| cases compared | $n_cases |"
  echo "| cases with valid Liberty stime on both | $n_stime_ok |"
  echo "| cases with emap MBIND > 0 | $n_with_mog |"
  echo "| cases where emap gates < nf gates | $n_emap_better_gates |"
  echo "| cases where emap area < nf area | $n_emap_better_area |"
  echo "| cases where emap delay < nf delay | $n_emap_better_delay |"
  echo
  echo "## How to reproduce"
  echo
  echo '```bash'
  echo "./scripts/compare_nf_emap_map.sh \\"
  echo "  --nf-dir $NF_DIR \\"
  echo "  --emap-dir $EMAP_DIR \\"
  echo "  --liberty $LIBERTY \\"
  echo "  --jobs $JOBS"
  echo '```'
} >> "$OUT_MD"

echo
echo "Wrote $OUT_MD"
echo
sed -n '/^## Per-case results/,/^## Summary$/p' "$OUT_MD" | head -n 35
echo
sed -n '/^## Summary$/,/^## How to reproduce$/p' "$OUT_MD" | head -n 20
