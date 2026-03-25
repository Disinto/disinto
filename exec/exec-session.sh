#!/usr/bin/env bash
# =============================================================================
# exec-session.sh — Spawn or reattach the executive assistant Claude session
#
# Unlike cron-driven agents, the exec session is on-demand:
#   1. Matrix listener receives a message tagged [exec]
#   2. If no tmux session exists → this script spawns one
#   3. Message is injected into the session
#   4. Claude's response is captured and posted back to Matrix
#
# Can also be invoked directly for interactive use:
#   exec-session.sh [projects/disinto.toml]
#
# The session stays alive for EXEC_SESSION_TTL (default: 1h) of idle time.
# On exit, Claude updates MEMORY.md and the session is logged to journal.
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
FACTORY_ROOT="$(dirname "$SCRIPT_DIR")"

# Accept project config from argument; default to disinto
export PROJECT_TOML="${1:-$FACTORY_ROOT/projects/disinto.toml}"
# shellcheck source=../lib/env.sh
source "$FACTORY_ROOT/lib/env.sh"
# shellcheck source=../lib/agent-session.sh
source "$FACTORY_ROOT/lib/agent-session.sh"

LOG_FILE="$SCRIPT_DIR/exec.log"
SESSION_NAME="exec-${PROJECT_NAME}"
PHASE_FILE="/tmp/exec-session-${PROJECT_NAME}.phase"
EXEC_SESSION_TTL="${EXEC_SESSION_TTL:-3600}"

log() { echo "[$(date -u +%Y-%m-%dT%H:%M:%S)Z] $*" >> "$LOG_FILE"; }

# ── Check if session already exists ──────────────────────────────────────
if tmux has-session -t "$SESSION_NAME" 2>/dev/null; then
  log "session already active: ${SESSION_NAME}"
  echo "ACTIVE"
  exit 0
fi

# ── Memory check (skip if low) ──────────────────────────────────────────
AVAIL_MB=$(free -m 2>/dev/null | awk '/Mem:/{print $7}' || echo 9999)
if [ "${AVAIL_MB:-0}" -lt 2000 ]; then
  log "skipping — only ${AVAIL_MB}MB available (need 2000)"
  exit 1
fi

log "--- Exec session start ---"

# ── Load compass (required — lives outside the repo) ──────────────────
# The compass is the agent's core identity. It cannot live in code because
# code can be changed by the factory. The compass cannot.
COMPASS_FILE="${EXEC_COMPASS:-}"
if [ -z "$COMPASS_FILE" ] || [ ! -f "$COMPASS_FILE" ]; then
  log "FATAL: EXEC_COMPASS not set or file not found (${COMPASS_FILE:-unset})"
  log "The exec agent refuses to start without its compass."
  log "Set EXEC_COMPASS=/path/to/compass.md in .env or .env.enc"
  matrix_send "exec" "❌ Exec agent cannot start: compass file missing (EXEC_COMPASS not configured)" 2>/dev/null || true
  exit 1
fi
COMPASS_BLOCK=$(cat "$COMPASS_FILE")
log "compass loaded from ${COMPASS_FILE}"

# ── Load character (voice, relationships — lives in the repo) ─────────
CHARACTER_FILE="${EXEC_CHARACTER:-$SCRIPT_DIR/CHARACTER.md}"
CHARACTER_BLOCK=""
if [ -f "$CHARACTER_FILE" ]; then
  CHARACTER_BLOCK=$(cat "$CHARACTER_FILE")
else
  log "WARNING: CHARACTER.md not found at ${CHARACTER_FILE}"
  CHARACTER_BLOCK="(no character file found — use your best judgment)"
fi

# Merge: compass first (identity), then character (voice/relationships)
CHARACTER_BLOCK="${COMPASS_BLOCK}

${CHARACTER_BLOCK}"

# ── Load factory context ────────────────────────────────────────────────
CONTEXT_BLOCK=""
for ctx in VISION.md AGENTS.md RESOURCES.md; do
  ctx_path="${PROJECT_REPO_ROOT}/${ctx}"
  if [ -f "$ctx_path" ]; then
    CONTEXT_BLOCK="${CONTEXT_BLOCK}
### ${ctx}
$(cat "$ctx_path")
"
  fi
done

# ── Load exec memory ───────────────────────────────────────────────────
MEMORY_BLOCK="(no previous memory — this is the first conversation)"
MEMORY_FILE="$PROJECT_REPO_ROOT/exec/MEMORY.md"
if [ -f "$MEMORY_FILE" ]; then
  MEMORY_BLOCK=$(cat "$MEMORY_FILE")
fi

# ── Load recent journal entries ─────────────────────────────────────────
JOURNAL_BLOCK=""
JOURNAL_DIR="$PROJECT_REPO_ROOT/exec/journal"
if [ -d "$JOURNAL_DIR" ]; then
  JOURNAL_FILES=$(find "$JOURNAL_DIR" -name '*.md' -type f | sort -r | head -3)
  if [ -n "$JOURNAL_FILES" ]; then
    JOURNAL_BLOCK="
### Recent conversation logs (exec/journal/)
"
    while IFS= read -r jf; do
      JOURNAL_BLOCK="${JOURNAL_BLOCK}
#### $(basename "$jf")
$(head -100 "$jf")
"
    done <<< "$JOURNAL_FILES"
  fi
fi

# ── Load recent agent activity summary ──────────────────────────────────
ACTIVITY_BLOCK=""
# Last planner journal
PLANNER_LATEST=$(find "$PROJECT_REPO_ROOT/planner/journal" -name '*.md' -type f 2>/dev/null | sort -r | head -1)
if [ -n "$PLANNER_LATEST" ]; then
  ACTIVITY_BLOCK="${ACTIVITY_BLOCK}
### Latest planner run ($(basename "$PLANNER_LATEST"))
$(tail -60 "$PLANNER_LATEST")
"
fi
# Last supervisor journal
SUPERVISOR_LATEST=$(find "$PROJECT_REPO_ROOT/supervisor/journal" -name '*.md' -type f 2>/dev/null | sort -r | head -1)
if [ -n "$SUPERVISOR_LATEST" ]; then
  ACTIVITY_BLOCK="${ACTIVITY_BLOCK}
### Latest supervisor run ($(basename "$SUPERVISOR_LATEST"))
$(tail -40 "$SUPERVISOR_LATEST")
"
fi

# Merge activity into journal block
if [ -n "$ACTIVITY_BLOCK" ]; then
  JOURNAL_BLOCK="${JOURNAL_BLOCK}${ACTIVITY_BLOCK}"
fi

# ── Build prompt ────────────────────────────────────────────────────────
# Read prompt template and expand variables
PROMPT="You are the executive assistant for ${FORGE_REPO}. Read your character definition carefully — it is who you are.

## Your character
${CHARACTER_BLOCK}

## Factory context
${CONTEXT_BLOCK}

## Your persistent memory
${MEMORY_BLOCK}

## Recent activity
${JOURNAL_BLOCK}

## Forge API reference
Base URL: ${FORGE_API}
Auth header: -H \"Authorization: token \${FORGE_TOKEN}\"
  Read issue:  curl -sf -H \"Authorization: token \${FORGE_TOKEN}\" '${FORGE_API}/issues/{number}' | jq '.body'
  Create issue: curl -sf -X POST -H \"Authorization: token \${FORGE_TOKEN}\" -H 'Content-Type: application/json' '${FORGE_API}/issues' -d '{\"title\":\"...\",\"body\":\"...\",\"labels\":[LABEL_ID]}'
  List labels: curl -sf -H \"Authorization: token \${FORGE_TOKEN}\" '${FORGE_API}/labels'
  Comment:     curl -sf -H \"Authorization: token \${FORGE_TOKEN}\" -X POST -H 'Content-Type: application/json' '${FORGE_API}/issues/{number}/comments' -d '{\"body\":\"...\"}'
  Close:       curl -sf -H \"Authorization: token \${FORGE_TOKEN}\" -X PATCH -H 'Content-Type: application/json' '${FORGE_API}/issues/{number}' -d '{\"state\":\"closed\"}'
NEVER echo or include the actual token value in output — always reference \${FORGE_TOKEN}.

## Structural analysis (on demand)
When the conversation calls for it — project health, bottlenecks, what to focus on:
  # Fresh graph:  python3 ${FACTORY_ROOT}/lib/build-graph.py --project-root ${PROJECT_REPO_ROOT} --output /tmp/${PROJECT_NAME}-graph-report.json
  # Cached daily: cat /tmp/${PROJECT_NAME}-graph-report.json
The report contains orphans, cycles, thin_objectives, bottlenecks (betweenness centrality).
Reach for it when structural reasoning is what the question needs, not by default.

## Environment
FACTORY_ROOT=${FACTORY_ROOT}
PROJECT_REPO_ROOT=${PROJECT_REPO_ROOT}
PRIMARY_BRANCH=${PRIMARY_BRANCH}
PHASE_FILE=${PHASE_FILE}

## Response format
When responding to the executive, write your response between these markers:
\`\`\`
---EXEC-RESPONSE-START---
Your response here.
---EXEC-RESPONSE-END---
\`\`\`
This allows the output capture to extract and post your response to Matrix.

## Phase protocol
When the executive ends the conversation (says goodbye, done, etc.):
  1. Update your memory: write to ${PROJECT_REPO_ROOT}/exec/MEMORY.md
  2. Log the conversation: append to ${PROJECT_REPO_ROOT}/exec/journal/\$(date -u +%Y-%m-%d).md
  3. Signal done: echo 'PHASE:done' > '${PHASE_FILE}'
On unrecoverable error:
  printf 'PHASE:failed\nReason: %s\n' 'describe error' > '${PHASE_FILE}'

You are now live. Wait for the executive's first message."

# ── Create tmux session ─────────────────────────────────────────────────
rm -f "$PHASE_FILE"

log "Creating tmux session: ${SESSION_NAME}"
if ! create_agent_session "$SESSION_NAME" "$PROJECT_REPO_ROOT" "$PHASE_FILE"; then
  log "ERROR: failed to create tmux session ${SESSION_NAME}"
  exit 1
fi

# Inject prompt
agent_inject_into_session "$SESSION_NAME" "$PROMPT"
log "Prompt injected, session live"

# Notify via Matrix
matrix_send "exec" "Executive assistant session started for ${FORGE_REPO}. Ready for messages." 2>/dev/null || true

echo "STARTED"
