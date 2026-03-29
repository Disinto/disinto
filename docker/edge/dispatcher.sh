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

# Load vault secrets after env.sh (env.sh unsets them for agent security)
# Vault secrets must be available to the dispatcher
if [ -f "$FACTORY_ROOT/.env.vault.enc" ] && command -v sops &>/dev/null; then
  set -a
  eval "$(sops -d --output-type dotenv "$FACTORY_ROOT/.env.vault.enc" 2>/dev/null)" \
    || echo "Warning: failed to decrypt .env.vault.enc — vault secrets not loaded" >&2
  set +a
elif [ -f "$FACTORY_ROOT/.env.vault" ]; then
  set -a
  # shellcheck source=/dev/null
  source "$FACTORY_ROOT/.env.vault"
  set +a
fi

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
    git clone "${FORGE_OPS_REPO}" "${OPS_REPO_ROOT}"
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

  # Extract secrets (array for safe handling)
  local -a secrets=()
  while IFS= read -r secret; do
    [ -n "$secret" ] && secrets+=("$secret")
  done < <(jq -r '.secrets[]? // empty' "$action_file" 2>/dev/null)

  # Build command array (safe from shell injection)
  local -a cmd=(docker compose run --rm runner)

  # Add environment variables BEFORE service name
  for secret in "${secrets[@]+"${secrets[@]}"}"; do
    cmd+=(-e "${secret}=***")  # Redact value in the command array
  done

  # Add formula and id as arguments (after service name)
  cmd+=("$formula" "$id")

  # Log command skeleton (secrets are redacted)
  log "Running: ${cmd[*]}"

  # Execute with array expansion (safe from shell injection)
  "${cmd[@]}"

  log "Runner completed for action: ${id}"
}

# Main dispatcher loop
main() {
  log "Starting dispatcher..."
  log "Polling ops repo: ${VAULT_ACTIONS_DIR}"

  while true; do
    # Refresh ops repo at the start of each poll cycle
    ensure_ops_repo

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
