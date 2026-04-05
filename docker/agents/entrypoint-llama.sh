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

# Install crontab entries for agent user from project TOMLs
install_project_crons() {
  local cron_lines="DISINTO_CONTAINER=1
USER=agent
FORGE_URL=http://forgejo:3000"

  # Parse DISINTO_AGENTS env var (default: all agents)
  # Expected format: comma-separated list like "review,gardener" or "dev"
  local agents_to_run="review,dev,gardener"
  if [ -n "${DISINTO_AGENTS:-}" ]; then
    agents_to_run="$DISINTO_AGENTS"
  fi

  for toml in "${DISINTO_DIR}"/projects/*.toml; do
    [ -f "$toml" ] || continue
    local pname
    pname=$(python3 -c "
import sys, tomllib
with open(sys.argv[1], 'rb') as f:
    print(tomllib.load(f)['name'])
" "$toml" 2>/dev/null) || continue

    cron_lines="${cron_lines}
PROJECT_REPO_ROOT=/home/agent/repos/${pname}
# disinto: ${pname}"

    # Add review-poll only if review agent is configured
    if echo "$agents_to_run" | grep -qw "review"; then
      cron_lines="${cron_lines}
2,7,12,17,22,27,32,37,42,47,52,57 * * * * ${DISINTO_DIR}/review/review-poll.sh ${toml} >>/home/agent/data/logs/cron.log 2>&1"
    fi

    # Add dev-poll only if dev agent is configured
    if echo "$agents_to_run" | grep -qw "dev"; then
      cron_lines="${cron_lines}
4,9,14,19,24,29,34,39,44,49,54,59 * * * * ${DISINTO_DIR}/dev/dev-poll.sh ${toml} >>/home/agent/data/logs/cron.log 2>&1"
    fi

    # Add gardener-run only if gardener agent is configured
    if echo "$agents_to_run" | grep -qw "gardener"; then
      cron_lines="${cron_lines}
0 0,6,12,18 * * * cd ${DISINTO_DIR} && bash gardener/gardener-run.sh ${toml} >>/home/agent/data/logs/cron.log 2>&1"
    fi
  done

  if [ -n "$cron_lines" ]; then
    printf '%s\n' "$cron_lines" | crontab -u agent -
    log "Installed crontab for agent user (agents: ${agents_to_run})"
  else
    log "No project TOMLs found — crontab empty"
  fi
}

log "Entering poll loop (interval: ${POLL_INTERVAL:-300}s)"

# Install and start cron daemon
DISINTO_DIR="/home/agent/disinto"
install_project_crons
log "Starting cron daemon"
cron
log "cron daemon started"

while true; do
  # Clear stale session IDs before each poll.
  # Local llama does not support --resume (no server-side session storage).
  # Stale .sid files cause agent_run to exit instantly on every retry.
  rm -f /tmp/dev-session-*.sid 2>/dev/null || true

  su -s /bin/bash agent -c "
    export FORGE_TOKEN='${FORGE_TOKEN}'
    cd /home/agent/disinto && \
    bash dev/dev-poll.sh ${PROJECT_TOML:-projects/disinto.toml}
  " >> "$LOG_DIR/llama-loop.log" 2>&1 || true
  sleep "${POLL_INTERVAL:-300}"
done
