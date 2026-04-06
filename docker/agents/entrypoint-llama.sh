#!/usr/bin/env bash
set -euo pipefail

LOG_DIR="/home/agent/data/logs/dev"
mkdir -p "$LOG_DIR" /home/agent/data
chown -R agent:agent /home/agent/data 2>/dev/null || true

log() {
  printf "[%s] llama-loop: %s\n" "$(date -u '+%Y-%m-%d %H:%M:%S UTC')" "$*" | tee -a "$LOG_DIR/llama-loop.log"
}

# Apply token override for named agent identity
if [ -n "${FORGE_TOKEN_OVERRIDE:-}" ]; then
  export FORGE_TOKEN="$FORGE_TOKEN_OVERRIDE"
fi

log "Starting llama dev-agent loop"
log "Backend: ${ANTHROPIC_BASE_URL:-not set}"
log "Claude CLI: $(claude --version 2>&1 || echo not found)"
log "Agent identity: $(curl -sf -H "Authorization: token ${FORGE_TOKEN}" "${FORGE_URL:-http://forgejo:3000}/api/v1/user" 2>/dev/null | jq -r '.login // "unknown"')"

# Clone repo if not present
if [ ! -d "${PROJECT_REPO_ROOT}/.git" ]; then
  log "Cloning repo..."
  mkdir -p "$(dirname "$PROJECT_REPO_ROOT")"
  chown -R agent:agent /home/agent/repos 2>/dev/null || true
  su -s /bin/bash agent -c "git clone http://dev-bot:${FORGE_TOKEN}@forgejo:3000/${FORGE_REPO:-disinto-admin/disinto}.git ${PROJECT_REPO_ROOT}"
  log "Repo cloned"
fi

log "Entering poll loop (interval: ${POLL_INTERVAL:-300}s)"

while true; do
  # Clear stale session IDs before each poll.
  # Local llama does not support --resume (no server-side session storage).
  # Stale .sid files cause agent_run to exit instantly on every retry.
  rm -f /tmp/dev-session-*.sid 2>/dev/null || true

  su -s /bin/bash agent -c "
    export FORGE_TOKEN='${FORGE_TOKEN}'
    export ANTHROPIC_API_KEY='${ANTHROPIC_API_KEY:-}'
    export ANTHROPIC_BASE_URL='${ANTHROPIC_BASE_URL:-}'
    export CLAUDE_CONFIG_DIR='${CLAUDE_CONFIG_DIR:-}'
    cd /home/agent/disinto && \
    bash dev/dev-poll.sh ${PROJECT_TOML:-projects/disinto.toml}
  " >> "$LOG_DIR/llama-loop.log" 2>&1 || true
  sleep "${POLL_INTERVAL:-300}"
done
