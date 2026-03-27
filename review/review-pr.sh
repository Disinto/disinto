#!/usr/bin/env bash
# shellcheck disable=SC2015,SC2016
# review-pr.sh — Thin orchestrator for AI PR review (formula: formulas/review-pr.toml)
# Usage: ./review-pr.sh <pr-number> [--force]
set -euo pipefail
source "$(dirname "$0")/../lib/env.sh"
source "$(dirname "$0")/../lib/ci-helpers.sh"
source "$(dirname "$0")/../lib/agent-session.sh"
git -C "$FACTORY_ROOT" pull --ff-only origin main 2>/dev/null || true

PR_NUMBER="${1:?Usage: review-pr.sh <pr-number> [--force]}"
FORCE="${2:-}"
API="${FORGE_API}"
LOGFILE="${DISINTO_LOG_DIR}/review/review.log"
SESSION="review-${PROJECT_NAME}-${PR_NUMBER}"
PHASE_FILE="/tmp/review-session-${PROJECT_NAME}-${PR_NUMBER}.phase"
OUTPUT_FILE="/tmp/${PROJECT_NAME}-review-output-${PR_NUMBER}.json"
WORKTREE="/tmp/${PROJECT_NAME}-review-${PR_NUMBER}"
LOCKFILE="/tmp/${PROJECT_NAME}-review.lock"
STATUSFILE="/tmp/${PROJECT_NAME}-review-status"
MAX_DIFF=25000
REVIEW_TMPDIR=$(mktemp -d)
log() { printf '[%s] PR#%s %s\n' "$(date -u '+%Y-%m-%d %H:%M:%S UTC')" "$PR_NUMBER" "$*" >> "$LOGFILE"; }
status() { printf '[%s] PR #%s: %s\n' "$(date -u '+%Y-%m-%d %H:%M:%S UTC')" "$PR_NUMBER" "$*" > "$STATUSFILE"; log "$*"; }
cleanup() { rm -rf "$REVIEW_TMPDIR" "$LOCKFILE" "$STATUSFILE" "/tmp/${PROJECT_NAME}-review-graph-${PR_NUMBER}.json"; }
trap cleanup EXIT

if [ -f "$LOGFILE" ] && [ "$(stat -c%s "$LOGFILE" 2>/dev/null || echo 0)" -gt 102400 ]; then
  mv "$LOGFILE" "$LOGFILE.old"
fi
AVAIL=$(awk '/MemAvailable/{printf "%d", $2/1024}' /proc/meminfo)
[ "$AVAIL" -lt 1500 ] && { log "SKIP: ${AVAIL}MB available"; exit 0; }
if [ -f "$LOCKFILE" ]; then
  LPID=$(cat "$LOCKFILE" 2>/dev/null || true)
  [ -n "$LPID" ] && kill -0 "$LPID" 2>/dev/null && { log "SKIP: locked"; exit 0; }
  rm -f "$LOCKFILE"
fi
echo $$ > "$LOCKFILE"
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
  log "SKIP: state=${PR_STATE}"; agent_kill_session "$SESSION"
  cd "${PROJECT_REPO_ROOT}"; git worktree remove "$WORKTREE" --force 2>/dev/null || true
  rm -rf "$WORKTREE" "$PHASE_FILE" "$OUTPUT_FILE" 2>/dev/null || true; exit 0
fi
CI_STATE=$(ci_commit_status "$PR_SHA")
CI_NOTE=""; if ! ci_passed "$CI_STATE"; then
  ci_required_for_pr "$PR_NUMBER" && { log "SKIP: CI=${CI_STATE}"; exit 0; }
  CI_NOTE=" (not required — non-code PR)"; fi
ALL_COMMENTS=$(forge_api_all "/issues/${PR_NUMBER}/comments")
HAS_CMT=$(printf '%s' "$ALL_COMMENTS" | jq --arg s "$PR_SHA" \
  '[.[]|select(.body|contains("<!-- reviewed: "+$s+" -->"))]|length')
[ "${HAS_CMT:-0}" -gt 0 ] && [ "$FORCE" != "--force" ] && { log "SKIP: reviewed ${PR_SHA:0:7}"; exit 0; }
HAS_FML=$(forge_api_all "/pulls/${PR_NUMBER}/reviews" | jq --arg s "$PR_SHA" \
  '[.[]|select(.commit_id==$s)|select(.state!="COMMENT")]|length')
[ "${HAS_FML:-0}" -gt 0 ] && [ "$FORCE" != "--force" ] && { log "SKIP: formal review"; exit 0; }
PREV_CONTEXT="" IS_RE_REVIEW=false PREV_SHA=""
PREV_REV=$(printf '%s' "$ALL_COMMENTS" | jq -r --arg s "$PR_SHA" \
  '[.[]|select(.body|contains("<!-- reviewed:"))|select(.body|contains($s)|not)]|last // empty')
if [ -n "$PREV_REV" ] && [ "$PREV_REV" != "null" ]; then
  PREV_BODY=$(printf '%s' "$PREV_REV" | jq -r '.body')
  PREV_SHA=$(printf '%s' "$PREV_BODY" | grep -oP '<!-- reviewed: \K[a-f0-9]+' | head -1)
  cd "${PROJECT_REPO_ROOT}"; git fetch origin "$PR_HEAD" 2>/dev/null || true
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
status "fetching diff"
curl -s -H "Authorization: token ${FORGE_TOKEN}" \
  "${API}/pulls/${PR_NUMBER}.diff" > "${REVIEW_TMPDIR}/full.diff"
FSIZE=$(stat -c%s "${REVIEW_TMPDIR}/full.diff" 2>/dev/null || echo 0)
DIFF=$(head -c "$MAX_DIFF" "${REVIEW_TMPDIR}/full.diff")
FILES=$(grep -E '^\+\+\+ b/' "${REVIEW_TMPDIR}/full.diff" | sed 's|^+++ b/||' | grep -v '/dev/null' | sort -u || true)
DNOTE=""; [ "$FSIZE" -gt "$MAX_DIFF" ] && DNOTE=" (truncated from ${FSIZE} bytes)"
cd "${PROJECT_REPO_ROOT}"; git fetch origin "$PR_HEAD" 2>/dev/null || true
if [ -d "$WORKTREE" ]; then
  cd "$WORKTREE"; git checkout --detach "$PR_SHA" 2>/dev/null || {
    cd "${PROJECT_REPO_ROOT}"; git worktree remove "$WORKTREE" --force 2>/dev/null || true
    rm -rf "$WORKTREE"; git worktree add "$WORKTREE" "$PR_SHA" --detach 2>/dev/null; }
else git worktree add "$WORKTREE" "$PR_SHA" --detach 2>/dev/null; fi
status "preparing review session"

# ── Build structural analysis graph for changed files ────────────────────
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

FORMULA=$(cat "${FACTORY_ROOT}/formulas/review-pr.toml")
{
  printf 'You are the review agent for %s. Follow the formula to review PR #%s.\nYou MUST write PHASE:done to '\''%s'\'' when finished.\n\n' \
    "${FORGE_REPO}" "${PR_NUMBER}" "${PHASE_FILE}"
  printf '## PR Context\n**%s** (%s → %s) | SHA: %s | CI: %s%s\nRe-review: %s\n\n' \
    "$PR_TITLE" "$PR_HEAD" "$PR_BASE" "$PR_SHA" "$CI_STATE" "$CI_NOTE" "$IS_RE_REVIEW"
  printf '### Description\n%s\n\n### Changed Files\n%s\n\n### Diff%s\n```diff\n%s\n```\n' \
    "$PR_BODY" "$FILES" "$DNOTE" "$DIFF"
  [ -n "$PREV_CONTEXT" ] && printf '%s\n' "$PREV_CONTEXT"
  [ -n "$GRAPH_SECTION" ] && printf '%s\n' "$GRAPH_SECTION"
  printf '\n## Formula\n%s\n\n## Environment\nREVIEW_OUTPUT_FILE=%s\nPHASE_FILE=%s\nFORGE_API=%s\nPR_NUMBER=%s\nFACTORY_ROOT=%s\n' \
    "$FORMULA" "$OUTPUT_FILE" "$PHASE_FILE" "$API" "$PR_NUMBER" "$FACTORY_ROOT"
  printf 'NEVER echo the actual token — always reference ${FORGE_TOKEN} or ${FORGE_REVIEW_TOKEN}.\n'
} > "${REVIEW_TMPDIR}/prompt.md"
PROMPT=$(cat "${REVIEW_TMPDIR}/prompt.md")

rm -f "$OUTPUT_FILE" "$PHASE_FILE"; agent_kill_session "$SESSION"
export CLAUDE_MODEL="sonnet"
create_agent_session "$SESSION" "$WORKTREE" "$PHASE_FILE" || { log "ERROR: session failed"; exit 1; }
agent_inject_into_session "$SESSION" "$PROMPT"
log "prompt injected (${#PROMPT} bytes, re-review: ${IS_RE_REVIEW})"

status "waiting for review"
_REVIEW_CRASH=0
review_cb() {
  log "phase: $1"
  case "$1" in
    PHASE:crashed)
      [ "$_REVIEW_CRASH" -gt 0 ] && return 0; _REVIEW_CRASH=$((_REVIEW_CRASH + 1))
      create_agent_session "${_MONITOR_SESSION}" "$WORKTREE" "$PHASE_FILE" 2>/dev/null && \
        agent_inject_into_session "${_MONITOR_SESSION}" "$PROMPT" ;;
    PHASE:done|PHASE:failed|PHASE:escalate) agent_kill_session "${_MONITOR_SESSION}" ;;
  esac
}
monitor_phase_loop "$PHASE_FILE" 600 "review_cb" "$SESSION"

REVIEW_JSON=""
if [ -f "$OUTPUT_FILE" ]; then
  RAW=$(cat "$OUTPUT_FILE")
  if printf '%s' "$RAW" | jq -e '.verdict' >/dev/null 2>&1; then REVIEW_JSON="$RAW"
  else
    EXT=$(printf '%s' "$RAW" | sed -n '/^```json/,/^```$/p' | sed '1d;$d')
    [ -z "$EXT" ] && EXT=$(printf '%s' "$RAW" | sed -n '/^{/,/^}/p')
    [ -n "${EXT:-}" ] && printf '%s' "$EXT" | jq -e '.verdict' >/dev/null 2>&1 && REVIEW_JSON="$EXT"
  fi
fi
if [ -z "$REVIEW_JSON" ]; then
  log "ERROR: no valid review output"
  jq -n --arg b "## AI Review — Error\n<!-- review-error: ${PR_SHA} -->\nReview failed.\n---\n*${PR_SHA:0:7}*" \
    '{body: $b}' | curl -sf -o /dev/null -X POST -H "Authorization: token ${FORGE_TOKEN}" \
    -H "Content-Type: application/json" "${API}/issues/${PR_NUMBER}/comments" -d @- || true
  exit 1
fi
VERDICT=$(printf '%s' "$REVIEW_JSON" | jq -r '.verdict' | tr '[:lower:]' '[:upper:]' | tr '-' '_')
REASON=$(printf '%s' "$REVIEW_JSON" | jq -r '.verdict_reason // ""')
REVIEW_MD=$(printf '%s' "$REVIEW_JSON" | jq -r '.review_markdown // ""')
log "verdict: ${VERDICT}"

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

case "$VERDICT" in
  REQUEST_CHANGES|DISCUSS) printf 'PHASE:awaiting_changes\nSHA:%s\n' "$PR_SHA" > "$PHASE_FILE" ;;
  *) rm -f "$PHASE_FILE" "$OUTPUT_FILE"; cd "${PROJECT_REPO_ROOT}"
     git worktree remove "$WORKTREE" --force 2>/dev/null || true
     rm -rf "$WORKTREE" 2>/dev/null || true ;;
esac
log "DONE: ${VERDICT} (re-review: ${IS_RE_REVIEW})"
