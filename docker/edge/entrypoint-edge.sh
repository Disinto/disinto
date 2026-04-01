#!/usr/bin/env bash
set -euo pipefail

# Set USER before sourcing env.sh (Alpine doesn't set USER)
export USER="${USER:-root}"

DISINTO_VERSION="${DISINTO_VERSION:-main}"
DISINTO_REPO="${FORGE_URL:-http://forgejo:3000}/johba/disinto.git"

# Shallow clone at the pinned version
if [ ! -d /opt/disinto/.git ]; then
  git clone --depth 1 --branch "$DISINTO_VERSION" "$DISINTO_REPO" /opt/disinto
fi

# Start dispatcher in background
bash /opt/disinto/docker/edge/dispatcher.sh &

# Caddy as main process
exec caddy run --config /etc/caddy/Caddyfile --adapter caddyfile
