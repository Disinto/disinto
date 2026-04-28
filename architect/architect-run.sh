#!/usr/bin/env bash
# =============================================================================
# architect-run.sh — Forgejo-state-driven architect lifecycle
#
# Bash-driven state machine operating on architect PRs on the ops repo.
# No tmux sessions, no phase files — the bash script IS the state machine.
#
# Lifecycle states:
#   [q_and_a]       — PR open, no APPROVED review, new operator comments
#   [approved_idle] — PR APPROVED, no ## Filed: marker yet
#   [tracking]      — ## Filed: marker present, sub-issues not all green
#   [mergeable]     — ## Filed: marker present, all sub-issues green
#
# Round-robin: PRs sorted by <!-- architect-last-seen: <iso> --> ascending;
# head of queue is picked each iteration. last-seen advances every iteration.
#
# Write-permission contract:
#   ops repo: PATCH PR body, POST comments, close PR, merge PR
#   project repo: NONE (only reads — issues, acceptance scripts, vision)
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

cd "$PROJECT_REPO_ROOT"
resolve_forge_remote

# ── Resolve agent identity ──────────────────────────────────────────────
if [ -z "${AGENT_IDENTITY:-}" ] && [ -n "${FORGE_ARCHITECT_TOKEN:-}" ]; then
  AGENT_IDENTITY=$(forge_whoami)
fi

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

# get_pr_reviews <pr_number> — JSON array of review objects
get_pr_reviews() {
  local pr="$1"
  curl -sf -H "Authorization: token ${FORGE_TOKEN}" \
    "${FORGE_API_BASE}/repos/${FORGE_OPS_REPO}/pulls/${pr}/reviews" 2>/dev/null || echo '[]'
}

# has_approved_review <pr_number> — 0 if APPROVED review exists
has_approved_review() {
  local pr="$1"
  local reviews
  reviews=$(get_pr_reviews "$pr")
  if printf '%s' "$reviews" | jq -e '.[] | select(.state == "APPROVED")' >/dev/null 2>&1; then
    return 0
  fi
  return 1
}

# get_pr_comments <pr_number> — JSON array of comment objects
get_pr_comments() {
  local pr="$1"
  curl -sf -H "Authorization: token ${FORGE_TOKEN}" \
    "${FORGE_API_BASE}/repos/${FORGE_OPS_REPO}/issues/${pr}/comments" 2>/dev/null || echo '[]'
}

# has_reject_comment <pr_number> <since_iso> — 0 if Reject: comment since marker
has_reject_comment() {
  local pr="$1" since="$2"
  local comments
  comments=$(get_pr_comments "$pr")
  # Extract comments newer than last-seen marker and check for Reject: prefix
  printf '%s' "$comments" | jq -r --arg since "$since" '
    [.[] | select(.updated_at > $since) | .body] | .[]
  ' 2>/dev/null | grep -q '^Reject:' 2>/dev/null
}

# get_reject_reason <pr_number> <since_iso> — the reason after "Reject: "
get_reject_reason() {
  local pr="$1" since="$2"
  local comments
  comments=$(get_pr_comments "$pr")
  printf '%s' "$comments" | jq -r --arg since "$since" '
    [.[] | select(.updated_at > $since) | .body] | .[] | select(startswith("Reject:"))
  ' 2>/dev/null | head -1 | sed 's/^Reject: *//' 2>/dev/null || echo "rejected"
}

# has_new_comment_since <pr_number> <since_iso> — 0 if non-reject comment exists
has_new_comment_since() {
  local pr="$1" since="$2"
  local comments
  comments=$(get_pr_comments "$pr")
  # Check for any comment newer than last-seen that is NOT a Reject:
  printf '%s' "$comments" | jq -r --arg since "$since" '
    [.[] | select(.updated_at > $since) | .body] | .[] | select(test("^Reject:") | not)
  ' 2>/dev/null | head -1 | grep -q . 2>/dev/null
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

# merge_pr <pr_number> — merge the PR
merge_pr() {
  local pr="$1"
  curl -sf -X PUT \
    -H "Authorization: token ${FORGE_TOKEN}" \
    -H "Content-Type: application/json" \
    "${FORGE_API_BASE}/repos/${FORGE_OPS_REPO}/pulls/${pr}/merge" \
    -d '{}' 2>/dev/null || true
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

# extract_filed_issues <pr_body> — extract issue numbers from ## Filed: #N1 #N2 ...
extract_filed_issues() {
  printf '%s' "$1" | grep -oP '## Filed:\s*\K#([0-9]+)(\s+#([0-9]+))*' 2>/dev/null | grep -oP '#[0-9]+' || echo ""
}

# has_filed_marker <pr_body> — 0 if ## Filed: marker present
has_filed_marker() {
  printf '%s' "$1" | grep -q '## Filed:' 2>/dev/null
}

# extract_last_digest <pr_body> — extract <!-- architect-digest: ... -->
extract_last_digest() {
  printf '%s' "$1" | grep -zoP '<!-- architect-digest: \K[\s\S]*?(?= -->)' 2>/dev/null | tr -d '\0' | head -1 || echo ""
}

# ── Project repo read helpers ───────────────────────────────────────────

# check_subissue_green <issue_number> — run acceptance test, check labels
# Returns 0 if issue is green (closed + deployed label + acceptance rc=0)
check_subissue_green() {
  local issue="$1"
  local issue_num="${issue#\#}"

  # Check if issue is closed
  local issue_state
  issue_state=$(curl -sf -H "Authorization: token ${FORGE_TOKEN}" \
    "${FORGE_API_BASE}/repos/${FORGE_REPO}/issues/${issue_num}" 2>/dev/null \
    | jq -r '.state // empty' 2>/dev/null) || return 1
  if [ "$issue_state" != "closed" ]; then
    return 1
  fi

  # Check for deployed label
  local has_deployed
  has_deployed=$(curl -sf -H "Authorization: token ${FORGE_TOKEN}" \
    "${FORGE_API_BASE}/repos/${FORGE_REPO}/issues/${issue_num}/labels" 2>/dev/null \
    | jq -r '.[].name // empty' 2>/dev/null | grep -q '^deployed$' && echo yes || echo no) || return 1
  if [ "$has_deployed" != "yes" ]; then
    return 1
  fi

  # Run acceptance test
  local test_script="${PROJECT_REPO_ROOT}/tests/acceptance/issue-${issue_num}.sh"
  if [ -f "$test_script" ] && bash "$test_script" >/dev/null 2>&1; then
    return 0
  fi

  # No acceptance test or it failed — not green
  return 1
}

# get_last_digest_state <pr_body> — extract issue states from last digest marker
# Returns space-separated "issueN:state" pairs (normalized, no space after colon)
get_last_digest_state() {
  local body="$1"
  local digest
  digest=$(extract_last_digest "$body")
  if [ -z "$digest" ]; then
    echo ""
    return
  fi
  # Extract issue states from the marker content (format: #N:state)
  printf '%s' "$digest" | grep -oP '#[0-9]+:\s*(open|closed|green|pending)' 2>/dev/null \
    | sed 's/: */:/' | tr '\n' ' ' | sed 's/ *$//' | sed 's/$/ /' || echo ""
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
# PR open, no APPROVED review, new operator comments since last-seen.
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
  load_formula_or_profile "architect" "$FACTORY_ROOT/formulas/run-architect.toml" || return 1
  build_context_block VISION.md AGENTS.md ops:prerequisites.md
  formula_prepare_profile_context
  build_graph_section

  SCRATCH_CONTEXT=$(read_scratch_context "/tmp/architect-${PROJECT_NAME}-scratch.md")
  SCRATCH_INSTRUCTION=$(build_scratch_instruction "/tmp/architect-${PROJECT_NAME}-scratch.md")
  build_sdk_prompt_footer

  local prompt
  prompt=$(cat <<_PROMPT_EOF_
You are the architect agent for ${FORGE_REPO}. Work through the formula below.

Your role: strategic decomposition of vision issues into development sprints.
Propose sprints via PRs on the ops repo, converse with humans through PR comments.
You are READ-ONLY on the project repo — sub-issues are filed by filer-bot after sprint PR merge (#764).
DO NOT create issues, PRs, or any other resource on the project repo. Any sub-issue
specification must go only into the filer:begin/filer:end block of the sprint pitch.
If you think sub-issues should be filed, write them into the sprint file's filer:begin
block only. You do not have permission to POST to the project repo and any such call
will return 403 and fail this run.

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
  agent_run --worktree "/tmp/${PROJECT_NAME}-architect-run" "$prompt"
  log "opus q_and_a session complete"
}

# ── State: approved_idle ────────────────────────────────────────────────
# PR has APPROVED review, no ## Filed: marker.
# Bash-only: post one "awaiting filer" comment per rotation.

dispatch_approved_idle() {
  local pr="$1" body="$2"

  # Check if we already posted an "awaiting filer" comment by looking at
  # recent PR comments (avoid spamming on each rotation pass)
  local comments
  comments=$(get_pr_comments "$pr")
  if printf '%s' "$comments" | jq -r '.[].body // empty' 2>/dev/null \
    | grep -q 'awaiting filer' 2>/dev/null; then
    log "PR #${pr}: already awaiting filer — no new comment needed"
    return
  fi

  log "PR #${pr}: approved, awaiting filer — posting comment"
  post_pr_comment "$pr" "Approved — awaiting filer. Sub-issues will be filed by the filer-bot after this PR merges." 2>/dev/null || true
}

# ── State: tracking ─────────────────────────────────────────────────────
# ## Filed: marker present, not all sub-issues green.
# Opus-only when sub-issue state has changed since last digest.

dispatch_tracking() {
  local pr="$1" body="$2"

  # Extract filed issue numbers
  local filed_issues
  filed_issues=$(extract_filed_issues "$body")
  if [ -z "$filed_issues" ]; then
    log "PR #${pr}: tracked but no filed issues — skipping"
    return
  fi

  # Check if all are green
  local all_green=true
  local current_states=""
  while IFS= read -r issue; do
    [ -z "$issue" ] && continue
    if check_subissue_green "$issue"; then
      current_states="${current_states}${issue}:green "
    else
      all_green=false
      current_states="${current_states}${issue}:pending "
    fi
  done <<< "$filed_issues"

  if [ "$all_green" = true ]; then
    log "PR #${pr}: all filed issues green — ready for merge"
    return
  fi

  # Check if state changed since last digest
  local last_digest last_digest_state needs_opus=false
  last_digest=$(extract_last_digest "$body")
  if [ -n "$last_digest" ]; then
    last_digest_state=$(get_last_digest_state "$body")
    if [ -n "$last_digest_state" ] && [ "$last_digest_state" != "$current_states" ]; then
      needs_opus=true
    fi
  else
    # No previous digest — always opus on first tracking pass
    needs_opus=true
  fi

  if [ "$needs_opus" = true ]; then
    log "PR #${pr}: state changed since last digest — dispatching opus digest"
    _dispatch_opus_tracking_digest "$pr" "$current_states"
  else
    log "PR #${pr}: no state change since last digest — skipping opus"
  fi
}

_dispatch_opus_tracking_digest() {
  local pr="$1" states="$2"

  load_formula_or_profile "architect" "$FACTORY_ROOT/formulas/run-architect.toml" || return 1
  build_context_block VISION.md AGENTS.md ops:prerequisites.md
  formula_prepare_profile_context
  build_graph_section
  build_sdk_prompt_footer

  local prompt
  prompt=$(cat <<_PROMPT_EOF_
You are the architect agent for ${FORGE_REPO}.

## CURRENT STATE: Tracking filed sub-issues

A sprint PR has been approved and sub-issues have been filed. You are tracking
their progress. The current state of each filed issue:

${states}

"green" = closed AND has deployed label AND acceptance test rc=0
"pending" = not yet green

Your task:
1. Write a digest comment summarizing the current state
2. Update the PR body with a <!-- architect-digest: TIMESTAMP #N:state ... --> marker
   (TIMESTAMP is ISO-8601 UTC; include each issue as #N:state where state is green/pending)
3. Post the digest as a PR comment

## Project context
${CONTEXT_BLOCK}
${GRAPH_SECTION}
$(formula_lessons_block)
## Formula
${FORMULA_CONTENT}

${PROMPT_FOOTER}
_PROMPT_EOF_
  )

  agent_run --worktree "/tmp/${PROJECT_NAME}-architect-run" "$prompt"
  log "opus tracking digest complete"
}

# ── State: mergeable ────────────────────────────────────────────────────
# ## Filed: marker present, all sub-issues green.
# Bash-only: merge PR, post closure summary.

dispatch_mergeable() {
  local pr="$1" body="$2"

  log "PR #${pr}: all sub-issues green — merging"

  # Post closure summary
  local filed_issues
  filed_issues=$(extract_filed_issues "$body")
  post_pr_comment "$pr" "All sub-issues verified green. Merging sprint PR." 2>/dev/null || true

  # Merge the PR
  merge_pr "$pr"
  log "PR #${pr}: merged"
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
elif has_approved_review "$PR_NUMBER"; then
  # [approved_idle] or [mergeable] — check for filed marker
  if has_filed_marker "$PR_BODY"; then
    # Check if mergeable
    filed_issues=$(extract_filed_issues "$PR_BODY")
    all_green=true
    while IFS= read -r issue; do
      [ -z "$issue" ] && continue
      if ! check_subissue_green "$issue"; then
        all_green=false
        break
      fi
    done <<< "$filed_issues"

    if [ "$all_green" = true ]; then
      log "PR #${PR_NUMBER}: approved + all green → mergeable"
      dispatch_mergeable "$PR_NUMBER" "$PR_BODY"
    else
      log "PR #${PR_NUMBER}: approved + some pending → tracking"
      dispatch_tracking "$PR_NUMBER" "$PR_BODY"
    fi
  else
    log "PR #${PR_NUMBER}: approved, no filed marker → approved_idle"
    dispatch_approved_idle "$PR_NUMBER" "$PR_BODY"
  fi
else
  # [q_and_a] — check for engagement
  log "PR #${PR_NUMBER}: q_and_a state"
  dispatch_q_and_a "$PR_NUMBER" "$PR_BODY" "$LAST_SEEN"
fi

# 5. Update last-seen marker (always, whether work happened or not)
UPDATED_BODY=$(update_last_seen "$PR_BODY" "$NOW_ISO")
if [ -n "$UPDATED_BODY" ] && [ "$UPDATED_BODY" != "$PR_BODY" ]; then
  patch_pr_body "$PR_NUMBER" "$UPDATED_BODY"
  log "Updated last-seen marker on PR #${PR_NUMBER}"
fi

# ── Regression guard ───────────────────────────────────────────────────
check_architect_issue_filing

log "--- Architect run done ---"
