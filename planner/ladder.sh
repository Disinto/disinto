#!/usr/bin/env bash
# =============================================================================
# planner/ladder.sh — name the lowest missing capability rung (#1975)
#
# The capability ladder (docs/design/notes/organs.md) is sense, provision,
# reach, deploy, replicate. claim_ids (lib/claims.sh) lists the claim files.
# Status lives in the catalog, not in the file.
#
# Function (sourced; no caller yet):
#   ladder_lowest_gap
#     -> the lowest rung that no claim id matches, or that any matching id
#        has status challenged. Prints nothing when every rung has a match
#        and none of those matches are challenged. Always returns 0 on that
#        decision. No arguments.
#
# A claim id matches a rung when:
#   sense      ^can-sense(-[a-z0-9-]+)?$
#   provision  can-provision
#   reach      can-reach-porter
#   deploy     can-deploy-porter
#   replicate  can-replicate
#
# Catalog: ${CLAIMS_CATALOG:-${OPS_REPO_ROOT:-}/catalog/claims.md}. Rows
# split on `|`. A leading `|` is the markdown-table marker (the claims
# report writes one), not a cell. The first cell is the id, the third is
# the status, both trimmed. Status challenged is a gap. Any other status,
# a missing row, or a missing catalog file is not challenged.
#
# Hermetic: lib/claims.sh only. Does not source lib/env.sh. No network,
# no writes, no secrets (AD-006).
# =============================================================================
set -euo pipefail

# shellcheck source=../lib/claims.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib/claims.sh"

# ladder_lowest_gap — print the lowest missing or challenged rung, or nothing.
ladder_lowest_gap() {
  local catalog ids id line rest cell_id cell_status
  local rung matched challenged_match
  local -a ids_arr=()
  local -A challenged=()

  ids="$(claim_ids)" || ids=""
  while IFS= read -r id; do
    [ -n "$id" ] || continue
    ids_arr+=("$id")
  done <<< "$ids"

  catalog="${CLAIMS_CATALOG:-${OPS_REPO_ROOT:-}/catalog/claims.md}"
  if [ -f "$catalog" ]; then
    while IFS= read -r line || [ -n "$line" ]; do
      case "$line" in
        *\|*) ;;
        *) continue ;;
      esac
      line="${line#"${line%%[![:space:]]*}"}"
      line="${line%"${line##*[![:space:]]}"}"
      # A markdown row starts with `|`. That empty field is not the id.
      line="${line#|}"
      cell_id="${line%%|*}"
      rest="${line#*|}"
      rest="${rest#*|}"
      cell_status="${rest%%|*}"
      cell_id="${cell_id#"${cell_id%%[![:space:]]*}"}"
      cell_id="${cell_id%"${cell_id##*[![:space:]]}"}"
      cell_status="${cell_status#"${cell_status%%[![:space:]]*}"}"
      cell_status="${cell_status%"${cell_status##*[![:space:]]}"}"
      if [ -n "$cell_id" ] && [ "$cell_status" = "challenged" ]; then
        challenged["$cell_id"]=1
      fi
    done < "$catalog"
  fi

  for rung in sense provision reach deploy replicate; do
    matched=0
    challenged_match=0
    if [ "${#ids_arr[@]}" -gt 0 ]; then
      for id in "${ids_arr[@]}"; do
        case "$rung" in
          sense)
            [[ "$id" =~ ^can-sense(-[a-z0-9-]+)?$ ]] || continue
            ;;
          provision)
            [ "$id" = "can-provision" ] || continue
            ;;
          reach)
            [ "$id" = "can-reach-porter" ] || continue
            ;;
          deploy)
            [ "$id" = "can-deploy-porter" ] || continue
            ;;
          replicate)
            [ "$id" = "can-replicate" ] || continue
            ;;
          *)
            continue
            ;;
        esac
        matched=1
        if [ -n "${challenged[$id]:-}" ]; then
          challenged_match=1
        fi
      done
    fi
    if [ "$matched" -eq 0 ] || [ "$challenged_match" -eq 1 ]; then
      printf '%s\n' "$rung"
      return 0
    fi
  done
  return 0
}
