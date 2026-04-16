#!/usr/bin/env bash
# load-project.sh — Load project config from a TOML file into env vars
#
# Usage (source, don't execute):
#   source lib/load-project.sh projects/harb.toml
#
# Exports:
#   PROJECT_NAME, FORGE_REPO, FORGE_API, FORGE_WEB, FORGE_URL,
#   PROJECT_REPO_ROOT, PRIMARY_BRANCH, WOODPECKER_REPO_ID,
#   PROJECT_CONTAINERS, CHECK_PRS, CHECK_DEV_AGENT,
#   CHECK_PIPELINE_STALL, CI_STALE_MINUTES,
#   MIRROR_NAMES, MIRROR_URLS, MIRROR_<NAME> (per configured mirror)
#
# If no argument given, does nothing (allows poll scripts to work with
# plain .env fallback for backwards compatibility).

_PROJECT_TOML="${1:-}"

if [ -z "$_PROJECT_TOML" ] || [ ! -f "$_PROJECT_TOML" ]; then
  return 0 2>/dev/null || exit 0
fi

# Parse TOML to shell variable assignments via Python
_PROJECT_VARS=$(python3 -c "
import sys, tomllib

with open(sys.argv[1], 'rb') as f:
    cfg = tomllib.load(f)

def emit(key, val):
    if isinstance(val, bool):
        print(f'{key}={str(val).lower()}')
    elif isinstance(val, list):
        print(f'{key}={\" \".join(str(v) for v in val)}')
    else:
        print(f'{key}={val}')

# Top-level
emit('PROJECT_NAME', cfg.get('name', ''))
emit('FORGE_REPO', cfg.get('repo', ''))
emit('FORGE_URL', cfg.get('forge_url', ''))

if 'repo_root' in cfg:
    emit('PROJECT_REPO_ROOT', cfg['repo_root'])
if 'ops_repo_root' in cfg:
    emit('OPS_REPO_ROOT', cfg['ops_repo_root'])
if 'ops_repo' in cfg:
    emit('FORGE_OPS_REPO', cfg['ops_repo'])
if 'primary_branch' in cfg:
    emit('PRIMARY_BRANCH', cfg['primary_branch'])

# [ci] section
ci = cfg.get('ci', {})
if 'woodpecker_repo_id' in ci:
    emit('WOODPECKER_REPO_ID', ci['woodpecker_repo_id'])
if 'stale_minutes' in ci:
    emit('CI_STALE_MINUTES', ci['stale_minutes'])

# [services] section
svc = cfg.get('services', {})
if 'containers' in svc:
    emit('PROJECT_CONTAINERS', svc['containers'])

# [monitoring] section
mon = cfg.get('monitoring', {})
for key in ['check_prs', 'check_dev_agent', 'check_pipeline_stall']:
    if key in mon:
        emit(key.upper(), mon[key])

# [mirrors] section
mirrors = cfg.get('mirrors', {})
for name, url in mirrors.items():
    emit(f'MIRROR_{name.upper()}', url)
if mirrors:
    emit('MIRROR_NAMES', list(mirrors.keys()))
    emit('MIRROR_URLS', list(mirrors.values()))
" "$_PROJECT_TOML" 2>/dev/null) || {
  echo "WARNING: failed to parse project TOML: $_PROJECT_TOML" >&2
  return 1 2>/dev/null || exit 1
}

# Export parsed variables.
# Inside the agents container (DISINTO_CONTAINER=1), compose already sets the
# correct FORGE_URL (http://forgejo:3000) and path vars for the container
# environment.  The TOML carries host-perspective values (localhost, /home/admin/…)
# that would break container API calls and path resolution.  Skip overriding
# any env var that is already set when running inside the container.
while IFS='=' read -r _key _val; do
  [ -z "$_key" ] && continue
  if [ "${DISINTO_CONTAINER:-}" = "1" ] && [ -n "${!_key:-}" ]; then
    continue
  fi
  export "$_key=$_val"
done <<< "$_PROJECT_VARS"

# Derive FORGE_API and FORGE_WEB from forge_url + repo
# FORGE_URL: TOML forge_url > existing FORGE_URL > default
export FORGE_URL="${FORGE_URL:-http://localhost:3000}"
if [ -n "$FORGE_REPO" ]; then
  export FORGE_API_BASE="${FORGE_URL}/api/v1"
  export FORGE_API="${FORGE_API_BASE}/repos/${FORGE_REPO}"
  export FORGE_WEB="${FORGE_URL}/${FORGE_REPO}"
  # Extract repo owner (first path segment of owner/repo)
  export FORGE_REPO_OWNER="${FORGE_REPO%%/*}"
fi

# PROJECT_REPO_ROOT and OPS_REPO_ROOT: no fallback derivation from USER/HOME.
# These must be set by the entrypoint (container) or the TOML (host CLI).
# Inside the container, the entrypoint exports the correct paths before agent
# scripts source env.sh; the TOML's host-perspective paths are skipped by the
# DISINTO_CONTAINER guard above.

# Derive FORGE_OPS_REPO if not explicitly set
if [ -z "${FORGE_OPS_REPO:-}" ] && [ -n "${FORGE_REPO:-}" ]; then
  export FORGE_OPS_REPO="${FORGE_REPO}-ops"
fi

# Parse [agents.*] sections for local-model agents
# Exports AGENT_<NAME>_BASE_URL, AGENT_<NAME>_MODEL, AGENT_<NAME>_API_KEY,
# AGENT_<NAME>_ROLES, AGENT_<NAME>_FORGE_USER, AGENT_<NAME>_COMPACT_PCT
if command -v python3 &>/dev/null; then
  _AGENT_VARS=$(python3 -c "
import sys, tomllib

with open(sys.argv[1], 'rb') as f:
    cfg = tomllib.load(f)

agents = cfg.get('agents', {})
for name, config in agents.items():
    if not isinstance(config, dict):
        continue
    # Normalize the TOML section key into a valid shell identifier fragment.
    # TOML allows dashes in bare keys (e.g. [agents.dev-qwen2]), but POSIX
    # shell var names cannot contain '-'. Match the 'tr a-z- A-Z_' convention
    # used in hire-agent.sh (#834) and generators.sh (#852) so the var names
    # stay consistent across the stack.
    safe = name.upper().replace('-', '_')
    # Emit variables in uppercase with the agent name
    if 'base_url' in config:
        print(f'AGENT_{safe}_BASE_URL={config[\"base_url\"]}')
    if 'model' in config:
        print(f'AGENT_{safe}_MODEL={config[\"model\"]}')
    if 'api_key' in config:
        print(f'AGENT_{safe}_API_KEY={config[\"api_key\"]}')
    if 'roles' in config:
        roles = ' '.join(config['roles']) if isinstance(config['roles'], list) else config['roles']
        print(f'AGENT_{safe}_ROLES={roles}')
    if 'forge_user' in config:
        print(f'AGENT_{safe}_FORGE_USER={config[\"forge_user\"]}')
    if 'compact_pct' in config:
        print(f'AGENT_{safe}_COMPACT_PCT={config[\"compact_pct\"]}')
" "$_PROJECT_TOML" 2>/dev/null) || true

  if [ -n "$_AGENT_VARS" ]; then
    while IFS='=' read -r _key _val; do
      [ -z "$_key" ] && continue
      export "$_key=$_val"
    done <<< "$_AGENT_VARS"
  fi
  unset _AGENT_VARS
fi

unset _PROJECT_TOML _PROJECT_VARS _key _val
