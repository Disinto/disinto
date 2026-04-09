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
SCRATCH_CONTEXT=$(build_scratch_context)
GRAPH_SECTION=$(build_graph_section)
GUIDANCE_BLOCK=$(build_guidance_block)
FORMULA_CONTENT=$(build_formula_content)
PROMPT_FOOTER=$(build_prompt_footer)
SCRATCH_INSTRUCTION=$(build_scratch_instruction)

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

#   5. Stateless pitch generation: for each selected issue:
#      - Fetch issue body from Forgejo API (bash)
#      - Invoke claude -p with issue body + context (stateless, no API calls)
#      - Create PR with pitch content (bash)
#      - Post footer comment (bash)
#   6. Response processing: handle ACCEPT/REJECT on existing PRs

# Clean up scratch files (legacy single file + per-issue files)
rm -f "$SCRATCH_FILE"
rm -f "${SCRATCH_FILE_PREFIX}"-*.md

# Write journal entry post-session
profile_write_journal "architect-run" "Architect run $(date -u +%Y-%m-%d)" "complete" "" || true

log "--- Architect run done ---"
