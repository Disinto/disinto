#!/usr/bin/env bash
# =============================================================================
# planner/gaps.sh — the challenged can-* claims the ladder cannot name (#2056)
#
# The ladder (planner/ladder.sh) knows five rungs; a can-* claim outside them
# is invisible there. A suspended remedy is a named gap (docs/design/
# proposal-loop.md §5, §8): the planner pitches the step that would add the
# missing capability, after the ladder. Which step that is, bash cannot know
# (for disk-pressure it was the sense rung), so this reader only names the
# gap and the planning session pitches it.
#
# Function (sourced; called by planner/planner-run.sh):
#   planner_claim_gaps
#     -> the ids from claim_ids (lib/claims.sh) that match ^can-, are not a
#        rung id (^can-(sense(-[a-z0-9-]+)?|provision|reach-porter|
#        deploy-porter|replicate)$ — the ladder's own patterns), and whose
#        row in the catalog has status challenged. One id per line, sorted
#        (claim_ids order). Nothing when none match or the catalog is
#        missing. Always returns 0. No arguments.
#
# Catalog: ${CLAIMS_CATALOG:-${OPS_REPO_ROOT:-}/catalog/claims.md}, read by
# one awk program — the claims-report.sh table shape: rows split on `|`, the
# leading `|` is the markdown-table marker (not a cell), the first cell is
# the id, the third is the status, both trimmed. The loop in ladder.sh is
# not copied here (CI rejects duplicated windows).
#
# Hermetic: lib/claims.sh only. Does not source lib/env.sh. No network, no
# writes, no secrets (AD-006).
# =============================================================================
set -euo pipefail

# shellcheck source=../lib/claims.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib/claims.sh"

# _planner_challenged_ids — ids whose catalog row carries status challenged.
# One awk pass over the catalog; prints nothing when the file is missing.
_planner_challenged_ids() {
  local catalog="${CLAIMS_CATALOG:-${OPS_REPO_ROOT:-}/catalog/claims.md}"
  [ -f "$catalog" ] || return 0
  awk '
    function trim(s) {
      gsub(/^[ \t]+/, "", s)
      gsub(/[ \t]+$/, "", s)
      return s
    }
    {
      line = $0
      sub(/\r$/, "", line)
      if (index(line, "|") == 0) next
      line = trim(line)
      if (substr(line, 1, 1) == "|") line = substr(line, 2)
      if (split(line, cell, "|") < 3) next
      id = trim(cell[1])
      status = trim(cell[3])
      if (id != "" && status == "challenged") print id
    }
  ' "$catalog"
}

# planner_claim_gaps — print the challenged can-* claims that are not ladder
# rungs, one per line, sorted. Always returns 0.
planner_claim_gaps() {
  local id ids
  local -A challenged=()

  while IFS= read -r id; do
    [ -n "$id" ] || continue
    challenged["$id"]=1
  done < <(_planner_challenged_ids)

  ids="$(claim_ids)" || ids=""
  while IFS= read -r id; do
    [ -n "$id" ] || continue
    [[ "$id" =~ ^can- ]] || continue
    if [[ "$id" =~ ^can-(sense(-[a-z0-9-]+)?|provision|reach-porter|deploy-porter|replicate)$ ]]; then
      continue
    fi
    [ -n "${challenged[$id]:-}" ] || continue
    printf '%s\n' "$id"
  done <<< "$ids"
  return 0
}
