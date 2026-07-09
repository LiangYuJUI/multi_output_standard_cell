#!/usr/bin/env bash
# See docs/SCRIPTS.md
# List EPFL benchmark names or resolve paths from data/epfl/*.yaml
#
# Usage:
#   ./scripts/list_epfl_benchmarks.sh small
#   ./scripts/list_epfl_benchmarks.sh medium large
#   ./scripts/list_epfl_benchmarks.sh --path small adder
#   ./scripts/list_epfl_benchmarks.sh --yaml medium
#
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DATA_DIR="$ROOT_DIR/data/epfl"

usage() {
  cat <<EOF
Usage:
  $0 [--path|--yaml] <scale> [name ...]

Scales: tiny, small, medium, large, all

Examples:
  $0 small
  $0 --path medium multiplier
  $0 --yaml all
EOF
}

mode="names"
scales=()
names=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --path) mode="path"; shift ;;
    --yaml) mode="yaml"; shift ;;
    -h|--help) usage; exit 0 ;;
    tiny|small|medium|large|all)
      scales+=("$1")
      shift
      ;;
    *)
      names+=("$1")
      shift
      ;;
  esac
done

if [[ ${#scales[@]} -eq 0 ]]; then
  usage >&2
  exit 1
fi

yaml_files=()
for scale in "${scales[@]}"; do
  if [[ "$scale" == "all" ]]; then
    yaml_files+=("$DATA_DIR/tiny.yaml" "$DATA_DIR/small.yaml" "$DATA_DIR/medium.yaml" "$DATA_DIR/large.yaml")
  else
    yaml_files+=("$DATA_DIR/${scale}.yaml")
  fi
done

lookup_path() {
  local target="$1"
  awk -v name="$target" '
    $1 == "name:" && $2 == name { found=1; next }
    found && $1 == "path:" { print $2; exit }
    found && $1 == "-" { found=0 }
  ' "${yaml_files[@]}"
}

lookup_name() {
  awk '$1 == "name:" { print $2 }' "${yaml_files[@]}"
}

case "$mode" in
  yaml)
    printf '%s\n' "${yaml_files[@]}"
    ;;
  path)
    if [[ ${#names[@]} -eq 0 ]]; then
      echo "missing benchmark name for --path" >&2
      exit 1
    fi
    for name in "${names[@]}"; do
      rel="$(lookup_path "$name")"
      if [[ -z "$rel" ]]; then
        echo "unknown benchmark: $name" >&2
        exit 1
      fi
      echo "$ROOT_DIR/$rel"
    done
    ;;
  names)
    lookup_name
    ;;
esac
