#!/usr/bin/env bash
set -euo pipefail

# entrypoint.sh — Start agent container with polling loop
#
# Runs as root inside the container.  Drops to agent user via gosu for all
# poll scripts.  All Docker Compose env vars are inherited (PATH, FORGE_TOKEN,
# ANTHROPIC_API_KEY, etc.).
#
# AGENT_ROLES env var controls which scripts run: "review,dev,gardener,architect,planner,predictor"
# (default: all six). Uses while-true loop with staggered intervals:
#   - review-poll: every 5 minutes (offset by 0s)
#   - dev-poll: every 5 minutes (offset by 2 minutes)
#   - gardener: every 6 hours (72 iterations * 5 min)
#   - architect: every 6 hours (same as gardener)
#   - planner: every 12 hours (144 iterations * 5 min)
#   - predictor: every 24 hours (288 iterations * 5 min)

DISINTO_DIR="/home/agent/disinto"
LOGFILE="/home/agent/data/agent-entrypoint.log"
mkdir -p /home/agent/data
chown agent:agent /home/agent/data

log() {
  printf '[%s] %s\n' "$(date -u '+%Y-%m-%d %H:%M:%S UTC')" "$*" | tee -a "$LOGFILE"
}

# Initialize state directory and files if they don't exist
init_state_dir() {
  local state_dir="${DISINTO_DIR}/state"
  mkdir -p "$state_dir"
  # Create empty state files so check_active guards work
  for agent in dev reviewer gardener architect planner predictor; do
    touch "$state_dir/.${agent}-active" 2>/dev/null || true
  done
  chown -R agent:agent "$state_dir"
  log "Initialized state directory"
}

# Configure git credential helper for password-based HTTP auth.
# Forgejo 11.x rejects API tokens for git push (#361); password auth works.
# This ensures all git operations (clone, fetch, push) from worktrees use
# password auth without needing tokens embedded in remote URLs.
configure_git_creds() {
  if [ -n "${FORGE_PASS:-}" ] && [ -n "${FORGE_URL:-}" ]; then
    _forge_host=$(printf '%s' "$FORGE_URL" | sed 's|https\?://||; s|/.*||')
    _forge_proto=$(printf '%s' "$FORGE_URL" | sed 's|://.*||')
    # Determine the bot username from FORGE_TOKEN identity (or default to dev-bot)
    _bot_user=$(curl -sf -H "Authorization: token ${FORGE_TOKEN}" \
      "${FORGE_URL}/api/v1/user" 2>/dev/null | jq -r '.login // empty') || _bot_user=""
    _bot_user="${_bot_user:-dev-bot}"

    # Write a static credential helper script (git credential protocol)
    cat > /home/agent/.git-credentials-helper <<CREDEOF
#!/bin/sh
# Auto-generated git credential helper for Forgejo password auth (#361)
# Only respond to "get" action; ignore "store" and "erase".
[ "\$1" = "get" ] || exit 0
# Read and discard stdin (git sends protocol/host info)
cat >/dev/null
echo "protocol=${_forge_proto}"
echo "host=${_forge_host}"
echo "username=${_bot_user}"
echo "password=${FORGE_PASS}"
CREDEOF
    chmod 755 /home/agent/.git-credentials-helper
    chown agent:agent /home/agent/.git-credentials-helper

    gosu agent bash -c "git config --global credential.helper '/home/agent/.git-credentials-helper'"
    log "Git credential helper configured for ${_bot_user}@${_forge_host} (password auth)"
  fi

  # Set safe.directory to work around dubious ownership after container restart
  # (https://github.com/disinto-admin/disinto/issues/517)
  gosu agent bash -c "git config --global --add safe.directory '*'"
}

# Configure tea CLI login for forge operations (runs as agent user).
# tea stores config in ~/.config/tea/ — persistent across container restarts
# only if that directory is on a mounted volume.
configure_tea_login() {
  if command -v tea &>/dev/null && [ -n "${FORGE_TOKEN:-}" ] && [ -n "${FORGE_URL:-}" ]; then
    local_tea_login="forgejo"
    case "$FORGE_URL" in
      *codeberg.org*) local_tea_login="codeberg" ;;
    esac
    gosu agent bash -c "tea login add \
      --name '${local_tea_login}' \
      --url '${FORGE_URL}' \
      --token '${FORGE_TOKEN}' \
      --no-version-check 2>/dev/null || true"
    log "tea login configured: ${local_tea_login} → ${FORGE_URL}"
  else
    log "tea login: skipped (tea not found or FORGE_TOKEN/FORGE_URL not set)"
  fi
}

log "Agent container starting"

# Set USER for scripts that source lib/env.sh (e.g., OPS_REPO_ROOT default)
export USER=agent

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

# Configure git and tea once at startup (as root, then drop to agent)
configure_git_creds
configure_tea_login

# Initialize state directory for check_active guards
init_state_dir

# Parse AGENT_ROLES env var (default: all agents)
# Expected format: comma-separated list like "review,dev,gardener"
AGENT_ROLES="${AGENT_ROLES:-review,dev,gardener,architect,planner,predictor}"
log "Agent roles configured: ${AGENT_ROLES}"

# Poll interval in seconds (5 minutes default)
POLL_INTERVAL="${POLL_INTERVAL:-300}"

log "Entering polling loop (interval: ${POLL_INTERVAL}s, roles: ${AGENT_ROLES})"

# Main polling loop using iteration counter for gardener scheduling
iteration=0
while true; do
  iteration=$((iteration + 1))
  now=$(date +%s)

  # Stale .sid cleanup — needed for agents that don't support --resume
  # Run this as the agent user
  gosu agent bash -c "rm -f /tmp/dev-session-*.sid /tmp/review-session-*.sid 2>/dev/null || true"

  # Poll each project TOML
  # Fast agents (review-poll, dev-poll) run in background so they don't block
  # each other.  Slow agents (gardener, architect, planner, predictor) also run
  # in background but are guarded by pgrep so only one instance runs at a time.
  # The flock on session.lock already serializes claude -p calls.
  for toml in "${DISINTO_DIR}"/projects/*.toml; do
    [ -f "$toml" ] || continue
    log "Processing project TOML: ${toml}"

    # --- Fast agents: run in background, wait before slow agents ---

    # Review poll (every iteration)
    if [[ ",${AGENT_ROLES}," == *",review,"* ]]; then
      log "Running review-poll (iteration ${iteration}) for ${toml}"
      gosu agent bash -c "cd ${DISINTO_DIR} && bash review/review-poll.sh \"${toml}\"" >> "${DISINTO_DIR}/../data/logs/review-poll.log" 2>&1 &
    fi

    sleep 2  # stagger fast polls

    # Dev poll (every iteration)
    if [[ ",${AGENT_ROLES}," == *",dev,"* ]]; then
      log "Running dev-poll (iteration ${iteration}) for ${toml}"
      gosu agent bash -c "cd ${DISINTO_DIR} && bash dev/dev-poll.sh \"${toml}\"" >> "${DISINTO_DIR}/../data/logs/dev-poll.log" 2>&1 &
    fi

    # Wait for fast polls to finish before launching slow agents
    wait

    # --- Slow agents: run in background with pgrep guard ---

    # Gardener (every 6 hours = 72 iterations * 5 min = 21600 seconds)
    if [[ ",${AGENT_ROLES}," == *",gardener,"* ]]; then
      gardener_iteration=$((iteration * POLL_INTERVAL))
      gardener_interval=$((6 * 60 * 60))  # 6 hours in seconds
      if [ $((gardener_iteration % gardener_interval)) -eq 0 ] && [ "$now" -ge "$gardener_iteration" ]; then
        if ! pgrep -f "gardener-run.sh" >/dev/null; then
          log "Running gardener (iteration ${iteration}, 6-hour interval) for ${toml}"
          gosu agent bash -c "cd ${DISINTO_DIR} && bash gardener/gardener-run.sh \"${toml}\"" >> "${DISINTO_DIR}/../data/logs/gardener.log" 2>&1 &
        else
          log "Skipping gardener — already running"
        fi
      fi
    fi

    # Architect (every 6 hours, same schedule as gardener)
    if [[ ",${AGENT_ROLES}," == *",architect,"* ]]; then
      architect_iteration=$((iteration * POLL_INTERVAL))
      architect_interval=$((6 * 60 * 60))  # 6 hours in seconds
      if [ $((architect_iteration % architect_interval)) -eq 0 ] && [ "$now" -ge "$architect_iteration" ]; then
        if ! pgrep -f "architect-run.sh" >/dev/null; then
          log "Running architect (iteration ${iteration}, 6-hour interval) for ${toml}"
          gosu agent bash -c "cd ${DISINTO_DIR} && bash architect/architect-run.sh \"${toml}\"" >> "${DISINTO_DIR}/../data/logs/architect.log" 2>&1 &
        else
          log "Skipping architect — already running"
        fi
      fi
    fi

    # Planner (every 12 hours = 144 iterations * 5 min = 43200 seconds)
    if [[ ",${AGENT_ROLES}," == *",planner,"* ]]; then
      planner_iteration=$((iteration * POLL_INTERVAL))
      planner_interval=$((12 * 60 * 60))  # 12 hours in seconds
      if [ $((planner_iteration % planner_interval)) -eq 0 ] && [ "$now" -ge "$planner_iteration" ]; then
        if ! pgrep -f "planner-run.sh" >/dev/null; then
          log "Running planner (iteration ${iteration}, 12-hour interval) for ${toml}"
          gosu agent bash -c "cd ${DISINTO_DIR} && bash planner/planner-run.sh \"${toml}\"" >> "${DISINTO_DIR}/../data/logs/planner.log" 2>&1 &
        else
          log "Skipping planner — already running"
        fi
      fi
    fi

    # Predictor (every 24 hours = 288 iterations * 5 min = 86400 seconds)
    if [[ ",${AGENT_ROLES}," == *",predictor,"* ]]; then
      predictor_iteration=$((iteration * POLL_INTERVAL))
      predictor_interval=$((24 * 60 * 60))  # 24 hours in seconds
      if [ $((predictor_iteration % predictor_interval)) -eq 0 ] && [ "$now" -ge "$predictor_iteration" ]; then
        if ! pgrep -f "predictor-run.sh" >/dev/null; then
          log "Running predictor (iteration ${iteration}, 24-hour interval) for ${toml}"
          gosu agent bash -c "cd ${DISINTO_DIR} && bash predictor/predictor-run.sh \"${toml}\"" >> "${DISINTO_DIR}/../data/logs/predictor.log" 2>&1 &
        else
          log "Skipping predictor — already running"
        fi
      fi
    fi
  done

  sleep "${POLL_INTERVAL}"
done
