#!/usr/bin/env bash
# =============================================================================
# planner-run.sh — Polling-loop wrapper: planner execution via SDK + formula
#
# Synchronous bash loop using claude -p (one-shot invocation).
# No tmux sessions, no phase files — the bash script IS the state machine.
#
# Flow:
#   1. Guards: run lock, memory check
#   2. Load formula (formulas/run-planner.toml)
#   3. Context: VISION.md, AGENTS.md, ops:RESOURCES.md, structural graph,
#      planner memory, journal entries
#   4. Create ops branch planner/run-YYYY-MM-DD for changes
#   5. agent_run(worktree, prompt) → Claude plans, commits to ops branch
#   6. If ops branch has commits: pr_create → pr_walk_to_merge (review-bot)
#
# Usage:
#   planner-run.sh [projects/disinto.toml]   # project config (default: disinto)
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
FACTORY_ROOT="$(dirname "$SCRIPT_DIR")"

# Accept project config from argument; default to disinto (planner is disinto infrastructure)
export PROJECT_TOML="${1:-$FACTORY_ROOT/projects/disinto.toml}"
# Set override BEFORE sourcing env.sh so it survives any later re-source of
# env.sh from nested shells / claude -p tools (#762, #747)
export FORGE_TOKEN_OVERRIDE="${FORGE_PLANNER_TOKEN:-}"
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
# shellcheck source=../lib/ci-helpers.sh
source "$FACTORY_ROOT/lib/ci-helpers.sh"
# shellcheck source=../lib/pr-lifecycle.sh
source "$FACTORY_ROOT/lib/pr-lifecycle.sh"
# shellcheck source=../lib/tape.sh
source "$FACTORY_ROOT/lib/tape.sh"

LOG_FILE="${DISINTO_LOG_DIR}/planner/planner.log"
# shellcheck disable=SC2034  # consumed by agent-sdk.sh
LOGFILE="$LOG_FILE"
# shellcheck disable=SC2034  # consumed by agent-sdk.sh
SID_FILE="/tmp/planner-session-${PROJECT_NAME}.sid"
SCRATCH_FILE="/tmp/planner-${PROJECT_NAME}-scratch.md"
WORKTREE="/tmp/${PROJECT_NAME}-planner-run"

# Override LOG_AGENT for consistent agent identification
# shellcheck disable=SC2034  # consumed by agent-sdk.sh and env.sh log()
LOG_AGENT="planner"

# Override log() to append to planner-specific log file
# shellcheck disable=SC2034
log() {
  local agent="${LOG_AGENT:-planner}"
  printf '[%s] %s: %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$agent" "$*" >> "$LOG_FILE"
}

# ── Tape: dev-loop proposal records for filed backlog issues (#1409) ──────
#
# The planning session files issues itself (tea/curl inside agent_run), so
# the wrapper learns of them by diffing the open-issue set around the
# session: a snapshot before agent_run, one fetch after, and
# emit_planner_proposal() for each new issue that carries the backlog label.
# Vision/prediction filings get no record — loop="dev" is for the backlog.
# Every helper below is total: any tape or API failure logs a WARNING and
# returns 0, so the planner run is never blocked by the tape.

# planner_open_issues_json — the project's open issues (one page, limit=50 —
# the API's max page size; a backlog deeper than that degrades the diff to
# best effort) as the API's JSON array on stdout. Returns 1 when the forge
# API is unreachable or answers with a non-array.
planner_open_issues_json() {
  local body
  body="$(curl -sf -H "Authorization: token ${FORGE_TOKEN}" \
    "${FORGE_API}/issues?state=open&limit=50" 2>/dev/null)" || return 1
  jq -e 'type == "array"' >/dev/null 2>&1 <<<"$body" || return 1
  printf '%s' "$body"
}

# emit_planner_proposal ISSUE_NUMBER [LABEL]
# Append one {"type":"proposal","loop":"dev",...} record for a backlog issue
# the planner just filed: class = LABEL (the filed primary label) or, when
# empty, the issue's primary label from one forge call, degrading to "dev"
# on API failure (the dev-poll convention); forecast = flat priors
# {"p_success":0.5,"est_cost":0,"est_dvision":0} (calibration comes later);
# ref = the issue number; id = a fresh ULID (formula_tape_ulid). Always
# returns 0 — a tape failure logs a WARNING and the run continues.
emit_planner_proposal() {
  local issue="${1:-}" label="${2:-}"
  local id class primary ctx

  if [ -z "$issue" ]; then
    log "WARNING: tape: no issue number — skipping planner proposal"
    return 0
  fi

  id="$(formula_tape_ulid 2>/dev/null)" || id=""
  [ -n "$id" ] || id="planner-$(date -u +%Y%m%d%H%M%S)-$$-${issue}"

  class="${label:-}"
  if [ -z "$class" ]; then
    class="dev"
    primary="$(curl -sf -H "Authorization: token ${FORGE_TOKEN}" \
      "${FORGE_API}/issues/${issue}" 2>/dev/null | jq -r '.labels[0].name // empty')" || primary=""
    [ -n "$primary" ] && class="$primary"
  fi

  if ! ctx="$(jq -cn --arg organ "planner" '{organ: $organ}')"; then
    log "WARNING: tape: failed to build context for #${issue}"
    return 0
  fi

  if ! tape_proposal "$id" dev "$class" "" "" "$ctx" \
      '{"p_success":0.5,"est_cost":0,"est_dvision":0}' "approved" "$issue" \
      >/dev/null 2>&1; then
    log "WARNING: tape: failed to append proposal record ${id} for #${issue}"
    return 0
  fi

  log "tape: recorded planner proposal ${id} for #${issue} (class: ${class})"
  return 0
}

# planner_tape_tick PRE_NUMBERS_FILE — called after the planning session
# closes: fetch the current open issues once (numbers + labels in one call)
# and, for each issue number missing from the pre-session snapshot, emit one
# dev-loop proposal when it carries the backlog label. An empty or unreadable
# pre-file (the pre-session fetch failed — the caller removed it) skips the
# tick entirely, so a broken forge API can never emit a false-positive
# proposal storm. Always returns 0.
planner_tape_tick() {
  local pre_file="${1:-}" post_file num labels_json has_backlog primary
  [ -n "$pre_file" ] && [ -r "$pre_file" ] || return 0

  post_file="$(mktemp)" || return 0
  if ! planner_open_issues_json > "$post_file"; then
    log "WARNING: tape: post-session issue fetch failed — no planner proposals this run"
    rm -f "$post_file"
    return 0
  fi

  while IFS=$'\t' read -r num labels_json; do
    [ -n "$num" ] || continue
    grep -qx "$num" "$pre_file" 2>/dev/null && continue
    has_backlog="$(jq -r '[.[] | select(.name == "backlog")] | length' \
      <<<"$labels_json" 2>/dev/null)" || has_backlog="0"
    [ "$has_backlog" = "1" ] || continue
    primary="$(jq -r '.[0].name // empty' <<<"$labels_json" 2>/dev/null)" || primary=""
    emit_planner_proposal "$num" "$primary" </dev/null
  done < <(jq -r '.[] | [(.number | tostring), ((.labels // []) | tojson)] | @tsv' \
    "$post_file" 2>/dev/null)

  rm -f "$post_file"
  return 0
}

# ── Guards ────────────────────────────────────────────────────────────────
check_active planner
acquire_run_lock "/tmp/planner-run.lock"
memory_guard 2000

log "--- Planner run start ---"

# ── Precondition checks: skip if nothing to plan ──────────────────────────
LAST_SHA_FILE="$FACTORY_ROOT/state/planner-last-sha"
LAST_OPS_SHA_FILE="$FACTORY_ROOT/state/planner-last-ops-sha"

CURRENT_SHA=$(git -C "$FACTORY_ROOT" rev-parse HEAD 2>/dev/null || echo "")
LAST_SHA=$(cat "$LAST_SHA_FILE" 2>/dev/null || echo "")

# ops repo is required for planner — pull before checking sha
ensure_ops_repo
CURRENT_OPS_SHA=$(git -C "$OPS_REPO_ROOT" rev-parse HEAD 2>/dev/null || echo "")
LAST_OPS_SHA=$(cat "$LAST_OPS_SHA_FILE" 2>/dev/null || echo "")

unreviewed_count=$(curl -sf -H "Authorization: token ${FORGE_TOKEN}" \
  "${FORGE_API}/issues?labels=prediction/unreviewed&state=open&limit=1" 2>/dev/null | jq length) || unreviewed_count=0
vision_open=$(curl -sf -H "Authorization: token ${FORGE_TOKEN}" \
  "${FORGE_API}/issues?labels=vision&state=open&limit=1" 2>/dev/null | jq length) || vision_open=0

if [ "$CURRENT_SHA" = "$LAST_SHA" ] \
   && [ "$CURRENT_OPS_SHA" = "$LAST_OPS_SHA" ] \
   && [ "${unreviewed_count:-0}" -eq 0 ] \
   && [ "${vision_open:-0}" -eq 0 ]; then
  log "no new commits, no ops changes, no unreviewed predictions, no open vision — skipping"
  exit 0
fi

log "sha=${CURRENT_SHA:0:8} ops=${CURRENT_OPS_SHA:0:8} unreviewed=${unreviewed_count} vision=${vision_open}"

# ── Resolve forge remote for git operations ─────────────────────────────
# Run git operations from the project checkout, not the baked code dir
cd "$PROJECT_REPO_ROOT"

resolve_forge_remote

# ── Resolve agent identity for .profile repo ────────────────────────────
resolve_agent_identity || true

# ── Load formula + context ───────────────────────────────────────────────
# #1334: the planner always uses formulas/run-planner.toml. Oak instances
# differ by ops/pack.toml, not by a project kind.
planner_formula_file() {
  echo "$FACTORY_ROOT/formulas/run-planner.toml"
}
PLANNER_FORMULA="$(planner_formula_file)"
log "planner formula: ${PLANNER_FORMULA##*/}"
load_formula_or_profile "planner" "$PLANNER_FORMULA" || exit 1
build_context_block VISION.md AGENTS.md ops:RESOURCES.md ops:prerequisites.md

# ── Build structural analysis graph ──────────────────────────────────────
build_graph_section

# ── Read planner memory ─────────────────────────────────────────────────
MEMORY_BLOCK=""
MEMORY_FILE="$OPS_REPO_ROOT/knowledge/planner-memory.md"
if [ -f "$MEMORY_FILE" ]; then
  MEMORY_BLOCK="
### knowledge/planner-memory.md (persistent memory from prior runs)
$(cat "$MEMORY_FILE")
"
fi

# ── Prepare .profile context (lessons injection) ─────────────────────────
formula_prepare_profile_context

# ── Read scratch file (compaction survival) ───────────────────────────────
SCRATCH_CONTEXT=$(read_scratch_context "$SCRATCH_FILE")
SCRATCH_INSTRUCTION=$(build_scratch_instruction "$SCRATCH_FILE")

# ── Build prompt ─────────────────────────────────────────────────────────
build_sdk_prompt_footer "
  Relabel:     curl -sf -H \"Authorization: token \${FORGE_TOKEN}\" -X PUT -H 'Content-Type: application/json' '${FORGE_API}/issues/{number}/labels' -d '{\"labels\":[LABEL_ID]}'
  Comment:     curl -sf -H \"Authorization: token \${FORGE_TOKEN}\" -X POST -H 'Content-Type: application/json' '${FORGE_API}/issues/{number}/comments' -d '{\"body\":\"...\"}'
  Close:       curl -sf -H \"Authorization: token \${FORGE_TOKEN}\" -X PATCH -H 'Content-Type: application/json' '${FORGE_API}/issues/{number}' -d '{\"state\":\"closed\"}'
"

PROMPT="You are the strategic planner for ${FORGE_REPO}. Work through the formula below.

## Project context
${CONTEXT_BLOCK}${MEMORY_BLOCK}$(formula_lessons_block)
${GRAPH_SECTION}
${SCRATCH_CONTEXT:+${SCRATCH_CONTEXT}
}
## Formula
${FORMULA_CONTENT}

${SCRATCH_INSTRUCTION}

${PROMPT_FOOTER}"

# ── Create worktree ──────────────────────────────────────────────────────
formula_worktree_setup "$WORKTREE"

# ── Prepare ops branch for PR-based merge (#765) ────────────────────────
PLANNER_OPS_BRANCH="planner/run-$(date -u +%Y-%m-%d)"
(
  cd "$OPS_REPO_ROOT"
  git fetch origin "${PRIMARY_BRANCH}" --quiet 2>/dev/null || true
  git checkout "${PRIMARY_BRANCH}" --quiet 2>/dev/null || true
  git pull --ff-only origin "${PRIMARY_BRANCH}" --quiet 2>/dev/null || true
  # Create (or reset to) a fresh branch from PRIMARY_BRANCH
  git checkout -B "$PLANNER_OPS_BRANCH" "origin/${PRIMARY_BRANCH}" --quiet 2>/dev/null || \
    git checkout -b "$PLANNER_OPS_BRANCH" --quiet 2>/dev/null || true
)
log "ops branch: ${PLANNER_OPS_BRANCH}"

# ── Run agent ─────────────────────────────────────────────────────────────
export CLAUDE_MODEL="opus"

# ── Tape: pre-session snapshot for the filed-issue diff (#1409) ────────────
# Open-issue numbers, one per line. A failed fetch removes the file and
# empties the variable — planner_tape_tick then skips, so a broken forge
# API can never emit a false-positive proposal storm.
PLANNER_PRE_ISSUES="$(mktemp)"
if ! planner_open_issues_json | jq -r '.[].number' > "$PLANNER_PRE_ISSUES" 2>/dev/null; then
  log "WARNING: tape: pre-session issue fetch failed — no planner proposals this run"
  rm -f "$PLANNER_PRE_ISSUES"
  PLANNER_PRE_ISSUES=""
fi

# Open the proposal-loop tape run record (#1391) — total, never fails us
formula_session_start "planner"

# Guarded: a resource-limit exit (rc 124 = wall-clock timeout) must not abort
# the script under set -e — record the rc and let the PR walk decide (#1164).
PLANNER_RUN_RC=0
agent_run --worktree "$WORKTREE" "$PROMPT" || PLANNER_RUN_RC=$?
[ "$PLANNER_RUN_RC" -eq 0 ] || log "planner agent_run exited ${PLANNER_RUN_RC} (124 = wall-clock timeout) — continuing"
log "agent_run complete"

# Close the tape run: outcome + closing run record (#1391)
formula_session_end "$PLANNER_RUN_RC"

# ── Tape: emit dev-loop proposals for the issues filed this run (#1409) ──
# Total — a tape/API failure can never abort the planner run.
planner_tape_tick "$PLANNER_PRE_ISSUES"
if [ -n "$PLANNER_PRE_ISSUES" ]; then
  rm -f "$PLANNER_PRE_ISSUES"
fi

# ── PR lifecycle: create PR on ops repo and walk to merge (#765) ─────────
OPS_FORGE_API="${FORGE_API_BASE}/repos/${FORGE_OPS_REPO}"
ops_has_commits=false
if ! git -C "$OPS_REPO_ROOT" diff --quiet "origin/${PRIMARY_BRANCH}..${PLANNER_OPS_BRANCH}" 2>/dev/null; then
  ops_has_commits=true
fi

if [ "$ops_has_commits" = "true" ]; then
  log "ops branch has commits — creating PR"
  # Push the branch to the ops remote
  git -C "$OPS_REPO_ROOT" push origin "$PLANNER_OPS_BRANCH" --quiet 2>/dev/null || \
    git -C "$OPS_REPO_ROOT" push --force-with-lease origin "$PLANNER_OPS_BRANCH" 2>/dev/null

  # Temporarily point FORGE_API at the ops repo for pr-lifecycle functions
  ORIG_FORGE_API="$FORGE_API"
  export FORGE_API="$OPS_FORGE_API"
  # Ops repo typically has no Woodpecker CI — skip CI polling
  ORIG_WOODPECKER_REPO_ID="${WOODPECKER_REPO_ID:-2}"
  export WOODPECKER_REPO_ID="0"

  PR_NUM=$(pr_create "$PLANNER_OPS_BRANCH" \
    "chore: planner run $(date -u +%Y-%m-%d)" \
    "Automated planner run — updates prerequisite tree, memory, and vault items." \
    "${PRIMARY_BRANCH}" \
    "$OPS_FORGE_API") || true

  if [ -n "$PR_NUM" ]; then
    log "ops PR #${PR_NUM} created — walking to merge"
    SESSION_ID=$(cat "$SID_FILE" 2>/dev/null || echo "planner-$$")
    pr_walk_to_merge "$PR_NUM" "$SESSION_ID" "$OPS_REPO_ROOT" 1 2 || {
      log "ops PR #${PR_NUM} walk finished: ${_PR_WALK_EXIT_REASON:-unknown}"
    }
    log "ops PR #${PR_NUM} result: ${_PR_WALK_EXIT_REASON:-unknown}"
  else
    log "WARNING: failed to create ops PR for branch ${PLANNER_OPS_BRANCH}"
  fi

  # Restore original FORGE_API
  export FORGE_API="$ORIG_FORGE_API"
  export WOODPECKER_REPO_ID="$ORIG_WOODPECKER_REPO_ID"
else
  log "no ops changes — skipping PR creation"
fi

# Persist watermarks so next run can skip if nothing changed
mkdir -p "$FACTORY_ROOT/state"
echo "$CURRENT_SHA" > "$LAST_SHA_FILE"
echo "$CURRENT_OPS_SHA" > "$LAST_OPS_SHA_FILE"

# Write journal entry post-session
profile_write_journal "planner-run" "Planner run $(date -u +%Y-%m-%d)" "complete" "" || true

rm -f "$SCRATCH_FILE"
log "--- Planner run done ---"
