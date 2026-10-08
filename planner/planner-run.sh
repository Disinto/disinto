#!/usr/bin/env bash
# =============================================================================
# planner-run.sh — Polling-loop wrapper: open the ladder pitch, or one session
#
# A missing capability rung is a pitch opened in bash (planner_pitch_or_idle).
# Otherwise one agent_run. No tmux sessions, no phase files — the bash script
# IS the state machine. The model is the job's; this script does not set one.
#
# Flow:
#   1. Guards: run lock, memory check
#   2. Load formula (formulas/run-planner.toml)
#   3. Context: VISION.md, AGENTS.md, ops:RESOURCES.md, ops:catalog/claims.md,
#      journal entries
#   4. planner_pitch_or_idle: open the ladder pitch, hold, or stay idle
#   5. On session only: agent_run, then planner_publish_session_pitch
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
# shellcheck source=../lib/tape.sh
source "$FACTORY_ROOT/lib/tape.sh"
# shellcheck source=pitch-or-idle.sh
source "$SCRIPT_DIR/pitch-or-idle.sh"

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

# ── Tape: dev-loop proposal records (pick-owned; #1476) ─────────────────────
#
# The planning session does not file issues (#1977). It writes at most one
# pitch file. The dev-loop proposal for a backlog issue is written by the
# *pick* (dev-poll claims the issue and appends its own "approved" proposal)
# — the pick is the sample. #1409's planner-side emission pre-approved work
# the factory had not yet run (a second approved row); #1476 removes that
# emission. The planner run's tape lifecycle (run open/close via
# formula_session_start/end) is unchanged and still comes from lib/tape.sh.

# planner_tape_tick — called after the planning session closes (#1476).
#
# The planner no longer appends a dev-loop proposal for a backlog issue:
# the pick (dev-poll) writes the "approved" proposal when it claims the
# issue (the pick is the sample). The session does not file issues. A second
# planner-side "approved" record
# pre-approved work the factory had not run — the very duplicate #1476 removes
# (it would also have re-fired #1462's counts forecast on that extra row).
# The open-issue diff that fed this emission is gone with it, so the tick is an
# intentional no-op stub. It is kept as the guarded call site after the session
# closes: the acceptance test (tests/acceptance/issue-1476.sh) extracts it and
# runs it against a stubbed tape_proposal, asserting nothing is emitted. The
# pre-file argument is accepted for signature compatibility with the caller and
# ignored. Always returns 0 — the planner run never fails on the tape.
planner_tape_tick() {
  return 0
}

# ── Guards ────────────────────────────────────────────────────────────────
check_active planner
acquire_run_lock "/tmp/planner-run.lock"
memory_guard 2000

log "--- Planner run start ---"

# ops repo is required for the claims catalog and the session context.
# An open prediction/unreviewed issue does not start or stop the run.
ensure_ops_repo

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
build_context_block VISION.md AGENTS.md ops:RESOURCES.md ops:catalog/claims.md

# ── Build structural analysis graph ──────────────────────────────────────
build_graph_section
log "planner prompt includes the claims catalog"

# ── Prepare .profile context (lessons injection) ─────────────────────────
formula_prepare_profile_context

# ── Read scratch file (compaction survival) ───────────────────────────────
SCRATCH_CONTEXT=$(read_scratch_context "$SCRATCH_FILE")
SCRATCH_INSTRUCTION=$(build_scratch_instruction "$SCRATCH_FILE")

# ── Build prompt ─────────────────────────────────────────────────────────
build_sdk_prompt_footer

PROMPT="You are the strategic planner for ${FORGE_REPO}. Work through the formula below.

## Project context
${CONTEXT_BLOCK}$(formula_lessons_block)
${GRAPH_SECTION}
${SCRATCH_CONTEXT:+${SCRATCH_CONTEXT}
}
## Formula
${FORMULA_CONTENT}

${SCRATCH_INSTRUCTION}

${PROMPT_FOOTER}"

# ── Ladder pitch, or one session ─────────────────────────────────────────
# held / opened: the pitch is already open, or this run just opened it.
# The session does not run. session: no rung is missing, so the agent may
# write one pitch file, which planner_publish_session_pitch then opens.
PITCH_RC=0
PITCH_LINE="$(planner_pitch_or_idle)" || PITCH_RC=$?
if [ "$PITCH_RC" -ne 0 ]; then
  log "planner_pitch_or_idle failed"
  exit 1
fi
log "planner_pitch_or_idle: ${PITCH_LINE}"

PUBLISH_RC=0
case "$PITCH_LINE" in
  session)
    PROMPT="${PROMPT}
ladder: none"
    formula_worktree_setup "$WORKTREE"
    formula_session_start "planner"
    # Same defaults planner_publish_session_pitch reads. Export them so a
    # shell write to $PLANNER_PITCH_FILE / $PLANNER_PROBE_FILE hits that path.
    # Clear both before the session: a long-lived container must not republish
    # a previous run's pitch, or attach a leftover probe to a new effect.
    export PLANNER_PITCH_FILE="${PLANNER_PITCH_FILE:-/tmp/planner-pitch.md}"
    export PLANNER_PROBE_FILE="${PLANNER_PROBE_FILE:-/tmp/planner-probe.sh}"
    rm -f "$PLANNER_PITCH_FILE" "$PLANNER_PROBE_FILE"
    # Guarded: a resource-limit exit (rc 124 = wall-clock timeout) must not
    # abort the script under set -e — record the rc and still publish (#1164).
    PLANNER_RUN_RC=0
    agent_run --worktree "$WORKTREE" "$PROMPT" || PLANNER_RUN_RC=$?
    [ "$PLANNER_RUN_RC" -eq 0 ] || log "planner agent_run exited ${PLANNER_RUN_RC} (124 = wall-clock timeout) — continuing"
    log "agent_run complete"
    formula_session_end "$PLANNER_RUN_RC"
    planner_publish_session_pitch || PUBLISH_RC=$?
    if [ "$PUBLISH_RC" -eq 0 ]; then
      rm -f "$PLANNER_PITCH_FILE" "$PLANNER_PROBE_FILE"
    fi
    ;;
  held|opened\ *)
    ;;
  *)
    log "planner_pitch_or_idle printed unexpected output"
    exit 1
    ;;
esac

# ── Tape: no-op stub call site (#1476) ─────────────────────────────────────
# The planner no longer appends a dev-loop proposal (the pick owns the
# record; the session does not file issues). planner_tape_tick is the intentional
# no-op stub kept as the guarded call site that the acceptance test verifies;
# it never fails the run (rc 0, no tape write). A held or opened run has no
# session; the tick is still a no-op.
planner_tape_tick

if [ "$PUBLISH_RC" -ne 0 ]; then
  log "planner_publish_session_pitch failed"
  exit 1
fi

# Write journal entry post-session
profile_write_journal "planner-run" "Planner run $(date -u +%Y-%m-%d)" "complete" "" || true

rm -f "$SCRATCH_FILE"
log "--- Planner run done ---"
