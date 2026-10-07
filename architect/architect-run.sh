#!/usr/bin/env bash
# =============================================================================
# architect-run.sh — Forgejo-state-driven architect lifecycle
#
# Bash-driven state machine operating on architect PRs on the ops repo.
# No tmux sessions, no phase files — the bash script IS the state machine.
#
# Lifecycle states:
#   [q_and_a] — PR open, new non-architect comment since last-seen marker
#
# Round-robin: PRs sorted by <!-- architect-last-seen: <iso> --> ascending;
# head of queue is picked each iteration. last-seen advances every iteration.
#
# Write-permission contract:
#   ops repo: PATCH PR body, POST comments, close PR
#   project repo: NONE (only reads — issues, acceptance scripts, vision)
#
# Formula (#1335): the architect always uses formulas/run-architect.toml —
# oak instances differ by pack, not kind, so research boxes run the
# software formula.
#
# Usage:
#   architect-run.sh [projects/disinto.toml]
#
# Called by: entrypoint.sh polling loop (every 15 min by default)
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
FACTORY_ROOT="$(dirname "$SCRIPT_DIR")"

export PROJECT_TOML="${1:-$FACTORY_ROOT/projects/disinto.toml}"
export FORGE_TOKEN_OVERRIDE="${FORGE_ARCHITECT_TOKEN:-}"

source "$FACTORY_ROOT/lib/env.sh"
source "$FACTORY_ROOT/lib/formula-session.sh"
source "$FACTORY_ROOT/lib/worktree.sh"
source "$FACTORY_ROOT/lib/guard.sh"
source "$FACTORY_ROOT/lib/agent-sdk.sh"

LOG_FILE="${DISINTO_LOG_DIR}/architect/architect.log"
# shellcheck disable=SC2034  # consumed by agent-sdk.sh
LOGFILE="$LOG_FILE"
LOG_AGENT="architect"

log() {
  local agent="${LOG_AGENT:-architect}"
  printf '[%s] %s: %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$agent" "$*" >> "$LOG_FILE"
}

# ── Guards ────────────────────────────────────────────────────────────────
check_active architect
acquire_run_lock "/tmp/architect-run.lock"
memory_guard 2000

log "--- Architect run start ---"

# ── Scratch worktree ──────────────────────────────────────────────────────
WORKTREE="/tmp/${PROJECT_NAME}-architect-run"

# Cleanup worktree (and claude cache) on exit so re-runs get a fresh checkout
trap 'worktree_cleanup "$WORKTREE" 2>/dev/null || true' EXIT

cd "$PROJECT_REPO_ROOT"
if [ -z "${FORGE_REMOTE:-}" ]; then
  resolve_forge_remote
fi
git fetch "${FORGE_REMOTE}" "${PRIMARY_BRANCH}" 2>/dev/null || true
worktree_cleanup "$WORKTREE" 2>/dev/null || true
git worktree add "$WORKTREE" "${FORGE_REMOTE}/${PRIMARY_BRANCH}" --detach 2>/dev/null || {
  log "WARNING: worktree add failed — q_and_a opus dispatch will fail"
}

# ── Resolve agent identity ──────────────────────────────────────────────
if [ -z "${AGENT_IDENTITY:-}" ] && [ -n "${FORGE_ARCHITECT_TOKEN:-}" ]; then
  AGENT_IDENTITY=$(forge_whoami)
fi

# ARCHITECT_LOGIN — the Forgejo identity that posts the architect's own
# comments. Engagement checks exclude it, so a posted reply does not re-wake
# the agent (reply loop, once per ARCHITECT_INTERVAL). #1910 uses
# architect_has_commented to detect it.
ARCHITECT_LOGIN="${AGENT_IDENTITY:-architect-bot}"

# ── Formula (#1335) ──────────────────────────────────────────────────────
# The architect always uses formulas/run-architect.toml — the kind
# selection from #1315 is gone: oak instances differ by pack, not kind,
# so research boxes run the software formula.
architect_formula_file() {
  echo "$FACTORY_ROOT/formulas/run-architect.toml"
}
ARCHITECT_FORMULA="$(architect_formula_file)"

# Role text for the opus prompts: the decomposition target is development
# sprints and the filed sub-issues are backlog sub-issues.
PITCH_NOUN="sprint"
SUBISSUE_TERM="sub-issues"
QA_ROLE_TEXT="Your role: strategic decomposition of vision issues into development sprints.
Propose sprints via PRs on the ops repo, converse with humans through PR comments.
You are READ-ONLY on the project repo — sub-issues are filed by filer-bot after sprint PR merge (#764).
Any sub-issue specification must go only into the filer:begin/filer:end block of the sprint pitch."
log "architect formula: ${ARCHITECT_FORMULA##*/}"

# ── Forgejo API helpers ─────────────────────────────────────────────────
# All writes target ${FORGE_OPS_REPO} only.

# fetch_open_architect_prs — JSON array of architect PR objects
fetch_open_architect_prs() {
  curl -sf -H "Authorization: token ${FORGE_TOKEN}" \
    "${FORGE_API_BASE}/repos/${FORGE_OPS_REPO}/pulls?state=open&limit=100" 2>/dev/null || echo '[]'
}

# get_pr_body <pr_number> — PR body text
get_pr_body() {
  local pr="$1"
  curl -sf -H "Authorization: token ${FORGE_TOKEN}" \
    "${FORGE_API_BASE}/repos/${FORGE_OPS_REPO}/pulls/${pr}" 2>/dev/null \
    | jq -r '.body // empty' 2>/dev/null || echo ""
}

# get_pr_comments <pr_number> — JSON array of comment objects
get_pr_comments() {
  local pr="$1"
  curl -sf -H "Authorization: token ${FORGE_TOKEN}" \
    "${FORGE_API_BASE}/repos/${FORGE_OPS_REPO}/issues/${pr}/comments" 2>/dev/null || echo '[]'
}

# others_comments_since <pr_number> <since_iso> — JSON array of the comments
# from get_pr_comments newer than SINCE and not by the architect
# ((.user.login // "") != ARCHITECT_LOGIN). The since-filter + architect
# exclusion live here so the state predicates read the filtered array instead
# of re-filtering get_pr_comments themselves.
others_comments_since() {
  local pr="$1" since="$2"
  printf '%s' "$(get_pr_comments "$pr")" | jq -c \
    --arg since "$since" \
    --arg me "$ARCHITECT_LOGIN" \
    '[(.[]
      | select(.updated_at > $since)
      | select((.user.login // "") != $me))]'
}

# has_reject_comment <pr_number> <since_iso> — 0 if Reject: comment since marker
# (by anyone other than the architect, via others_comments_since)
has_reject_comment() {
  local pr="$1" since="$2"
  # Extract the non-architect comments since the marker and check for Reject: prefix
  printf '%s' "$(others_comments_since "$pr" "$since")" | jq -r '
    [.[] | .body] | .[]
  ' 2>/dev/null | grep -q '^Reject:' 2>/dev/null
}

# get_reject_reason <pr_number> <since_iso> — the reason after "Reject: "
# (from a non-architect comment since the marker, via others_comments_since)
get_reject_reason() {
  local pr="$1" since="$2"
  printf '%s' "$(others_comments_since "$pr" "$since")" | jq -r '
    [.[] | .body] | .[] | select(startswith("Reject:"))
  ' 2>/dev/null | head -1 | sed 's/^Reject: *//' 2>/dev/null || echo "rejected"
}

# has_new_comment_since <pr_number> <since_iso> — 0 if non-reject comment exists
# (by anyone other than the architect since the marker, via others_comments_since)
has_new_comment_since() {
  local pr="$1" since="$2"
  # Check for any non-architect comment newer than last-seen that is NOT a Reject:
  printf '%s' "$(others_comments_since "$pr" "$since")" | jq -r '
    [.[] | .body] | .[] | select(test("^Reject:") | not)
  ' 2>/dev/null | head -1 | grep -q . 2>/dev/null
}

# architect_has_commented <pr_number> — 0 if a comment of get_pr_comments
# carries .user.login == ARCHITECT_LOGIN, 1 otherwise. #1910 uses it to
# decide whether a pitch already has an architect reply on the thread.
architect_has_commented() {
  local pr="$1"
  printf '%s' "$(get_pr_comments "$pr")" | jq -e \
    --arg me "$ARCHITECT_LOGIN" \
    'any(.[]; (.user.login // "") == $me)' >/dev/null 2>&1
}

# post_pr_comment <pr_number> <body> — POST a comment
post_pr_comment() {
  local pr="$1" body="$2"
  curl -sf -X POST \
    -H "Authorization: token ${FORGE_TOKEN}" \
    -H "Content-Type: application/json" \
    "${FORGE_API_BASE}/repos/${FORGE_OPS_REPO}/issues/${pr}/comments" \
    -d "{\"body\":$(printf '%s' "$body" | jq -Rs '.')} " 2>/dev/null
}

# patch_pr_body <pr_number> <new_body> — PATCH the PR body
patch_pr_body() {
  local pr="$1" body="$2"
  curl -sf -X PATCH \
    -H "Authorization: token ${FORGE_TOKEN}" \
    -H "Content-Type: application/json" \
    "${FORGE_API_BASE}/repos/${FORGE_OPS_REPO}/pulls/${pr}" \
    -d "{\"body\":$(printf '%s' "$body" | jq -Rs '.')} " 2>/dev/null
}

# close_pr <pr_number> — close the PR with a comment
close_pr() {
  local pr="$1" reason="$2"
  post_pr_comment "$pr" "Rejected: ${reason}" 2>/dev/null || true
  curl -sf -X PATCH \
    -H "Authorization: token ${FORGE_TOKEN}" \
    -H "Content-Type: application/json" \
    "${FORGE_API_BASE}/repos/${FORGE_OPS_REPO}/pulls/${pr}" \
    -d '{"state":"closed"}' 2>/dev/null || true
}

# ── PR body marker helpers ──────────────────────────────────────────────

# extract_last_seen <pr_body> — extract <!-- architect-last-seen: ... -->
extract_last_seen() {
  printf '%s' "$1" | grep -oP '<!-- architect-last-seen:\s*\K[^ ]+' 2>/dev/null || echo ""
}

# update_last_seen <pr_body> <new_iso> — replace last-seen marker
update_last_seen() {
  local body="$1" new_iso="$2"
  if printf '%s' "$body" | grep -q '<!-- architect-last-seen:'; then
    printf '%s' "$body" | sed "s|<!-- architect-last-seen: *[^ ]* -->|<!-- architect-last-seen: ${new_iso} -->|"
  else
    printf '%s\n%s' "$body" "<!-- architect-last-seen: ${new_iso} -->"
  fi
}

# ── Round-robin: list and sort PRs by last-seen marker ─────────────────

list_architect_prs_sorted() {
  local prs
  prs=$(fetch_open_architect_prs)

  # Extract PR number and last-seen timestamp, sort by timestamp ascending
  printf '%s' "$prs" | jq -r '.[] | select(.title | startswith("architect:")) |
    "\(.number)|\(.updated_at)"' 2>/dev/null | sort -t'|' -k2 || true
}

# ── State: q_and_a ──────────────────────────────────────────────────────
# PR open, new non-architect comments since last-seen.
# Reject branch: bash-only (close PR). Otherwise: opus session.

dispatch_q_and_a() {
  local pr="$1" body="$2" last_seen="$3"

  # Check for Reject: comment
  if has_reject_comment "$pr" "$last_seen"; then
    local reason
    reason=$(get_reject_reason "$pr" "$last_seen")
    log "PR #${pr}: REJECT detected — closing PR"
    close_pr "$pr" "$reason"
    return
  fi

  # Check for new non-reject comments (engagement signal)
  if has_new_comment_since "$pr" "$last_seen"; then
    log "PR #${pr}: new engagement detected — dispatching opus session"
    _dispatch_opus_qa "$pr" "$body"
    return
  fi

  log "PR #${pr}: no new engagement — idle"
}

_dispatch_opus_qa() {
  local pr="$1" body="$2"

  # Load formula + context for the opus session
  load_formula_or_profile "architect" "$ARCHITECT_FORMULA" || return 1
  build_context_block VISION.md AGENTS.md ops:prerequisites.md
  formula_prepare_profile_context
  build_graph_section

  SCRATCH_CONTEXT=$(read_scratch_context "/tmp/architect-${PROJECT_NAME}-scratch.md")
  SCRATCH_INSTRUCTION=$(build_scratch_instruction "/tmp/architect-${PROJECT_NAME}-scratch.md")
  build_sdk_prompt_footer

  local prompt
  prompt=$(cat <<_PROMPT_EOF_
You are the architect agent for ${FORGE_REPO}. Work through the formula below.

${QA_ROLE_TEXT}
DO NOT create issues, PRs, or any other resource on the project repo.
If you think ${SUBISSUE_TERM} should be filed, write them into the ${PITCH_NOUN} file's
filer:begin block only. You do not have permission to POST to the project repo and
any such call will return 403 and fail this run.

## CURRENT STATE: Design Q&A in progress

An architect PR has received new operator engagement (a non-reject comment).
Your task:
1. Read the PR body and new comments
2. Refine the <!-- filer:begin --> ... <!-- filer:end --> block inline
3. Post a reply comment with your response
4. Do NOT close the PR — the operator drives the lifecycle

## Project context
${CONTEXT_BLOCK}
${GRAPH_SECTION}
${SCRATCH_CONTEXT}
$(formula_lessons_block)
## Formula
${FORMULA_CONTENT}

${SCRATCH_INSTRUCTION}
${PROMPT_FOOTER}
_PROMPT_EOF_
  )

  # Run opus session
  agent_run --worktree "$WORKTREE" "$prompt" || {
    log "PR #${pr}: opus q_and_a FAILED (exit $?)"
    _OPUS_DISPATCH_FAILED=true
    return 1
  }
  log "opus q_and_a session complete"
}

# ── Regression guard ───────────────────────────────────────────────────
check_architect_issue_filing() {
  local project_repo_path
  project_repo_path="/repos/${FORGE_REPO}/issues"

  if grep -q "POST.*${project_repo_path}" "$LOG_FILE" 2>/dev/null; then
    log "ERROR: regression detected — architect session attempted to POST to ${project_repo_path}"
    log "This violates the read-only contract established in #764."
    log "The architect-bot must NOT file issues directly on the project repo."
    log "Sub-issues are filed exclusively by filer-bot after sprint PR merge."
    echo "FATAL: architect-bot attempted direct issue creation on project repo" >&2
    exit 1
  fi
}

# ── Main: single linear flow ───────────────────────────────────────────

# Track whether any opus dispatch failed (prevents silent marker advancement)
_OPUS_DISPATCH_FAILED=false

# 1. List open architect PRs sorted by last-seen (round-robin)
pr_list=$(list_architect_prs_sorted)
if [ -z "$pr_list" ]; then
  log "No open architect PRs — exiting"
  check_architect_issue_filing
  exit 0
fi

# 2. Pick head of queue (first line = earliest last-seen)
head_pr_line=$(printf '%s\n' "$pr_list" | head -1)
PR_NUMBER="${head_pr_line%%|*}"
PR_UPDATED_AT="${head_pr_line##*|}"

log "Processing PR #${PR_NUMBER} (updated: ${PR_UPDATED_AT})"

# 3. Read PR state
PR_BODY=$(get_pr_body "$PR_NUMBER")
LAST_SEEN=$(extract_last_seen "$PR_BODY")

# If no last-seen marker exists, use PR updated_at as initial marker
if [ -z "$LAST_SEEN" ]; then
  LAST_SEEN="$PR_UPDATED_AT"
fi

NOW_ISO=$(date -u '+%Y-%m-%dT%H:%M:%SZ')

# 4. Detect state and dispatch
# Reject takes priority at any point in the lifecycle
if has_reject_comment "$PR_NUMBER" "$LAST_SEEN"; then
  # reject at any point — bash-only (close PR)
  log "PR #${PR_NUMBER}: reject detected → closing"
  REASON=$(get_reject_reason "$PR_NUMBER" "$LAST_SEEN")
  close_pr "$PR_NUMBER" "$REASON"
else
  # [q_and_a] — check for engagement
  log "PR #${PR_NUMBER}: q_and_a state"
  dispatch_q_and_a "$PR_NUMBER" "$PR_BODY" "$LAST_SEEN" || true
fi

# 5. Update last-seen marker only if opus dispatch succeeded
#    (failed dispatches must be re-detected on the next cycle)
if [ "$_OPUS_DISPATCH_FAILED" = false ]; then
  UPDATED_BODY=$(update_last_seen "$PR_BODY" "$NOW_ISO")
  if [ -n "$UPDATED_BODY" ] && [ "$UPDATED_BODY" != "$PR_BODY" ]; then
    patch_pr_body "$PR_NUMBER" "$UPDATED_BODY"
    log "Updated last-seen marker on PR #${PR_NUMBER}"
  fi
else
  log "PR #${PR_NUMBER}: opus dispatch failed — skipping marker advance"
fi

# ── Regression guard ───────────────────────────────────────────────────
check_architect_issue_filing

log "--- Architect run done ---"
