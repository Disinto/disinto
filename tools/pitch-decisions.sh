#!/usr/bin/env bash
# =============================================================================
# tools/pitch-decisions.sh — a pitch closed unmerged reaches the tape (#1891)
#
# A pitch is an ops-repo PR that adds sprints/<slug>.md. When the owner closes
# it unmerged, the tape gets a rejected sprint proposal. Merged pitches are
# left unmarked; #1892 turns those into the sprint.
#
# List closed ops-repo PRs:
#   curl -sf -H "Authorization: token ${FORGE_TOKEN}" \
#     "${FORGE_API_BASE}/repos/${FORGE_OPS_REPO}/pulls?state=closed&limit=50&page=N"
# for N = 1, 2, … until a page has fewer than 50. A page that fails, or is
# not a JSON array, logs a warning and exits 1.
#
# Skip a PR when ${TAPE_DIR}/pitches/pr-<P> exists. Otherwise GET
# …/pulls/<P>/files. A pitch is a files entry with status "added" and a
# filename matching ^sprints/[^/]+\.md$. A failed files call logs a warning,
# writes no marker, and the run exits 1 after the remaining PRs. A PR that
# is not a pitch is marked and not recorded.
#
# An unmerged pitch (merged == false) appends
#   tape_proposal "$id" sprint "$class" "" "" '{"pitch":<P>}' "" rejected "pitch:<P>"
# class is sprint_field of the PR body for `class`, or unclassed when that
# is empty. The id is uuidgen, then the kernel uuid. The marker is written
# only after the append; a failed append logs a warning and writes no marker.
#
# The gardener calls this right after resolve_forge_remote, before the
# precondition checks, so an early exit still records the decision. A
# non-zero exit only logs a warning; it never fails the gardener run.
#
# Usage:
#   tools/pitch-decisions.sh
#
# Environment:
#   TAPE_DIR        tape directory (default /srv/disinto/tape)
#   FORGE_API_BASE  forge API base (no trailing path)
#   FORGE_OPS_REPO  owner/name of the ops repo
#   FORGE_TOKEN     token for the Authorization header
#
# Exit codes:
#   0  every closed PR was recorded, marked, or skipped
#   1  a page could not be listed, or a pitch could not be read, appended,
#      or marked — nothing was marked for a decision that is not on the tape
#
# Hermetic aside from the tape and the forge it is pointed at. No agent, no
# secrets (AD-006). Does not source lib/env.sh: the gardener already loaded
# the project, and a hermetic run must not require USER/HOME or re-read .env.
# =============================================================================
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

# shellcheck source=../lib/sprint-block.sh
source "$REPO_ROOT/lib/sprint-block.sh"
# shellcheck source=../lib/tape.sh
source "$REPO_ROOT/lib/tape.sh"

TAPE_DIR="${TAPE_DIR:-/srv/disinto/tape}"

if ! command -v jq >/dev/null 2>&1; then
  printf 'pitch-decisions: jq is required\n' >&2
  exit 1
fi
if ! command -v curl >/dev/null 2>&1; then
  printf 'pitch-decisions: curl is required\n' >&2
  exit 1
fi

# Warnings only. stdout stays empty so a caller can tell a decision from a log.
log() { printf 'pitch-decisions: WARNING: %s\n' "$*" >&2; }

# ops_get PATH — GET under the ops repo. The caller sees curl's status.
ops_get() {
  curl -sf -H "Authorization: token ${FORGE_TOKEN}" \
    "${FORGE_API_BASE}/repos/${FORGE_OPS_REPO}${1}"
}

# mark_seen P — create pitches/pr-P. A failure leaves the decision unmarked.
mark_seen() {
  local number="$1"
  local dir="${TAPE_DIR}/pitches"
  mkdir -p "$dir" || return 1
  touch "${dir}/pr-${number}" || return 1
}

# reject_unmerged PR_JSON P — append the rejected sprint proposal, then mark.
# A failed append writes no marker.
reject_unmerged() {
  local pr_json="$1" number="$2"
  local body="" class="" id="" ctx=""
  body="$(printf '%s' "$pr_json" | jq -r '.body // empty' 2>/dev/null || true)"
  class="$(sprint_field "$body" class || true)"
  if [ -z "$class" ]; then
    class="unclassed"
  fi
  id="$(uuidgen 2>/dev/null || cat /proc/sys/kernel/random/uuid)" || id=""
  if [ -z "$id" ]; then
    log "could not mint an id for pitch ${number}; no marker written"
    return 1
  fi
  ctx="$(jq -cn --argjson p "$number" '{pitch: $p}')" || ctx=""
  if [ -z "$ctx" ]; then
    log "could not build context for pitch ${number}; no marker written"
    return 1
  fi
  if ! tape_proposal "$id" sprint "$class" "" "" "$ctx" "" rejected "pitch:${number}"; then
    log "tape append failed for pitch ${number}; no marker written"
    return 1
  fi
  if ! mark_seen "$number"; then
    log "pitch ${number} was appended but its marker could not be written"
    return 1
  fi
  return 0
}

# handle_pr PR_JSON — record, mark, or skip one closed PR.
#   0  recorded, marked as not a pitch, skipped (marker or merged pitch)
#   1  files, append, or marker failed; no marker for a decision not on the tape
handle_pr() {
  local pr_json="$1"
  local number="" files_body="" files_rc=0 pitch="" marker=""
  number="$(printf '%s' "$pr_json" | jq -r '.number // empty' 2>/dev/null || true)"
  if ! [[ "$number" =~ ^[0-9]+$ ]]; then
    log "skipped a closed PR with no numeric number"
    return 0
  fi
  marker="${TAPE_DIR}/pitches/pr-${number}"
  if [ -e "$marker" ]; then
    return 0
  fi

  files_rc=0
  files_body="$(ops_get "/pulls/${number}/files")" || files_rc=$?
  if [ "$files_rc" -ne 0 ]; then
    log "files listing failed for PR ${number} (rc=${files_rc}); no marker written"
    return 1
  fi
  if ! printf '%s' "$files_body" | jq -e 'type == "array"' >/dev/null 2>&1; then
    log "files listing for PR ${number} was not a JSON array; no marker written"
    return 1
  fi
  pitch="$(printf '%s' "$files_body" | jq -r --arg re '^sprints/[^/]+\.md$' \
    'if any(.[]; .status == "added" and ((.filename // "") | test($re))) then "yes" else "no" end')" \
    || pitch=""
  if [ -z "$pitch" ]; then
    log "could not read the file list for PR ${number}; no marker written"
    return 1
  fi
  if [ "$pitch" != "yes" ]; then
    mark_seen "$number"
    return $?
  fi
  # Merged pitches stay unmarked so #1892 can still see them.
  if printf '%s' "$pr_json" | jq -e '.merged == false' >/dev/null 2>&1; then
    reject_unmerged "$pr_json" "$number"
    return $?
  fi
  return 0
}

# walk_closed — every page of closed ops-repo PRs.
#   0  each PR was recorded, marked, or skipped
#   1  a page could not be listed, or a PR's decision failed
walk_closed() {
  local page=1 list_body="" list_rc=0 count="" kind="" pr_json="" any_failed=0
  while true; do
    list_rc=0
    list_body="$(ops_get "/pulls?state=closed&limit=50&page=${page}")" || list_rc=$?
    if [ "$list_rc" -ne 0 ]; then
      log "listing closed ops-repo PRs failed (page ${page}, rc=${list_rc})"
      exit 1
    fi
    kind="$(printf '%s' "$list_body" | jq -r 'type' 2>/dev/null || printf 'invalid')"
    if [ "$kind" != "array" ]; then
      log "listing closed ops-repo PRs returned ${kind}, not an array (page ${page})"
      exit 1
    fi
    count="$(printf '%s' "$list_body" | jq 'length' 2>/dev/null || true)"
    if ! [[ "$count" =~ ^[0-9]+$ ]]; then
      log "listing closed ops-repo PRs had no length (page ${page})"
      exit 1
    fi
    if [ "$count" -gt 0 ]; then
      while IFS= read -r pr_json || [ -n "${pr_json:-}" ]; do
        [ -n "${pr_json:-}" ] || continue
        if ! handle_pr "$pr_json"; then
          any_failed=1
        fi
      done < <(printf '%s\n' "$list_body" | jq -c '.[]')
    fi
    # Stop once a page is short. A full page means another may follow.
    if [ "$count" -lt 50 ]; then
      break
    fi
    page=$((page + 1))
  done
  return "$any_failed"
}

closed_rc=0
walk_closed || closed_rc=$?
exit "$closed_rc"
