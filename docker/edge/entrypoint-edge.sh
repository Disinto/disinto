#!/usr/bin/env bash
set -euo pipefail

# Set USER and HOME before sourcing env.sh — preconditions for lib/env.sh (#674).
export USER="${USER:-agent}"
export HOME="${HOME:-/home/agent}"

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

# Set HOME early so credential helper and git config land in the right place.
export HOME=/home/agent
mkdir -p "$HOME"

# Configure git credential helper before cloning (#604).
# /opt/disinto does not exist yet so we cannot source lib/git-creds.sh;
# inline a minimal credential-helper setup here.
if [ -n "${FORGE_PASS:-}" ] && [ -n "${FORGE_URL:-}" ]; then
  _forge_host=$(printf '%s' "$FORGE_URL" | sed 's|https\?://||; s|/.*||')
  _forge_proto=$(printf '%s' "$FORGE_URL" | sed 's|://.*||')
  _bot_user=""
  if [ -n "${FORGE_TOKEN:-}" ]; then
    _bot_user=$(curl -sf -H "Authorization: token ${FORGE_TOKEN}" \
      "${FORGE_URL}/api/v1/user" 2>/dev/null | jq -r '.login // empty') || _bot_user=""
  fi
  _bot_user="${_bot_user:-dev-bot}"

  cat > "${HOME}/.git-credentials-helper" <<CREDEOF
#!/bin/sh
# Reads \$FORGE_PASS from env at runtime — file is safe to read on disk.
[ "\$1" = "get" ] || exit 0
cat >/dev/null
echo "protocol=${_forge_proto}"
echo "host=${_forge_host}"
echo "username=${_bot_user}"
echo "password=\$FORGE_PASS"
CREDEOF
  chmod 755 "${HOME}/.git-credentials-helper"
  git config --global credential.helper "${HOME}/.git-credentials-helper"
  git config --global --add safe.directory '*'
fi

# Shallow clone at the pinned version — use clean URL, credential helper
# supplies auth (#604).
# Retry with exponential backoff — forgejo may still be starting (#665).
if [ ! -d /opt/disinto/.git ]; then
  echo "edge: cloning ${FORGE_URL}/${FORGE_REPO} (branch ${DISINTO_VERSION:-main})..." >&2
  _clone_ok=false
  _backoff=2
  _max_backoff=30
  _max_attempts=10
  for _attempt in $(seq 1 "$_max_attempts"); do
    if git clone --depth 1 --branch "${DISINTO_VERSION:-main}" "${FORGE_URL}/${FORGE_REPO}.git" /opt/disinto 2>&1; then
      _clone_ok=true
      break
    fi
    rm -rf /opt/disinto  # clean up partial clone before retry
    if [ "$_attempt" -lt "$_max_attempts" ]; then
      echo "edge: clone attempt ${_attempt}/${_max_attempts} failed, retrying in ${_backoff}s..." >&2
      sleep "$_backoff"
      _backoff=$(( _backoff * 2 ))
      if [ "$_backoff" -gt "$_max_backoff" ]; then _backoff=$_max_backoff; fi
    fi
  done
  if [ "$_clone_ok" != "true" ]; then
    echo >&2
    echo "FATAL: failed to clone ${FORGE_URL}/${FORGE_REPO}.git (branch ${DISINTO_VERSION:-main}) after ${_max_attempts} attempts" >&2
    echo "Likely causes:" >&2
    echo "  - Forgejo at ${FORGE_URL} is unreachable from the edge container" >&2
    echo "  - Repository '${FORGE_REPO}' does not exist on this forge" >&2
    echo "  - FORGE_TOKEN/FORGE_PASS is invalid or has no read access to '${FORGE_REPO}'" >&2
    echo "  - Branch '${DISINTO_VERSION:-main}' does not exist in '${FORGE_REPO}'" >&2
    echo "Workaround: bind-mount a local git checkout into /opt/disinto." >&2
    echo "Sleeping 60s before exit to throttle the restart loop..." >&2
    sleep 60
    exit 1
  fi
fi

# Repair any legacy baked-credential URLs in /opt/disinto (#604).
# Now that /opt/disinto exists, source the shared lib.
if [ -f /opt/disinto/lib/git-creds.sh ]; then
  # shellcheck source=/opt/disinto/lib/git-creds.sh
  source /opt/disinto/lib/git-creds.sh
  _GIT_CREDS_LOG_FN="echo" repair_baked_cred_urls /opt/disinto
fi

# Ensure log directory exists
mkdir -p /opt/disinto-logs

# ── Reverse tunnel (optional) ──────────────────────────────────────────
# When EDGE_TUNNEL_HOST is set, open a single reverse-SSH forward so the
# DO edge box can reach this container's Caddy on the project's assigned port.
# Guarded: if EDGE_TUNNEL_HOST is empty/unset the block is skipped entirely,
# keeping local-only dev working without errors.
if [ -n "${EDGE_TUNNEL_HOST:-}" ]; then
  _tunnel_key="/run/secrets/tunnel_key"
  if [ ! -f "$_tunnel_key" ]; then
    echo "WARN: EDGE_TUNNEL_HOST is set but ${_tunnel_key} is missing — skipping tunnel" >&2
  else
    # Ensure correct permissions (bind-mount may arrive as 644)
    chmod 0400 "$_tunnel_key" 2>/dev/null || true

    : "${EDGE_TUNNEL_USER:=tunnel}"
    : "${EDGE_TUNNEL_PORT:?EDGE_TUNNEL_PORT must be set when EDGE_TUNNEL_HOST is set}"

    export AUTOSSH_GATETIME=0   # don't exit if the first attempt fails quickly

    autossh -M 0 -N -f \
      -o StrictHostKeyChecking=accept-new \
      -o ServerAliveInterval=30 \
      -o ServerAliveCountMax=3 \
      -o ExitOnForwardFailure=yes \
      -i "$_tunnel_key" \
      -R "127.0.0.1:${EDGE_TUNNEL_PORT}:localhost:80" \
      "${EDGE_TUNNEL_USER}@${EDGE_TUNNEL_HOST}"

    echo "edge: reverse tunnel → ${EDGE_TUNNEL_HOST}:${EDGE_TUNNEL_PORT}" >&2
  fi
fi

# Set project context vars for scripts that source lib/env.sh (#674).
# These satisfy env.sh's preconditions for edge-container scripts.
export PROJECT_REPO_ROOT="${PROJECT_REPO_ROOT:-/opt/disinto}"
export PRIMARY_BRANCH="${PRIMARY_BRANCH:-main}"
export OPS_REPO_ROOT="${OPS_REPO_ROOT:-/home/agent/repos/${PROJECT_NAME:-disinto}-ops}"

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
