#!/usr/bin/env bash
# =============================================================================
# exec-briefing.sh — Daily morning briefing via the executive assistant
#
# Cron wrapper: spawns a one-shot Claude session that gathers factory state
# and posts a morning briefing to Matrix. Unlike the interactive session,
# this runs, posts, and exits.
#
# Usage:
#   exec-briefing.sh [projects/disinto.toml]
#
# Cron:
#   0 7 * * *  /path/to/disinto/exec/exec-briefing.sh
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
FACTORY_ROOT="$(dirname "$SCRIPT_DIR")"

export PROJECT_TOML="${1:-$FACTORY_ROOT/projects/disinto.toml}"
# shellcheck source=../lib/env.sh
source "$FACTORY_ROOT/lib/env.sh"
# shellcheck source=../lib/agent-session.sh
source "$FACTORY_ROOT/lib/agent-session.sh"
# shellcheck source=../lib/formula-session.sh
source "$FACTORY_ROOT/lib/formula-session.sh"
# shellcheck source=../lib/guard.sh
source "$FACTORY_ROOT/lib/guard.sh"

LOG_FILE="$SCRIPT_DIR/exec.log"
# shellcheck disable=SC2034  # consumed by run_formula_and_monitor
SESSION_NAME="exec-briefing-${PROJECT_NAME}"
PHASE_FILE="/tmp/exec-briefing-${PROJECT_NAME}.phase"
# shellcheck disable=SC2034
PHASE_POLL_INTERVAL=10

log() { echo "[$(date -u +%Y-%m-%dT%H:%M:%S)Z] $*" >> "$LOG_FILE"; }

# ── Guards ────────────────────────────────────────────────────────────────
check_active exec
acquire_cron_lock "/tmp/exec-briefing.lock"
check_memory 2000

log "--- Exec briefing start ---"

# ── Load compass (required) ────────────────────────────────────────────
COMPASS_FILE="${EXEC_COMPASS:-${HOME}/.disinto/compass.md}"
if [ ! -f "$COMPASS_FILE" ]; then
  log "FATAL: compass not found at ${COMPASS_FILE} — exec agent refuses to start without its compass"
  exit 1
fi
COMPASS_BLOCK=$(cat "$COMPASS_FILE")

# ── Load character (voice/relationships from repo) ────────────────────
CHARACTER_FILE="${EXEC_CHARACTER:-$SCRIPT_DIR/CHARACTER.md}"
CHARACTER_BLOCK=""
if [ -f "$CHARACTER_FILE" ]; then
  CHARACTER_BLOCK=$(cat "$CHARACTER_FILE")
fi

# Merge: compass first, then character
CHARACTER_BLOCK="${COMPASS_BLOCK}

${CHARACTER_BLOCK}"

# ── Load memory ─────────────────────────────────────────────────────────
MEMORY_BLOCK="(no previous memory)"
MEMORY_FILE="$PROJECT_REPO_ROOT/exec/MEMORY.md"
if [ -f "$MEMORY_FILE" ]; then
  MEMORY_BLOCK=$(cat "$MEMORY_FILE")
fi

# ── Gather factory state ───────────────────────────────────────────────
# Open issues count
OPEN_ISSUES=$(curl -sf -H "Authorization: token ${FORGE_TOKEN}" \
  "${FORGE_API}/issues?state=open&type=issues&limit=1" 2>/dev/null \
  | jq 'length' 2>/dev/null || echo "?")

# Open PRs
OPEN_PRS=$(curl -sf -H "Authorization: token ${FORGE_TOKEN}" \
  "${FORGE_API}/pulls?state=open&limit=1" 2>/dev/null \
  | jq 'length' 2>/dev/null || echo "?")

# Pending vault items
VAULT_PENDING=$(ls "$FACTORY_ROOT/vault/pending/" 2>/dev/null | wc -l || echo 0)

# Recent agent activity (last 24h log lines)
RECENT_ACTIVITY=""
for agent_dir in supervisor planner predictor gardener dev review; do
  latest_log="$FACTORY_ROOT/${agent_dir}/${agent_dir}.log"
  if [ -f "$latest_log" ]; then
    lines=$(grep "$(date -u +%Y-%m-%d)" "$latest_log" 2>/dev/null | tail -5 || true)
    if [ -n "$lines" ]; then
      RECENT_ACTIVITY="${RECENT_ACTIVITY}
### ${agent_dir} (today)
${lines}
"
    fi
  fi
done

# ── Build briefing prompt ──────────────────────────────────────────────
# shellcheck disable=SC2034  # consumed by run_formula_and_monitor
PROMPT="You are the executive assistant for ${FORGE_REPO}. This is a morning briefing run.

## Your character
${CHARACTER_BLOCK}

## Your memory
${MEMORY_BLOCK}

## Current factory state
- Open issues: ${OPEN_ISSUES}
- Open PRs: ${OPEN_PRS}
- Pending vault items: ${VAULT_PENDING}

${RECENT_ACTIVITY}

## Task

Produce a morning briefing for the executive. Be concise — 10-15 lines max.
Cover:
1. What happened overnight (merges, CI failures, agent activity)
2. What needs attention today (blocked issues, vault items, stale work)
3. One observation or recommendation

Fetch additional data if needed:
- Open issues: curl -sf -H \"Authorization: token \${FORGE_TOKEN}\" '${FORGE_API}/issues?state=open&type=issues&limit=20'
- Recent closed: curl -sf -H \"Authorization: token \${FORGE_TOKEN}\" '${FORGE_API}/issues?state=closed&type=issues&limit=10&sort=updated&direction=desc'
- Prerequisite tree: cat ${PROJECT_REPO_ROOT}/planner/prerequisite-tree.md

Write your briefing between markers:
\`\`\`
---EXEC-RESPONSE-START---
Your briefing here.
---EXEC-RESPONSE-END---
\`\`\`

Then log the briefing to: ${PROJECT_REPO_ROOT}/exec/journal/\$(date -u +%Y-%m-%d).md
(append, don't overwrite — there may be interactive sessions later today)

Then: echo 'PHASE:done' > '${PHASE_FILE}'

## Environment
FACTORY_ROOT=${FACTORY_ROOT}
PROJECT_REPO_ROOT=${PROJECT_REPO_ROOT}
PHASE_FILE=${PHASE_FILE}"

# ── Run session ──────────────────────────────────────────────────────────
export CLAUDE_MODEL="${CLAUDE_MODEL:-sonnet}"
run_formula_and_monitor "exec-briefing" 600

log "--- Exec briefing done ---"
