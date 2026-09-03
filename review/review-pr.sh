#!/usr/bin/env bash
# shellcheck disable=SC2015,SC2016
# review-pr.sh — Synchronous reviewer agent for a single PR
#
# Usage: ./review-pr.sh <pr-number> [--force]
#
# Architecture:
#   Synchronous bash loop using claude -p (one-shot invocations).
#   Session continuity via --resume and .sid file.
#   Re-review resumes the original session — Claude remembers its prior review.
#
# Flow:
#   1. Fetch PR metadata (title, body, head, base, SHA, CI state)
#   2. Detect re-review (previous review at different SHA, incremental diff)
#   3. Create review worktree, checkout PR head
#   4. Build structural analysis graph
#   5. Load review formula
#   6. agent_run(worktree, prompt) → Claude reviews, writes verdict JSON
#   7. Parse verdict, post as Forge review (APPROVE / REQUEST_CHANGES / COMMENT)
#   8. Save session ID to .sid file for re-review continuity
#
# Session file: /tmp/review-session-{project}-{pr}.sid
set -euo pipefail

# Load shared environment and libraries
source "$(dirname "$0")/../lib/env.sh"
source "$(dirname "$0")/../lib/ci-helpers.sh"
source "$(dirname "$0")/../lib/worktree.sh"
source "$(dirname "$0")/../lib/agent-sdk.sh"
# shellcheck source=../lib/formula-session.sh
source "$(dirname "$0")/../lib/formula-session.sh"
# shellcheck source=../lib/stale-base-check.sh
source "$(dirname "$0")/../lib/stale-base-check.sh"

# Auto-pull factory code to pick up merged fixes before any logic runs.
# stdout must stay silent: the poller tail's this script's output for
# failure messages, and "Already up to date." is not a useful reason (#1075).
git -C "$FACTORY_ROOT" pull --ff-only origin main >/dev/null 2>&1 || true

# --- Config ---
PR_NUMBER="${1:?Usage: review-pr.sh <pr-number> [--force]}"

# Change to project repo early — required before any git commands
# (factory root is not a git repo after image rebuild)
cd "${PROJECT_REPO_ROOT}"
FORCE="${2:-}"
API="${FORGE_API}"
LOGFILE="${DISINTO_LOG_DIR}/review/review.log"
WORKTREE="/tmp/${PROJECT_NAME}-review-${PR_NUMBER}"
SID_FILE="/tmp/review-session-${PROJECT_NAME}-${PR_NUMBER}.sid"
OUTPUT_FILE="/tmp/${PROJECT_NAME}-review-output-${PR_NUMBER}.json"
LOCKFILE="/tmp/${PROJECT_NAME}-review.lock"
STATUSFILE="/tmp/${PROJECT_NAME}-review-status"
MAX_DIFF=25000
REVIEW_TMPDIR=$(mktemp -d)

log() { printf '[%s] PR#%s %s\n' "$(date -u '+%Y-%m-%d %H:%M:%S UTC')" "$PR_NUMBER" "$*" >> "$LOGFILE"; }
status() { printf '[%s] PR #%s: %s\n' "$(date -u '+%Y-%m-%d %H:%M:%S UTC')" "$PR_NUMBER" "$*" > "$STATUSFILE"; log "$*"; }

# cleanup — remove temp files (NOT lockfile — cleanup_on_exit handles that)
cleanup() {
  rm -rf "$REVIEW_TMPDIR" "$STATUSFILE" "/tmp/${PROJECT_NAME}-review-graph-${PR_NUMBER}.json"
}

# cleanup_on_exit — defensive cleanup: remove lockfile if we own it, kill residual children
# This handles the case where review-pr.sh is terminated unexpectedly (e.g., watchdog SIGTERM)
cleanup_on_exit() {
  local ec=$?
  # Remove lockfile only if we own it (PID matches $$)
  if [ -f "$LOCKFILE" ] && [ -n "$(cat "$LOCKFILE" 2>/dev/null)" ]; then
    if [ "$(cat "$LOCKFILE" 2>/dev/null)" = "$$" ]; then
      rm -f "$LOCKFILE"
      log "cleanup_on_exit: removed lockfile (we owned it)"
    fi
  fi
  # Kill any direct children that may have been spawned by this process
  # (e.g., bash -c commands from Claude's Bash tool that didn't get reaped)
  pkill -P $$ 2>/dev/null || true
  # Call the main cleanup function to remove temp files
  cleanup
  exit "$ec"
}
trap cleanup_on_exit EXIT INT TERM

# Note: EXIT trap is already set above. The cleanup function is still available for
# non-error exits (e.g., normal completion via exit 0 after verdict posted).
# When review succeeds, we want to skip lockfile removal since the verdict was posted.

# =============================================================================
# LOG ROTATION
# =============================================================================
if [ -f "$LOGFILE" ] && [ "$(stat -c%s "$LOGFILE" 2>/dev/null || echo 0)" -gt 102400 ]; then
  mv "$LOGFILE" "$LOGFILE.old"
fi

# =============================================================================
# RESOLVE FORGE REMOTE FOR GIT OPERATIONS
# =============================================================================
resolve_forge_remote

# =============================================================================
# RESOLVE AGENT IDENTITY FOR .PROFILE REPO
# =============================================================================
resolve_agent_identity || true

# =============================================================================
# MEMORY GUARD
# =============================================================================
memory_guard 1500

# =============================================================================
# CONCURRENCY LOCK
# =============================================================================
if [ -f "$LOCKFILE" ]; then
  LPID=$(cat "$LOCKFILE" 2>/dev/null || true)
  [ -n "$LPID" ] && kill -0 "$LPID" 2>/dev/null && { log "SKIP: locked"; exit 0; }
  rm -f "$LOCKFILE"
fi
echo $$ > "$LOCKFILE"

# =============================================================================
# FETCH PR METADATA
# =============================================================================
status "fetching metadata"
PR_JSON=$(curl -sf -H "Authorization: token ${FORGE_TOKEN}" "${API}/pulls/${PR_NUMBER}")
PR_TITLE=$(printf '%s' "$PR_JSON" | jq -r '.title')
PR_BODY=$(printf '%s' "$PR_JSON" | jq -r '.body // ""')
PR_HEAD=$(printf '%s' "$PR_JSON" | jq -r '.head.ref')
PR_BASE=$(printf '%s' "$PR_JSON" | jq -r '.base.ref')
PR_SHA=$(printf '%s' "$PR_JSON" | jq -r '.head.sha')
PR_STATE=$(printf '%s' "$PR_JSON" | jq -r '.state')
log "${PR_TITLE} (${PR_HEAD}→${PR_BASE} ${PR_SHA:0:7})"

if [ "$PR_STATE" != "open" ]; then
  log "SKIP: state=${PR_STATE}"
  worktree_cleanup "$WORKTREE"
  rm -f "$OUTPUT_FILE" "$SID_FILE" 2>/dev/null || true
  rm -f "$LOCKFILE"
  exit 0
fi

# =============================================================================
# CI CHECK
# =============================================================================
CI_STATE=$(ci_commit_status "$PR_SHA")
CI_NOTE=""
# Gate only on required pipelines (#920). Optional/stuck workflows do not block.
if ! ci_required_passed "$PR_SHA"; then
  log "SKIP: required CI not green (CI=${CI_STATE})"
  rm -f "$LOCKFILE"
  exit 0
fi
if ! ci_passed "$CI_STATE"; then
  CI_NOTE=" (optional checks not green; required passed)"
fi

# =============================================================================
# DUPLICATE CHECK — skip if already reviewed at this SHA
# =============================================================================
ALL_COMMENTS=$(forge_api_all "/issues/${PR_NUMBER}/comments")
HAS_CMT=$(printf '%s' "$ALL_COMMENTS" | jq --arg s "$PR_SHA" \
  '[.[]|select(.body|contains("<!-- reviewed: "+$s+" -->"))]|length')
[ "${HAS_CMT:-0}" -gt 0 ] && [ "$FORCE" != "--force" ] && { log "SKIP: reviewed ${PR_SHA:0:7}"; rm -f "$LOCKFILE"; exit 0; }
HAS_FML=$(forge_api_all "/pulls/${PR_NUMBER}/reviews" | jq --arg s "$PR_SHA" \
  '[.[]|select(.commit_id==$s)|select(.state!="COMMENT")]|length')
[ "${HAS_FML:-0}" -gt 0 ] && [ "$FORCE" != "--force" ] && { log "SKIP: formal review"; rm -f "$LOCKFILE"; exit 0; }

# =============================================================================
# RE-REVIEW DETECTION
# =============================================================================
PREV_CONTEXT="" IS_RE_REVIEW=false PREV_SHA=""
PREV_REV=$(printf '%s' "$ALL_COMMENTS" | jq -r --arg s "$PR_SHA" \
  '[.[]|select(.body|contains("<!-- reviewed:"))|select(.body|contains($s)|not)]|last // empty')
if [ -n "$PREV_REV" ] && [ "$PREV_REV" != "null" ]; then
  PREV_BODY=$(printf '%s' "$PREV_REV" | jq -r '.body')
  PREV_SHA=$(printf '%s' "$PREV_BODY" | grep -oP '<!-- reviewed: \K[a-f0-9]+' | head -1)
  cd "${PROJECT_REPO_ROOT}"
  FETCH_ERR=$(git fetch "${FORGE_REMOTE}" "$PR_HEAD" 2>&1 >/dev/null) || \
    log "WARN: git fetch ${FORGE_REMOTE} ${PR_HEAD} failed: ${FETCH_ERR} — incremental diff may be incomplete"
  INCR=$(git diff "${PREV_SHA}..${PR_SHA}" 2>/dev/null | head -c "$MAX_DIFF") || true
  if [ -n "$INCR" ]; then
    IS_RE_REVIEW=true; log "re-review: previous at ${PREV_SHA:0:7}"
    DEV_R=$(printf '%s' "$ALL_COMMENTS" | jq -r \
      '[.[]|select(.body|contains("<!-- dev-response:"))]|last // empty')
    DEV_SEC=""; [ -n "$DEV_R" ] && [ "$DEV_R" != "null" ] && \
      DEV_SEC=$(printf '\n### Developer Response\n%s' "$(printf '%s' "$DEV_R" | jq -r '.body')") || true
    PREV_CONTEXT=$(printf '\n## This is a RE-REVIEW\nPrevious review at %s requested changes.\n### Previous Review\n%s%s\n### Incremental Diff (%s..%s)\n```diff\n%s\n```' \
      "${PREV_SHA:0:7}" "$PREV_BODY" "$DEV_SEC" "${PREV_SHA:0:7}" "${PR_SHA:0:7}" "$INCR")
  fi
fi

# Recover session_id from .sid file (re-review continuity)
agent_recover_session

# =============================================================================
# FETCH DIFF
# =============================================================================
status "fetching diff"
curl -s -H "Authorization: token ${FORGE_TOKEN}" \
  "${API}/pulls/${PR_NUMBER}.diff" > "${REVIEW_TMPDIR}/full.diff"
FSIZE=$(stat -c%s "${REVIEW_TMPDIR}/full.diff" 2>/dev/null || echo 0)
DIFF=$(head -c "$MAX_DIFF" "${REVIEW_TMPDIR}/full.diff")
FILES=$(grep -E '^\+\+\+ b/' "${REVIEW_TMPDIR}/full.diff" | sed 's|^+++ b/||' | grep -v '/dev/null' | sort -u || true)
DNOTE=""; [ "$FSIZE" -gt "$MAX_DIFF" ] && DNOTE=" (truncated from ${FSIZE} bytes)"

# =============================================================================
# WORKTREE SETUP
# =============================================================================
# Fetch the PR head objects into this clone before checking them out. A
# swallowed fetch failure here made every review of an unfetched branch die
# with exit 128 and an unrelated message (#1075).
FETCH_ERR=$(git fetch "${FORGE_REMOTE}" "$PR_HEAD" 2>&1 >/dev/null) || {
  log "WARN: git fetch ${FORGE_REMOTE} ${PR_HEAD} failed: ${FETCH_ERR}"
  # The PR head branch may have been deleted while the PR is still open;
  # retry by fetching the commit SHA directly.
  FETCH_ERR=$(git fetch "${FORGE_REMOTE}" "$PR_SHA" 2>&1 >/dev/null) || \
    log "WARN: git fetch ${FORGE_REMOTE} ${PR_SHA} failed: ${FETCH_ERR}"
}

if ! git cat-file -e "${PR_SHA}^{commit}" 2>/dev/null; then
  # Objects are still missing. Record a review error naming the SHA so the
  # poll's error counter backs off instead of retrying blind (#1075).
  log "ERROR: objects for ${PR_SHA} missing after git fetch ${FORGE_REMOTE} (${FETCH_ERR})"
  jq -n --arg b "## AI Review — Error\n<!-- review-error: ${PR_SHA} -->\nReview failed: cannot fetch objects for \`${PR_SHA:0:7}\` from remote \`${FORGE_REMOTE}\` (head ref \`${PR_HEAD}\`). Both \`git fetch ${FORGE_REMOTE} ${PR_HEAD}\` and \`git fetch ${FORGE_REMOTE} ${PR_SHA}\` failed.\n---\n*${PR_SHA:0:7}*" \
    '{body: $b}' | curl -sf -o /dev/null -X POST -H "Authorization: token ${FORGE_TOKEN}" \
    -H "Content-Type: application/json" "${API}/issues/${PR_NUMBER}/comments" -d @- || true
  echo "ERROR: git fetch ${FORGE_REMOTE} ${PR_HEAD}/${PR_SHA} failed — objects for ${PR_SHA} missing, cannot check out"
  exit 128
fi

if [ -d "$WORKTREE" ]; then
  CO_ERR=$(cd "$WORKTREE" && git checkout --detach "$PR_SHA" 2>&1 >/dev/null) || {
    log "git checkout --detach ${PR_SHA} failed in existing worktree (${CO_ERR}); recreating"
    worktree_cleanup "$WORKTREE"
  }
fi
if [ ! -d "$WORKTREE" ]; then
  # A registration can outlive the worktree directory (a container restart
  # wiped this container's /tmp while the shared clone kept the record), in
  # which case `git worktree add` fails with "missing, but already registered"
  # and blocks every future review of this PR (#1082). Clear only this
  # path's stale registration before claiming it — never a blanket prune,
  # since the clone also registers live worktrees of other containers.
  worktree_clear_stale "$WORKTREE"
  WT_ERR=$(git worktree add "$WORKTREE" "$PR_SHA" --detach 2>&1 >/dev/null) || {
    log "ERROR: git worktree add ${WORKTREE} ${PR_SHA} --detach failed: ${WT_ERR}"
    # Record a review error naming the SHA so the poll's circuit breaker
    # backs off after N identical failures instead of retrying silently
    # forever (#1082).
    WT_MSG=$(printf '## AI Review — Error\n<!-- review-error: %s -->\nReview failed: could not create the review worktree at `%s` for `%s`.\n```\n%s\n```\n---\n*%s*' \
      "$PR_SHA" "$WORKTREE" "${PR_SHA:0:7}" "$WT_ERR" "${PR_SHA:0:7}")
    jq -n --arg b "$WT_MSG" '{body: $b}' | curl -sf -o /dev/null -X POST \
      -H "Authorization: token ${FORGE_TOKEN}" -H "Content-Type: application/json" \
      "${API}/issues/${PR_NUMBER}/comments" -d @- || true
    echo "ERROR: git worktree add failed to check out ${PR_SHA}: ${WT_ERR}"
    exit 128
  }
fi

# =============================================================================
# STALE-BASE REGRESSION CHECK (#896)
# =============================================================================
# Detect PRs whose merged result will silently revert upstream changes that
# landed on main since the PR's base. The forward (head vs base) diff would
# look correct, so review-bot's normal pass would miss this.
status "checking stale-base regressions"
STALE_BASE_SECTION=""
git fetch "${FORGE_REMOTE}" "${PRIMARY_BRANCH}" 2>/dev/null || true
STALE_MAIN_REF="${FORGE_REMOTE}/${PRIMARY_BRANCH}"
STALE_OUTPUT=$(stale_base_check "$PR_SHA" "$STALE_MAIN_REF" 2>/dev/null || true)
if [ -n "$STALE_OUTPUT" ]; then
  STALE_LIST=$(stale_base_check_format "$STALE_OUTPUT")
  STALE_BASE_SECTION=$(printf '\n## Stale-base regression check (BLOCKER)\n\nThis PR is based on a stale main. After merge, the following files would be left missing lines that landed upstream since the PR'\''s merge-base:\n\n%s\n\nUnless the PR description explicitly states these reverts are intentional, you MUST set verdict=REQUEST_CHANGES and instruct the author to rebase on main and re-resolve. Reference issue #896.\n' "$STALE_LIST")
  log "stale-base regression detected: $(printf '%s' "$STALE_OUTPUT" | tr '\n' ' ')"
else
  log "stale-base check: no regressions"
fi

# =============================================================================
# BUILD STRUCTURAL ANALYSIS GRAPH
# =============================================================================
status "preparing review"
GRAPH_REPORT="/tmp/${PROJECT_NAME}-review-graph-${PR_NUMBER}.json"
GRAPH_SECTION=""
# shellcheck disable=SC2086
if python3 "$FACTORY_ROOT/lib/build-graph.py" \
     --project-root "$PROJECT_REPO_ROOT" \
     --changed-files $FILES \
     --output "$GRAPH_REPORT" 2>>"$LOGFILE"; then
  GRAPH_SECTION=$(printf '\n## Structural analysis (affected objectives)\n```json\n%s\n```\n' \
    "$(cat "$GRAPH_REPORT")")
  log "graph report generated for PR #${PR_NUMBER}"
else
  log "WARN: build-graph.py failed — continuing without structural analysis"
fi

# =============================================================================
# LOAD LESSONS FROM .PROFILE REPO (PRE-SESSION)
# =============================================================================
formula_prepare_profile_context

# =============================================================================
# BUILD PROMPT
# =============================================================================
FORMULA=$(cat "${FACTORY_ROOT}/formulas/review-pr.toml")
{
  printf 'You are the review agent for %s. Follow the formula to review PR #%s.\n\n' \
    "${FORGE_REPO}" "${PR_NUMBER}"
  printf '## PR Context\n**%s** (%s → %s) | SHA: %s | CI: %s%s\nRe-review: %s\n\n' \
    "$PR_TITLE" "$PR_HEAD" "$PR_BASE" "$PR_SHA" "$CI_STATE" "$CI_NOTE" "$IS_RE_REVIEW"
  printf '### Description\n%s\n\n### Changed Files\n%s\n\n### Diff%s\n```diff\n%s\n```\n' \
    "$PR_BODY" "$FILES" "$DNOTE" "$DIFF"
  [ -n "$PREV_CONTEXT" ] && printf '%s\n' "$PREV_CONTEXT"
  [ -n "$STALE_BASE_SECTION" ] && printf '%s\n' "$STALE_BASE_SECTION"
  [ -n "$GRAPH_SECTION" ] && printf '%s\n' "$GRAPH_SECTION"
  formula_lessons_block
  printf '\n## Formula\n%s\n\n## Environment\nREVIEW_OUTPUT_FILE=%s\nFORGE_API=%s\nPR_NUMBER=%s\nFACTORY_ROOT=%s\n' \
    "$FORMULA" "$OUTPUT_FILE" "$API" "$PR_NUMBER" "$FACTORY_ROOT"
  printf 'NEVER echo the actual token — always reference ${FORGE_TOKEN} or ${FORGE_REVIEW_TOKEN}.\n'
  printf '\n## Completion\nAfter writing the JSON file to REVIEW_OUTPUT_FILE (%s), stop.\nDo NOT write to any phase file — completion is automatic.\n' "$OUTPUT_FILE"
} > "${REVIEW_TMPDIR}/prompt.md"
PROMPT=$(cat "${REVIEW_TMPDIR}/prompt.md")

# =============================================================================
# RUN REVIEW AGENT + PARSE OUTPUT
# =============================================================================
# review_run_and_parse() — run the review agent and parse its verdict.
# The agent_run calls are guarded (`|| REVIEW_RUN_RC=$?`): a session that
# hits its resource limit (rc 124 = wall-clock timeout) must NOT abort this
# script under set -e — the run's rc is recorded instead, and the no-output
# path below posts the "Review failed" comment with the reason so a timed-out
# review is visible on the PR rather than a silent hang (#1164).
# Returns 0 on valid output (REVIEW_JSON set), 1 after posting the error
# comment.
review_run_and_parse() {
  local raw="" ext="" rc_note=""
  REVIEW_RUN_RC=0
  status "running review"
  rm -f "$OUTPUT_FILE"
  # Review-specific overrides, distinct from the container's values: the jobspec
  # sets CLAUDE_MODEL deliberately (Claude Code sizes its context window from
  # the name, so it must match the served model) and CLAUDE_TIMEOUT carries the
  # dev budget (7200) — a fallback that inherited it would never apply the cap.
  export CLAUDE_MODEL="${REVIEW_CLAUDE_MODEL:-$CLAUDE_MODEL}"
  export CLAUDE_TIMEOUT="${REVIEW_CLAUDE_TIMEOUT:-2400}"   # 40 min — deliberate cap: a review still running at 40 min is stuck, not thorough
  # dsh agents need output paths in-process: formulas/review-pr.toml section 9
  # uses shell expansion ("> $REVIEW_OUTPUT_FILE"), and without the export the
  # agent guesses a path and the verdict is lost (#1230 wrote
  # /tmp/disinto-review-1230.json instead of the file below).
  export REVIEW_OUTPUT_FILE="$OUTPUT_FILE"
  if [ "$IS_RE_REVIEW" = true ] && [ -n "$_AGENT_SESSION_ID" ]; then
    agent_run --resume "$_AGENT_SESSION_ID" --worktree "$WORKTREE" --task "$PR_NUMBER" "$PROMPT" || REVIEW_RUN_RC=$?
  else
    agent_run --worktree "$WORKTREE" --task "$PR_NUMBER" "$PROMPT" || REVIEW_RUN_RC=$?
  fi
  if [ "$REVIEW_RUN_RC" -ne 0 ]; then
    log "agent_run exited ${REVIEW_RUN_RC} (re-review: ${IS_RE_REVIEW})"
  else
    log "agent_run complete (re-review: ${IS_RE_REVIEW})"
  fi

  REVIEW_JSON=""
  if [ -f "$OUTPUT_FILE" ]; then
    raw=$(cat "$OUTPUT_FILE")
    if printf '%s' "$raw" | jq -e '.verdict' >/dev/null 2>&1; then REVIEW_JSON="$raw"
    else
      ext=$(printf '%s' "$raw" | sed -n '/^```json/,/^```$/p' | sed '1d;$d')
      [ -z "$ext" ] && ext=$(printf '%s' "$raw" | sed -n '/^{/,/^}/p')
      [ -n "${ext:-}" ] && printf '%s' "$ext" | jq -e '.verdict' >/dev/null 2>&1 && REVIEW_JSON="$ext"
    fi
  fi

  if [ -z "$REVIEW_JSON" ]; then
    case "$REVIEW_RUN_RC" in
      124) rc_note=" (review timed out after ${CLAUDE_TIMEOUT}s — agent_run rc 124)" ;;
      0) rc_note="" ;;
      *) rc_note=" (agent_run rc ${REVIEW_RUN_RC})" ;;
    esac
    log "ERROR: no valid review output${rc_note}"
    jq -n --arg b "## AI Review — Error\n<!-- review-error: ${PR_SHA} -->\nReview failed${rc_note}.\n---\n*${PR_SHA:0:7}*" \
      '{body: $b}' | curl -sf -o /dev/null -X POST -H "Authorization: token ${FORGE_TOKEN}" \
      -H "Content-Type: application/json" "${API}/issues/${PR_NUMBER}/comments" -d @- || true
    return 1
  fi
  return 0
}

if ! review_run_and_parse; then
  exit 1
fi

VERDICT=$(printf '%s' "$REVIEW_JSON" | jq -r '.verdict' | tr '[:lower:]' '[:upper:]' | tr '-' '_')
REASON=$(printf '%s' "$REVIEW_JSON" | jq -r '.verdict_reason // ""')
REVIEW_MD=$(printf '%s' "$REVIEW_JSON" | jq -r '.review_markdown // ""')
log "verdict: ${VERDICT}"

# =============================================================================
# POST REVIEW
# =============================================================================
status "posting review"
RTYPE="Review"
if [ "$IS_RE_REVIEW" = true ]; then
  RTYPE="Re-review (round $(($(printf '%s' "$ALL_COMMENTS" | \
    jq '[.[]|select(.body|contains("<!-- reviewed:"))]|length') + 1)))"
fi
PREV_REF=""; [ "$IS_RE_REVIEW" = true ] && PREV_REF=$(printf ' | Previous: `%s`' "${PREV_SHA:0:7}") || true
COMMENT_BODY=$(printf '## AI %s\n<!-- reviewed: %s -->\n\n%s\n\n### Verdict\n**%s** — %s\n\n---\n*Reviewed at `%s`%s | [AGENTS.md](AGENTS.md)*' \
  "$RTYPE" "$PR_SHA" "$REVIEW_MD" "$VERDICT" "$REASON" "${PR_SHA:0:7}" "$PREV_REF")
printf '%s' "$COMMENT_BODY" > "${REVIEW_TMPDIR}/body.txt"
jq -Rs '{body: .}' < "${REVIEW_TMPDIR}/body.txt" > "${REVIEW_TMPDIR}/comment.json"
POST_RC=$(curl -s -o /dev/null -w "%{http_code}" -X POST \
  -H "Authorization: token ${FORGE_REVIEW_TOKEN}" -H "Content-Type: application/json" \
  "${API}/issues/${PR_NUMBER}/comments" --data-binary @"${REVIEW_TMPDIR}/comment.json")
[ "$POST_RC" != "201" ] && { log "ERROR: comment HTTP ${POST_RC}"; exit 1; }
log "posted review comment"

# =============================================================================
# POST FORMAL REVIEW
# =============================================================================
REVENT="COMMENT"
case "$VERDICT" in APPROVE) REVENT="APPROVED" ;; REQUEST_CHANGES|DISCUSS) REVENT="REQUEST_CHANGES" ;; esac
if [ "$REVENT" = "APPROVED" ]; then
  BLOGIN=$(curl -sf -H "Authorization: token ${FORGE_REVIEW_TOKEN}" \
    "${API%%/repos*}/user" 2>/dev/null | jq -r '.login // empty' || true)
  [ -n "$BLOGIN" ] && forge_api_all "/pulls/${PR_NUMBER}/reviews" "${FORGE_REVIEW_TOKEN}" 2>/dev/null | \
    jq -r --arg l "$BLOGIN" '.[]|select(.state=="REQUEST_CHANGES")|select(.user.login==$l)|.id' | \
    while IFS= read -r rid; do
      curl -sf -o /dev/null -X POST -H "Authorization: token ${FORGE_REVIEW_TOKEN}" \
        -H "Content-Type: application/json" "${API}/pulls/${PR_NUMBER}/reviews/${rid}/dismissals" \
        -d '{"message":"Superseded by approval"}' || true; log "dismissed review ${rid}"
    done || true
fi
jq -n --arg b "AI ${RTYPE}: **${VERDICT}** — ${REASON}" --arg e "$REVENT" --arg s "$PR_SHA" \
  '{body: $b, event: $e, commit_id: $s}' > "${REVIEW_TMPDIR}/formal.json"
curl -s -o /dev/null -X POST -H "Authorization: token ${FORGE_REVIEW_TOKEN}" \
  -H "Content-Type: application/json" "${API}/pulls/${PR_NUMBER}/reviews" \
  --data-binary @"${REVIEW_TMPDIR}/formal.json" >/dev/null 2>&1 || true
log "formal ${REVENT} submitted"

# =============================================================================
# FINAL CLEANUP
# =============================================================================
case "$VERDICT" in
  REQUEST_CHANGES|DISCUSS)
    # Keep session and worktree for re-review continuity
    log "keeping session for re-review (SID: ${_AGENT_SESSION_ID:0:12}...)"
    ;;
  *)
    rm -f "$SID_FILE" "$OUTPUT_FILE"
    worktree_cleanup "$WORKTREE"
    ;;
esac

# Write journal entry post-session
profile_write_journal "review-${PR_NUMBER}" "Review PR #${PR_NUMBER} (${VERDICT})" "${VERDICT,,}" "" || true

log "DONE: ${VERDICT} (re-review: ${IS_RE_REVIEW})"

# Remove lockfile on successful completion (cleanup_on_exit will also do this,
# but we do it here to avoid the trap running twice)
rm -f "$LOCKFILE"
