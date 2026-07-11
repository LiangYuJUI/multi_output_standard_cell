# Shared helpers for emap SO export policy (Phase 4).
# Source from runner scripts:  # shellcheck source=emap_so_policy_lib.sh
#   source "$ROOT_DIR/scripts/sh/emap_so_policy_lib.sh"
#
# Formal GradMap-ready policy: --so-dedup nf-like --so-cut-topk 16
# Legacy / unlimited:          --so-dedup none    --so-cut-topk 0
# Exact only:                  --so-dedup exact   --so-cut-topk 0

emap_so_dedup_to_num() {
  case "$1" in
    none|0) echo 0 ;;
    exact|1) echo 1 ;;
    nf-like|nflike|2) echo 2 ;;
    *)
      echo "invalid --so-dedup '$1' (want none|exact|nf-like)" >&2
      return 1
      ;;
  esac
}

# Append -D/-K to EMAP_FLAGS. Call after option parsing.
# Usage: EMAP_FLAGS="$(emap_so_append_flags "$EMAP_FLAGS" "$SO_DEDUP" "$SO_CUT_TOPK")"
emap_so_append_flags() {
  local flags="$1"
  local dedup="$2"
  local topk="$3"
  local n
  n="$(emap_so_dedup_to_num "$dedup")" || return 1
  if ! [[ "$topk" =~ ^[0-9]+$ ]]; then
    echo "invalid --so-cut-topk '$topk' (want integer >= 0)" >&2
    return 1
  fi
  echo "$flags -D $n -K $topk"
}

emap_so_policy_usage_lines() {
  cat <<'EOF'
  --so-dedup none|exact|nf-like   SO dump dedup → emap -D [default: nf-like]
  --so-cut-topk N                 SO export cut top-K → emap -K [default: 16]
                                  0 = no top-K (all internal cuts; EMAP_CUT_MAX unchanged)
EOF
}
