#!/usr/bin/env bash
# dispatcher.sh — Edge task dispatcher
#
# Polls the ops repo for approved actions and launches task-runner containers.
# Part of #24.
#
# Action JSON schema:
# {
#   "id": "publish-skill-20260328",
#   "formula": "clawhub-publish",
#   "secrets": ["CLAWHUB_TOKEN"],
#   "tools": ["clawhub"],
#   "context": "SKILL.md bumped to 0.3.0",
#   "model": "sonnet"
# }

set -euo pipefail

# Resolve script root (parent of lib/)
SCRIPT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Source shared environment
source "${SCRIPT_ROOT}/../lib/env.sh"

# Ops repo location (vault/actions directory)
OPS_REPO_ROOT="${OPS_REPO_ROOT:-/home/debian/disinto-ops}"
VAULT_ACTIONS_DIR="${OPS_REPO_ROOT}/vault/actions"

# Log function
log() {
  printf '[%s] %s\n' "$(date -u '+%Y-%m-%d %H:%M:%S UTC')" "$*"
}

# Clone or pull the ops repo
ensure_ops_repo() {
  if [ ! -d "${OPS_REPO_ROOT}/.git" ]; then
    log "Cloning ops repo from ${FORGE_OPS_REPO}..."
    git clone "${FORGE_WEB}" "${OPS_REPO_ROOT}"
  else
    log "Pulling latest ops repo changes..."
    (cd "${OPS_REPO_ROOT}" && git pull --rebase)
  fi
}

# Check if an action has already been completed
is_action_completed() {
  local id="$1"
  [ -f "${VAULT_ACTIONS_DIR}/${id}.result.json" ]
}

# Launch a runner for the given action ID
launch_runner() {
  local id="$1"
  log "Launching runner for action: ${id}"

  # Read action config
  local action_file="${VAULT_ACTIONS_DIR}/${id}.json"
  if [ ! -f "$action_file" ]; then
    log "ERROR: Action file not found: ${action_file}"
    return 1
  fi

  # Extract formula from action JSON
  local formula
  formula=$(jq -r '.formula // empty' "$action_file")
  if [ -z "$formula" ]; then
    log "ERROR: Action ${id} missing 'formula' field"
    return 1
  fi

  # Extract secrets (as space-separated list for env injection)
  local secrets
  secrets=$(jq -r '.secrets[]? // empty' "$action_file" 2>/dev/null | tr '\n' ' ')

  # Run the formula via docker compose with action ID as argument
  # The runner container should be defined in docker-compose.yml
  # Secrets are injected via -e flags
  local compose_cmd="docker compose run --rm runner ${formula} ${id}"

  if [ -n "$secrets" ]; then
    # Inject secrets as environment variables
    for secret in $secrets; do
      compose_cmd+=" -e ${secret}=${!secret}"
    done
  fi

  log "Running: ${compose_cmd}"
  eval "${compose_cmd}"

  log "Runner completed for action: ${id}"
}

# Main dispatcher loop
main() {
  log "Starting dispatcher..."
  log "Polling ops repo: ${VAULT_ACTIONS_DIR}"

  # Ensure ops repo is available
  ensure_ops_repo

  while true; do
    # Check if actions directory exists
    if [ ! -d "${VAULT_ACTIONS_DIR}" ]; then
      log "Actions directory not found: ${VAULT_ACTIONS_DIR}"
      sleep 60
      continue
    fi

    # Process each action file
    for action_file in "${VAULT_ACTIONS_DIR}"/*.json; do
      # Handle case where no .json files exist
      [ -e "$action_file" ] || continue

      local id
      id=$(basename "$action_file" .json)

      # Skip if already completed
      if is_action_completed "$id"; then
        continue
      fi

      # Launch runner for this action
      launch_runner "$id"
    done

    # Wait before next poll
    sleep 60
  done
}

# Run main
main "$@"
