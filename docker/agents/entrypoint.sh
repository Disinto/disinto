#!/usr/bin/env bash
set -euo pipefail

# entrypoint.sh — Start agent container with cron in foreground
#
# Runs as root inside the container.  Installs crontab entries for the
# agent user from project TOMLs, then starts cron in the foreground.
# All cron jobs execute as the agent user (UID 1000).

DISINTO_DIR="/home/agent/disinto"
LOGFILE="/home/agent/data/agent-entrypoint.log"
mkdir -p /home/agent/data
chown agent:agent /home/agent/data

log() {
  printf '[%s] %s\n' "$(date -u '+%Y-%m-%d %H:%M:%S UTC')" "$*" | tee -a "$LOGFILE"
}

# Build crontab from project TOMLs and install for the agent user.
install_project_crons() {
  local cron_lines="DISINTO_CONTAINER=1
USER=agent
FORGE_URL=http://forgejo:3000
PROJECT_REPO_ROOT=/home/agent/repos/${pname}"
  for toml in "${DISINTO_DIR}"/projects/*.toml; do
    [ -f "$toml" ] || continue
    local pname
    pname=$(python3 -c "
import sys, tomllib
with open(sys.argv[1], 'rb') as f:
    print(tomllib.load(f)['name'])
" "$toml" 2>/dev/null) || continue

    cron_lines="${cron_lines}
# disinto: ${pname}
2,7,12,17,22,27,32,37,42,47,52,57 * * * * ${DISINTO_DIR}/review/review-poll.sh ${toml} >>/home/agent/data/logs/cron.log 2>&1
4,9,14,19,24,29,34,39,44,49,54,59 * * * * ${DISINTO_DIR}/dev/dev-poll.sh ${toml} >>/home/agent/data/logs/cron.log 2>&1
0 0,6,12,18 * * * cd ${DISINTO_DIR} && bash gardener/gardener-run.sh ${toml} >>/home/agent/data/logs/cron.log 2>&1"
  done

  if [ -n "$cron_lines" ]; then
    printf '%s\n' "$cron_lines" | crontab -u agent -
    log "Installed crontab for agent user"
  else
    log "No project TOMLs found — crontab empty"
  fi
}

log "Agent container starting"

# Verify Claude CLI is available (expected via volume mount from host).
if ! command -v claude &>/dev/null; then
  log "FATAL: claude CLI not found in PATH."
  log "Mount the host binary into the container, e.g.:"
  log "  volumes:"
  log "    - /usr/local/bin/claude:/usr/local/bin/claude:ro"
  exit 1
fi
log "Claude CLI: $(claude --version 2>&1 || true)"

# ANTHROPIC_API_KEY fallback: when set, Claude uses the API key directly
# and OAuth token refresh is not needed (no rotation race).  Log which
# auth method is active so operators can debug 401s.
if [ -n "${ANTHROPIC_API_KEY:-}" ]; then
  log "Auth: ANTHROPIC_API_KEY is set — using API key (no OAuth rotation)"
elif [ -f /home/agent/.claude/credentials.json ]; then
  log "Auth: OAuth credentials mounted from host (~/.claude)"
else
  log "WARNING: No ANTHROPIC_API_KEY and no OAuth credentials found."
  log "Run 'claude auth login' on the host, or set ANTHROPIC_API_KEY in .env"
fi

install_project_crons

# Configure tea CLI login for forge operations (runs as agent user).
# tea stores config in ~/.config/tea/ — persistent across container restarts
# only if that directory is on a mounted volume.
if command -v tea &>/dev/null && [ -n "${FORGE_TOKEN:-}" ] && [ -n "${FORGE_URL:-}" ]; then
  local_tea_login="forgejo"
  case "$FORGE_URL" in
    *codeberg.org*) local_tea_login="codeberg" ;;
  esac
  su -s /bin/bash agent -c "tea login add \
    --name '${local_tea_login}' \
    --url '${FORGE_URL}' \
    --token '${FORGE_TOKEN}' \
    --no-version-check 2>/dev/null || true"
  log "tea login configured: ${local_tea_login} → ${FORGE_URL}"
else
  log "tea login: skipped (tea not found or FORGE_TOKEN/FORGE_URL not set)"
fi

# Run cron in the foreground.  Cron jobs execute as the agent user.
log "Starting cron daemon"
exec cron -f
