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
#   - gardener: every GARDENER_INTERVAL seconds (default: 21600 = 6 hours)
#   - architect: every ARCHITECT_INTERVAL seconds (default: 21600 = 6 hours)
#   - planner: every 12 hours (144 iterations * 5 min)
#   - predictor: every 24 hours (288 iterations * 5 min)

DISINTO_BAKED="/home/agent/disinto"
DISINTO_LIVE="/home/agent/repos/_factory"
DISINTO_DIR="$DISINTO_BAKED"  # start with baked copy; switched to live checkout after bootstrap
LOGFILE="/home/agent/data/agent-entrypoint.log"

# Create all expected log subdirectories and set ownership as root before dropping to agent.
# This handles both fresh volumes and stale root-owned dirs from prior container runs.
mkdir -p /home/agent/data/logs/{dev,action,review,supervisor,vault,site,metrics,gardener,planner,predictor,architect,dispatcher}
chown -R agent:agent /home/agent/data

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

# Source shared git credential helper library (#604).
# shellcheck source=lib/git-creds.sh
source "${DISINTO_BAKED}/lib/git-creds.sh"

# Wrapper that calls the shared configure_git_creds with agent-specific paths,
# then repairs any legacy baked-credential URLs in existing clones.
_setup_git_creds() {
  configure_git_creds "/home/agent" "gosu agent"
  if [ -n "${FORGE_PASS:-}" ] && [ -n "${FORGE_URL:-}" ]; then
    log "Git credential helper configured (password auth)"
  fi

  # Repair legacy clones with baked-in stale credentials (#604).
  _GIT_CREDS_LOG_FN=log repair_baked_cred_urls --as "gosu agent" /home/agent/repos
}

# Configure git author identity for commits made by this container.
# Derives identity from the resolved bot user (BOT_USER) to ensure commits
# are visibly attributable to the correct bot in the forge timeline.
configure_git_identity() {
  # Resolve BOT_USER from FORGE_TOKEN if not already set
  if [ -z "${BOT_USER:-}" ] && [ -n "${FORGE_TOKEN:-}" ]; then
    BOT_USER=$(curl -sf --max-time 10 \
      -H "Authorization: token ${FORGE_TOKEN}" \
      "${FORGE_URL:-http://localhost:3000}/api/v1/user" 2>/dev/null | jq -r '.login // empty') || true
  fi

  # Default to dev-bot if resolution fails
  BOT_USER="${BOT_USER:-dev-bot}"

  # Configure git identity for all repositories
  gosu agent git config --global user.name "${BOT_USER}"
  gosu agent git config --global user.email "${BOT_USER}@disinto.local"

  log "Git identity configured: ${BOT_USER} <${BOT_USER}@disinto.local>"
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

# Set USER and HOME for scripts that source lib/env.sh.
# These are preconditions required by lib/env.sh's surface contract.
# gosu agent inherits the parent's env, so exports here propagate to all children.
export USER=agent
export HOME=/home/agent

# Source lib/env.sh to get DISINTO_LOG_DIR and other shared environment.
# This must happen after USER/HOME are set (env.sh preconditions).
# shellcheck source=lib/env.sh
source "${DISINTO_BAKED}/lib/env.sh"

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
elif [ -f "${CLAUDE_CONFIG_DIR:-/home/agent/.claude}/.credentials.json" ]; then
  log "Auth: OAuth credentials mounted from host (${CLAUDE_CONFIG_DIR:-~/.claude})"
else
  log "WARNING: No ANTHROPIC_API_KEY and no OAuth credentials found."
  log "Run 'claude auth login' on the host, or set ANTHROPIC_API_KEY in .env"
fi

# Bootstrap ops repos for each project TOML (#586).
# In compose mode the ops repo lives on a Docker named volume at
# /home/agent/repos/<project>-ops.  If init ran migrate_ops_repo on the host
# the container never saw those changes.  This function clones from forgejo
# when the repo is missing, or configures the remote and pulls when it exists
# but has no remote (orphaned local-only checkout).
bootstrap_ops_repos() {
  local repos_dir="/home/agent/repos"
  mkdir -p "$repos_dir"
  chown agent:agent "$repos_dir"

  for toml in "${DISINTO_DIR}"/projects/*.toml; do
    [ -f "$toml" ] || continue

    # Extract project name, ops repo slug, repo slug, and primary branch from TOML
    local project_name ops_slug primary_branch
    local _toml_vals
    _toml_vals=$(python3 -c "
import tomllib, sys
with open(sys.argv[1], 'rb') as f:
    cfg = tomllib.load(f)
print(cfg.get('name', ''))
print(cfg.get('ops_repo', ''))
print(cfg.get('repo', ''))
print(cfg.get('primary_branch', 'main'))
" "$toml" 2>/dev/null || true)

    project_name=$(sed -n '1p' <<< "$_toml_vals")
    [ -n "$project_name" ] || continue
    ops_slug=$(sed -n '2p' <<< "$_toml_vals")
    local repo_slug
    repo_slug=$(sed -n '3p' <<< "$_toml_vals")
    primary_branch=$(sed -n '4p' <<< "$_toml_vals")
    primary_branch="${primary_branch:-main}"

    # Fall back to convention if ops_repo not in TOML
    if [ -z "$ops_slug" ]; then
      if [ -n "$repo_slug" ]; then
        ops_slug="${repo_slug}-ops"
      else
        ops_slug="disinto-admin/${project_name}-ops"
      fi
    fi

    local ops_root="${repos_dir}/${project_name}-ops"
    local remote_url="${FORGE_URL}/${ops_slug}.git"

    if [ ! -d "${ops_root}/.git" ]; then
      # Clone ops repo from forgejo
      log "Ops bootstrap: cloning ${ops_slug} -> ${ops_root}"
      if gosu agent git clone --quiet "$remote_url" "$ops_root" 2>/dev/null; then
        log "Ops bootstrap: ${ops_slug} cloned successfully"
      else
        # Remote may not exist yet (first run before init); create empty repo
        log "Ops bootstrap: clone failed for ${ops_slug} — initializing empty repo"
        gosu agent bash -c "
          mkdir -p '${ops_root}' && \
          git -C '${ops_root}' init --initial-branch='${primary_branch}' -q && \
          git -C '${ops_root}' remote add origin '${remote_url}'
        "
      fi
    else
      # Repo exists — ensure remote is configured and pull latest
      local current_remote
      current_remote=$(git -C "$ops_root" remote get-url origin 2>/dev/null || true)
      if [ -z "$current_remote" ]; then
        log "Ops bootstrap: adding missing remote to ${ops_root}"
        gosu agent git -C "$ops_root" remote add origin "$remote_url"
      elif [ "$current_remote" != "$remote_url" ]; then
        log "Ops bootstrap: fixing remote URL in ${ops_root}"
        gosu agent git -C "$ops_root" remote set-url origin "$remote_url"
      fi
      # Pull latest from forgejo to pick up any host-side migrations
      log "Ops bootstrap: pulling latest for ${project_name}-ops"
      gosu agent bash -c "
        cd '${ops_root}' && \
        git fetch origin '${primary_branch}' --quiet 2>/dev/null && \
        git reset --hard 'origin/${primary_branch}' --quiet 2>/dev/null
      " || log "Ops bootstrap: pull failed for ${ops_slug} (remote may not exist yet)"
    fi
  done
}

# Bootstrap the factory (disinto) repo from Forgejo into the project-repos
# volume so the entrypoint runs from a live git checkout that receives
# updates via `git pull`, not the stale baked copy from `COPY .` (#593).
bootstrap_factory_repo() {
  local repo="${FACTORY_REPO:-}"
  if [ -z "$repo" ]; then
    log "Factory bootstrap: FACTORY_REPO not set — running from baked copy"
    return 0
  fi

  local remote_url="${FORGE_URL}/${repo}.git"
  local primary_branch="${PRIMARY_BRANCH:-main}"

  if [ ! -d "${DISINTO_LIVE}/.git" ]; then
    log "Factory bootstrap: cloning ${repo} -> ${DISINTO_LIVE}"
    if gosu agent git clone --quiet --branch "$primary_branch" "$remote_url" "$DISINTO_LIVE" 2>&1; then
      log "Factory bootstrap: cloned successfully"
    else
      log "Factory bootstrap: clone failed — running from baked copy"
      return 0
    fi
  else
    log "Factory bootstrap: pulling latest ${repo}"
    gosu agent bash -c "
      cd '${DISINTO_LIVE}' && \
      git fetch origin '${primary_branch}' --quiet 2>/dev/null && \
      git reset --hard 'origin/${primary_branch}' --quiet 2>/dev/null
    " || log "Factory bootstrap: pull failed — using existing checkout"
  fi

  # Copy project TOMLs from baked dir — they are gitignored AND docker-ignored,
  # so neither the image nor the clone normally contains them.  If the baked
  # copy has any (e.g. operator manually placed them), propagate them.
  if compgen -G "${DISINTO_BAKED}/projects/*.toml" >/dev/null 2>&1; then
    mkdir -p "${DISINTO_LIVE}/projects"
    cp "${DISINTO_BAKED}"/projects/*.toml "${DISINTO_LIVE}/projects/"
    chown -R agent:agent "${DISINTO_LIVE}/projects"
    log "Factory bootstrap: copied project TOMLs to live checkout"
  fi

  # Verify the live checkout has the expected structure
  if [ -f "${DISINTO_LIVE}/lib/env.sh" ]; then
    DISINTO_DIR="$DISINTO_LIVE"
    log "Factory bootstrap: DISINTO_DIR switched to live checkout at ${DISINTO_LIVE}"
  else
    log "Factory bootstrap: live checkout missing expected files — falling back to baked copy"
  fi
}

# Ensure the project repo is cloned on first run (#589).
# The agents container uses a named volume (project-repos) at /home/agent/repos.
# On first startup, if the project repo is missing, clone it from FORGE_URL/FORGE_REPO.
# This makes the agents container self-healing and independent of init's host clone.
ensure_project_clone() {
  # shellcheck disable=SC2153
  local repo_dir="/home/agent/repos/${PROJECT_NAME}"
  if [ -d "${repo_dir}/.git" ]; then
    log "Project repo present at ${repo_dir}"
    return 0
  fi
  if [ -z "${FORGE_REPO:-}" ] || [ -z "${FORGE_URL:-}" ]; then
    log "Cannot clone project repo: FORGE_REPO or FORGE_URL unset"
    return 1
  fi
  log "Cloning ${FORGE_URL}/${FORGE_REPO}.git -> ${repo_dir} (first run)"
  mkdir -p "$(dirname "$repo_dir")"
  chown -R agent:agent "$(dirname "$repo_dir")"
  if gosu agent git clone --quiet "${FORGE_URL}/${FORGE_REPO}.git" "$repo_dir"; then
    log "Project repo cloned"
  else
    log "Project repo clone failed — agents may fail until manually fixed"
    return 1
  fi
}

# Pull latest factory code at the start of each poll iteration (#593).
# Runs as the agent user; failures are non-fatal (stale code still works).
pull_factory_repo() {
  [ "$DISINTO_DIR" = "$DISINTO_LIVE" ] || return 0
  local primary_branch="${PRIMARY_BRANCH:-main}"
  gosu agent bash -c "
    cd '${DISINTO_LIVE}' && \
    git fetch origin '${primary_branch}' --quiet 2>/dev/null && \
    git reset --hard 'origin/${primary_branch}' --quiet 2>/dev/null
  " || log "Factory pull failed — continuing with current checkout"
}

# Configure git and tea once at startup (as root, then drop to agent)
_setup_git_creds
configure_git_identity
configure_tea_login

# Clone project repo on first run (makes agents self-healing, #589)
ensure_project_clone

# Bootstrap ops repos from forgejo into container volumes (#586)
bootstrap_ops_repos

# Bootstrap factory repo — switch DISINTO_DIR to live checkout (#593)
bootstrap_factory_repo

# Initialize state directory for check_active guards
init_state_dir

# Parse AGENT_ROLES env var (default: all agents)
# Expected format: comma-separated list like "review,dev,gardener"
AGENT_ROLES="${AGENT_ROLES:-review,dev,gardener,architect,planner,predictor}"
log "Agent roles configured: ${AGENT_ROLES}"

# Poll interval in seconds (5 minutes default)
POLL_INTERVAL="${POLL_INTERVAL:-300}"

# Gardener and architect intervals (default 6 hours = 21600 seconds)
GARDENER_INTERVAL="${GARDENER_INTERVAL:-21600}"
ARCHITECT_INTERVAL="${ARCHITECT_INTERVAL:-21600}"

log "Entering polling loop (interval: ${POLL_INTERVAL}s, roles: ${AGENT_ROLES})"
log "Gardener interval: ${GARDENER_INTERVAL}s, Architect interval: ${ARCHITECT_INTERVAL}s"

# Main polling loop using iteration counter for gardener scheduling
iteration=0
while true; do
  iteration=$((iteration + 1))
  now=$(date +%s)

  # Pull latest factory code so poll scripts stay current (#593)
  pull_factory_repo

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

    # Parse project name and primary branch from TOML so env.sh preconditions
    # are satisfied when agent scripts source it (#674).
    _toml_vals=$(python3 -c "
import tomllib, sys
with open(sys.argv[1], 'rb') as f:
    cfg = tomllib.load(f)
print(cfg.get('name', ''))
print(cfg.get('primary_branch', 'main'))
" "$toml" 2>/dev/null || true)
    _pname=$(sed -n '1p' <<< "$_toml_vals")
    _pbranch=$(sed -n '2p' <<< "$_toml_vals")
    [ -n "$_pname" ] || { log "WARNING: could not parse project name from ${toml} — skipping"; continue; }

    export PROJECT_NAME="$_pname"
    export PROJECT_REPO_ROOT="/home/agent/repos/${_pname}"
    export OPS_REPO_ROOT="/home/agent/repos/${_pname}-ops"
    export PRIMARY_BRANCH="${_pbranch:-main}"

    log "Processing project TOML: ${toml}"

    # --- Fast agents: run in background, wait before slow agents ---

    # Review poll (every iteration)
    if [[ ",${AGENT_ROLES}," == *",review,"* ]]; then
      log "Running review-poll (iteration ${iteration}) for ${toml}"
      gosu agent bash -c "cd ${DISINTO_DIR} && bash review/review-poll.sh \"${toml}\"" >> "${DISINTO_LOG_DIR}/review-poll.log" 2>&1 &
    fi

    sleep 2  # stagger fast polls

    # Dev poll (every iteration)
    if [[ ",${AGENT_ROLES}," == *",dev,"* ]]; then
      log "Running dev-poll (iteration ${iteration}) for ${toml}"
      gosu agent bash -c "cd ${DISINTO_DIR} && bash dev/dev-poll.sh \"${toml}\"" >> "${DISINTO_LOG_DIR}/dev-poll.log" 2>&1 &
    fi

    # Wait for fast polls to finish before launching slow agents
    wait

    # --- Slow agents: run in background with pgrep guard ---

    # Gardener (interval configurable via GARDENER_INTERVAL env var)
    if [[ ",${AGENT_ROLES}," == *",gardener,"* ]]; then
      gardener_iteration=$((iteration * POLL_INTERVAL))
      if [ $((gardener_iteration % GARDENER_INTERVAL)) -eq 0 ] && [ "$now" -ge "$gardener_iteration" ]; then
        if ! pgrep -f "gardener-run.sh" >/dev/null; then
          log "Running gardener (iteration ${iteration}, ${GARDENER_INTERVAL}s interval) for ${toml}"
          gosu agent bash -c "cd ${DISINTO_DIR} && bash gardener/gardener-run.sh \"${toml}\"" >> "${DISINTO_LOG_DIR}/gardener.log" 2>&1 &
        else
          log "Skipping gardener — already running"
        fi
      fi
    fi

    # Architect (interval configurable via ARCHITECT_INTERVAL env var)
    if [[ ",${AGENT_ROLES}," == *",architect,"* ]]; then
      architect_iteration=$((iteration * POLL_INTERVAL))
      if [ $((architect_iteration % ARCHITECT_INTERVAL)) -eq 0 ] && [ "$now" -ge "$architect_iteration" ]; then
        if ! pgrep -f "architect-run.sh" >/dev/null; then
          log "Running architect (iteration ${iteration}, ${ARCHITECT_INTERVAL}s interval) for ${toml}"
          gosu agent bash -c "cd ${DISINTO_DIR} && bash architect/architect-run.sh \"${toml}\"" >> "${DISINTO_LOG_DIR}/architect.log" 2>&1 &
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
          gosu agent bash -c "cd ${DISINTO_DIR} && bash planner/planner-run.sh \"${toml}\"" >> "${DISINTO_LOG_DIR}/planner.log" 2>&1 &
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
          gosu agent bash -c "cd ${DISINTO_DIR} && bash predictor/predictor-run.sh \"${toml}\"" >> "${DISINTO_LOG_DIR}/predictor.log" 2>&1 &
        else
          log "Skipping predictor — already running"
        fi
      fi
    fi
  done

  sleep "${POLL_INTERVAL}"
done
