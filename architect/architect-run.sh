#!/usr/bin/env bash
# =============================================================================
# architect-run.sh — Polling-loop wrapper: architect execution via SDK + formula
#
# Synchronous bash loop using claude -p (one-shot invocation).
# No tmux sessions, no phase files — the bash script IS the state machine.
#
# Flow:
#   1. Guards: run lock, memory check
#   2. Precondition checks: skip if no responses to process on open architect PRs
#   3. Load formula (formulas/run-architect.toml)
#   4. Context: VISION.md, AGENTS.md, ops:prerequisites.md, structural graph
#   5. Response processing: handle ACCEPT/REJECT/APPROVED on existing
#      architect PRs (start design Q&A, continue Q&A, or general response)
#
# Vision pitching is owned by the gardener (formulas/pitch-vision.toml — see
# #871, #877, #897). The architect now only handles the response/Q&A phase
# on existing architect PRs.
#
# Precondition checks (bash before model):
#   - Skip if no open architect PRs and no vision issues
#   - Only invoke model when there's actual response work to process
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
# FORGE_TOKEN was overridden to FORGE_ARCHITECT_TOKEN above (line 39) before
# env.sh sourcing, so forge_whoami() resolves the architect bot's login.
if [ -z "${AGENT_IDENTITY:-}" ] && [ -n "${FORGE_ARCHITECT_TOKEN:-}" ]; then
  AGENT_IDENTITY=$(forge_whoami)
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

# ── Build prompt for specific session mode ───────────────────────────────
# Args: session_mode (fresh / questions_phase / start_questions)
# Returns: prompt text via stdout
# Note: Uses CONTEXT_BLOCK, GRAPH_SECTION, SCRATCH_CONTEXT from formula-session.sh
# Architecture Decision: AD-003 — The runtime creates and destroys, the formula preserves.
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
    "fresh"|*)
      # Default: generic response-phase prompt (ACCEPT/REJECT handling on
      # existing architect PRs). New-pitch generation has moved to the
      # gardener (formulas/pitch-vision.toml) — see #871, #877, #897.
      cat <<_PROMPT_EOF_
You are the architect agent for ${FORGE_REPO}. Work through the formula below.

Your role: strategic decomposition of vision issues into development sprints.
Converse with humans through PR comments on existing architect PRs on the ops repo.
You are READ-ONLY on the project repo — sub-issues are filed by filer-bot after sprint PR merge (#764).
DO NOT create issues, PRs, or any other resource on the project repo. Any sub-issue
specification must go only into the filer:begin/filer:end block of the sprint pitch.
If you think sub-issues should be filed, write them into the sprint file's filer:begin
block only. You do not have permission to POST to the project repo and any such call
will return 403 and fail this run.

## CURRENT STATE: Response phase on an existing architect PR

An open architect PR has received a response (ACCEPT / REJECT / APPROVED review,
or a typed ACCEPT/REJECT comment). Read the PR body and comments, then handle
the response: process REJECT reasons, acknowledge ACCEPTs, and continue any
in-flight design conversation as appropriate.

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

# NOTE: generate_pitch(), create_sprint_pr(), post_pr_footer(), and the
# vision-issue read helpers (has_open_subissues, has_merged_sprint_pr,
# fetch_vision_issues, get_vision_issue_body, get_vision_issue_title) removed
# (#897, PR #900 review). Vision pitching moved to the gardener
# (formulas/pitch-vision.toml — see #871, #877), which now owns vision
# fetching, dedup, and footer posting. The previous in-process pitch path was
# also silently broken: claude_run_with_watchdog runs `claude` under a
# `script -qfc` PTY (workaround for #575) which appends terminal mode-restore
# escape codes to the JSON output, causing the `jq -r '.result'` extraction
# to fail under `set -euo pipefail`.

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
# NOTE: Vision-issue selection logic and the per-issue pitch loop removed (#897).
# Vision pitching is now owned by the gardener (formulas/pitch-vision.toml —
# see #871, #877).

# If there are no responses to process, exit cleanly.
if [ "${has_responses_to_process:-false}" != "true" ]; then
  log "No ACCEPT/REJECT/APPROVED responses on open architect PRs — signaling PHASE:done"
  if [ -f "/tmp/architect-${PROJECT_NAME}.phase" ]; then
    echo "PHASE:done" > "/tmp/architect-${PROJECT_NAME}.phase"
  fi
  exit 0
fi

# ── Run agent for response processing ─────────────────────────────────────
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
