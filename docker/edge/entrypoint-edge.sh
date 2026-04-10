#!/usr/bin/env bash
set -euo pipefail

# Set USER before sourcing env.sh (Alpine doesn't set USER)
export USER="${USER:-root}"

FORGE_URL="${FORGE_URL:-http://forgejo:3000}"

# Derive FORGE_REPO from PROJECT_TOML if available, otherwise require explicit env var
if [ -z "${FORGE_REPO:-}" ]; then
  # Try to find a project TOML to derive FORGE_REPO from
  _project_toml="${PROJECT_TOML:-}"
  if [ -z "$_project_toml" ] && [ -d "${FACTORY_ROOT:-/opt/disinto}/projects" ]; then
    for toml in "${FACTORY_ROOT:-/opt/disinto}"/projects/*.toml; do
      if [ -f "$toml" ]; then
        _project_toml="$toml"
        break
      fi
    done
  fi

  if [ -n "$_project_toml" ] && [ -f "$_project_toml" ]; then
    # Parse FORGE_REPO from project TOML using load-project.sh
    if source "${FACTORY_ROOT:-/opt/disinto}/lib/load-project.sh" "$_project_toml" 2>/dev/null; then
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

# Detect bind-mount of a non-git directory before attempting clone
if [ -d /opt/disinto ] && [ ! -d /opt/disinto/.git ] && [ -n "$(ls -A /opt/disinto 2>/dev/null)" ]; then
  echo "FATAL: /opt/disinto contains files but no .git directory." >&2
  echo "If you bind-mounted a directory at /opt/disinto, ensure it is a git working tree." >&2
  echo "Sleeping 60s before exit to throttle the restart loop..." >&2
  sleep 60
  exit 1
fi

# Shallow clone at the pinned version (inject token to support auth-required Forgejo)
if [ ! -d /opt/disinto/.git ]; then
  _auth_url=$(printf '%s' "$FORGE_URL" | sed "s|://|://token:${FORGE_TOKEN}@|")
  echo "edge: cloning ${FORGE_URL}/${FORGE_REPO} (branch ${DISINTO_VERSION:-main})..." >&2
  if ! git clone --depth 1 --branch "${DISINTO_VERSION:-main}" "${_auth_url}/${FORGE_REPO}.git" /opt/disinto; then
    echo >&2
    echo "FATAL: failed to clone ${FORGE_URL}/${FORGE_REPO}.git (branch ${DISINTO_VERSION:-main})" >&2
    echo "Likely causes:" >&2
    echo "  - Forgejo at ${FORGE_URL} is unreachable from the edge container" >&2
    echo "  - Repository '${FORGE_REPO}' does not exist on this forge" >&2
    echo "  - FORGE_TOKEN is invalid or has no read access to '${FORGE_REPO}'" >&2
    echo "  - Branch '${DISINTO_VERSION:-main}' does not exist in '${FORGE_REPO}'" >&2
    echo "Workaround: bind-mount a local git checkout into /opt/disinto." >&2
    echo "Sleeping 60s before exit to throttle the restart loop..." >&2
    sleep 60
    exit 1
  fi
fi

# Set HOME so that claude OAuth credentials and session.lock are found at the
# same in-container path as in disinto-agents (/home/agent/.claude), which makes
# flock cross-serialize across containers on the same host inode.
export HOME=/home/agent
mkdir -p "$HOME"

# Ensure log directory exists
mkdir -p /opt/disinto-logs

# Start dispatcher in background
bash /opt/disinto/docker/edge/dispatcher.sh &

# Start supervisor loop in background
PROJECT_TOML="${PROJECT_TOML:-projects/disinto.toml}"
(while true; do
  bash /opt/disinto/supervisor/supervisor-run.sh "/opt/disinto/${PROJECT_TOML}" 2>&1 | tee -a /opt/disinto-logs/supervisor.log || true
  sleep 1200  # 20 minutes
done) &

# Caddy as main process — run in foreground via wait so background jobs survive
# (exec replaces the shell, which can orphan backgrounded subshells)
caddy run --config /etc/caddy/Caddyfile --adapter caddyfile &

# Exit when any child dies (caddy crash → container restart via docker compose)
wait -n
exit 1
