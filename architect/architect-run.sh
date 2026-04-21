#!/usr/bin/env bash
# =============================================================================
# architect-run.sh — Polling-loop wrapper: architect execution via SDK + formula
#
# Synchronous bash loop using claude -p (one-shot invocation).
# No tmux sessions, no phase files — the bash script IS the state machine.
#
# Flow:
#   1. Guards: run lock, memory check
#   2. Precondition checks: skip if no work (no vision issues, no responses)
#   3. Load formula (formulas/run-architect.toml)
#   4. Context: VISION.md, AGENTS.md, ops:prerequisites.md, structural graph
#   5. Stateless pitch generation: for each selected issue:
#      - Fetch issue body from Forgejo API (bash)
#      - Invoke claude -p with issue body + context (stateless, no API calls)
#      - Create PR with pitch content (bash)
#      - Post footer comment (bash)
#   6. Response processing: handle ACCEPT/REJECT on existing PRs
#
# Precondition checks (bash before model):
#   - Skip if no vision issues AND no open architect PRs
#   - Skip if 3+ architect PRs open AND no ACCEPT/REJECT responses to process
#   - Only invoke model when there's actual work: new pitches or response processing
#
# Usage:
#   architect-run.sh [projects/disinto.toml]   # project config (default: disinto)
#
# Called by: entrypoint.sh polling loop (every 6 hours)
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
FACTORY_ROOT="$(dirname "$SCRIPT_DIR")"

# Accept project config from argument; default to disinto
export PROJECT_TOML="${1:-$FACTORY_ROOT/projects/disinto.toml}"
# Set override BEFORE sourcing env.sh so it survives any later re-source of
# env.sh from nested shells / claude -p tools (#762, #747)
export FORGE_TOKEN_OVERRIDE="${FORGE_ARCHITECT_TOKEN:-}"
# shellcheck source=../lib/env.sh
source "$FACTORY_ROOT/lib/env.sh"
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
# shellcheck disable=SC2034  # consumed by agent-sdk.sh and env.sh
LOG_AGENT="architect"

# Override log() to append to architect-specific log file
# shellcheck disable=SC2034
log() {
  local agent="${LOG_AGENT:-architect}"
  printf '[%s] %s: %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$agent" "$*" >> "$LOG_FILE"
}

# ── Guards ────────────────────────────────────────────────────────────────
check_active architect
acquire_run_lock "/tmp/architect-run.lock"
memory_guard 2000

log "--- Architect run start ---"

# ── Resolve forge remote for git operations ─────────────────────────────
# Run git operations from the project checkout, not the baked code dir
cd "$PROJECT_REPO_ROOT"

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

# ── Build prompt ─────────────────────────────────────────────────────────
build_sdk_prompt_footer

# Architect prompt: strategic decomposition of vision into sprints
# See: architect/AGENTS.md for full role description
# Pattern: heredoc function to avoid inline prompt construction
# Note: Uses CONTEXT_BLOCK, GRAPH_SECTION, SCRATCH_CONTEXT from formula-session.sh
# Architecture Decision: AD-003 — The runtime creates and destroys, the formula preserves.
build_architect_prompt() {
  cat <<_PROMPT_EOF_
You are the architect agent for ${FORGE_REPO}. Work through the formula below.

Your role: strategic decomposition of vision issues into development sprints.
Propose sprints via PRs on the ops repo, converse with humans through PR comments.
You are READ-ONLY on the project repo — sub-issues are filed by filer-bot after sprint PR merge (#764).
DO NOT create issues, PRs, or any other resource on the project repo. Any sub-issue
specification must go only into the filer:begin/filer:end block of the sprint pitch.
If you think sub-issues should be filed, write them into the sprint file's filer:begin
block only. You do not have permission to POST to the project repo and any such call
will return 403 and fail this run.

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

# ── Build prompt for specific session mode ───────────────────────────────
# Args: session_mode (pitch / questions_phase / start_questions)
# Returns: prompt text via stdout
build_architect_prompt_for_mode() {
  local session_mode="$1"

  case "$session_mode" in
    "start_questions")
      cat <<_PROMPT_EOF_
You are the architect agent for ${FORGE_REPO}. Work through the formula below.

Your role: strategic decomposition of vision issues into development sprints.
Propose sprints via PRs on the ops repo, converse with humans through PR comments.
You are READ-ONLY on the project repo — sub-issues are filed by filer-bot after sprint PR merge (#764).
DO NOT create issues, PRs, or any other resource on the project repo. Any sub-issue
specification must go only into the filer:begin/filer:end block of the sprint pitch.
If you think sub-issues should be filed, write them into the sprint file's filer:begin
block only. You do not have permission to POST to the project repo and any such call
will return 403 and fail this run.

## CURRENT STATE: Approved PR awaiting initial design questions

A sprint pitch PR has been approved by the human (via APPROVED review), but the
design conversation has not yet started. Your task is to:

1. Read the approved sprint pitch from the PR body
2. Identify the key design decisions that need human input
3. Post initial design questions (Q1:, Q2:, etc.) as comments on the PR
4. Add a `## Design forks` section to the PR body documenting the design decisions
5. Update the ## Sub-issues section in the sprint spec if design decisions affect decomposition

This is NOT a pitch phase — the pitch is already approved. This is the START
of the design Q&A phase. Sub-issues are filed by filer-bot after sprint PR merge (#764).

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
      ;;
    "questions_phase")
      cat <<_PROMPT_EOF_
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

A sprint pitch PR is in the questions phase:
- The PR has a `## Design forks` section
- Initial questions (Q1:, Q2:, etc.) have been posted
- Humans may have posted answers or follow-up questions

Your task is to:
1. Read the existing questions and the PR body
2. Read human answers from PR comments
3. Parse the answers and determine next steps
4. Post follow-up questions if needed (Q3:, Q4:, etc.)
5. If all design forks are resolved, finalize the ## Sub-issues section in the sprint spec
6. Update the `## Design forks` section as you progress

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
      ;;
    "pitch"|*)
      # Default: pitch new sprints (original behavior)
      build_architect_prompt
      ;;
  esac
}

# ── Create worktree ──────────────────────────────────────────────────────
formula_worktree_setup "$WORKTREE"

# ── Detect if PR is in questions-awaiting-answers phase ──────────────────
# A PR is in the questions phase if it has a `## Design forks` section and
# question comments. We check this to decide whether to resume the session
# from the research/questions run (preserves codebase context for answer parsing).
detect_questions_phase() {
  local pr_number=""
  local pr_body=""

  # Get open architect PRs on ops repo
  local ops_repo="${OPS_REPO_ROOT:-/home/agent/data/ops}"
  if [ ! -d "${ops_repo}/.git" ]; then
    return 1
  fi

  # Use Forgejo API to find open architect PRs
  local response
  response=$(curl -sf -H "Authorization: token ${FORGE_TOKEN}" \
    "${FORGE_API_BASE}/repos/${FORGE_OPS_REPO}/pulls?state=open" 2>/dev/null) || return 1

  # Check each open PR for architect markers
  pr_number=$(printf '%s' "$response" | jq -r '.[] | select(.title | contains("architect:")) | .number' 2>/dev/null | head -1) || return 1

  if [ -z "$pr_number" ]; then
    return 1
  fi

  # Fetch PR body
  pr_body=$(curl -sf -H "Authorization: token ${FORGE_TOKEN}" \
    "${FORGE_API_BASE}/repos/${FORGE_OPS_REPO}/pulls/${pr_number}" 2>/dev/null | jq -r '.body // empty') || return 1

  # Check for `## Design forks` section (added by #101 after ACCEPT)
  if ! printf '%s' "$pr_body" | grep -q "## Design forks"; then
    return 1
  fi

  # Check for question comments (Q1:, Q2:, etc.)
  # Use jq to extract body text before grepping (handles JSON escaping properly)
  local comments
  comments=$(curl -sf -H "Authorization: token ${FORGE_TOKEN}" \
    "${FORGE_API_BASE}/repos/${FORGE_OPS_REPO}/issues/${pr_number}/comments" 2>/dev/null) || return 1

  if ! printf '%s' "$comments" | jq -r '.[].body // empty' | grep -qE 'Q[0-9]+:'; then
    return 1
  fi

  # PR is in questions phase
  log "Detected PR #${pr_number} in questions-awaiting-answers phase"
  return 0
}

# ── Detect if PR is approved and awaiting initial design questions ────────
# A PR is in this state when:
# - It's an open architect PR on ops repo
# - It has an APPROVED review (from human acceptance)
# - It has NO `## Design forks` section yet
# - It has NO Q1:, Q2:, etc. comments yet
# This means the human accepted the pitch and we need to start the design
# conversation by posting initial questions and adding the Design forks section.
detect_approved_pending_questions() {
  local pr_number=""
  local pr_body=""

  # Get open architect PRs on ops repo
  local ops_repo="${OPS_REPO_ROOT:-/home/agent/data/ops}"
  if [ ! -d "${ops_repo}/.git" ]; then
    return 1
  fi

  # Use Forgejo API to find open architect PRs
  local response
  response=$(curl -sf -H "Authorization: token ${FORGE_TOKEN}" \
    "${FORGE_API_BASE}/repos/${FORGE_OPS_REPO}/pulls?state=open" 2>/dev/null) || return 1

  # Check each open PR for architect markers
  pr_number=$(printf '%s' "$response" | jq -r '.[] | select(.title | contains("architect:")) | .number' 2>/dev/null | head -1) || return 1

  if [ -z "$pr_number" ]; then
    return 1
  fi

  # Fetch PR body
  pr_body=$(curl -sf -H "Authorization: token ${FORGE_TOKEN}" \
    "${FORGE_API_BASE}/repos/${FORGE_OPS_REPO}/pulls/${pr_number}" 2>/dev/null | jq -r '.body // empty') || return 1

  # Check for APPROVED review
  local reviews
  reviews=$(curl -sf -H "Authorization: token ${FORGE_TOKEN}" \
    "${FORGE_API_BASE}/repos/${FORGE_OPS_REPO}/pulls/${pr_number}/reviews" 2>/dev/null) || return 1

  if ! printf '%s' "$reviews" | jq -e '.[] | select(.state == "APPROVED")' >/dev/null 2>&1; then
    return 1
  fi

  # Check that PR does NOT have `## Design forks` section yet
  # (we're in the "start questions" phase, not "process answers" phase)
  if printf '%s' "$pr_body" | grep -q "## Design forks"; then
    # Has design forks section — this is either in questions phase or past it
    return 1
  fi

  # Check that PR has NO question comments yet (Q1:, Q2:, etc.)
  local comments
  comments=$(curl -sf -H "Authorization: token ${FORGE_TOKEN}" \
    "${FORGE_API_BASE}/repos/${FORGE_OPS_REPO}/issues/${pr_number}/comments" 2>/dev/null) || return 1

  if printf '%s' "$comments" | jq -r '.[].body // empty' | grep -qE 'Q[0-9]+:'; then
    # Has question comments — this is either in questions phase or past it
    return 1
  fi

  # PR is approved and awaiting initial design questions
  log "Detected PR #${pr_number} approved and awaiting initial design questions"
  return 0
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
    [.[] | select(.number != ($vid | tonumber)) | select(.body // "" | contains("Decomposed from #" + $vid))] | length
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
    "${FORGE_API_BASE}/repos/${FORGE_OPS_REPO}/pulls?state=closed&limit=100" 2>/dev/null) || return 1

  # Check each closed PR for architect markers and vision issue reference
  local pr_numbers
  pr_numbers=$(printf '%s' "$prs_json" | jq -r '.[] | select(.title | contains("architect:")) | .number' 2>/dev/null) || return 1

  local pr_num
  while IFS= read -r pr_num; do
    [ -z "$pr_num" ] && continue

    # Get PR details including merged status
    local pr_details
    pr_details=$(curl -sf -H "Authorization: token ${FORGE_TOKEN}" \
      "${FORGE_API_BASE}/repos/${FORGE_OPS_REPO}/pulls/${pr_num}" 2>/dev/null) || continue

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

# ── Helper: Fetch all open vision issues from Forgejo API ─────────────────
# Returns: JSON array of vision issue objects
fetch_vision_issues() {
  curl -sf -H "Authorization: token ${FORGE_TOKEN}" \
    "${FORGE_API}/issues?labels=vision&state=open&limit=100" 2>/dev/null || echo '[]'
}

# NOTE: get_vision_subissues, all_subissues_closed, close_vision_issue,
# check_and_close_completed_visions removed (#764) — architect-bot is read-only
# on the project repo. Vision lifecycle (closing completed visions, adding
# in-progress labels) is now handled by filer-bot via lib/sprint-filer.sh.

# ── Helper: Fetch open architect PRs from ops repo Forgejo API ───────────
# Returns: JSON array of architect PR objects
fetch_open_architect_prs() {
  curl -sf -H "Authorization: token ${FORGE_TOKEN}" \
    "${FORGE_API_BASE}/repos/${FORGE_OPS_REPO}/pulls?state=open&limit=100" 2>/dev/null || echo '[]'
}

# ── Helper: Get vision issue body by number ──────────────────────────────
# Args: issue_number
# Returns: issue body text
get_vision_issue_body() {
  local issue_num="$1"
  curl -sf -H "Authorization: token ${FORGE_TOKEN}" \
    "${FORGE_API}/issues/${issue_num}" 2>/dev/null | jq -r '.body // ""'
}

# ── Helper: Get vision issue title by number ─────────────────────────────
# Args: issue_number
# Returns: issue title
get_vision_issue_title() {
  local issue_num="$1"
  curl -sf -H "Authorization: token ${FORGE_TOKEN}" \
    "${FORGE_API}/issues/${issue_num}" 2>/dev/null | jq -r '.title // ""'
}

# ── Helper: Create a sprint pitch via stateless claude -p call ───────────
# The model NEVER calls Forgejo API. It only reads context and generates pitch.
# Args: vision_issue_number vision_issue_title vision_issue_body
# Returns: pitch markdown to stdout
#
# This is a stateless invocation: the model has no memory between calls.
# All state management (which issues to pitch, dedup logic, etc.) happens in bash.
generate_pitch() {
  local issue_num="$1"
  local issue_title="$2"
  local issue_body="$3"

  # Build context block with vision issue details
  local pitch_context
  pitch_context="
## Vision Issue #${issue_num}
### Title
${issue_title}

### Description
${issue_body}

## Project Context
${CONTEXT_BLOCK}
${GRAPH_SECTION}
$(formula_lessons_block)
## Formula
${FORMULA_CONTENT}

${SCRATCH_INSTRUCTION}
${PROMPT_FOOTER}
"

  # Prompt: model generates pitch markdown only, no API calls
  local pitch_prompt="You are the architect agent for ${FORGE_REPO}. Write a sprint pitch for the vision issue above.

Instructions:
1. Output ONLY the pitch markdown (no explanations, no preamble, no postscript)
2. Use this exact format:

# Sprint: <sprint-name>

## Vision issues
- #${issue_num} — ${issue_title}

## What this enables
<what the project can do after this sprint that it can't do now>

## What exists today
<current state — infrastructure, interfaces, code that can be reused>

## Complexity
<number of files/subsystems, estimated sub-issues>
<gluecode vs greenfield ratio>

## Risks
<what could go wrong, what breaks if this is done badly>

## Cost — new infra to maintain
<what ongoing maintenance burden does this sprint add>
<new services, scheduled tasks, formulas, agent roles>

## Recommendation
<architect's assessment: worth it / defer / alternative approach>

## Sub-issues

<!-- filer:begin -->
- id: <kebab-case-id>
  title: \"vision(#${issue_num}): <concise sub-issue title>\"
  labels: [backlog]
  depends_on: []
  body: |
    ## Goal
    <what this sub-issue accomplishes>
    ## Acceptance criteria
    - [ ] <criterion>
<!-- filer:end -->

IMPORTANT: Do NOT include design forks or questions. This is a go/no-go pitch.
The ## Sub-issues block is parsed by the filer-bot pipeline after sprint PR merge.
Each sub-issue between filer:begin/end markers becomes a Forgejo issue.

CRITICAL: You are READ-ONLY on the project repo. DO NOT create issues, PRs, or
POST to any /repos/${FORGE_REPO}/... endpoint. Sub-issues belong only inside the
filer:begin/filer:end block above. Any direct API call to the project repo will
return 403 and abort this run.

---

${pitch_context}
"

  # Execute stateless claude -p call
  agent_run "$pitch_prompt" 2>>"$LOGFILE" || true

  # Extract pitch content from JSON response
  local pitch
  pitch=$(printf '%s' "$_AGENT_LAST_OUTPUT" | jq -r '.result // empty' 2>/dev/null) || pitch=""

  if [ -z "$pitch" ]; then
    log "WARNING: empty pitch generated for vision issue #${issue_num}"
    return 1
  fi

  # Output pitch to stdout for caller to use
  printf '%s' "$pitch"
}

# ── Helper: Create PR on ops repo via Forgejo API ────────────────────────
# Args: sprint_title sprint_body branch_name
# Returns: PR number on success, empty on failure
create_sprint_pr() {
  local sprint_title="$1"
  local sprint_body="$2"
  local branch_name="$3"

  # Create branch on ops repo
  if ! curl -sf -X POST \
    -H "Authorization: token ${FORGE_TOKEN}" \
    -H "Content-Type: application/json" \
    "${FORGE_API_BASE}/repos/${FORGE_OPS_REPO}/branches" \
    -d "{\"new_branch_name\": \"${branch_name}\", \"old_branch_name\": \"${PRIMARY_BRANCH:-main}\"}" >/dev/null 2>&1; then
    log "WARNING: failed to create branch ${branch_name}"
    return 1
  fi

  # Extract sprint name from title for filename
  local sprint_name
  sprint_name=$(printf '%s' "$sprint_title" | sed 's/^architect: *//; s/ *$//')
  local sprint_slug
  sprint_slug=$(printf '%s' "$sprint_name" | tr '[:upper:]' '[:lower:]' | tr ' ' '-' | sed 's/--*/-/g')

  # Prepare sprint spec content
  local sprint_spec="# Sprint: ${sprint_name}

${sprint_body}
"
  # Base64 encode the content
  local sprint_spec_b64
  sprint_spec_b64=$(printf '%s' "$sprint_spec" | base64 -w 0)

  # Write sprint spec file to branch
  if ! curl -sf -X PUT \
    -H "Authorization: token ${FORGE_TOKEN}" \
    -H "Content-Type: application/json" \
    "${FORGE_API_BASE}/repos/${FORGE_OPS_REPO}/contents/sprints/${sprint_slug}.md" \
    -d "{\"message\": \"sprint: add ${sprint_slug}.md\", \"content\": \"${sprint_spec_b64}\", \"branch\": \"${branch_name}\"}" >/dev/null 2>&1; then
    log "WARNING: failed to write sprint spec file"
    return 1
  fi

  # Create PR - use jq to build JSON payload safely (prevents injection from markdown)
  local pr_payload
  pr_payload=$(jq -n \
    --arg title "$sprint_title" \
    --arg body "$sprint_body" \
    --arg head "$branch_name" \
    --arg base "${PRIMARY_BRANCH:-main}" \
    '{title: $title, body: $body, head: $head, base: $base}')

  local pr_response
  pr_response=$(curl -sf -X POST \
    -H "Authorization: token ${FORGE_TOKEN}" \
    -H "Content-Type: application/json" \
    "${FORGE_API_BASE}/repos/${FORGE_OPS_REPO}/pulls" \
    -d "$pr_payload" 2>/dev/null) || return 1

  # Extract PR number
  local pr_number
  pr_number=$(printf '%s' "$pr_response" | jq -r '.number // empty')

  log "Created sprint PR #${pr_number}: ${sprint_title}"
  printf '%s' "$pr_number"
}

# ── Helper: Post footer comment on PR ────────────────────────────────────
# Args: pr_number
post_pr_footer() {
  local pr_number="$1"
  local footer="Reply \`ACCEPT\` to proceed with design questions, or \`REJECT: <reason>\` to decline."

  if curl -sf -X POST \
    -H "Authorization: token ${FORGE_TOKEN}" \
    -H "Content-Type: application/json" \
    "${FORGE_API_BASE}/repos/${FORGE_OPS_REPO}/issues/${pr_number}/comments" \
    -d "{\"body\": \"${footer}\"}" >/dev/null 2>&1; then
    log "Posted footer comment on PR #${pr_number}"
    return 0
  else
    log "WARNING: failed to post footer comment on PR #${pr_number}"
    return 1
  fi
}

# NOTE: add_inprogress_label removed (#764) — architect-bot is read-only on
# project repo. in-progress label is now added by filer-bot via sprint-filer.sh.

# ── Precondition checks in bash before invoking the model ─────────────────

# Check 1: Skip if no vision issues exist and no open architect PRs to handle
vision_count=$(curl -sf -H "Authorization: token $FORGE_TOKEN" \
  "$FORGE_API/issues?labels=vision&state=open&limit=1" 2>/dev/null | jq length) || vision_count=0
if [ "${vision_count:-0}" -eq 0 ]; then
  # Check for open architect PRs that need handling (ACCEPT/REJECT responses)
  open_arch_prs=$(curl -sf -H "Authorization: token $FORGE_TOKEN" \
    "${FORGE_API_BASE}/repos/${FORGE_OPS_REPO}/pulls?state=open&limit=10" 2>/dev/null | jq '[.[] | select(.title | startswith("architect:"))] | length') || open_arch_prs=0
  if [ "${open_arch_prs:-0}" -eq 0 ]; then
    log "no vision issues and no open architect PRs — skipping"
    exit 0
  fi
fi

# Check 2: Scan for ACCEPT/REJECT responses on open architect PRs (unconditional)
# This ensures responses are processed regardless of open_arch_prs count
has_responses_to_process=false
pr_numbers=$(curl -sf -H "Authorization: token $FORGE_TOKEN" \
  "${FORGE_API_BASE}/repos/${FORGE_OPS_REPO}/pulls?state=open&limit=100" 2>/dev/null | jq -r '.[] | select(.title | startswith("architect:")) | .number') || pr_numbers=""
for pr_num in $pr_numbers; do
  # Check formal reviews first (Forgejo green check via review API)
  reviews=$(curl -sf -H "Authorization: token $FORGE_TOKEN" \
    "${FORGE_API_BASE}/repos/${FORGE_OPS_REPO}/pulls/${pr_num}/reviews" 2>/dev/null) || reviews="[]"
  if printf '%s' "$reviews" | jq -e '.[] | select(.state == "APPROVED" or .state == "REQUEST_CHANGES")' >/dev/null 2>&1; then
    has_responses_to_process=true
    break
  fi
  # Then check ACCEPT/REJECT in comments (legacy / human-typed)
  comments=$(curl -sf -H "Authorization: token $FORGE_TOKEN" \
    "${FORGE_API_BASE}/repos/${FORGE_OPS_REPO}/issues/${pr_num}/comments" 2>/dev/null) || continue
  if printf '%s' "$comments" | jq -r '.[].body // empty' | grep -qE '(ACCEPT|REJECT):'; then
    has_responses_to_process=true
    break
  fi
done

# Check 2 (continued): Skip if already at max open pitches (3), unless there are responses to process
open_arch_prs=$(curl -sf -H "Authorization: token $FORGE_TOKEN" \
  "${FORGE_API_BASE}/repos/${FORGE_OPS_REPO}/pulls?state=open&limit=100" 2>/dev/null | jq '[.[] | select(.title | startswith("architect:"))] | length') || open_arch_prs=0
if [ "${open_arch_prs:-0}" -ge 3 ]; then
  if [ "$has_responses_to_process" = false ]; then
    log "already 3 open architect PRs with no responses to process — skipping"
    exit 0
  fi
  log "3 open architect PRs found but responses detected — processing"
fi

# NOTE: Vision lifecycle check (close completed visions) moved to filer-bot (#764)

# ── Bash-driven state management: Select vision issues for pitching ───────
# This logic is also documented in formulas/run-architect.toml preflight step

# Fetch all data from Forgejo API upfront (bash handles state, not model)
vision_issues_json=$(fetch_vision_issues)
open_arch_prs_json=$(fetch_open_architect_prs)

# Build list of vision issues that already have open architect PRs
declare -A _arch_vision_issues_with_open_prs
while IFS= read -r pr_num; do
  [ -z "$pr_num" ] && continue
  pr_body=$(curl -sf -H "Authorization: token $FORGE_TOKEN" \
    "${FORGE_API_BASE}/repos/${FORGE_OPS_REPO}/pulls/${pr_num}" 2>/dev/null | jq -r '.body // ""') || continue
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

# If no issues selected, decide whether to exit or process responses
if [ ${#ARCHITECT_TARGET_ISSUES[@]} -eq 0 ]; then
  if [ "${has_responses_to_process:-false}" = "true" ]; then
    log "No new pitches needed — responses to process"
    # Fall through to response processing block below
  else
    log "No vision issues available for pitching (all have open PRs, sub-issues, or merged sprint PRs) — signaling PHASE:done"
    # Signal PHASE:done by writing to phase file if it exists
    if [ -f "/tmp/architect-${PROJECT_NAME}.phase" ]; then
      echo "PHASE:done" > "/tmp/architect-${PROJECT_NAME}.phase"
    fi
    exit 0
  fi
fi

log "Selected ${#ARCHITECT_TARGET_ISSUES[@]} vision issue(s) for pitching: ${ARCHITECT_TARGET_ISSUES[*]}"

# ── Stateless pitch generation and PR creation (bash-driven, no model API calls) ──
# For each target issue:
#   1. Fetch issue body from Forgejo API (bash)
#   2. Invoke claude -p with issue body + context (stateless, no API calls)
#   3. Create PR with pitch content (bash)
#   4. Post footer comment (bash)

pitch_count=0
for vision_issue in "${ARCHITECT_TARGET_ISSUES[@]}"; do
  log "Processing vision issue #${vision_issue}"

  # Fetch vision issue details from Forgejo API (bash, not model)
  issue_title=$(get_vision_issue_title "$vision_issue")
  issue_body=$(get_vision_issue_body "$vision_issue")

  if [ -z "$issue_title" ] || [ -z "$issue_body" ]; then
    log "WARNING: failed to fetch vision issue #${vision_issue} details"
    continue
  fi

  # Generate pitch via stateless claude -p call (model has no API access)
  log "Generating pitch for vision issue #${vision_issue}"
  pitch=$(generate_pitch "$vision_issue" "$issue_title" "$issue_body") || true

  if [ -z "$pitch" ]; then
    log "WARNING: failed to generate pitch for vision issue #${vision_issue}"
    continue
  fi

  # Create sprint PR (bash, not model)
  # Use issue number in branch name to avoid collisions across runs
  branch_name="architect/sprint-vision-${vision_issue}"
  pr_number=$(create_sprint_pr "architect: ${issue_title}" "$pitch" "$branch_name")

  if [ -z "$pr_number" ]; then
    log "WARNING: failed to create PR for vision issue #${vision_issue}"
    continue
  fi

  # Post footer comment
  post_pr_footer "$pr_number"

  # NOTE: in-progress label is added by filer-bot after sprint PR merge (#764)

  pitch_count=$((pitch_count + 1))
  log "Completed pitch for vision issue #${vision_issue} — PR #${pr_number}"
done

log "Generated ${pitch_count} sprint pitch(es)"

# ── Run agent for response processing if needed ───────────────────────────
# Always process ACCEPT/REJECT responses when present, regardless of new pitches
if [ "${has_responses_to_process:-false}" = "true" ]; then
  log "Processing ACCEPT/REJECT responses on existing PRs"

  # Check if any PRs have responses that need agent handling
  needs_agent=false
  pr_numbers=$(curl -sf -H "Authorization: token $FORGE_TOKEN" \
    "${FORGE_API_BASE}/repos/${FORGE_OPS_REPO}/pulls?state=open&limit=100" 2>/dev/null | jq -r '.[] | select(.title | startswith("architect:")) | .number') || pr_numbers=""

  for pr_num in $pr_numbers; do
    # Check for ACCEPT/REJECT in comments
    comments=$(curl -sf -H "Authorization: token $FORGE_TOKEN" \
      "${FORGE_API_BASE}/repos/${FORGE_OPS_REPO}/issues/${pr_num}/comments" 2>/dev/null) || continue

    # Check for review decisions (higher precedence)
    reviews=$(curl -sf -H "Authorization: token $FORGE_TOKEN" \
      "${FORGE_API_BASE}/repos/${FORGE_OPS_REPO}/pulls/${pr_num}/reviews" 2>/dev/null) || reviews=""

    # Check for ACCEPT (APPROVED review or ACCEPT comment)
    if printf '%s' "$reviews" | jq -e '.[] | select(.state == "APPROVED")' >/dev/null 2>&1; then
      log "PR #${pr_num} has APPROVED review — needs agent handling"
      needs_agent=true
    elif printf '%s' "$comments" | jq -r '.[].body // empty' | grep -qiE '^[^:]+: *ACCEPT'; then
      log "PR #${pr_num} has ACCEPT comment — needs agent handling"
      needs_agent=true
    elif printf '%s' "$comments" | jq -r '.[].body // empty' | grep -qiE '^[^:]+: *REJECT:'; then
      log "PR #${pr_num} has REJECT comment — needs agent handling"
      needs_agent=true
    fi
  done

  # Run agent only if there are responses to process
  if [ "$needs_agent" = "true" ]; then
    # Determine session handling based on PR state
    RESUME_ARGS=()
    SESSION_MODE="fresh"

    if detect_questions_phase; then
      # PR is in questions-awaiting-answers phase — resume from that session
      if [ -f "$SID_FILE" ]; then
        RESUME_SESSION=$(cat "$SID_FILE")
        RESUME_ARGS=(--resume "$RESUME_SESSION")
        SESSION_MODE="questions_phase"
        log "PR in questions-awaiting-answers phase — resuming session: ${RESUME_SESSION:0:12}..."
      else
        log "PR in questions phase but no session file — starting fresh session"
      fi
    elif detect_approved_pending_questions; then
      # PR is approved but awaiting initial design questions — start fresh with special prompt
      SESSION_MODE="start_questions"
      log "PR approved and awaiting initial design questions — starting fresh session"
    else
      log "PR not in questions phase — starting fresh session"
    fi

    # Build prompt with appropriate mode
    PROMPT_FOR_MODE=$(build_architect_prompt_for_mode "$SESSION_MODE")

    agent_run "${RESUME_ARGS[@]}" --worktree "$WORKTREE" "$PROMPT_FOR_MODE"
    log "agent_run complete"
  fi
fi

# ── Regression guard: detect direct issue creation by architect session ──
# Scans the architect log for any POST to the project repo's /issues endpoint.
# This is a cheap guard — if the model used its Bash tool to curl POST /issues
# on the project repo, it would appear in the log. Fails loudly on detection.
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

# Run regression guard before cleanup
check_architect_issue_filing

# ── Clean up scratch files (legacy single file + per-issue files) ──────────
rm -f "$SCRATCH_FILE"
rm -f "${SCRATCH_FILE_PREFIX}"-*.md

# Write journal entry post-session
profile_write_journal "architect-run" "Architect run $(date -u +%Y-%m-%d)" "complete" "" || true

log "--- Architect run done ---"
