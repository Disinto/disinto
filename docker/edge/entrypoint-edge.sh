#!/usr/bin/env bash
set -euo pipefail

# Set USER before sourcing env.sh (Alpine doesn't set USER)
export USER="${USER:-root}"

FORGE_URL="${FORGE_URL:-http://forgejo:3000}"
FORGE_REPO="${FORGE_REPO:-disinto-admin/disinto}"

# Shallow clone at the pinned version (inject token to support auth-required Forgejo)
if [ ! -d /opt/disinto/.git ]; then
  _auth_url=$(printf '%s' "$FORGE_URL" | sed "s|://|://token:${FORGE_TOKEN}@|")
  git clone --depth 1 --branch "${DISINTO_VERSION:-main}" "${_auth_url}/${FORGE_REPO}.git" /opt/disinto
fi

# Start dispatcher in background
bash /opt/disinto/docker/edge/dispatcher.sh &

# Start supervisor loop in background
PROJECT_TOML="${PROJECT_TOML:-projects/disinto.toml}"
while true; do
  bash /opt/disinto/supervisor/supervisor-run.sh "/opt/disinto/${PROJECT_TOML}" 2>&1 | tee -a /opt/disinto-logs/supervisor.log || true
  sleep 1200  # 20 minutes
done &

# Caddy as main process
exec caddy run --config /etc/caddy/Caddyfile --adapter caddyfile
