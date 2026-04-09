#!/usr/bin/env bash
# =============================================================================
# architect-run.sh — Cron wrapper: architect execution via SDK + formula
#
# Synchronous bash loop using claude -p (one-shot invocation).
# No tmux sessions, no phase files — the bash script IS the state machine.
#
# Flow:
#   1. Guards: cron lock, memory check
#   2. Precondition checks: skip if no work (no vision issues, no responses)
#   3. Load formula (formulas/run-architect.toml)
#   4. Context: VISION.md, AGENTS.md, ops:prerequisites.md, structural graph
#   5. Bash-driven design phase:
#      a. Fetch reviews API for ACCEPT/REJECT detection (deterministic)
#      b. REJECT: handled entirely in bash (close PR, delete branch, journal)
#      c. ACCEPT: invoke claude with human guidance injected into prompt
#      d. Answers: resume saved session with answers injected
#   6. New pitches: agent_run(worktree, prompt)
#
# Precondition checks (bash before model):
#   - Skip if no vision issues AND no open architect PRs
#   - Skip if 3+ architect PRs open AND no ACCEPT/REJECT responses to process
#   - Only invoke model when there's actual work: new pitches or response processing
#
# Usage:
#   architect-run.sh [projects/disinto.toml]   # project config (default: disinto)
#
# Cron: 0 */6 * * *   # every 6 hours
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
FACTORY_ROOT="$(dirname "$SCRIPT_DIR")"

# Accept project config from argument; default to disinto
export PROJECT_TOML="${1:-$FACTORY_ROOT/projects/disinto.toml}"
# shellcheck source=../lib/env.sh
source "$FACTORY_ROOT/lib/env.sh"
# Override FORGE_TOKEN with architect-bot's token (#747)
FORGE_TOKEN="${FORGE_ARCHITECT_TOKEN:-${FORGE_TOKEN}}"
# shellcheck source=../lib/formula-session.sh
source "$FACTORY_ROOT/lib/formula-session.sh"
# shellcheck source=../lib/worktree.sh
source "$FACTORY_ROOT/lib/worktree.sh"
# shellcheck source=../lib/guard.sh
source "$FACTORY_ROOT/lib/guard.sh"
# shellcheck source=../lib/agent-sdk.sh
source "$FACTORY_ROOT/lib/agent-sdk.sh"

LOG_FILE="${DISINTO_LOG_DIR}/architect/architect.log"
# shellcheck disable=SC2034  # consumed by agent-sdk.sh
LOGFILE="$LOG_FILE"
# shellcheck disable=SC2034  # consumed by agent-sdk.sh
SID_FILE="/tmp/architect-session-${PROJECT_NAME}.sid"
# Per-PR session files for stateful resumption across runs
SID_DIR="/tmp/architect-sessions-${PROJECT_NAME}"
mkdir -p "$SID_DIR"
SCRATCH_FILE="/tmp/architect-${PROJECT_NAME}-scratch.md"
SCRATCH_FILE_PREFIX="/tmp/architect-${PROJECT_NAME}-scratch"
WORKTREE="/tmp/${PROJECT_NAME}-architect-run"

# Override LOG_AGENT for consistent agent identification
# shellcheck disable=SC2034  # consumed by agent-sdk.sh and env.sh log()
LOG_AGENT="architect"

# Override log() to append to architect-specific log file
# shellcheck disable=SC2034
log() {
  local agent="${LOG_AGENT:-architect}"
  printf '[%s] %s: %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$agent" "$*" >> "$LOG_FILE"
}

# ── Guards ────────────────────────────────────────────────────────────────
check_active architect
acquire_cron_lock "/tmp/architect-run.lock"
memory_guard 2000

log "--- Architect run start ---"

# ── Resolve forge remote for git operations ─────────────────────────────
resolve_forge_remote

# ── Resolve agent identity for .profile repo ────────────────────────────
if [ -z "${AGENT_IDENTITY:-}" ] && [ -n "${FORGE_ARCHITECT_TOKEN:-}" ]; then
  AGENT_IDENTITY=$(curl -sf -H "Authorization: token ${FORGE_ARCHITECT_TOKEN}" \
    "${FORGE_URL:-http://localhost:3000}/api/v1/user" 2>/dev/null | jq -r '.login // empty' 2>/dev/null || true)
fi

# ── Load formula + context ───────────────────────────────────────────────
load_formula_or_profile "architect" "$FACTORY_ROOT/formulas/run-architect.toml" || exit 1
build_context_block VISION.md AGENTS.md ops:prerequisites.md

# ── Prepare .profile context (lessons injection) ─────────────────────────
formula_prepare_profile_context

# ── Build structural analysis graph ──────────────────────────────────────
build_graph_section

# ── Read scratch file (compaction survival) ───────────────────────────────
SCRATCH_CONTEXT=$(read_scratch_context "$SCRATCH_FILE")
SCRATCH_INSTRUCTION=$(build_scratch_instruction "$SCRATCH_FILE")

# ── Build prompt footer ──────────────────────────────────────────────────
build_sdk_prompt_footer

# ── Design phase: bash-driven review detection ────────────────────────────
# Fetch PR reviews from Forgejo API (deterministic, not model-dependent).
# Sets global output variables (not stdout — guidance text is often multiline):
#   REVIEW_DECISION  — ACCEPT|REJECT|NONE
#   REVIEW_GUIDANCE  — human guidance text (review body or comment text)
# Args: pr_number
fetch_pr_review_decision() {
  local pr_num="$1"
  REVIEW_DECISION="NONE"
  REVIEW_GUIDANCE=""

  # Step 1: Check PR reviews (Forgejo review UI) — takes precedence
  local reviews_json
  reviews_json=$(curl -sf -H "Authorization: token ${FORGE_TOKEN}" \
    "${FORGE_API}/repos/${FORGE_OPS_REPO}/pulls/${pr_num}/reviews" 2>/dev/null) || reviews_json='[]'

  # Find most recent non-bot review with a decision state
  local review_decision review_body
  review_decision=$(printf '%s' "$reviews_json" | jq -r '
    [.[] | select(.user.login | test("bot$"; "i") | not)
         | select(.state == "APPROVED" or .state == "REQUEST_CHANGES")]
    | last | .state // empty
  ' 2>/dev/null) || review_decision=""
  review_body=$(printf '%s' "$reviews_json" | jq -r '
    [.[] | select(.user.login | test("bot$"; "i") | not)
         | select(.state == "APPROVED" or .state == "REQUEST_CHANGES")]
    | last | .body // empty
  ' 2>/dev/null) || review_body=""

  if [ "$review_decision" = "APPROVED" ]; then
    REVIEW_DECISION="ACCEPT"
    REVIEW_GUIDANCE="$review_body"
    return 0
  elif [ "$review_decision" = "REQUEST_CHANGES" ]; then
    REVIEW_DECISION="REJECT"
    REVIEW_GUIDANCE="$review_body"
    return 0
  fi

  # Step 2: Fallback — check PR comments for ACCEPT/REJECT text
  local comments_json
  comments_json=$(curl -sf -H "Authorization: token ${FORGE_TOKEN}" \
    "${FORGE_API}/repos/${FORGE_OPS_REPO}/issues/${pr_num}/comments" 2>/dev/null) || comments_json='[]'

  # Find most recent comment with ACCEPT or REJECT (case insensitive)
  local comment_body
  comment_body=$(printf '%s' "$comments_json" | jq -r '
    [.[] | select(.body | test("(?i)^\\s*(ACCEPT|REJECT)"))] | last | .body // empty
  ' 2>/dev/null) || comment_body=""

  if [ -n "$comment_body" ]; then
    if printf '%s' "$comment_body" | grep -qiE '^\s*ACCEPT'; then
      REVIEW_DECISION="ACCEPT"
      # Extract guidance text after ACCEPT (e.g., "ACCEPT — use SSH approach" → "use SSH approach")
      REVIEW_GUIDANCE=$(printf '%s' "$comment_body" | sed -n 's/^[[:space:]]*[Aa][Cc][Cc][Ee][Pp][Tt][[:space:]]*[—:–-]*[[:space:]]*//p' | head -1)
      # If guidance is empty on first line, use rest of comment
      if [ -z "$REVIEW_GUIDANCE" ]; then
        REVIEW_GUIDANCE=$(printf '%s' "$comment_body" | tail -n +2)
      fi
    elif printf '%s' "$comment_body" | grep -qiE '^\s*REJECT'; then
      REVIEW_DECISION="REJECT"
      REVIEW_GUIDANCE=$(printf '%s' "$comment_body" | sed -n 's/^[[:space:]]*[Rr][Ee][Jj][Ee][Cc][Tt][[:space:]]*[—:–-]*[[:space:]]*//p' | head -1)
      if [ -z "$REVIEW_GUIDANCE" ]; then
        REVIEW_GUIDANCE=$(printf '%s' "$comment_body" | tail -n +2)
      fi
    fi
  fi
}

# Handle REJECT entirely in bash — no model invocation needed.
# Args: pr_number, pr_head_branch, rejection_reason
handle_reject() {
  local pr_num="$1"
  local pr_branch="$2"
  local reason="$3"

  log "Handling REJECT for PR #${pr_num}: ${reason}"

  # Close the PR via Forgejo API
  curl -sf -X PATCH -H "Authorization: token ${FORGE_TOKEN}" \
    -H 'Content-Type: application/json' \
    "${FORGE_API}/repos/${FORGE_OPS_REPO}/pulls/${pr_num}" \
    -d '{"state":"closed"}' >/dev/null 2>&1 || log "WARN: failed to close PR #${pr_num}"

  # Delete the branch via Forgejo API
  if [ -n "$pr_branch" ]; then
    curl -sf -X DELETE -H "Authorization: token ${FORGE_TOKEN}" \
      "${FORGE_API}/repos/${FORGE_OPS_REPO}/git/branches/${pr_branch}" >/dev/null 2>&1 \
      || log "WARN: failed to delete branch ${pr_branch}"
  fi

  # Remove in-progress label from the vision issue referenced in the PR
  local pr_body
  pr_body=$(curl -sf -H "Authorization: token ${FORGE_TOKEN}" \
    "${FORGE_API}/repos/${FORGE_OPS_REPO}/pulls/${pr_num}" 2>/dev/null | jq -r '.body // ""') || pr_body=""
  local vision_ref
  vision_ref=$(printf '%s' "$pr_body" | grep -oE '#[0-9]+' | head -1 | tr -d '#') || vision_ref=""

  if [ -n "$vision_ref" ]; then
    # Look up in-progress label ID
    local label_id
    label_id=$(curl -sf -H "Authorization: token ${FORGE_TOKEN}" \
      "${FORGE_API}/labels" 2>/dev/null | jq -r '.[] | select(.name == "in-progress") | .id' 2>/dev/null) || label_id=""
    if [ -n "$label_id" ]; then
      curl -sf -X DELETE -H "Authorization: token ${FORGE_TOKEN}" \
        "${FORGE_API}/issues/${vision_ref}/labels/${label_id}" >/dev/null 2>&1 \
        || log "WARN: failed to remove in-progress label from issue #${vision_ref}"
    fi
  fi

  # Journal the rejection via .profile (if available)
  profile_write_journal "architect-reject-${pr_num}" \
    "Sprint PR #${pr_num} rejected" \
    "rejected: ${reason}" "" || true

  # Clean up per-PR session file
  rm -f "${SID_DIR}/pr-${pr_num}.sid"

  log "REJECT handled for PR #${pr_num}"
}

# Detect answers on a PR in questions phase.
# Returns answer text via stdout, empty if no answers found.
# Args: pr_number
fetch_pr_answers() {
  local pr_num="$1"

  # Get PR body to check for Design forks section
  local pr_body
  pr_body=$(curl -sf -H "Authorization: token ${FORGE_TOKEN}" \
    "${FORGE_API}/repos/${FORGE_OPS_REPO}/pulls/${pr_num}" 2>/dev/null | jq -r '.body // ""') || return 1

  if ! printf '%s' "$pr_body" | grep -q "## Design forks"; then
    return 1
  fi

  # Fetch comments and look for answer patterns (Q1: A, Q2: B, etc.)
  local comments_json
  comments_json=$(curl -sf -H "Authorization: token ${FORGE_TOKEN}" \
    "${FORGE_API}/repos/${FORGE_OPS_REPO}/issues/${pr_num}/comments" 2>/dev/null) || return 1

  # Find the most recent comment containing answer patterns
  local answer_comment
  answer_comment=$(printf '%s' "$comments_json" | jq -r '
    [.[] | select(.body | test("Q[0-9]+:\\s*[A-Da-d]"))] | last | .body // empty
  ' 2>/dev/null) || answer_comment=""

  if [ -n "$answer_comment" ]; then
    printf '%s' "$answer_comment"
    return 0
  fi

  return 1
}

# ── Sub-issue existence check ────────────────────────────────────────────
# Check if a vision issue already has sub-issues filed from it.
# Returns 0 if sub-issues exist and are open, 1 otherwise.
# Args: vision_issue_number
has_open_subissues() {
  local vision_issue="$1"
  local subissue_count=0

  # Search for issues whose body contains 'Decomposed from #N' pattern
  # Fetch all open issues with bodies in one API call (avoids N+1 calls)
  local issues_json
  issues_json=$(curl -sf -H "Authorization: token ${FORGE_TOKEN}" \
    "${FORGE_API}/issues?state=open&limit=100" 2>/dev/null) || return 1

  # Check each issue for the decomposition pattern using jq to extract bodies
  subissue_count=$(printf '%s' "$issues_json" | jq -r --arg vid "$vision_issue" '
    [.[] | select(.number != $vid) | select(.body // "" | contains("Decomposed from #" + $vid))] | length
  ' 2>/dev/null) || subissue_count=0

  if [ "$subissue_count" -gt 0 ]; then
    log "Vision issue #${vision_issue} has ${subissue_count} open sub-issue(s) — skipping"
    return 0  # Has open sub-issues
  fi

  log "Vision issue #${vision_issue} has no open sub-issues"
  return 1  # No open sub-issues
}

# ── Merged sprint PR check ───────────────────────────────────────────────
# Check if a vision issue already has a merged sprint PR on the ops repo.
# Returns 0 if a merged sprint PR exists, 1 otherwise.
# Args: vision_issue_number
has_merged_sprint_pr() {
  local vision_issue="$1"

  # Get closed PRs from ops repo
  local prs_json
  prs_json=$(curl -sf -H "Authorization: token ${FORGE_TOKEN}" \
    "${FORGE_API}/repos/${FORGE_OPS_REPO}/pulls?state=closed&limit=100" 2>/dev/null) || return 1

  # Check each closed PR for architect markers and vision issue reference
  local pr_numbers
  pr_numbers=$(printf '%s' "$prs_json" | jq -r '.[] | select(.title | contains("architect:")) | .number' 2>/dev/null) || return 1

  local pr_num
  while IFS= read -r pr_num; do
    [ -z "$pr_num" ] && continue

    # Get PR details including merged status
    local pr_details
    pr_details=$(curl -sf -H "Authorization: token ${FORGE_TOKEN}" \
      "${FORGE_API}/repos/${FORGE_OPS_REPO}/pulls/${pr_num}" 2>/dev/null) || continue

    # Check if PR is actually merged (not just closed)
    local is_merged
    is_merged=$(printf '%s' "$pr_details" | jq -r '.merged // false') || continue

    if [ "$is_merged" != "true" ]; then
      continue
    fi

    # Get PR body and check for vision issue reference
    local pr_body
    pr_body=$(printf '%s' "$pr_details" | jq -r '.body // ""') || continue

    # Check if PR body references the vision issue number
    # Look for patterns like "#N" where N is the vision issue number
    if printf '%s' "$pr_body" | grep -qE "(#|refs|references)[[:space:]]*#${vision_issue}|#${vision_issue}[^0-9]|#${vision_issue}$"; then
      log "Found merged sprint PR #${pr_num} referencing vision issue #${vision_issue} — skipping"
      return 0  # Has merged sprint PR
    fi
  done <<< "$pr_numbers"

  log "Vision issue #${vision_issue} has no merged sprint PR"
  return 1  # No merged sprint PR
}

# ── Precondition checks in bash before invoking the model ─────────────────

# Check 1: Skip if no vision issues exist and no open architect PRs to handle
vision_count=$(curl -sf -H "Authorization: token $FORGE_TOKEN" \
  "$FORGE_API/issues?labels=vision&state=open&limit=1" 2>/dev/null | jq length) || vision_count=0
if [ "${vision_count:-0}" -eq 0 ]; then
  # Check for open architect PRs that need handling (ACCEPT/REJECT responses)
  open_arch_prs=$(curl -sf -H "Authorization: token $FORGE_TOKEN" \
    "${FORGE_API}/repos/${FORGE_OPS_REPO}/pulls?state=open&limit=10" 2>/dev/null | jq '[.[] | select(.title | startswith("architect:"))] | length') || open_arch_prs=0
  if [ "${open_arch_prs:-0}" -eq 0 ]; then
    log "no vision issues and no open architect PRs — skipping"
    exit 0
  fi
fi

# ── Design phase: process existing architect PRs (bash-driven) ────────────
# Bash reads the reviews API and handles state transitions deterministically.
# Model is only invoked for research (ACCEPT) and answer processing.

open_arch_prs_json=$(curl -sf -H "Authorization: token $FORGE_TOKEN" \
  "${FORGE_API}/repos/${FORGE_OPS_REPO}/pulls?state=open&limit=10" 2>/dev/null) || open_arch_prs_json='[]'
open_arch_prs=$(printf '%s' "$open_arch_prs_json" | jq '[.[] | select(.title | startswith("architect:"))] | length') || open_arch_prs=0

# Track whether we processed any responses (to decide if pitching is needed)
processed_responses=false

# Iterate over open architect PRs and handle each based on review state
arch_pr_data=$(printf '%s' "$open_arch_prs_json" | jq -r '.[] | select(.title | startswith("architect:")) | "\(.number)\t\(.head.ref // "")"' 2>/dev/null) || arch_pr_data=""

while IFS=$'\t' read -r pr_num pr_branch; do
  [ -z "$pr_num" ] && continue

  log "Checking PR #${pr_num} (branch: ${pr_branch})"

  # First check: is this PR in the answers phase (questions posted, answers received)?
  answer_text=""
  answer_text=$(fetch_pr_answers "$pr_num") || true

  if [ -n "$answer_text" ]; then
    # ── Answers received: resume saved session with answers injected ──
    log "Answers detected on PR #${pr_num} — resuming design session"
    processed_responses=true

    pr_sid_file="${SID_DIR}/pr-${pr_num}.sid"
    RESUME_ARGS=()
    if [ -f "$pr_sid_file" ]; then
      RESUME_SESSION=$(cat "$pr_sid_file")
      RESUME_ARGS=(--resume "$RESUME_SESSION")
      log "Resuming session ${RESUME_SESSION:0:12}... for answer processing"
    else
      log "No saved session for PR #${pr_num} — starting fresh for answers"
    fi

    # Build answer-processing prompt with answers injected
    # shellcheck disable=SC2034
    SID_FILE="$pr_sid_file"
    ANSWER_PROMPT="You are the architect agent for ${FORGE_REPO}. You previously researched a sprint and posted design questions on PR #${pr_num}.

Human answered the design fork questions. Parse the answers and file concrete sub-issues.

## Human answers
${answer_text}

## Project context
${CONTEXT_BLOCK}
${GRAPH_SECTION}
$(formula_lessons_block)

## Instructions
1. Parse each answer (e.g. Q1: A, Q2: C)
2. Read the sprint spec from the PR branch
3. Look up the backlog label ID on the disinto repo:
   GET ${FORGE_API}/labels — find label with name 'backlog'
4. Generate final sub-issues based on answers:
   - Each sub-issue uses the appropriate issue template
   - Fill all template fields (problem, solution, affected files max 3, acceptance criteria max 5, dependencies)
   - File via Forgejo API on the disinto repo (not ops repo)
   - MUST include 'labels' with backlog label ID in create-issue request
   - Include 'Decomposed from #<vision_issue_number>' in each issue body
5. Comment on PR #${pr_num}: 'Sprint filed: #N, #N, #N'
6. Merge the PR via: POST ${FORGE_API}/repos/${FORGE_OPS_REPO}/pulls/${pr_num}/merge with body {\"Do\":\"merge\"}

${PROMPT_FOOTER}"

    # Create worktree if not already set up
    if [ ! -d "$WORKTREE" ]; then
      formula_worktree_setup "$WORKTREE"
    fi

    export CLAUDE_MODEL="sonnet"
    agent_run "${RESUME_ARGS[@]}" --worktree "$WORKTREE" "$ANSWER_PROMPT"
    # Restore SID_FILE to default
    # shellcheck disable=SC2034  # consumed by agent-sdk.sh
    SID_FILE="/tmp/architect-session-${PROJECT_NAME}.sid"
    log "Answer processing complete for PR #${pr_num}"
    continue
  fi

  # Second check: fetch review decision (ACCEPT/REJECT/NONE)
  # Sets REVIEW_DECISION and REVIEW_GUIDANCE global variables
  fetch_pr_review_decision "$pr_num"
  decision="$REVIEW_DECISION"
  guidance="$REVIEW_GUIDANCE"

  case "$decision" in
    REJECT)
      # ── REJECT: handled entirely in bash ──
      handle_reject "$pr_num" "$pr_branch" "$guidance"
      processed_responses=true
      # Decrement open PR count (PR is now closed)
      open_arch_prs=$((open_arch_prs - 1))
      ;;

    ACCEPT)
      # ── ACCEPT: invoke model with human guidance for research + questions ──
      log "ACCEPT detected on PR #${pr_num} with guidance: ${guidance:-(none)}"
      processed_responses=true

      # Build human guidance block
      GUIDANCE_BLOCK=""
      if [ -n "$guidance" ]; then
        GUIDANCE_BLOCK="## Human guidance (from sprint PR review)
${guidance}

The architect MUST factor this guidance into design fork identification
and question formulation — if the human specifies an approach, that approach
should be the default fork, and questions should refine it rather than
re-evaluate it."
      fi

      # Build research + questions prompt
      RESEARCH_PROMPT="You are the architect agent for ${FORGE_REPO}. A sprint pitch on PR #${pr_num} has been ACCEPTED by a human reviewer.

Your task: research the codebase deeply, identify design forks, and formulate questions.

${GUIDANCE_BLOCK}

## Project context
${CONTEXT_BLOCK}
${GRAPH_SECTION}
${SCRATCH_CONTEXT}
$(formula_lessons_block)

## Instructions
1. Read the sprint spec from PR #${pr_num} on the ops repo (branch: ${pr_branch})
2. Research the codebase deeply:
   - Read all files mentioned in the sprint spec
   - Search for existing interfaces that could be reused
   - Check what infrastructure already exists
3. Identify design forks — multiple valid implementation approaches
4. Formulate multiple-choice questions (Q1, Q2, Q3...)
5. Update the sprint spec file on the PR branch:
   - Add '## Design forks' section with fork options
   - Add '## Proposed sub-issues' section with concrete issues per fork path
   - Use Forgejo API: PUT ${FORGE_API}/repos/${FORGE_OPS_REPO}/contents/<path> with branch ${pr_branch}
6. Update the PR body to include the Design forks section (required for answer detection):
   - PATCH ${FORGE_API}/repos/${FORGE_OPS_REPO}/pulls/${pr_num}
   - Body: {\"body\": \"<existing PR body + Design forks section>\"}
   - The PR body MUST contain '## Design forks' after this step
7. Comment on PR #${pr_num} with the questions formatted as multiple choice:
   - POST ${FORGE_API}/repos/${FORGE_OPS_REPO}/issues/${pr_num}/comments

${SCRATCH_INSTRUCTION}
${PROMPT_FOOTER}"

      # Use per-PR session file for stateful resumption
      pr_sid_file="${SID_DIR}/pr-${pr_num}.sid"
      # shellcheck disable=SC2034
      SID_FILE="$pr_sid_file"

      # Create worktree if not already set up
      if [ ! -d "$WORKTREE" ]; then
        formula_worktree_setup "$WORKTREE"
      fi

      export CLAUDE_MODEL="sonnet"
      agent_run --worktree "$WORKTREE" "$RESEARCH_PROMPT"
      log "Research + questions posted for PR #${pr_num}, session saved: ${pr_sid_file}"
      # Restore SID_FILE to default
      # shellcheck disable=SC2034  # consumed by agent-sdk.sh
      SID_FILE="/tmp/architect-session-${PROJECT_NAME}.sid"
      ;;

    NONE)
      log "PR #${pr_num} — no response yet, skipping"
      ;;
  esac
done <<< "$arch_pr_data"

# ── Preflight: Select vision issues for pitching ──────────────────────────
# Recalculate open PR count after handling responses (REJECTs reduce count)

# Re-fetch if we processed any responses (PR count may have changed)
if [ "$processed_responses" = true ]; then
  open_arch_prs_json=$(curl -sf -H "Authorization: token $FORGE_TOKEN" \
    "${FORGE_API}/repos/${FORGE_OPS_REPO}/pulls?state=open&limit=10" 2>/dev/null) || open_arch_prs_json='[]'
  open_arch_prs=$(printf '%s' "$open_arch_prs_json" | jq '[.[] | select(.title | startswith("architect:"))] | length') || open_arch_prs=0
fi

# Build list of vision issues that already have open architect PRs
declare -A _arch_vision_issues_with_open_prs
while IFS= read -r pr_num; do
  [ -z "$pr_num" ] && continue
  pr_body=$(curl -sf -H "Authorization: token $FORGE_TOKEN" \
    "${FORGE_API}/repos/${FORGE_OPS_REPO}/pulls/${pr_num}" 2>/dev/null | jq -r '.body // ""') || continue
  # Extract vision issue numbers referenced in PR body (e.g., "refs #419" or "#419")
  while IFS= read -r ref_issue; do
    [ -z "$ref_issue" ] && continue
    _arch_vision_issues_with_open_prs["$ref_issue"]=1
  done <<< "$(printf '%s' "$pr_body" | grep -oE '#[0-9]+' | tr -d '#' | sort -u)"
done <<< "$(printf '%s' "$open_arch_prs_json" | jq -r '.[] | select(.title | startswith("architect:")) | .number')"

# Get all open vision issues
vision_issues_json=$(curl -sf -H "Authorization: token $FORGE_TOKEN" \
  "${FORGE_API}/issues?labels=vision&state=open&limit=100" 2>/dev/null) || vision_issues_json='[]'

# Get issues with in-progress label
in_progress_issues=$(curl -sf -H "Authorization: token $FORGE_TOKEN" \
  "${FORGE_API}/issues?labels=in-progress&state=open&limit=100" 2>/dev/null | jq -r '.[].number' 2>/dev/null) || in_progress_issues=""

# Select vision issues for pitching
ARCHITECT_TARGET_ISSUES=()
vision_issue_count=0
pitch_budget=$((3 - open_arch_prs))

# Get all vision issue numbers
vision_issue_nums=$(printf '%s' "$vision_issues_json" | jq -r '.[].number' 2>/dev/null) || vision_issue_nums=""

while IFS= read -r vision_issue; do
  [ -z "$vision_issue" ] && continue
  vision_issue_count=$((vision_issue_count + 1))

  # Skip if pitch budget exhausted
  if [ "${pitch_budget}" -le 0 ] || [ ${#ARCHITECT_TARGET_ISSUES[@]} -ge "$pitch_budget" ]; then
    log "Pitch budget exhausted (${#ARCHITECT_TARGET_ISSUES[@]}/${pitch_budget})"
    break
  fi

  # Skip if vision issue already has open architect PR
  if [ "${_arch_vision_issues_with_open_prs[$vision_issue]:-}" = "1" ]; then
    log "Vision issue #${vision_issue} already has open architect PR — skipping"
    continue
  fi

  # Skip if vision issue has in-progress label
  if printf '%s\n' "$in_progress_issues" | grep -q "^${vision_issue}$"; then
    log "Vision issue #${vision_issue} has in-progress label — skipping"
    continue
  fi

  # Skip if vision issue has open sub-issues (already being worked on)
  if has_open_subissues "$vision_issue"; then
    log "Vision issue #${vision_issue} has open sub-issues — skipping"
    continue
  fi

  # Skip if vision issue has merged sprint PR (decomposition already done)
  if has_merged_sprint_pr "$vision_issue"; then
    log "Vision issue #${vision_issue} has merged sprint PR — skipping"
    continue
  fi

  # Add to target issues
  ARCHITECT_TARGET_ISSUES+=("$vision_issue")
  log "Selected vision issue #${vision_issue} for pitching"
done <<< "$vision_issue_nums"

# If no issues selected and no responses processed, signal done
if [ ${#ARCHITECT_TARGET_ISSUES[@]} -eq 0 ]; then
  if [ "$processed_responses" = true ]; then
    log "No new pitches needed — responses already processed"
  else
    log "No vision issues available for pitching (all have open PRs, sub-issues, or merged sprint PRs) — signaling PHASE:done"
  fi
  # Signal PHASE:done by writing to phase file if it exists
  if [ -f "/tmp/architect-${PROJECT_NAME}.phase" ]; then
    echo "PHASE:done" > "/tmp/architect-${PROJECT_NAME}.phase"
  fi
  if [ ${#ARCHITECT_TARGET_ISSUES[@]} -eq 0 ] && [ "$processed_responses" = false ]; then
    exit 0
  fi
  # If responses were processed but no pitches, still clean up and exit
  if [ ${#ARCHITECT_TARGET_ISSUES[@]} -eq 0 ]; then
    rm -f "$SCRATCH_FILE"
    rm -f "${SCRATCH_FILE_PREFIX}"-*.md
    profile_write_journal "architect-run" "Architect run $(date -u +%Y-%m-%d)" "complete" "" || true
    log "--- Architect run done ---"
    exit 0
  fi
fi

log "Selected ${#ARCHITECT_TARGET_ISSUES[@]} vision issue(s) for pitching: ${ARCHITECT_TARGET_ISSUES[*]}"

# ── Pitch prompt: research + PR creation (model handles pitching only) ────
# Architecture Decision: AD-003 — The runtime creates and destroys, the formula preserves.
build_architect_prompt() {
  cat <<_PROMPT_EOF_
You are the architect agent for ${FORGE_REPO}. Work through the formula below.

Your role: strategic decomposition of vision issues into development sprints.
Propose sprints via PRs on the ops repo.

## Target vision issues for pitching
${ARCHITECT_TARGET_ISSUES[*]}

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
}

PROMPT=$(build_architect_prompt)

# ── Create worktree (if not already set up from design phase) ─────────────
if [ ! -d "$WORKTREE" ]; then
  formula_worktree_setup "$WORKTREE"
fi

# ── Run agent for pitching ────────────────────────────────────────────────
export CLAUDE_MODEL="sonnet"
agent_run --worktree "$WORKTREE" "$PROMPT"
log "agent_run complete (pitching)"

# Clean up scratch files (legacy single file + per-issue files)
rm -f "$SCRATCH_FILE"
rm -f "${SCRATCH_FILE_PREFIX}"-*.md

# Write journal entry post-session
profile_write_journal "architect-run" "Architect run $(date -u +%Y-%m-%d)" "complete" "" || true

log "--- Architect run done ---"
