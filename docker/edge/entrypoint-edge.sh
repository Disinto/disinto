#!/usr/bin/env bash
set -euo pipefail

# Set USER before sourcing env.sh (Alpine doesn't set USER)
export USER="${USER:-root}"

FORGE_URL="${FORGE_URL:-http://forgejo:3000}"

# Derive FORGE_REPO from PROJECT_TOML if available, otherwise require explicit env var
if [ -z "${FORGE_REPO:-}" ]; then
  # Try to find and parse PROJECT_TOML
  _project_toml="${PROJECT_TOML:-}"
  if [ -z "$_project_toml" ]; then
    # Default path for project TOML in container
    _project_toml="${FACTORY_ROOT:-/opt/disinto}/projects/disinto.toml"
  fi
  # Also check the generic projects directory
  if [ ! -f "$_project_toml" ] && [ -d "${FACTORY_ROOT:-/opt/disinto}/projects" ]; then
    for toml in "${FACTORY_ROOT:-/opt/disinto}"/projects/*.toml; do
      if [ -f "$toml" ]; then
        _project_toml="$toml"
        break
      fi
    done
  fi

  if [ -n "$_project_toml" ] && [ -f "$_project_toml" ]; then
    # Parse FORGE_REPO from project TOML using load-project.sh
    if source "${SCRIPT_ROOT:-$(dirname "${BASH_SOURCE[0]}")}/../lib/load-project.sh" "$_project_toml" 2>/dev/null; then
      if [ -n "${FORGE_REPO:-}" ]; then
        echo "Derived FORGE_REPO from PROJECT_TOML: $_project_toml" >&2
      fi
    fi
  fi

  # If still not set, fail fast with a clear error message
  if [ -z "${FORGE_REPO:-}" ]; then
    echo "FATAL: FORGE_REPO environment variable not set" >&2
    echo "Set FORGE_REPO=<owner>/<repo> in .env (e.g. FORGE_REPO=disinto-admin/disinto)" >&2
    exit 1
  fi
fi

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
