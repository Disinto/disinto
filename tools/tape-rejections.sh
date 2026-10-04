#!/usr/bin/env bash
# =============================================================================
# tools/tape-rejections.sh — rejected issues reach the tape (#1631)
#
# A proposal that is rejected before it runs never reaches the tape, so the
# tape only knows what was approved. This tool is the missing half: a rejected
# proposal is written when it is rejected, with decision rejected, and never
# runs. On disinto an issue is rejected by labelling it `rejected` and closing
# it (a human or an organ); a predictor issue is rejected with
# `prediction/dismissed`.
#
# List closed issues labelled `rejected`, then those labelled
# `prediction/dismissed`:
#   forge_api GET "/issues?state=closed&type=issues&labels=<label>&limit=50"
# every page (`&page=N`, stop when a page returns fewer than 50).
#
# Skip an issue when ${TAPE_DIR}/rejected/issue-<N> exists, or when the tape
# already holds a proposal whose ref is <N> (any loop; the dev agent's own
# refusals already have one). Otherwise mint a fresh id the same way
# emit_tape_proposal (dev/dev-poll.sh) does (uuidgen, then the kernel uuid)
# and append
#   tape_proposal "$id" dev "$class" "" "" '{}' "" rejected "<N>"
# class is sprint_field of the issue's milestone description for `class`
# (lib/sprint-block.sh); unclassed when the milestone has no class line;
# backlog when the issue has no milestone. Then touch the marker.
#
# The gardener calls this right after tools/sprint-outcomes.sh (#1676). A
# non-zero exit only logs a warning; it never fails the gardener run.
#
# Usage:
#   tools/tape-rejections.sh
#
# Environment (all optional; the test seam):
#   TAPE_DIR     tape directory (default /srv/disinto/tape)
#   FORGE_API    repo API base, used only when forge_api is not already a
#                function or a command
#   FORGE_TOKEN  token for that fallback
#
# Exit codes:
#   0  every listed issue was recorded or skipped
#   1  a page could not be listed, or a proposal could not be minted,
#      appended, or marked — nothing was marked for a proposal that is not
#      on the tape
#
# Hermetic aside from the tape and forge_api it is pointed at. No agent, no
# secrets (AD-006). Does not source lib/env.sh: the gardener already loaded
# the project, and a hermetic run must not require USER/HOME or re-read .env.
# =============================================================================
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

# shellcheck source=../lib/sprint-block.sh
source "$REPO_ROOT/lib/sprint-block.sh"
# shellcheck source=../lib/tape.sh
source "$REPO_ROOT/lib/tape.sh"
# shellcheck source=../lib/forge-api-fallback.sh
source "$REPO_ROOT/lib/forge-api-fallback.sh"

TAPE_DIR="${TAPE_DIR:-/srv/disinto/tape}"
TAPE_FILE="${TAPE_DIR}/tape.jsonl"
REJECT_DIR="${TAPE_DIR}/rejected"

command -v jq >/dev/null 2>&1 || {
  echo "tape-rejections: required tool missing: jq" >&2
  exit 1
}

# Same shape as lib/env.sh log(), without sourcing it (see header).
log() {
  printf '[%s] %s: %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" \
    "${LOG_AGENT:-tape-rejections}" "$*"
}

# _fresh_id — echo a fresh id, or nothing when no generator exists.
# Same order as emit_tape_proposal (dev/dev-poll.sh): uuidgen, then kernel.
_fresh_id() {
  local minted=""
  minted="$(uuidgen 2>/dev/null || true)"
  if [ -z "$minted" ]; then
    minted="$(cat /proc/sys/kernel/random/uuid 2>/dev/null || true)"
  fi
  if [ -n "$minted" ]; then
    printf '%s' "$minted"
  fi
}

# _load_refs — one ref per line, from proposal records already on the tape.
# Malformed lines are skipped (a torn final line must not fail the listing).
# Numeric refs are stringified so a ref of 5 matches issue 5.
_load_refs() {
  TAPE_REFS="$(mktemp)"
  local line ref
  if [ -f "$TAPE_FILE" ]; then
    while IFS= read -r line || [ -n "${line:-}" ]; do
      [ -n "$line" ] || continue
      ref="$(printf '%s' "$line" | jq -r \
        'select(type == "object" and .type == "proposal")
         | .ref
         | if type == "string" or type == "number" then tostring else empty end' \
        2>/dev/null || true)"
      if [ -n "$ref" ]; then
        printf '%s\n' "$ref"
      fi
    done < "$TAPE_FILE" > "$TAPE_REFS"
  else
    : > "$TAPE_REFS"
  fi
}

# _tape_has_ref N — true when a loaded proposal ref equals N.
_tape_has_ref() {
  grep -Fxq -- "$1" "$TAPE_REFS"
}

# _class_of ISSUE_JSON — backlog (no milestone), the class line, or unclassed.
_class_of() {
  local issue_json="$1"
  local kind desc class
  kind="$(printf '%s' "$issue_json" | jq -r '.milestone | type')"
  if [ "$kind" != "object" ]; then
    printf '%s' backlog
    return 0
  fi
  desc="$(printf '%s' "$issue_json" | jq -r '.milestone.description // empty')"
  class="$(sprint_field "$desc" class)"
  if [ -n "$class" ]; then
    printf '%s' "$class"
  else
    printf '%s' unclassed
  fi
}

# _record_one ISSUE_JSON — append a rejected dev proposal, or skip.
#   0  recorded, or skipped (marker, existing ref, or a non-numeric number)
#   1  mint, append, or marker failed; no marker for a proposal not on the tape
_record_one() {
  local issue_json="$1"
  local number marker class id
  number="$(printf '%s' "$issue_json" | jq -r '.number // empty')"
  if ! [[ "$number" =~ ^[0-9]+$ ]]; then
    log "WARNING: skipped an issue with no numeric number"
    return 0
  fi
  marker="${REJECT_DIR}/issue-${number}"
  if [ -e "$marker" ]; then
    return 0
  fi
  if _tape_has_ref "$number"; then
    return 0
  fi

  class="$(_class_of "$issue_json")"
  id="$(_fresh_id)"
  if [ -z "$id" ]; then
    log "WARNING: no uuid generator available — rejected proposal not minted for #${number}"
    return 1
  fi
  # No parent, no forecast, empty context: the proposal never runs.
  if ! tape_proposal "$id" dev "$class" "" "" '{}' "" rejected "$number"; then
    log "WARNING: tape append failed for rejected #${number} — no marker written"
    return 1
  fi
  # The in-run set must know about the append before the marker, so a second
  # label listing the same number cannot append again if the touch fails.
  printf '%s\n' "$number" >> "$TAPE_REFS"
  if ! mkdir -p "$REJECT_DIR" || ! touch "$marker"; then
    log "WARNING: failed to touch marker for rejected #${number}"
    return 1
  fi
  log "recorded rejected proposal ${id} for #${number} (class: ${class})"
  return 0
}

# _list_label LABEL — every page of closed issues with that label.
#   0  each issue on each page was recorded or skipped
#   1  a page could not be listed, or a record failed
_list_label() {
  local label="$1"
  local page=1 body count rc prev="" issue_json label_failed=0
  while true; do
    rc=0
    body="$(forge_api GET \
      "/issues?state=closed&type=issues&labels=${label}&limit=50&page=${page}")" || rc=$?
    if [ "$rc" -ne 0 ]; then
      log "WARNING: listing closed ${label} issues failed (page ${page}, rc=${rc})"
      return 1
    fi
    if ! printf '%s' "$body" | jq -e 'type == "array"' >/dev/null 2>&1; then
      log "WARNING: listing closed ${label} issues returned a non-array (page ${page})"
      return 1
    fi
    count="$(printf '%s' "$body" | jq 'length')"
    if [ "$count" -eq 0 ]; then
      return "$label_failed"
    fi
    # A stub (or a broken page) that ignores `page` and repeats a full page
    # must not loop forever.
    if [ -n "$prev" ] && [ "$body" = "$prev" ]; then
      log "WARNING: listing closed ${label} issues repeated page ${page} — stopping"
      return 1
    fi
    prev="$body"
    while IFS= read -r issue_json; do
      [ -n "$issue_json" ] || continue
      _record_one "$issue_json" || label_failed=1
    done < <(printf '%s' "$body" | jq -c '.[]')
    if [ "$count" -lt 50 ]; then
      return "$label_failed"
    fi
    page=$((page + 1))
  done
}

TAPE_REFS=""
cleanup() {
  if [ -n "${TAPE_REFS:-}" ]; then
    rm -f "$TAPE_REFS"
  fi
}
trap cleanup EXIT

_load_refs

reject_failed=0
_list_label rejected || reject_failed=1
_list_label "prediction/dismissed" || reject_failed=1
exit "$reject_failed"
