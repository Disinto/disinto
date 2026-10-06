#!/usr/bin/env bash
# ci-first-green.sh — the PR's first Woodpecker pull_request pipeline (#1877)
#
# ci_first_green_bits PR_NUMBER BITS_JSON
#   Prints BITS_JSON as one compact line, with ci_first_green added when the
#   PR's first Woodpecker pull_request pipeline is known:
#     1 — that pipeline's status is success
#     0 — failure, error, killed, or canceled
#   The first pipeline is the entry with the lowest .number. BITS_JSON is
#   printed unchanged when the bit is unknown: PR_NUMBER is not an integer,
#   WOODPECKER_REPO_ID is unset or 0, the one API call fails or times out,
#   the response is not a non-empty array shorter than a full page of 50
#   (the first pipeline may be on a later page), or the status is anything
#   else (pending, running, blocked, ...). Always returns 0. No paging.
#
# Requires: woodpecker_api() (lib/env.sh), jq.
#
# Hermetic when woodpecker_api is stubbed. One call, no forge, no agent.

set -euo pipefail

# ci_first_green_bits PR_NUMBER BITS_JSON — see the file header.
ci_first_green_bits() {
  local pr="${1:-}"
  local bits="${2:-}"
  local repo_id="${WOODPECKER_REPO_ID:-}"
  local body="" count="" status="" bit="" out=""

  # No call when the PR or the repo id cannot name a pipeline list.
  if ! [[ "$pr" =~ ^[0-9]+$ ]] || [ -z "$repo_id" ] || [ "$repo_id" = "0" ]; then
    printf '%s\n' "$bits"
    return 0
  fi

  # One page. woodpecker_api forwards --max-time to curl (lib/env.sh).
  if ! body="$(woodpecker_api "/repos/${repo_id}/pipelines?event=pull_request&ref=refs/pull/${pr}/head&perPage=50" --max-time 10)"; then
    printf '%s\n' "$bits"
    return 0
  fi

  # Non-array, empty, or a full page: the first pipeline is not on this page.
  count="$(printf '%s' "$body" | jq -r 'if type == "array" then length else empty end' 2>/dev/null)" || count=""
  if ! [[ "$count" =~ ^[0-9]+$ ]] || [ "$count" -eq 0 ] || [ "$count" -ge 50 ]; then
    printf '%s\n' "$bits"
    return 0
  fi

  status="$(printf '%s' "$body" | jq -r 'min_by(.number) | .status // empty' 2>/dev/null)" || status=""
  case "$status" in
    success) bit=1 ;;
    failure|error|killed|canceled) bit=0 ;;
    *)
      printf '%s\n' "$bits"
      return 0
      ;;
  esac

  # Invalid BITS_JSON must not drop the outcome: print it unchanged.
  if ! out="$(printf '%s' "$bits" | jq -c --argjson b "$bit" '. + {ci_first_green: $b}' 2>/dev/null)"; then
    printf '%s\n' "$bits"
    return 0
  fi
  printf '%s\n' "$out"
  return 0
}
