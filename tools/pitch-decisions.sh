#!/usr/bin/env bash
# =============================================================================
# tools/pitch-decisions.sh — a decided pitch reaches the tape (#1891, #1892)
#
# A pitch is an ops-repo PR that adds sprints/<slug>.md. When the owner closes
# it unmerged, the tape gets a rejected sprint proposal. When the owner merges
# it, the project gets the sprint's milestone and its sub-issues, and the tape
# gets an approved sprint proposal (#1892).
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
# A merged pitch (merged == true) whose added file is sprints/<slug>.md, in
# order:
#   1. file="${OPS_REPO_ROOT}/sprints/<slug>.md". Missing: warning, no marker,
#      the run exits 1 after the remaining PRs.
#   2. pitch_sprint_block. Failure: log "pitch #P has no sprint block", touch
#      the marker, record nothing.
#   3. N=$(sprint_milestone_ensure "$file"). Failure: warning, no marker.
#   4. class from sprint_field of the block, then
#      sprint_proposal_id "$N" "$class" '{"pitch":<P>}'. Failure: warning, no
#      marker. The proposal is approved, ref milestone:<N>; the id file is
#      ${TAPE_DIR}/sprints/<N>.
#   5. If the file contains <!-- filer:begin -->, run
#      bash "$SPRINT_FILER" "$file" "$N" as a separate process. It sources
#      lib/env.sh itself; FACTORY_ROOT is not set. Failure: warning, no
#      marker. The next run finds the milestone and the id file again, and
#      the filer skips issues it already filed.
#   6. Touch ${TAPE_DIR}/pitches/pr-P.
# The proposal is written before the sub-issues are filed, so dev-poll's
# sprint_proposal_id finds the id file and never mints a second proposal.
#
# The gardener calls this right after resolve_forge_remote, before the
# precondition checks, so an early exit still records the decision. A
# non-zero exit only logs a warning; it never fails the gardener run.
#
# Usage:
#   tools/pitch-decisions.sh
#
# Environment:
#   TAPE_DIR           tape directory (default /srv/disinto/tape)
#   FORGE_API_BASE     forge API base (no trailing path)
#   FORGE_OPS_REPO     owner/name of the ops repo
#   FORGE_TOKEN        token for the Authorization header
#   OPS_REPO_ROOT      ops clone (ensure_ops_repo syncs it at run start)
#   FORGE_API          project-repo API (milestone ensure and the filer)
#   FORGE_FILER_TOKEN  filer-bot token (milestone ensure and the filer)
#   SPRINT_FILER       sub-issue filer (default $REPO_ROOT/lib/sprint-filer.sh;
#                      a test seam)
#
# Exit codes:
#   0  every closed PR was recorded, marked, or skipped
#   1  a page could not be listed, or a pitch could not be read, appended,
#      filed, or marked — nothing was marked for a decision that is not on
#      the tape
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
# shellcheck source=../lib/pitch.sh
source "$REPO_ROOT/lib/pitch.sh"
# shellcheck source=../lib/sprint-milestone.sh
source "$REPO_ROOT/lib/sprint-milestone.sh"
# shellcheck source=../lib/sprint-tape.sh
source "$REPO_ROOT/lib/sprint-tape.sh"

TAPE_DIR="${TAPE_DIR:-/srv/disinto/tape}"
SPRINT_FILER="${SPRINT_FILER:-$REPO_ROOT/lib/sprint-filer.sh}"

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

# approve_merged P RELPATH — a merged pitch becomes its sprint (#1892).
# Order: file, sprint block, milestone, approved proposal, sub-issues, marker.
# A missing file, or a failed milestone, proposal, or filer, writes no marker.
# A file with no sprint block is marked and nothing is recorded.
#   0  marked (sprint filed, or no sprint block)
#   1  a step failed and the marker was not written
approve_merged() {
  local number="$1" relpath="$2"
  local file="${OPS_REPO_ROOT:-}/${relpath}"
  local block="" class="" ctx="" n=""

  if [ ! -f "$file" ]; then
    log "pitch file missing for pitch ${number} (${file}); no marker written"
    return 1
  fi

  if ! block="$(pitch_sprint_block "$file")"; then
    log "pitch #${number} has no sprint block"
    if ! mark_seen "$number"; then
      log "pitch #${number} has no sprint block, and its marker could not be written"
      return 1
    fi
    return 0
  fi

  if ! n="$(sprint_milestone_ensure "$file")" || [ -z "$n" ]; then
    log "milestone ensure failed for pitch ${number}; no marker written"
    return 1
  fi

  class="$(sprint_field "$block" class)"
  if ! ctx="$(jq -cn --argjson p "$number" '{pitch: $p}')"; then
    log "could not build context for pitch ${number}; no marker written"
    return 1
  fi
  # The id is on the tape and in the id file. stdout stays empty (warnings only).
  if ! sprint_proposal_id "$n" "$class" "$ctx" >/dev/null; then
    log "proposal failed for pitch ${number}; no marker written"
    return 1
  fi

  # Separate process: the filer sources lib/env.sh itself. Do not set
  # FACTORY_ROOT — an exported one from the gardener must not leak in.
  if grep -qF '<!-- filer:begin -->' "$file"; then
    if ! env -u FACTORY_ROOT bash "$SPRINT_FILER" "$file" "$n"; then
      log "filer failed for pitch ${number}; no marker written"
      return 1
    fi
  fi

  if ! mark_seen "$number"; then
    log "pitch ${number} was filed but its marker could not be written"
    return 1
  fi
  return 0
}

# handle_pr PR_JSON — record, mark, or skip one closed PR.
#   0  recorded, marked as not a pitch, skipped (marker), or a merged pitch
#      with no sprint block was marked
#   1  files, append, milestone, proposal, filer, or marker failed; no marker
#      for a decision not on the tape
handle_pr() {
  local pr_json="$1"
  local number="" files_body="" files_rc=0 added="" added_rc=0 marker=""
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
  added_rc=0
  added="$(printf '%s' "$files_body" | jq -r --arg re '^sprints/[^/]+\.md$' \
    '[.[] | select(.status == "added" and ((.filename // "") | test($re))) | .filename] | first // empty')" \
    || added_rc=$?
  if [ "$added_rc" -ne 0 ]; then
    log "could not read the file list for PR ${number}; no marker written"
    return 1
  fi
  if [ -z "$added" ]; then
    mark_seen "$number"
    return $?
  fi
  if printf '%s' "$pr_json" | jq -e '.merged == false' >/dev/null 2>&1; then
    reject_unmerged "$pr_json" "$number"
    return $?
  fi
  if printf '%s' "$pr_json" | jq -e '.merged == true' >/dev/null 2>&1; then
    approve_merged "$number" "$added"
    return $?
  fi
  # Closed, but neither merged nor unmerged: leave unmarked.
  return 0
}

# walk_closed — every page of closed ops-repo PRs.
#   0  each PR was recorded, marked, or skipped
#   1  a page could not be listed, or a PR's decision failed
walk_closed() {
  local page=0 list_body="" list_rc=0 count=50 kind="" pr_json="" any_failed=0
  # A full page (50) means another may follow. A short page ends the walk.
  while [ "$count" -ge 50 ]; do
    page=$((page + 1))
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
    [ "$count" -eq 0 ] && continue
    while IFS= read -r pr_json || [ -n "${pr_json:-}" ]; do
      [ -n "${pr_json:-}" ] || continue
      if ! handle_pr "$pr_json"; then
        any_failed=1
      fi
    done < <(printf '%s\n' "$list_body" | jq -c '.[]')
  done
  return "$any_failed"
}

closed_rc=0
walk_closed || closed_rc=$?
exit "$closed_rc"
