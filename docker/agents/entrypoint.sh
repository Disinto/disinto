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
install_project_crons

# Run cron in the foreground.  Cron jobs execute as the agent user.
log "Starting cron daemon"
exec cron -f
