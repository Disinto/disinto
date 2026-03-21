#!/usr/bin/env bash
# =============================================================================
# gardener-run.sh — Cron wrapper: gardener execution via Claude + formula
#
# Runs 4x/day (or on-demand). Guards against concurrent runs and low memory.
# Creates a tmux session with Claude (sonnet) reading formulas/run-gardener.toml.
# No action issues — the gardener is a nervous system component, not work (AD-001).
#
# Usage:
#   gardener-run.sh [projects/disinto.toml]   # project config (default: disinto)
#
# Cron: 0 0,6,12,18 * * * cd /home/debian/dark-factory && bash gardener/gardener-run.sh projects/disinto.toml
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
# shellcheck source=../lib/formula-session.sh
source "$FACTORY_ROOT/lib/formula-session.sh"

LOG_FILE="$SCRIPT_DIR/gardener.log"
# shellcheck disable=SC2034  # consumed by run_formula_and_monitor
SESSION_NAME="gardener-${PROJECT_NAME}"
PHASE_FILE="/tmp/gardener-session-${PROJECT_NAME}.phase"

# shellcheck disable=SC2034  # read by monitor_phase_loop in lib/agent-session.sh
PHASE_POLL_INTERVAL=15

SCRATCH_FILE="/tmp/gardener-${PROJECT_NAME}-scratch.md"
RESULT_FILE="/tmp/gardener-result-${PROJECT_NAME}.txt"

log() { echo "[$(date -u +%Y-%m-%dT%H:%M:%S)Z] $*" >> "$LOG_FILE"; }

# ── Guards ────────────────────────────────────────────────────────────────
acquire_cron_lock "/tmp/gardener-run.lock"
check_memory 2000

log "--- Gardener run start ---"

# ── Consume escalation replies ────────────────────────────────────────────
consume_escalation_reply "gardener"

# ── Load formula + context ───────────────────────────────────────────────
load_formula "$FACTORY_ROOT/formulas/run-gardener.toml"
build_context_block AGENTS.md

# ── Read scratch file (compaction survival) ───────────────────────────────
SCRATCH_CONTEXT=$(read_scratch_context "$SCRATCH_FILE")
SCRATCH_INSTRUCTION=$(build_scratch_instruction "$SCRATCH_FILE")

# ── Build prompt (gardener needs extra API endpoints for issue management) ─
GARDENER_API_EXTRA="
  Relabel:     curl -sf -H \"Authorization: token \$CODEBERG_TOKEN\" -X PUT -H 'Content-Type: application/json' '${CODEBERG_API}/issues/{number}/labels' -d '{\"labels\":[LABEL_ID]}'
  Comment:     curl -sf -H \"Authorization: token \$CODEBERG_TOKEN\" -X POST -H 'Content-Type: application/json' '${CODEBERG_API}/issues/{number}/comments' -d '{\"body\":\"...\"}'
  Close:       curl -sf -H \"Authorization: token \$CODEBERG_TOKEN\" -X PATCH -H 'Content-Type: application/json' '${CODEBERG_API}/issues/{number}' -d '{\"state\":\"closed\"}'
  Edit body:   curl -sf -H \"Authorization: token \$CODEBERG_TOKEN\" -X PATCH -H 'Content-Type: application/json' '${CODEBERG_API}/issues/{number}' -d '{\"body\":\"new body\"}'
"
build_prompt_footer "$GARDENER_API_EXTRA"

# shellcheck disable=SC2034  # consumed by run_formula_and_monitor
PROMPT="You are the issue gardener for ${CODEBERG_REPO}. Work through the formula below. You MUST write PHASE:done to '${PHASE_FILE}' when finished — the orchestrator will time you out if you return to the prompt without signalling.

You have full shell access and --dangerously-skip-permissions.
Fix what you can. Escalate what you cannot. Do NOT ask permission — act first, report after.
${ESCALATION_REPLY:+
## Escalation Reply (from Matrix — human message)
${ESCALATION_REPLY}

Act on this reply during the grooming step.
}
## Project context
${CONTEXT_BLOCK}
${SCRATCH_CONTEXT:+${SCRATCH_CONTEXT}
}
## Result file
Write actions and dust items to: ${RESULT_FILE}

## Formula
${FORMULA_CONTENT}

${SCRATCH_INSTRUCTION}
${PROMPT_FOOTER}"

# ── Reset result file ────────────────────────────────────────────────────
rm -f "$RESULT_FILE"
touch "$RESULT_FILE"

# ── Run session ──────────────────────────────────────────────────────────
export CLAUDE_MODEL="sonnet"
run_formula_and_monitor "gardener" 7200

# ── Cleanup scratch file on normal exit ──────────────────────────────────
# FINAL_PHASE already set by run_formula_and_monitor
if [ "${FINAL_PHASE:-}" = "PHASE:done" ]; then
  rm -f "$SCRATCH_FILE"
fi
