#!/usr/bin/env bash
# =============================================================================
# gardener/gardener-step.sh — Pull-one-task driver for the gardener
#
# Per-iteration script: does exactly one task per invocation. Same loop shape
# as dev/dev-poll.sh — invoked once per polling iteration.
#
# Replaces the monolithic gardener/gardener-run.sh (one-shot batch every
# GARDENER_INTERVAL) with a focused step driver:
#   1. gardener/classify.sh → emits one JSON task on stdout (or empty for CLEAN)
#   2. CLEAN → exit 0 immediately (~1s, no slot used)
#   3. Otherwise dispatch to formulas/<task>.toml in a single claude session
#      via lib/formula-session.sh (load_formula_or_profile)
#   4. lib/gardener-edit.sh helpers are sourced and exported for direct API
#      edits from within the claude session's bash tool
#
# Usage:
#   gardener/gardener-step.sh [projects/disinto.toml]
#
# Concurrency: /tmp/gardener-step.lock acquired via flock -n. If another step
# is already in flight, exits silently (no work, no log).
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
FACTORY_ROOT="$(dirname "$SCRIPT_DIR")"

# Accept project config from argument; default to disinto
export PROJECT_TOML="${1:-$FACTORY_ROOT/projects/disinto.toml}"
# Set override BEFORE sourcing env.sh so it survives any later re-source of
# env.sh from nested shells / claude -p tools (#762, #747)
export FORGE_TOKEN_OVERRIDE="${FORGE_GARDENER_TOKEN:-}"
# shellcheck source=../lib/env.sh
source "$FACTORY_ROOT/lib/env.sh"
# shellcheck source=../lib/formula-session.sh
source "$FACTORY_ROOT/lib/formula-session.sh"
# shellcheck source=../lib/worktree.sh
source "$FACTORY_ROOT/lib/worktree.sh"
# shellcheck source=../lib/agent-sdk.sh
source "$FACTORY_ROOT/lib/agent-sdk.sh"
# shellcheck source=../lib/guard.sh
source "$FACTORY_ROOT/lib/guard.sh"
# shellcheck source=../lib/gardener-edit.sh
source "$FACTORY_ROOT/lib/gardener-edit.sh"
# shellcheck source=../lib/pr-lifecycle.sh
source "$FACTORY_ROOT/lib/pr-lifecycle.sh"
# shellcheck source=../lib/mirrors.sh
source "$FACTORY_ROOT/lib/mirrors.sh"

LOG_FILE="${DISINTO_LOG_DIR}/gardener/step.log"
# Tighten log perms (#910): sub-session JSONL transcripts may contain
# tool_result stdout that echoes loaded env (FORGE_*_TOKEN, etc.) — a
# default umask of 022 produces world-readable 644 logs on the host
# volume. umask 077 ensures both the dir and any log file we create
# below are 700/600 = agent-only readable. Stream-level redaction in
# lib/agent-sdk.sh is the second line of defense; this is the first.
umask 077
mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null || true
chmod 700 "$(dirname "$LOG_FILE")" 2>/dev/null || true
if [ -e "$LOG_FILE" ]; then
  chmod 600 "$LOG_FILE" 2>/dev/null || true
fi
# shellcheck disable=SC2034  # consumed by agent-sdk.sh
LOGFILE="$LOG_FILE"
# shellcheck disable=SC2034  # consumed by agent-sdk.sh and env.sh log()
LOG_AGENT="gardener-step"

# Override log() so output lands in step.log specifically (not gardener.log).
log() {
  printf '[%s] %s: %s\n' \
    "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "${LOG_AGENT}" "$*" >> "$LOG_FILE"
}

# ── Run lock: flock -n; exit silently if another step is in flight ────────
LOCK_FILE="/tmp/gardener-step.lock"
exec 9>"$LOCK_FILE"
if ! flock -n 9; then
  exit 0
fi

# ── Scratch dir + worktree paths ──────────────────────────────────────────
SCRATCH_DIR="$(mktemp -d /tmp/gardener-step-XXXXXX)"
# shellcheck disable=SC2034  # consumed by agent-sdk.sh agent_run
SID_FILE="${SCRATCH_DIR}/session.sid"
WORKTREE="${SCRATCH_DIR}/worktree"

# ── PR number scratch file (formula writes PR_NUMBER here) ────────────────
GARDENER_PR_FILE="${SCRATCH_DIR}/pr-number.txt"
: > "$GARDENER_PR_FILE"

# ── Cleanup trap: scratch dir, worktree, and the flock fd ─────────────────
_step_cleanup() {
  worktree_cleanup "$WORKTREE" 2>/dev/null || true
  rm -rf "$SCRATCH_DIR"
  # Closing fd 9 releases the flock.
  exec 9>&-
}
trap _step_cleanup EXIT

log "--- gardener step start ---"

# ── Guards ────────────────────────────────────────────────────────────────
check_active gardener
memory_guard 2000

# ── Classify: emit one task or CLEAN ──────────────────────────────────────
TASK_JSON=""
TASK_JSON=$(bash "$SCRIPT_DIR/classify.sh" "$PROJECT_TOML" 2>>"$LOG_FILE") || {
  log "classify.sh failed (exit non-zero)"
  exit 1
}

if [ -z "$TASK_JSON" ]; then
  log "gardener: nothing to do"
  exit 0
fi

# Parse task field
TASK=$(printf '%s' "$TASK_JSON" | jq -r '.task // empty' 2>/dev/null) || TASK=""
if [ -z "$TASK" ]; then
  log "ERROR: classify output missing .task field: ${TASK_JSON}"
  exit 1
fi

FORMULA_FILE="$FACTORY_ROOT/formulas/${TASK}.toml"
if [ ! -f "$FORMULA_FILE" ]; then
  log "ERROR: formula not found for task '${TASK}': ${FORMULA_FILE}"
  exit 1
fi

log "task=${TASK} payload=${TASK_JSON}"

# ── Resolve agent identity for .profile repo (lessons-learned + journal) ──
resolve_agent_identity || true

# ── Load formula (.profile first, fallback to formulas/<task>.toml) ───────
load_formula_or_profile "$TASK" "$FORMULA_FILE" || exit 1

# ── Build context block ───────────────────────────────────────────────────
build_context_block AGENTS.md gardener/AGENTS.md

# Inject lessons from .profile if available (sets PROFILE_LESSONS_BLOCK).
formula_prepare_profile_context

# ── Build prompt footer (forge API ref + environment) ────────────────────
build_sdk_prompt_footer ""

# ── Export gardener-edit helpers so the claude bash tool can call them ────
# `export -f` ships the function definitions through BASH_FUNC_*; the bash
# subshells claude spawns for tool calls will inherit them. Direct edits are
# auto-journaled to ${DISINTO_LOG_DIR}/gardener/journal.jsonl by the helpers.
export -f gardener_edit_body
export -f gardener_add_label
export -f gardener_remove_label
export -f gardener_post_comment
# Private helpers needed by the public ones (functions don't auto-export).
export -f _ge_log_dir
export -f _ge_log
export -f _ge_journal
export -f _ge_curl
export -f _ge_split
export -f _ge_is_2xx
export -f _ge_label_id
export -f _ge_issue_has_label
export FORGE_GARDENER_TOKEN FORGE_TOKEN FORGE_API DISINTO_LOG_DIR

# ── Build prompt ──────────────────────────────────────────────────────────
PROMPT="You are the gardener executing one focused task: ${TASK}.

You have full shell access and --dangerously-skip-permissions.
This is ONE task per session — work the formula below to completion and stop.
Do NOT pick up additional grooming work or open issues outside the task scope.

## Project context
${CONTEXT_BLOCK}$(formula_lessons_block)

## Classification payload (from gardener/classify.sh)
\`\`\`json
${TASK_JSON}
\`\`\`

## Direct-edit primitives (pre-loaded bash functions)
The following helpers are exported into your bash environment. Use them for
any repo edits — each call applies via the Forgejo API immediately and is
auto-journaled to \${DISINTO_LOG_DIR}/gardener/journal.jsonl. Bodies are read
from a file (not an arg) to avoid shell-quoting hell on multi-line / markdown
content.
  gardener_edit_body    <issue_num> <body_file>
  gardener_add_label    <issue_num> <label_name>     # idempotent
  gardener_remove_label <issue_num> <label_name>     # idempotent
  gardener_post_comment <issue_num> <body_file>

A scratch worktree is available at: ${WORKTREE}
(Use it only if the formula requires committing/pushing files.)

## Formula
${FORMULA_CONTENT}

${PROMPT_FOOTER}"

# ── Worktree (in case the formula needs to commit/push) ──────────────────
# Set up the scratch worktree inline rather than via formula_worktree_setup
# so we keep our single EXIT trap (formula_worktree_setup overrides it).
cd "$PROJECT_REPO_ROOT"
if [ -z "${FORGE_REMOTE:-}" ]; then
  resolve_forge_remote
fi
git fetch "${FORGE_REMOTE}" "$PRIMARY_BRANCH" 2>/dev/null || true
worktree_cleanup "$WORKTREE" 2>/dev/null || true
git worktree add "$WORKTREE" "${FORGE_REMOTE}/${PRIMARY_BRANCH}" --detach 2>/dev/null || {
  log "WARNING: worktree add failed — formula must avoid git ops"
}

# ── Run agent (single claude session — no orchestration here) ─────────────
export CLAUDE_MODEL="${CLAUDE_MODEL:-sonnet}"
agent_run --worktree "$WORKTREE" "$PROMPT"
log "agent_run complete"

# ── Detect PR opened by the formula ───────────────────────────────────────
PR_NUMBER=""
if [ -f "$GARDENER_PR_FILE" ]; then
  PR_NUMBER=$(tr -d '[:space:]' < "$GARDENER_PR_FILE")
fi

# Fallback: search for open agents-md PRs on this branch prefix
if [ -z "$PR_NUMBER" ]; then
  PR_NUMBER=$(curl -sf -H "Authorization: token ${FORGE_TOKEN}" \
    "${FORGE_API}/pulls?state=open&limit=10" | \
    jq -r '[.[] | select(.head.ref | startswith("chore/agents-md-"))] | .[0].number // empty') || true
fi

# ── Walk PR to merge ──────────────────────────────────────────────────────
if [ -n "$PR_NUMBER" ]; then
  log "walking PR #${PR_NUMBER} to merge"
  rc=0
  pr_walk_to_merge "$PR_NUMBER" "$_AGENT_SESSION_ID" "$WORKTREE" 3 5 || rc=$?
  if [ "$rc" -eq 0 ]; then
    log "PR #${PR_NUMBER} merged"
    git -C "$PROJECT_REPO_ROOT" fetch "${FORGE_REMOTE}" "$PRIMARY_BRANCH" 2>/dev/null || true
    git -C "$PROJECT_REPO_ROOT" checkout "$PRIMARY_BRANCH" 2>/dev/null || true
    git -C "$PROJECT_REPO_ROOT" pull --ff-only "${FORGE_REMOTE}" "$PRIMARY_BRANCH" 2>/dev/null || true
    mirror_push
  else
    log "PR #${PR_NUMBER} not merged (reason: ${_PR_WALK_EXIT_REASON:-unknown})"
  fi
else
  log "no PR created — gardener step complete"
fi

# ── Journal entry post-session ────────────────────────────────────────────
profile_write_journal "gardener-step" \
  "Gardener step: ${TASK}" "complete" "" || true

log "--- gardener step done (task=${TASK}) ---"
