#!/usr/bin/env bash
set -euo pipefail

# entrypoint.sh — Start agent container with cron and stay alive
#
# Installs crontab entries from project TOMLs found in the factory
# mount, then runs cron in the background and tails the log.

DISINTO_DIR="${HOME}/disinto"
LOGFILE="${HOME}/data/agent-entrypoint.log"
mkdir -p "${HOME}/data"

log() {
  printf '[%s] %s\n' "$(date -u '+%Y-%m-%d %H:%M:%S UTC')" "$*" | tee -a "$LOGFILE"
}

# Build crontab from project TOMLs
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
    printf '%s\n' "$cron_lines" | crontab -
    log "Installed crontab for projects"
  else
    log "No project TOMLs found — crontab empty"
  fi
}

log "Agent container starting"
install_project_crons

# Keep container alive — cron runs in foreground via tail on log
# (cron daemon needs root; since we run as agent, we use a polling approach
#  or the host cron can be used via docker compose exec)
log "Agent container ready — waiting for work"
exec tail -f /dev/null
