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
#   5. agent_run(worktree, prompt) → Claude decomposes vision into sprints
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
Propose sprints via PRs on the ops repo, converse with humans through PR comments,
and file sub-issues after design forks are resolved.

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
    "${FORGE_API}/repos/${FORGE_OPS_REPO}/pulls?state=open" 2>/dev/null) || return 1

  # Check each open PR for architect markers
  pr_number=$(printf '%s' "$response" | jq -r '.[] | select(.title | contains("architect:")) | .number' 2>/dev/null | head -1) || return 1

  if [ -z "$pr_number" ]; then
    return 1
  fi

  # Fetch PR body
  pr_body=$(curl -sf -H "Authorization: token ${FORGE_TOKEN}" \
    "${FORGE_API}/repos/${FORGE_OPS_REPO}/pulls/${pr_number}" 2>/dev/null | jq -r '.body // empty') || return 1

  # Check for `## Design forks` section (added by #101 after ACCEPT)
  if ! printf '%s' "$pr_body" | grep -q "## Design forks"; then
    return 1
  fi

  # Check for question comments (Q1:, Q2:, etc.)
  # Use jq to extract body text before grepping (handles JSON escaping properly)
  local comments
  comments=$(curl -sf -H "Authorization: token ${FORGE_TOKEN}" \
    "${FORGE_API}/repos/${FORGE_OPS_REPO}/issues/${pr_number}/comments" 2>/dev/null) || return 1

  if ! printf '%s' "$comments" | jq -r '.[].body // empty' | grep -qE 'Q[0-9]+:'; then
    return 1
  fi

  # PR is in questions phase
  log "Detected PR #${pr_number} in questions-awaiting-answers phase"
  return 0
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

# Check 2: Skip if already at max open pitches (3), unless there are responses to process
open_arch_prs=$(curl -sf -H "Authorization: token $FORGE_TOKEN" \
  "${FORGE_API}/repos/${FORGE_OPS_REPO}/pulls?state=open&limit=10" 2>/dev/null | jq '[.[] | select(.title | startswith("architect:"))] | length') || open_arch_prs=0
if [ "${open_arch_prs:-0}" -ge 3 ]; then
  # Check if any open architect PRs have ACCEPT/REJECT responses that need processing
  has_responses=false
  pr_numbers=$(curl -sf -H "Authorization: token $FORGE_TOKEN" \
    "${FORGE_API}/repos/${FORGE_OPS_REPO}/pulls?state=open&limit=10" 2>/dev/null | jq -r '.[] | select(.title | startswith("architect:")) | .number') || pr_numbers=""
  for pr_num in $pr_numbers; do
    comments=$(curl -sf -H "Authorization: token $FORGE_TOKEN" \
      "${FORGE_API}/repos/${FORGE_OPS_REPO}/issues/${pr_num}/comments" 2>/dev/null) || continue
    if printf '%s' "$comments" | jq -r '.[].body // empty' | grep -qE '(ACCEPT|REJECT):'; then
      has_responses=true
      break
    fi
  done
  if [ "$has_responses" = false ]; then
    log "already 3 open architect PRs with no responses to process — skipping"
    exit 0
  fi
  log "3 open architect PRs found but responses detected — processing"
fi

# ── Run agent ─────────────────────────────────────────────────────────────
export CLAUDE_MODEL="sonnet"

# Determine whether to resume session:
# - If answers detected (PR in questions phase), resume prior session to preserve
#   codebase context from research/questions run
# - Otherwise, start fresh (new pitch or PR not in questions phase)
RESUME_ARGS=()
if detect_questions_phase && [ -f "$SID_FILE" ]; then
  RESUME_SESSION=$(cat "$SID_FILE")
  RESUME_ARGS=(--resume "$RESUME_SESSION")
  log "Resuming session from questions phase run: ${RESUME_SESSION:0:12}..."
elif ! detect_questions_phase; then
  log "PR not in questions phase — starting fresh session"
elif [ ! -f "$SID_FILE" ]; then
  log "No session ID found for questions phase — starting fresh session"
fi

agent_run "${RESUME_ARGS[@]}" --worktree "$WORKTREE" "$PROMPT"
log "agent_run complete"

# Clean up scratch files (legacy single file + per-issue files)
rm -f "$SCRATCH_FILE"
rm -f "${SCRATCH_FILE_PREFIX}"-*.md

# Write journal entry post-session
profile_write_journal "architect-run" "Architect run $(date -u +%Y-%m-%d)" "complete" "" || true

log "--- Architect run done ---"
