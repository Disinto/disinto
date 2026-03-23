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
#   CHECK_PIPELINE_STALL, CI_STALE_MINUTES
#   (plus backwards-compat aliases: CODEBERG_REPO, CODEBERG_API, CODEBERG_WEB)
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

# [matrix] section
mx = cfg.get('matrix', {})
if 'room_id' in mx:
    emit('MATRIX_ROOM_ID', mx['room_id'])
if 'bot_user' in mx:
    emit('MATRIX_BOT_USER', mx['bot_user'])
if 'token_env' in mx:
    emit('MATRIX_TOKEN_ENV', mx['token_env'])

# [monitoring] section
mon = cfg.get('monitoring', {})
for key in ['check_prs', 'check_dev_agent', 'check_pipeline_stall']:
    if key in mon:
        emit(key.upper(), mon[key])
" "$_PROJECT_TOML" 2>/dev/null) || {
  echo "WARNING: failed to parse project TOML: $_PROJECT_TOML" >&2
  return 1 2>/dev/null || exit 1
}

# Export parsed variables
while IFS='=' read -r _key _val; do
  [ -z "$_key" ] && continue
  export "$_key=$_val"
done <<< "$_PROJECT_VARS"

# Derive FORGE_API and FORGE_WEB from forge_url + repo
# FORGE_URL: TOML forge_url > existing FORGE_URL > default
export FORGE_URL="${FORGE_URL:-http://localhost:3000}"
if [ -n "$FORGE_REPO" ]; then
  export FORGE_API="${FORGE_URL}/api/v1/repos/${FORGE_REPO}"
  export FORGE_WEB="${FORGE_URL}/${FORGE_REPO}"
fi
# Backwards-compat aliases
export CODEBERG_REPO="${FORGE_REPO}"
export CODEBERG_API="${FORGE_API:-}"
export CODEBERG_WEB="${FORGE_WEB:-}"

# Derive PROJECT_REPO_ROOT if not explicitly set
if [ -z "${PROJECT_REPO_ROOT:-}" ] && [ -n "${PROJECT_NAME:-}" ]; then
  export PROJECT_REPO_ROOT="/home/${USER}/${PROJECT_NAME}"
fi

# Resolve MATRIX_TOKEN from env var name (token_env points to an env var, not the token itself)
if [ -n "${MATRIX_TOKEN_ENV:-}" ]; then
  export MATRIX_TOKEN="${!MATRIX_TOKEN_ENV:-}"
  unset MATRIX_TOKEN_ENV
fi

unset _PROJECT_TOML _PROJECT_VARS _key _val
