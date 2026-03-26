#!/usr/bin/env bash
# vault-agent.sh — Invoke claude -p to classify and route pending vault actions
#
# Called by vault-poll.sh when pending actions exist. Reads all pending/*.json,
# builds a prompt with action summaries, and lets the LLM decide routing.
#
# The LLM can call vault-fire.sh (auto-approve) or vault-reject.sh (reject)
# directly. For escalations, it writes a PHASE:escalate file and marks the
# action as "escalated" in pending/ so vault-poll skips it on future runs.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/../lib/env.sh"

VAULT_DIR="${FACTORY_ROOT}/vault"
PROMPT_FILE="${VAULT_DIR}/PROMPT.md"
LOGFILE="${VAULT_DIR}/vault.log"
CLAUDE_TIMEOUT="${CLAUDE_TIMEOUT:-3600}"

log() {
  printf '[%s] vault-agent: %s\n' "$(date -u '+%Y-%m-%d %H:%M:%S UTC')" "$*" >> "$LOGFILE"
}

# Collect all pending actions (skip already-escalated)
ACTIONS_BATCH=""
ACTION_COUNT=0

for action_file in "${VAULT_DIR}/pending/"*.json; do
  [ -f "$action_file" ] || continue

  ACTION_STATUS=$(jq -r '.status // ""' < "$action_file" 2>/dev/null)
  [ "$ACTION_STATUS" = "escalated" ] && continue

  # Validate JSON
  if ! jq empty < "$action_file" 2>/dev/null; then
    ACTION_ID=$(basename "$action_file" .json)
    log "malformed JSON: $action_file — rejecting"
    bash "${VAULT_DIR}/vault-reject.sh" "$ACTION_ID" "malformed JSON" 2>/dev/null || true
    continue
  fi

  ACTION_JSON=$(cat "$action_file")
  ACTIONS_BATCH="${ACTIONS_BATCH}
--- ACTION ---
$(echo "$ACTION_JSON" | jq '.')
--- END ACTION ---
"
  ACTION_COUNT=$((ACTION_COUNT + 1))
done

if [ "$ACTION_COUNT" -eq 0 ]; then
  log "no actionable pending items"
  exit 0
fi

log "processing $ACTION_COUNT pending action(s) via claude -p"

# Build the prompt
SYSTEM_PROMPT=$(cat "$PROMPT_FILE" 2>/dev/null || echo "You are a vault agent. Classify and route actions.")

PROMPT="${SYSTEM_PROMPT}

## Pending Actions (${ACTION_COUNT} total)
${ACTIONS_BATCH}

## Environment
- FACTORY_ROOT=${FACTORY_ROOT}
- Vault directory: ${VAULT_DIR}
- vault-fire.sh: bash ${VAULT_DIR}/vault-fire.sh <action-id>
- vault-reject.sh: bash ${VAULT_DIR}/vault-reject.sh <action-id> \"<reason>\"

Process each action now. For auto-approve, fire immediately. For reject, call vault-reject.sh.

For actions that need human approval (escalate), write a PHASE:escalate file
to signal the unified escalation path:
  printf 'PHASE:escalate\nReason: vault procurement — %s\n' '<action summary>' \\
    > /tmp/vault-escalate-<action-id>.phase
Then STOP and wait — a human will review via the forge."

CLAUDE_OUTPUT=$(timeout "$CLAUDE_TIMEOUT" claude -p "$PROMPT" \
  --model sonnet \
  --dangerously-skip-permissions \
  --max-turns 20 \
  2>/dev/null) || true

log "claude finished ($(echo "$CLAUDE_OUTPUT" | wc -c) bytes)"

# Log routing decisions
ROUTES=$(echo "$CLAUDE_OUTPUT" | grep "^ROUTE:" || true)
if [ -n "$ROUTES" ]; then
  echo "$ROUTES" | while read -r line; do
    log "  $line"
  done
fi
