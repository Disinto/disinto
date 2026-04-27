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
# inline a minimal credential-helper setup here. We do source the baked-in
# copy of lib/forge-helpers.sh so forge_whoami() stays consistent with the
# rest of the codebase (#694).
if [ -n "${FORGE_PASS:-}" ] && [ -n "${FORGE_URL:-}" ]; then
  # shellcheck source=/usr/local/lib/forge-helpers.sh
  source /usr/local/lib/forge-helpers.sh
  _forge_host=$(printf '%s' "$FORGE_URL" | sed 's|https\?://||; s|/.*||')
  _forge_proto=$(printf '%s' "$FORGE_URL" | sed 's|://.*||')
  _bot_user=""
  if [ -n "${FORGE_TOKEN:-}" ]; then
    _bot_user=$(forge_whoami)
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

# ── Load optional secrets from secrets/*.enc (#777) ────────────────────
# Engagement collection (collect-engagement.sh) requires CADDY_ secrets to
# SCP access logs from a remote edge host. When age key or secrets dir is
# missing, or any secret fails to decrypt, log a warning and skip the cron.
# Caddy itself does not depend on these secrets.
_AGE_KEY_FILE="${HOME}/.config/sops/age/keys.txt"
_SECRETS_DIR="/opt/disinto/secrets"
EDGE_REQUIRED_SECRETS="CADDY_SSH_KEY CADDY_SSH_HOST CADDY_SSH_USER CADDY_ACCESS_LOG"
EDGE_ENGAGEMENT_READY=0  # Assume not ready until proven otherwise

_edge_decrypt_secret() {
  local enc_path="${_SECRETS_DIR}/${1}.enc"
  [ -f "$enc_path" ] || return 1
  age -d -i "$_AGE_KEY_FILE" "$enc_path" 2>/dev/null
}

if [ -f "$_AGE_KEY_FILE" ] && [ -d "$_SECRETS_DIR" ]; then
  _missing=""
  for _secret_name in $EDGE_REQUIRED_SECRETS; do
    _val=$(_edge_decrypt_secret "$_secret_name") || { _missing="${_missing} ${_secret_name}"; continue; }
    export "$_secret_name=$_val"
  done
  if [ -n "$_missing" ]; then
    echo "WARN: required engagement secrets missing from secrets/*.enc:${_missing}" >&2
    echo "  collect-engagement cron will be skipped. Run 'disinto secrets add <NAME>' to enable." >&2
    EDGE_ENGAGEMENT_READY=0
  else
    echo "edge: loaded required engagement secrets: ${EDGE_REQUIRED_SECRETS}" >&2
    EDGE_ENGAGEMENT_READY=1
  fi
else
  echo "WARN: age key (${_AGE_KEY_FILE}) or secrets dir (${_SECRETS_DIR}) not found — engagement secrets unavailable" >&2
  echo "  collect-engagement cron will be skipped. Run 'disinto secrets add <NAME>' to enable." >&2
  EDGE_ENGAGEMENT_READY=0
fi

# Start daily engagement collection cron loop in background (#745)
# Runs collect-engagement.sh daily at ~23:50 UTC via a sleep loop that
# calculates seconds until the next 23:50 window. SSH key from secrets/*.enc (#777).
# Guarded: only start if EDGE_ENGAGEMENT_READY=1.
if [ "$EDGE_ENGAGEMENT_READY" -eq 1 ]; then
  (while true; do
    # Calculate seconds until next 23:50 UTC
    _now=$(date -u +%s)
    _target=$(date -u -d "today 23:50" +%s 2>/dev/null || date -u -d "23:50" +%s 2>/dev/null || echo 0)
    if [ "$_target" -le "$_now" ]; then
      _target=$(( _target + 86400 ))
    fi
    _sleep_secs=$(( _target - _now ))
    echo "edge: collect-engagement scheduled in ${_sleep_secs}s (next 23:50 UTC)" >&2
    sleep "$_sleep_secs"
    _fetch_log="/tmp/caddy-access-log-fetch.log"
    _ssh_key_file=$(mktemp)
    printf '%s\n' "$CADDY_SSH_KEY" > "$_ssh_key_file"
    chmod 0600 "$_ssh_key_file"
    scp -i "$_ssh_key_file" -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10 -o BatchMode=yes \
      "${CADDY_SSH_USER}@${CADDY_SSH_HOST}:${CADDY_ACCESS_LOG}" \
      "$_fetch_log" 2>&1 | tee -a /opt/disinto-logs/collect-engagement.log || true
    rm -f "$_ssh_key_file"
    if [ -s "$_fetch_log" ]; then
      CADDY_ACCESS_LOG="$_fetch_log" bash /opt/disinto/site/collect-engagement.sh 2>&1 \
        | tee -a /opt/disinto-logs/collect-engagement.log || true
    else
      echo "edge: collect-engagement: fetched log is empty, skipping parse" >&2
    fi
    rm -f "$_fetch_log"
  done) &
else
  echo "edge: collect-engagement cron skipped (EDGE_ENGAGEMENT_READY=0)" >&2
fi

# ── chat-Claude factory control surface (#650) ────────────────────────
# Install settings.json + .mcp.json templates into $CHAT_WORKSPACE_DIR so
# Claude Code auto-loads them when chat-server.py spawns `claude -p` with
# cwd=$CHAT_WORKSPACE_DIR. The templates are baked into the image at
# /var/chat/config-templates/ by the Dockerfile.
#
# Load Vault-templated secrets (if present) into env so the Bash allow-list
# and the forge-api MCP header substitution can reach them:
#   - FACTORY_FORGE_PAT  — Forge admin PAT (issue/PR CRUD via forge-api MCP)
#   - NOMAD_TOKEN        — scoped ACL token (namespace default, submit/read/list/logs)
#
# Files are expected under /secrets/ inside the caddy task (Vault template
# writes them there when the jobspec's `template` stanza is configured —
# see nomad/jobs/edge.hcl).
export CHAT_WORKSPACE_DIR="${CHAT_WORKSPACE_DIR:-/opt/disinto}"

_chat_install_settings() {
  local workspace="$1"
  [ -d "$workspace" ] || return 0
  mkdir -p "${workspace}/.claude"
  if [ -f /var/chat/config-templates/settings.json ]; then
    cp /var/chat/config-templates/settings.json "${workspace}/.claude/settings.json"
    echo "edge: installed chat settings.json -> ${workspace}/.claude/settings.json" >&2
  fi
  if [ -f /var/chat/config-templates/mcp.json ]; then
    cp /var/chat/config-templates/mcp.json "${workspace}/.mcp.json"
    echo "edge: installed chat .mcp.json -> ${workspace}/.mcp.json" >&2
  fi
  # Skills (#727): copy each /var/chat/skill-templates/<name>/ into
  # ${workspace}/.claude/skills/<name>/ so chat-Claude has its operator
  # skill set discoverable under CWD. Done at container start (not baked
  # into the image) so the workspace tree owns the installed copy.
  if [ -d /var/chat/skill-templates ]; then
    mkdir -p "${workspace}/.claude/skills"
    cp -R /var/chat/skill-templates/. "${workspace}/.claude/skills/"
    find "${workspace}/.claude/skills" -type f -name '*.sh' -exec chmod 0755 {} + 2>/dev/null || true
    echo "edge: installed chat skills -> ${workspace}/.claude/skills/" >&2
  fi
}

_chat_load_secret_file() {
  # $1 = env var name, $2 = file path
  local var="$1" path="$2"
  if [ -n "${!var:-}" ]; then
    # Already set (dev override) — leave it.
    return 0
  fi
  if [ -r "$path" ] && [ -s "$path" ]; then
    # shellcheck disable=SC2046  # single line, no IFS weirdness
    export "$var=$(tr -d '\r\n' < "$path")"
    echo "edge: loaded $var from $path" >&2
  fi
}

_chat_load_secret_file FACTORY_FORGE_PAT "${FACTORY_FORGE_PAT_FILE:-/secrets/forge-pat}"
_chat_load_secret_file NOMAD_TOKEN       "${NOMAD_TOKEN_FILE:-/secrets/nomad-token}"
export NOMAD_ADDR="${NOMAD_ADDR:-http://localhost:4646}"
_chat_install_settings "$CHAT_WORKSPACE_DIR"

# ── Ensure chat session dir ownership (issue #747) ───────────────────
# claude-code persists session state to ${CLAUDE_CONFIG_DIR}/projects/<cwd>/
# Historically chat spawned claude as root (pre-#743), leaving the session
# dir root-owned. After #743 drop-priv to agent, claude cannot write new
# sessions or resume existing ones — continuity is lost.
_chat_ensure_session_dir() {
  # Match _claude_session_flag's path encoding: cwd "/opt/disinto" -> "-opt-disinto"
  local encoded="${CHAT_WORKSPACE_DIR//\//-}"
  local dir="${CLAUDE_CONFIG_DIR:-}/projects/${encoded}"
  install -d -m 0750 -o agent -g agent "$dir" 2>/dev/null || true
  # Repair pre-existing root-owned files (idempotent, no-op once clean).
  chown -R agent:agent "$dir" 2>/dev/null || true
}
_chat_ensure_session_dir

# Start chat server in background (#1083 — merged from docker/chat into edge)
(python3 /usr/local/bin/chat-server.py 2>&1 | tee -a /opt/disinto-logs/chat.log) &

# ── Voice bridge (#662, parent #651) ──────────────────────────────────
# Gemini Live WebSocket bridge on 127.0.0.1:$VOICE_PORT. Caddy forwards
# /voice/ws here with X-Forwarded-User stamped by forward_auth (same
# OAuth gate as /chat/*). GEMINI_API_KEY is scoped to this subprocess
# only — we export it into the child env from the Vault-rendered file
# at $GEMINI_API_KEY_FILE and then unset it again from our own env so
# neither chat-server.py nor any `claude -p` child can inherit it.
#
# The key-from-file contract is documented in docs/voice/README.md and
# enforced by the env stanza in nomad/jobs/edge.hcl (which sets
# GEMINI_API_KEY_FILE but NEVER GEMINI_API_KEY on the task).
export VOICE_PORT="${VOICE_PORT:-8090}"
export VOICE_HOST="${VOICE_HOST:-127.0.0.1}"
(
  if [ -r "${GEMINI_API_KEY_FILE:-}" ] && [ -s "${GEMINI_API_KEY_FILE:-}" ]; then
    GEMINI_API_KEY="$(tr -d '\r\n' < "$GEMINI_API_KEY_FILE")"
    # Skip launch if the template has not been seeded yet — the file
    # will contain the sentinel "seed-me" until `disinto vault
    # reseed-voice` runs. Caddy will return 502 on /voice/ws which is
    # the expected pre-seed behavior.
    if [ -n "$GEMINI_API_KEY" ] && [ "$GEMINI_API_KEY" != "seed-me" ]; then
      export GEMINI_API_KEY
      exec /opt/voice-venv/bin/python3 /usr/local/bin/voice-bridge.py \
        2>&1 | tee -a /opt/disinto-logs/voice-bridge.log
    else
      echo "edge: voice bridge skipped — $GEMINI_API_KEY_FILE is unseeded" >&2
      sleep infinity
    fi
  else
    echo "edge: voice bridge skipped — GEMINI_API_KEY_FILE not readable" >&2
    sleep infinity
  fi
) &

# Nomad template renders Caddyfile to /local/Caddyfile via service discovery;
# copy it into the expected location if present (compose uses the mounted path).
if [ -f /local/Caddyfile ]; then
  cp /local/Caddyfile /etc/caddy/Caddyfile
  echo "edge: using Nomad-rendered Caddyfile from /local/Caddyfile" >&2
fi

# Caddy as main process — run in foreground via wait so background jobs survive
# (exec replaces the shell, which can orphan backgrounded subshells)
caddy run --config /etc/caddy/Caddyfile --adapter caddyfile &

# Exit when any child dies (caddy crash → container restart via docker compose)
wait -n
exit 1
