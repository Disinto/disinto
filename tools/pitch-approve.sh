#!/usr/bin/env bash
# =============================================================================
# tools/pitch-approve.sh — the gate merges a bot's ready pitch (#2038)
#
# A pitch is an ops-repo PR adding sprints/<slug>.md, opened by planner-bot
# (planner/pitch-open.sh) or the gardener. The owner used to merge it by
# hand; since 2026-11-02 the gate merges it itself and tells the owner
# (docs/design/proposal-loop.md §3; notes/organs.md, "Pitches go through the
# existing vault gate", item 3). tools/pitch-decisions.sh writes the tape row
# today once the PR is closed.
#
# List open ops-repo PRs the way tools/pitch-decisions.sh walks closed ones:
#   curl -sf -H "Authorization: token ${FORGE_TOKEN}" \
#     "${FORGE_API_BASE}/repos/${FORGE_OPS_REPO}/pulls?state=open&limit=50&page=N"
# for N = 1, 2, … until a page has fewer than 50. A page that fails, or is
# not a JSON array, logs a warning and exits 1.
#
# A PR is considered when its .user.login is one of the comma-separated
# ${FORGE_BOT_USERNAMES} and the marker ${TAPE_DIR}/gate/pr-<P> is absent.
# Per such PR, in order:
#   1. path=$(pitch_pr_path P). No pitch file: not a pitch — skip, no marker.
#   2. pitch_pr_fetch P path tmp. Ready when: pitch_sprint_block tmp
#      succeeds; tmp contains `<!-- filer:begin -->` (the architect has
#      drafted the sub-issues onto the branch); "${PITCH_LINT:-
#      tools/pitch-lint.sh}" tmp exits 0; and the block's `effect` is `none`,
#      a file under ${OPS_REPO_ROOT}, or a filename in GET /pulls/P/files —
#      a sprint whose probe is not in the ops repo is never scored
#      (tools/sprint-outcomes.sh skips a failing probe every run). Not
#      ready: one warning naming the missing piece, no marker, next run
#      retries.
#   3. tier=$("${CLASSIFY:-action-vault/classify.sh}" pitch); a failing
#      classifier means high.
#   4. POST /pulls/P/merge with body {"Do":"merge"} and FORGE_TOKEN. Failure:
#      warning, no marker, the run exits 1 at the end.
#   5. notice_owner "pitch #P '<title>' approved by the gate (tier <tier>):
#      <html_url>", then mkdir -p ${TAPE_DIR}/gate and touch the marker.
#
# Usage:
#   tools/pitch-approve.sh
#
# Environment:
#   FORGE_API_BASE          forge API base (no trailing path)
#   FORGE_OPS_REPO          owner/name of the ops repo
#   FORGE_TOKEN            token for the Authorization header
#   FORGE_BOT_USERNAMES    comma-separated bot logins (lib/env.sh)
#   OPS_REPO_ROOT          ops clone (ensure_ops_repo syncs it at run start)
#   TAPE_DIR               tape directory (default /srv/disinto/tape)
#   PITCH_LINT             lint seam (default $REPO_ROOT/tools/pitch-lint.sh)
#   CLASSIFY               tier seam (default $REPO_ROOT/action-vault/classify.sh)
#
# Exit codes:
#   0  every open bot pitch was merged, skipped, or left unready for the
#      next run
#   1  a page could not be listed, or a ready pitch could not be merged
#
# The gardener calls this right after the run lock, before ensure_ops_repo,
# so the merged pitch is pulled by the ops sync and pitch-decisions.sh files
# it in the same run. A non-zero exit only logs a warning; it never fails the
# gardener run.
#
# Hermetic apart from the forge it is pointed at and the tape markers it
# writes. No agent, no secrets (AD-006). No lib/env.sh here: the gardener
# already loaded the project.
# =============================================================================
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

# shellcheck source=../lib/pitch.sh
source "$REPO_ROOT/lib/pitch.sh"
# shellcheck source=../lib/pitch-pr.sh
source "$REPO_ROOT/lib/pitch-pr.sh"
# shellcheck source=../lib/notice.sh
source "$REPO_ROOT/lib/notice.sh"

TAPE_DIR="${TAPE_DIR:-/srv/disinto/tape}"
PITCH_LINT="${PITCH_LINT:-$REPO_ROOT/tools/pitch-lint.sh}"
CLASSIFY="${CLASSIFY:-$REPO_ROOT/action-vault/classify.sh}"

if ! command -v jq >/dev/null 2>&1; then
  printf 'pitch-approve: jq is required\n' >&2
  exit 1
fi
if ! command -v curl >/dev/null 2>&1; then
  printf 'pitch-approve: curl is required\n' >&2
  exit 1
fi

# Warnings only. stdout stays empty so a caller can tell a merge from a log.
log() { printf 'pitch-approve: WARNING: %s\n' "$*" >&2; }

# ops_get PATH — GET under the ops repo. The caller sees curl's status.
ops_get() {
  curl -sf -H "Authorization: token ${FORGE_TOKEN}" \
    "${FORGE_API_BASE}/repos/${FORGE_OPS_REPO}${1}"
}

# ops_post PATH BODY — POST under the ops repo with a JSON body.
ops_post() {
  curl -sf -X POST \
    -H "Authorization: token ${FORGE_TOKEN}" \
    -H "Content-Type: application/json" \
    -d "$2" \
    "${FORGE_API_BASE}/repos/${FORGE_OPS_REPO}${1}"
}

# is_bot LOGIN — 0 when LOGIN appears in the comma list FORGE_BOT_USERNAMES.
is_bot() {
  local login="$1" list
  list="${FORGE_BOT_USERNAMES:-}"
  if [ -z "$list" ] || [ -z "$login" ]; then
    return 1
  fi
  case ",${list}," in
    *,${login},*) return 0 ;;
    *) return 1 ;;
  esac
}

# mark_approved P — create gate/pr-P. A failure leaves the approval unmarked.
mark_approved() {
  local number="$1"
  local dir="${TAPE_DIR}/gate"
  mkdir -p "$dir" || return 1
  touch "${dir}/pr-${number}" || return 1
}

# probe_present P EFFECT — the effect of a scorable sprint: `none`, a file
# under OPS_REPO_ROOT, or a file the PR itself adds. An empty effect is not
# scorable.
probe_present() {
  local number="$1" effect="$2" body="" match="" rc=0
  if [ "$effect" = "none" ]; then
    return 0
  fi
  if [ -n "$effect" ] && [ -f "${OPS_REPO_ROOT:-}/${effect}" ]; then
    return 0
  fi
  if [ -z "$effect" ]; then
    return 1
  fi
  rc=0
  body="$(ops_get "/pulls/${number}/files")" || rc=$?
  if [ "$rc" -ne 0 ]; then
    return 1
  fi
  # Captured, not jq -e: jq 1.6 reports success on empty output.
  match="$(printf '%s' "$body" | jq -r --arg e "$effect" \
    '.[] | .filename // empty | select(. == $e)' 2>/dev/null || true)"
  [ -n "$match" ]
}

# pitch_tier — the blast-radius tier of a pitch; high when the classifier
# fails or prints nothing.
pitch_tier() {
  local tier="" rc=0
  tier="$("${CLASSIFY}" pitch 2>/dev/null)" || rc=$?
  if [ "$rc" -ne 0 ] || [ -z "$tier" ]; then
    tier="high"
  fi
  printf '%s\n' "$tier"
}

# handle_open_pr PR_JSON — approve one open bot pitch, or leave it for the
# next run.
#   0  not a bot, not a pitch, already marked, or left unready (retry)
#   1  a ready pitch failed to merge or failed to be marked
handle_open_pr() {
  local pr_json="$1"
  local number="" login="" marker="" path="" tmp="" block="" effect="" tier="" rc=0
  number="$(printf '%s' "$pr_json" | jq -r '.number // empty' 2>/dev/null || true)"
  if ! [[ "$number" =~ ^[0-9]+$ ]]; then
    return 0
  fi
  login="$(printf '%s' "$pr_json" | jq -r '.user.login // empty' 2>/dev/null || true)"
  if ! is_bot "$login"; then
    return 0
  fi
  marker="${TAPE_DIR}/gate/pr-${number}"
  if [ -e "$marker" ]; then
    return 0
  fi

  # 1. A pitch adds exactly one sprints/<slug>.md. Without it this PR is
  #    not a pitch: skip, and write no marker.
  path=""
  if ! path="$(pitch_pr_path "$number")"; then
    return 0
  fi

  # 2. Ready: sprint block, drafted sub-issues, lint, scorable effect.
  tmp="$(mktemp)" || {
    log "could not create a temp file for pitch #${number}; no marker written"
    return 1
  }
  if ! pitch_pr_fetch "$number" "$path" "$tmp" >/dev/null; then
    log "could not read pitch file ${path} for PR ${number}; retry next run"
    rm -f "$tmp"
    return 0
  fi
  if ! block="$(pitch_sprint_block "$tmp")"; then
    log "pitch #${number} is missing its sprint block; not merged"
    rm -f "$tmp"
    return 0
  fi
  if ! grep -qF '<!-- filer:begin -->' "$tmp"; then
    log "pitch #${number} has no filer block: the sub-issues are not drafted; not merged"
    rm -f "$tmp"
    return 0
  fi
  rc=0
  "$PITCH_LINT" "$tmp" >/dev/null 2>&1 || rc=$?
  if [ "$rc" -ne 0 ]; then
    log "pitch #${number} fails pitch-lint (rc=${rc}); the drafted sub-issues are not clean; not merged"
    rm -f "$tmp"
    return 0
  fi
  effect="$(sprint_field "$block" effect)"
  if ! probe_present "$number" "$effect"; then
    log "pitch #${number} effect probe '${effect:-missing}' is not in the ops clone or the PR files; not merged"
    rm -f "$tmp"
    return 0
  fi
  rm -f "$tmp"

  # 3. Tier from the vault classifier.
  tier="$(pitch_tier)"

  # 4. The gate merges. A failed merge leaves the PR open, writes no marker,
  # and makes the run exit 1 at the end.
  if ! ops_post "/pulls/${number}/merge" '{"Do":"merge"}' >/dev/null; then
    log "gate merge failed for pitch #${number}; no marker written, retry next run"
    return 1
  fi

  # 5. Tell the owner, then mark.
  local title="" html=""
  title="$(printf '%s' "$pr_json" | jq -r '.title // empty' 2>/dev/null || true)"
  html="$(printf '%s' "$pr_json" | jq -r '.html_url // empty' 2>/dev/null || true)"
  if ! notice_owner "pitch #${number} '${title}' approved by the gate (tier ${tier}): ${html}"; then
    log "notice for pitch #${number} could not be queued; the merge still stands"
  fi
  if ! mark_approved "$number"; then
    log "could not write the gate marker for pitch #${number}"
    return 1
  fi
  log "pitch #${number} merged by the gate (tier ${tier})"
  return 0
}

# walk_open — every page of open ops-repo PRs.
#   0  each bot pitch was merged, skipped, or left unready
#   1  a page could not be listed, or a ready pitch could not be merged
walk_open() {
  local page=0 body="" kind="" count="" entry="" failed=0
  while true; do
    page=$((page + 1))
    if ! body="$(ops_get "/pulls?state=open&limit=50&page=${page}")"; then
      log "could not list open ops-repo PRs (page ${page})"
      return 1
    fi
    kind="$(jq -r 'type' <<< "$body" 2>/dev/null || printf 'invalid')"
    if [ "$kind" != "array" ]; then
      log "open PR listing (page ${page}) returned ${kind}, not an array"
      return 1
    fi
    count="$(jq -r 'length' <<< "$body" 2>/dev/null || printf '0')"
    while IFS= read -r entry; do
      handle_open_pr "$entry" || failed=1
    done < <(jq -c '.[]' <<< "$body")
    if [ "$count" -lt 50 ]; then
      break
    fi
  done
  return "$failed"
}

open_rc=0
walk_open || open_rc=$?
exit "$open_rc"
