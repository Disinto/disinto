#!/usr/bin/env bash
set -euo pipefail

# entrypoint.sh — Start agent container with polling loop
#
# Runs as root inside the container.  Drops to agent user via gosu for all
# poll scripts.  All Docker Compose env vars are inherited (PATH, FORGE_TOKEN,
# ANTHROPIC_API_KEY, etc.).
#
# AGENT_ROLES env var controls which scripts run: "review,dev,gardener,architect,planner,predictor,supervisor"
# (default: all seven). Uses while-true loop with staggered intervals:
#   - review-poll: every 5 minutes (offset by 0s)
#   - dev-poll: every 5 minutes (offset by 2 minutes)
#   - gardener: every iteration (per-iteration step driver, #872 — single
#     task per cycle, llama-friendly; previously every GARDENER_INTERVAL
#     seconds in monolithic batch mode, now obsolete)
#   - architect: every ARCHITECT_INTERVAL seconds (default: 900 = 15 minutes)
#   - planner: every PLANNER_INTERVAL seconds (default: 43200 = 12 hours)
#   - predictor: every 24 hours (288 iterations * 5 min)
#   - supervisor: every SUPERVISOR_INTERVAL seconds (default: 1200 = 20 min)

# ── Migration check: reject ENABLE_LLAMA_AGENT ───────────────────────────────
# #846: The legacy ENABLE_LLAMA_AGENT env flag is no longer supported.
# Activation is now done exclusively via [agents.X] sections in project TOML.
# If this legacy flag is detected, fail immediately with a migration message.
if [ "${ENABLE_LLAMA_AGENT:-}" = "1" ]; then
  cat <<'MIGRATION_ERR'
FATAL: ENABLE_LLAMA_AGENT is no longer supported.

The legacy ENABLE_LLAMA_AGENT=1 flag has been removed (#846).
Activation is now done exclusively via [agents.X] sections in projects/*.toml.

To migrate:
  1. Remove ENABLE_LLAMA_AGENT from your .env or .env.enc file
  2. Add an [agents.<name>] section to your project TOML:

     [agents.dev-qwen]
     base_url = "http://your-llama-server:8081"
     model = "unsloth/Qwen3.5-35B-A3B"
     api_key = "sk-no-key-required"
     roles = ["dev"]
     forge_user = "dev-qwen"
     compact_pct = 60
     poll_interval = 60

  3. Run: disinto init
  4. Start the agent: docker compose up -d agents-dev-qwen

See docs/agents-llama.md for full details.
MIGRATION_ERR
  exit 1
fi

DISINTO_BAKED="/home/agent/disinto"
DISINTO_LIVE="/home/agent/repos/_factory"
DISINTO_DIR="$DISINTO_BAKED"  # start with baked copy; switched to live checkout after bootstrap
LOGFILE="/home/agent/data/agent-entrypoint.log"

# Create all expected log subdirectories and set ownership as root before dropping to agent.
# This handles both fresh volumes and stale root-owned dirs from prior container runs.
# Tighten perms (#910): formula sub-session JSONL transcripts may contain
# tool_result stdout that echoes loaded env (FORGE_*_TOKEN, etc.). umask
# 077 ensures both subdirs and any log files we create after this point
# are agent-only readable; the find sweeps fix stale 644 from previous
# container runs (umask 022 default).
umask 077
mkdir -p /home/agent/data/logs/{dev,action,review,supervisor,vault,site,metrics,gardener,planner,predictor,architect,dispatcher}
chown -R agent:agent /home/agent/data
chmod 700 /home/agent/data/logs 2>/dev/null || true
find /home/agent/data/logs -mindepth 1 -type d -exec chmod 700 {} + 2>/dev/null || true
find /home/agent/data/logs -type f -exec chmod 600 {} + 2>/dev/null || true

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
  _GIT_CREDS_LOG_FN=log configure_git_creds "/home/agent" "gosu agent"
  if [ -n "${FORGE_PASS:-}" ] && [ -n "${FORGE_URL:-}" ]; then
    log "Git credential helper configured (password auth)"
  fi

  # Repair legacy clones with baked-in stale credentials (#604).
  _GIT_CREDS_LOG_FN=log repair_baked_cred_urls --as "gosu agent" /home/agent/repos
}

# Configure git author identity for commits made by this container.
# Derives identity from the resolved bot user (BOT_USER) to ensure commits
# are visibly attributable to the correct bot in the forge timeline.
# BOT_USER is normally set by configure_git_creds() (#741); this function
# only falls back to its own API call if BOT_USER was not already resolved.
configure_git_identity() {
  # Resolve BOT_USER from FORGE_TOKEN if not already set (configure_git_creds
  # exports BOT_USER on success, so this is a fallback for edge cases only).
  if [ -z "${BOT_USER:-}" ] && [ -n "${FORGE_TOKEN:-}" ]; then
    BOT_USER=$(forge_whoami)
  fi

  if [ -z "${BOT_USER:-}" ]; then
    log "WARNING: Could not resolve bot username for git identity — commits will use fallback"
    BOT_USER="agent"
  fi

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
    # NOTE: --no-version-check was dropped (#733) — the bundled tea version
    # rejects the flag and exits non-zero, which under set -euo pipefail in
    # callers would crash. The version-check warning is cosmetic; tea login
    # add succeeds without it.
    gosu agent bash -c "tea login add \
      --name '${local_tea_login}' \
      --url '${FORGE_URL}' \
      --token '${FORGE_TOKEN}' 2>/dev/null || true"
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

# Claude CLI auth gate (#733). Roles like the edge dispatcher reuse this image
# but never invoke claude — they only poll the ops repo. The auth check would
# spuriously trip them. Set AGENT_REQUIRES_CLAUDE=0 in those task blocks to
# skip the gate; default (unset / non-zero) preserves the legacy behavior
# expected by review/architect/dev/etc.
if [ "${AGENT_REQUIRES_CLAUDE:-1}" != "0" ]; then
  # Verify Claude CLI is available (expected via volume mount from host).
  if ! command -v claude &>/dev/null; then
    log "FATAL: claude CLI not found in PATH."
    log "Mount the host binary into the container, e.g.:"
    log "  volumes:"
    log "    - /usr/local/bin/claude:/usr/local/bin/claude:ro"
    exit 1
  fi
  log "Claude CLI: $(claude --version 2>&1 || true)"

  # Ensure CLAUDE_CONFIG_DIR exists before Claude runs (issue #579).
  # Setting CLAUDE_CONFIG_DIR to a missing path causes Claude to silently
  # hang at turn zero — 0 bytes stdout, no llama calls, no error, until
  # CLAUDE_TIMEOUT fires. bin/disinto's setup_claude_config_dir() creates
  # this on the host side during `disinto init`, but on Nomad the agents
  # alloc runs the container cold without that setup ever executing.
  if [ -n "${CLAUDE_CONFIG_DIR:-}" ] && [ ! -d "$CLAUDE_CONFIG_DIR" ]; then
    log "Creating CLAUDE_CONFIG_DIR=${CLAUDE_CONFIG_DIR} (missing)"
    install -d -m 0700 -o agent -g agent "$CLAUDE_CONFIG_DIR" \
      || log "WARNING: failed to create $CLAUDE_CONFIG_DIR — Claude may hang"
  fi

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
else
  log "Claude auth gate: skipped (AGENT_REQUIRES_CLAUDE=0)"
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
        # Remote may not exist yet (first run before init); create empty repo.
        # Use idempotent remote setup so a partially-initialized volume from
        # a prior failed run doesn't crash with "remote origin already exists"
        # (#733).
        log "Ops bootstrap: clone failed for ${ops_slug} — initializing empty repo"
        # Pass TOML-derived values via environment, not via outer-shell string
        # expansion into `bash -c`, so shell metacharacters in TOML values
        # cannot escape into the command (#738).
        gosu agent env \
          OPS_ROOT="$ops_root" \
          PRIMARY_BRANCH="$primary_branch" \
          REMOTE_URL="$remote_url" \
          bash -s <<'EOF'
          mkdir -p "$OPS_ROOT" && \
          git -C "$OPS_ROOT" init --initial-branch="$PRIMARY_BRANCH" -q && \
          ( git -C "$OPS_ROOT" remote | grep -qx origin \
              || git -C "$OPS_ROOT" remote add origin "$REMOTE_URL" ) && \
          git -C "$OPS_ROOT" remote set-url origin "$REMOTE_URL"
EOF
      fi
    else
      # Repo exists — ensure remote is configured and pull latest.
      # Use `git remote` listing (not get-url) for the existence check —
      # get-url can return empty in edge cases (legacy config, permissions
      # quirks under gosu) while origin is actually defined, which previously
      # caused a non-idempotent `git remote add` crash on every restart (#733).
      if ! gosu agent git -C "$ops_root" remote | grep -qx origin; then
        log "Ops bootstrap: adding missing remote to ${ops_root}"
        gosu agent git -C "$ops_root" remote add origin "$remote_url"
      fi
      # Always reconcile the URL — cheap and idempotent.
      gosu agent git -C "$ops_root" remote set-url origin "$remote_url"
      # Pull latest from forgejo to pick up any host-side migrations
      log "Ops bootstrap: pulling latest for ${project_name}-ops"
      # See #738 — pass values via env to avoid outer-shell expansion into bash -c.
      gosu agent env \
        OPS_ROOT="$ops_root" \
        PRIMARY_BRANCH="$primary_branch" \
        bash -s <<'EOF' || log "Ops bootstrap: pull failed for ${ops_slug} (remote may not exist yet)"
        cd "$OPS_ROOT" && \
        git fetch origin "$PRIMARY_BRANCH" --quiet 2>/dev/null && \
        git reset --hard "origin/$PRIMARY_BRANCH" --quiet 2>/dev/null
EOF
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
    # See #738 — pass branch via env to avoid outer-shell expansion into bash -c.
    gosu agent env \
      DISINTO_LIVE="$DISINTO_LIVE" \
      PRIMARY_BRANCH="$primary_branch" \
      bash -s <<'EOF' || log "Factory bootstrap: pull failed — using existing checkout"
      cd "$DISINTO_LIVE" && \
      git fetch origin "$PRIMARY_BRANCH" --quiet 2>/dev/null && \
      git reset --hard "origin/$PRIMARY_BRANCH" --quiet 2>/dev/null
EOF
  fi

  # Copy project TOMLs from baked dir — they are gitignored AND docker-ignored,
  # so neither the image nor the clone normally contains them.  If the baked
  # copy has any (e.g. operator manually placed them), propagate them.
  if compgen -G "${DISINTO_BAKED}/projects/*.toml" >/dev/null 2>&1; then
    mkdir -p "${DISINTO_LIVE}/projects"
    cp "${DISINTO_BAKED}"/projects/*.toml "${DISINTO_LIVE}/projects/"
    chown -R agent:agent "${DISINTO_LIVE}/projects"
    log "Factory bootstrap: copied project TOMLs from baked copy to live checkout"
  fi

  # Also copy from host-volume path (/srv/disinto/project-repos/_factory/)
  # where disinto init --backend=nomad seeds default TOMLs (#574).
  local host_projects="/srv/disinto/project-repos/_factory/projects"
  if [ -d "$host_projects" ]; then
    mkdir -p "${DISINTO_LIVE}/projects"
    local copied=false
    for toml in "${host_projects}"/*.toml; do
      [ -f "$toml" ] || continue
      cp "$toml" "${DISINTO_LIVE}/projects/"
      copied=true
    done
    if [ "$copied" = true ]; then
      chown -R agent:agent "${DISINTO_LIVE}/projects"
      log "Factory bootstrap: copied project TOMLs from host volume to live checkout"
    fi
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
  # See #738 — pass branch via env to avoid outer-shell expansion into bash -c.
  gosu agent env \
    DISINTO_LIVE="$DISINTO_LIVE" \
    PRIMARY_BRANCH="$primary_branch" \
    bash -s <<'EOF' || log "Factory pull failed — continuing with current checkout"
    cd "$DISINTO_LIVE" && \
    git fetch origin "$PRIMARY_BRANCH" --quiet 2>/dev/null && \
    git reset --hard "origin/$PRIMARY_BRANCH" --quiet 2>/dev/null
EOF
}

# Configure git and tea once at startup (as root, then drop to agent)
_setup_git_creds
configure_git_identity
configure_tea_login

# Parse first available project TOML to get the project name for cloning.
# This ensures PROJECT_NAME matches the TOML 'name' field, not the compose
# default of 'project'. The clone will land at /home/agent/repos/<toml_name>
# and subsequent env exports in the main loop will be consistent.
if compgen -G "${DISINTO_DIR}/projects/*.toml" >/dev/null 2>&1; then
  _first_toml=$(compgen -G "${DISINTO_DIR}/projects/*.toml" | head -1)
  _pname=$(python3 -c "
import sys, tomllib
with open(sys.argv[1], 'rb') as f:
    print(tomllib.load(f).get('name', ''))
" "$_first_toml" 2>/dev/null) || _pname=""
  if [ -n "$_pname" ]; then
    export PROJECT_NAME="$_pname"
    export PROJECT_REPO_ROOT="/home/agent/repos/${_pname}"
    log "Parsed PROJECT_NAME=${PROJECT_NAME} from ${_first_toml}"
  fi
fi

# Clone project repo on first run (makes agents self-healing, #589)
ensure_project_clone

# Bootstrap ops repos from forgejo into container volumes (#586)
bootstrap_ops_repos

# Bootstrap factory repo — switch DISINTO_DIR to live checkout (#593)
bootstrap_factory_repo

# Copy project TOMLs from the factory-projects host_volume mount into
# DISINTO_DIR/projects/ so validate_projects_dir succeeds even when
# FACTORY_REPO is unset and bootstrap_factory_repo returned early without
# switching DISINTO_DIR to the live checkout (#794).
#
# Operator-managed per-env config lives at /srv/disinto/projects/ on the host
# and is mounted RO into the container at the path below via the
# `factory-projects` Nomad host_volume. This mirrors the copy already done in
# bootstrap_factory_repo's success path, but runs unconditionally so the
# baked-image fallback path is no longer fatal.
seed_projects_from_host_volume() {
  local host_projects="/srv/disinto/project-repos/_factory/projects"
  [ -d "$host_projects" ] || return 0
  if ! compgen -G "${host_projects}/*.toml" >/dev/null 2>&1; then
    return 0
  fi
  mkdir -p "${DISINTO_DIR}/projects"
  cp "${host_projects}"/*.toml "${DISINTO_DIR}/projects/" 2>/dev/null || true
  chown -R agent:agent "${DISINTO_DIR}/projects" 2>/dev/null || true
  log "Seeded ${DISINTO_DIR}/projects from host volume ${host_projects} (#794)"
}

# Validate that projects directory has at least one real .toml file (not .example)
# This prevents the silent-zombie mode where the polling loop matches zero files
# and does nothing forever.
validate_projects_dir() {
  # NOTE: compgen -G exits non-zero when no matches exist, so piping it through
  # `wc -l` under `set -eo pipefail` aborts the script before the FATAL branch
  # can log a diagnostic (#877).  Use the conditional form already adopted at
  # lines above (see bootstrap_factory_repo, PROJECT_NAME parsing).
  if ! compgen -G "${DISINTO_DIR}/projects/*.toml" >/dev/null 2>&1; then
    # Graceful degrade (#794): if the factory-projects host_volume is mounted
    # and contains TOMLs, seed_projects_from_host_volume should already have
    # populated DISINTO_DIR. Reaching here means neither path produced any
    # real config — that is genuinely fatal.
    log "FATAL: No real .toml files found in ${DISINTO_DIR}/projects/"
    log "Expected at least one project config file (e.g., disinto.toml)"
    log "The directory only contains *.toml.example template files."
    log "Populate /srv/disinto/projects/ on the host (mounted via the"
    log "factory-projects host_volume) or set FACTORY_REPO to clone a"
    log "checkout with project TOMLs."
    exit 1
  fi
  local toml_count
  toml_count=$(compgen -G "${DISINTO_DIR}/projects/*.toml" | wc -l)
  log "Projects directory validated: ${toml_count} real .toml file(s) found"
}

# Initialize state directory for check_active guards
init_state_dir

# Seed projects from factory-projects host_volume — runs after both bootstrap
# paths so it covers the FACTORY_REPO-unset / clone-failed cases too (#794).
seed_projects_from_host_volume

# Validate projects directory before entering polling loop
validate_projects_dir

# Parse AGENT_ROLES env var (default: all agents)
# Expected format: comma-separated list like "review,dev,gardener"
AGENT_ROLES="${AGENT_ROLES:-review,dev,gardener,architect,planner,predictor,supervisor}"
log "Agent roles configured: ${AGENT_ROLES}"

# Poll interval in seconds (5 minutes default)
POLL_INTERVAL="${POLL_INTERVAL:-300}"

# Architect / planner / supervisor intervals.
# GARDENER_INTERVAL was dropped in #872 — gardener now runs every iteration
# via gardener/gardener-step.sh (single task per cycle, paced by POLL_INTERVAL).
ARCHITECT_INTERVAL="${ARCHITECT_INTERVAL:-900}"
PLANNER_INTERVAL="${PLANNER_INTERVAL:-43200}"
SUPERVISOR_INTERVAL="${SUPERVISOR_INTERVAL:-1200}"

log "Entering polling loop (interval: ${POLL_INTERVAL}s, roles: ${AGENT_ROLES})"
log "Architect interval: ${ARCHITECT_INTERVAL}s, Planner interval: ${PLANNER_INTERVAL}s, Supervisor interval: ${SUPERVISOR_INTERVAL}s"

# Main polling loop. Iteration counter paces architect/planner/predictor/
# supervisor (modulo their intervals); gardener and review/dev run every tick.
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
  # Per-session CLAUDE_CONFIG_DIR isolation handles OAuth concurrency natively.
  # Set CLAUDE_EXTERNAL_LOCK=1 to re-enable the legacy flock serialization.
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
    FAST_PIDS=()

    # Review poll (every iteration)
    if [[ ",${AGENT_ROLES}," == *",review,"* ]]; then
      log "Running review-poll (iteration ${iteration}) for ${toml}"
      gosu agent bash -c "cd ${DISINTO_DIR} && bash review/review-poll.sh \"${toml}\"" >> "${DISINTO_LOG_DIR}/review-poll.log" 2>&1 &
      FAST_PIDS+=($!)
    fi

    sleep 2  # stagger fast polls

    # Dev poll (every iteration)
    if [[ ",${AGENT_ROLES}," == *",dev,"* ]]; then
      log "Running dev-poll (iteration ${iteration}) for ${toml}"
      gosu agent bash -c "cd ${DISINTO_DIR} && bash dev/dev-poll.sh \"${toml}\"" >> "${DISINTO_LOG_DIR}/dev-poll.log" 2>&1 &
      FAST_PIDS+=($!)
    fi

    # Wait only for THIS iteration's fast polls — long-running gardener/dev-agent
    # from prior iterations must not block us.
    if [ ${#FAST_PIDS[@]} -gt 0 ]; then
      wait "${FAST_PIDS[@]}"
    fi

    # Gardener (per-iteration step driver, #872 — single task per cycle).
    # Runs alongside dev-poll/review-poll on every loop tick. The script's
    # own flock guards against overlap; the pgrep check is a cheap belt-and-
    # braces skip to avoid the gosu/source overhead when a step is already
    # in flight.
    if [[ ",${AGENT_ROLES}," == *",gardener,"* ]]; then
      if ! pgrep -f "gardener-step.sh" >/dev/null; then
        log "Running gardener-step (iteration ${iteration}) for ${toml}"
        gosu agent bash -c "cd ${DISINTO_DIR} && bash gardener/gardener-step.sh \"${toml}\"" >> "${DISINTO_LOG_DIR}/gardener/step.log" 2>&1 &
      else
        log "Skipping gardener-step — previous step still in flight"
      fi
    fi

    # --- Slow agents: run in background with pgrep guard ---

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

    # Planner (interval configurable via PLANNER_INTERVAL env var)
    if [[ ",${AGENT_ROLES}," == *",planner,"* ]]; then
      planner_iteration=$((iteration * POLL_INTERVAL))
      if [ $((planner_iteration % PLANNER_INTERVAL)) -eq 0 ] && [ "$now" -ge "$planner_iteration" ]; then
        if ! pgrep -f "planner-run.sh" >/dev/null; then
          log "Running planner (iteration ${iteration}, ${PLANNER_INTERVAL}s interval) for ${toml}"
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

    # Supervisor (interval configurable via SUPERVISOR_INTERVAL env var, default 20 min)
    if [[ ",${AGENT_ROLES}," == *",supervisor,"* ]]; then
      supervisor_iteration=$((iteration * POLL_INTERVAL))
      if [ $((supervisor_iteration % SUPERVISOR_INTERVAL)) -eq 0 ] && [ "$now" -ge "$supervisor_iteration" ]; then
        if ! pgrep -f "supervisor-run.sh" >/dev/null; then
          log "Running supervisor (iteration ${iteration}, ${SUPERVISOR_INTERVAL}s interval) for ${toml}"
          gosu agent bash -c "cd ${DISINTO_DIR} && bash supervisor/supervisor-run.sh \"${toml}\"" >> "${DISINTO_LOG_DIR}/supervisor/supervisor.log" 2>&1 &
        else
          log "Skipping supervisor — already running"
        fi
      fi
    fi
  done

  sleep "${POLL_INTERVAL}"
done
