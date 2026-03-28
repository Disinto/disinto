#!/usr/bin/env bash
set -euo pipefail

LOG_DIR="/home/agent/data/logs/dev"
mkdir -p "$LOG_DIR" /home/agent/data

log() {
  printf "[%s] llama-loop: %s\n" "$(date -u +%Y-%m-%d\ %H:%M:%S\ UTC)" "$*" | tee -a "$LOG_DIR/llama-loop.log"
}

log "Starting llama dev-agent loop"
log "Backend: ${ANTHROPIC_BASE_URL:-not set}"
log "Claude CLI: $(claude --version 2>&1 || echo not found)"

# Clone repo if not present
if [ ! -d "${PROJECT_REPO_ROOT}/.git" ]; then
  log "Cloning repo..."
  mkdir -p "$(dirname "$PROJECT_REPO_ROOT")"
  chown -R agent:agent /home/agent/repos 2>/dev/null || true
  su -s /bin/bash agent -c "git clone http://dev-bot:${FORGE_TOKEN}@forgejo:3000/${FORGE_REPO:-johba/disinto}.git ${PROJECT_REPO_ROOT}"
  log "Repo cloned"
fi

log "Entering poll loop (interval: ${POLL_INTERVAL:-300}s)"

# Run dev-poll in a loop as agent user
while true; do
  su -s /bin/bash agent -c "
    cd /home/agent/disinto && \
    bash dev/dev-poll.sh ${PROJECT_TOML:-projects/disinto.toml}
  " >> "$LOG_DIR/llama-loop.log" 2>&1 || true
  sleep "${POLL_INTERVAL:-300}"
done
