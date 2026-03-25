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
  local cron_lines=""
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
2,7,12,17,22,27,32,37,42,47,52,57 * * * * ${DISINTO_DIR}/review/review-poll.sh ${toml} >/dev/null 2>&1
4,9,14,19,24,29,34,39,44,49,54,59 * * * * ${DISINTO_DIR}/dev/dev-poll.sh ${toml} >/dev/null 2>&1
0 0,6,12,18 * * * cd ${DISINTO_DIR} && bash gardener/gardener-run.sh ${toml} >/dev/null 2>&1"
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

# Start matrix listener in background (if configured)
if [ -n "${MATRIX_TOKEN:-}" ] && [ -n "${MATRIX_ROOM_ID:-}" ]; then
  log "Starting matrix listener in background"
  su -s /bin/bash agent -c "${DISINTO_DIR}/lib/matrix_listener.sh" &
else
  log "Matrix listener: skipped (MATRIX_TOKEN or MATRIX_ROOM_ID not set)"
fi

# Run cron in the foreground.  Cron jobs execute as the agent user.
log "Starting cron daemon"
exec cron -f
