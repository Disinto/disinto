#!/usr/bin/env bash
# dispatcher.sh — Edge task dispatcher
#
# Polls the ops repo for vault actions that arrived via admin-merged PRs.
#
# Flow:
# 1. Poll loop: git pull the ops repo every 60s
# 2. Scan vault/actions/ for TOML files without .result.json
# 3. Verify TOML arrived via merged PR with admin merger (Forgejo API)
# 4. Validate TOML using vault-env.sh validator
# 5. Decrypt .env.vault.enc and extract only declared secrets
# 6. Launch: docker compose run --rm runner <formula> <action-id>
# 7. Write <action-id>.result.json with exit code, timestamp, logs summary
#
# Part of #76.

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

# Vault action validation
VAULT_ENV="${SCRIPT_ROOT}/../vault/vault-env.sh"

# Admin users who can merge vault PRs (from issue #77)
# Comma-separated list of Forgejo usernames with admin role
ADMIN_USERS="${FORGE_ADMIN_USERS:-vault-bot,admin}"

# Log function
log() {
  printf '[%s] %s\n' "$(date -u '+%Y-%m-%d %H:%M:%S UTC')" "$*"
}

# -----------------------------------------------------------------------------
# Forge API helpers for admin verification
# -----------------------------------------------------------------------------

# Check if a user has admin role
# Usage: is_user_admin <username>
# Returns: 0=yes, 1=no
is_user_admin() {
  local username="$1"
  local user_json

  # Fetch user info from Forgejo API
  user_json=$(curl -sf -H "Authorization: token ${FORGE_TOKEN}" \
    "${FORGE_URL}/api/v1/users/${username}" 2>/dev/null) || return 1

  # Forgejo uses .is_admin for site-wide admin users
  local is_admin
  is_admin=$(echo "$user_json" | jq -r '.is_admin // false' 2>/dev/null) || return 1

  if [[ "$is_admin" == "true" ]]; then
    return 0
  fi

  return 1
}

# Check if a user is in the allowed admin list
# Usage: is_allowed_admin <username>
# Returns: 0=yes, 1=no
is_allowed_admin() {
  local username="$1"
  local admin_list
  admin_list=$(echo "$ADMIN_USERS" | tr ',' '\n')

  while IFS= read -r admin; do
    admin=$(echo "$admin" | xargs)  # trim whitespace
    if [[ "$username" == "$admin" ]]; then
      return 0
    fi
  done <<< "$admin_list"

  # Also check via API if not in static list
  if is_user_admin "$username"; then
    return 0
  fi

  return 1
}

# Get the PR that introduced a specific file to vault/actions
# Usage: get_pr_for_file <file_path>
# Returns: PR number or empty if not found via PR
get_pr_for_file() {
  local file_path="$1"
  local file_name
  file_name=$(basename "$file_path")

  # Get recent commits that added this specific file
  local commits
  commits=$(git -C "$OPS_REPO_ROOT" log --oneline --diff-filter=A -- "vault/actions/${file_name}" 2>/dev/null | head -20) || true

  if [ -z "$commits" ]; then
    return 1
  fi

  # For each commit, check if it's a merge commit from a PR
  while IFS= read -r commit; do
    local commit_sha commit_msg

    commit_sha=$(echo "$commit" | awk '{print $1}')
    commit_msg=$(git -C "$OPS_REPO_ROOT" log -1 --format="%B" "$commit_sha" 2>/dev/null) || continue

    # Check if this is a merge commit (has "Merge pull request" in message)
    if [[ "$commit_msg" =~ "Merge pull request" ]]; then
      # Extract PR number from merge message (e.g., "Merge pull request #123")
      local pr_num
      pr_num=$(echo "$commit_msg" | grep -oP '#\d+' | head -1 | tr -d '#') || true

      if [ -n "$pr_num" ]; then
        echo "$pr_num"
        return 0
      fi
    fi
  done <<< "$commits"

  return 1
}

# Get PR merger info
# Usage: get_pr_merger <pr_number>
# Returns: JSON with merger username and merged timestamp
get_pr_merger() {
  local pr_number="$1"

  curl -sf -H "Authorization: token ${FORGE_TOKEN}" \
    "${FORGE_API}/pulls/${pr_number}" 2>/dev/null | jq -r '{
      username: .merge_user?.login // .user?.login,
      merged: .merged,
      merged_at: .merged_at // empty
    }' || true
}

# Verify vault action arrived via admin-merged PR
# Usage: verify_admin_merged <toml_file>
# Returns: 0=verified, 1=not verified
verify_admin_merged() {
  local toml_file="$1"
  local action_id
  action_id=$(basename "$toml_file" .toml)

  # Get the PR that introduced this file
  local pr_num
  pr_num=$(get_pr_for_file "$toml_file") || {
    log "WARNING: No PR found for action ${action_id} — skipping (possible direct push)"
    return 1
  }

  log "Action ${action_id} arrived via PR #${pr_num}"

  # Get PR merger info
  local merger_json
  merger_json=$(get_pr_merger "$pr_num") || {
    log "WARNING: Could not fetch PR #${pr_num} details — skipping"
    return 1
  }

  local merged merger_username
  merged=$(echo "$merger_json" | jq -r '.merged // false')
  merger_username=$(echo "$merger_json" | jq -r '.username // empty')

  # Check if PR is merged
  if [[ "$merged" != "true" ]]; then
    log "WARNING: PR #${pr_num} is not merged — skipping"
    return 1
  fi

  # Check if merger is admin
  if [ -z "$merger_username" ]; then
    log "WARNING: Could not determine PR #${pr_num} merger — skipping"
    return 1
  fi

  if ! is_allowed_admin "$merger_username"; then
    log "WARNING: PR #${pr_num} merged by non-admin user '${merger_username}' — skipping"
    return 1
  fi

  log "Verified: PR #${pr_num} merged by admin '${merger_username}'"
  return 0
}

# -----------------------------------------------------------------------------
# Vault action processing
# -----------------------------------------------------------------------------

# Check if an action has already been completed
is_action_completed() {
  local id="$1"
  [ -f "${VAULT_ACTIONS_DIR}/${id}.result.json" ]
}

# Validate a vault action TOML file
# Usage: validate_action <toml_file>
# Sets: VAULT_ACTION_ID, VAULT_ACTION_FORMULA, VAULT_ACTION_CONTEXT, VAULT_ACTION_SECRETS
validate_action() {
  local toml_file="$1"

  # Source vault-env.sh for validate_vault_action function
  if [ ! -f "$VAULT_ENV" ]; then
    echo "ERROR: vault-env.sh not found at ${VAULT_ENV}" >&2
    return 1
  fi

  if ! source "$VAULT_ENV"; then
    echo "ERROR: failed to source vault-env.sh" >&2
    return 1
  fi

  if ! validate_vault_action "$toml_file"; then
    return 1
  fi

  return 0
}

# Write result file for an action
# Usage: write_result <action_id> <exit_code> <logs>
write_result() {
  local action_id="$1"
  local exit_code="$2"
  local logs="$3"

  local result_file="${VAULT_ACTIONS_DIR}/${action_id}.result.json"

  # Truncate logs if too long (keep last 1000 chars)
  if [ ${#logs} -gt 1000 ]; then
    logs="${logs: -1000}"
  fi

  # Write result JSON
  jq -n \
    --arg id "$action_id" \
    --argjson exit_code "$exit_code" \
    --arg timestamp "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" \
    --arg logs "$logs" \
    '{id: $id, exit_code: $exit_code, timestamp: $timestamp, logs: $logs}' \
    > "$result_file"

  log "Result written: ${result_file}"
}

# Launch runner for the given action
# Usage: launch_runner <toml_file>
launch_runner() {
  local toml_file="$1"
  local action_id
  action_id=$(basename "$toml_file" .toml)

  log "Launching runner for action: ${action_id}"

  # Validate TOML
  if ! validate_action "$toml_file"; then
    log "ERROR: Action validation failed for ${action_id}"
    write_result "$action_id" 1 "Validation failed: see logs above"
    return 1
  fi

  # Verify admin merge
  if ! verify_admin_merged "$toml_file"; then
    log "ERROR: Admin merge verification failed for ${action_id}"
    write_result "$action_id" 1 "Admin merge verification failed: see logs above"
    return 1
  fi

  # Extract secrets from validated action
  local secrets_array
  secrets_array="${VAULT_ACTION_SECRETS:-}"

  if [ -z "$secrets_array" ]; then
    log "ERROR: Action ${action_id} has no secrets declared"
    write_result "$action_id" 1 "No secrets declared in TOML"
    return 1
  fi

  # Build command array (safe from shell injection)
  local -a cmd=(docker compose run --rm runner)

  # Add environment variables for secrets
  for secret in $secrets_array; do
    secret=$(echo "$secret" | xargs)
    if [ -n "$secret" ]; then
      # Verify secret exists in vault
      if [ -z "${!secret:-}" ]; then
        log "ERROR: Secret '${secret}' not found in vault for action ${action_id}"
        write_result "$action_id" 1 "Secret not found in vault: ${secret}"
        return 1
      fi
      cmd+=(-e "$secret")
    fi
  done

  # Add formula and action id as arguments (after service name)
  local formula="${VAULT_ACTION_FORMULA:-}"
  cmd+=("$formula" "$action_id")

  # Log command skeleton (hide all -e flags for security)
  local -a log_cmd=()
  local skip_next=0
  for arg in "${cmd[@]}"; do
    if [[ $skip_next -eq 1 ]]; then
      skip_next=0
      continue
    fi
    if [[ "$arg" == "-e" ]]; then
      log_cmd+=("$arg" "<redacted>")
      skip_next=1
    else
      log_cmd+=("$arg")
    fi
  done
  log "Running: ${log_cmd[*]}"

  # Create temp file for logs
  local log_file
  log_file=$(mktemp /tmp/dispatcher-logs-XXXXXX.txt)
  trap 'rm -f "$log_file"' RETURN

  # Execute with array expansion (safe from shell injection)
  # Capture stdout and stderr to log file
  "${cmd[@]}" > "$log_file" 2>&1
  local exit_code=$?

  # Read logs summary
  local logs
  logs=$(cat "$log_file")

  # Write result file
  write_result "$action_id" "$exit_code" "$logs"

  if [ $exit_code -eq 0 ]; then
    log "Runner completed successfully for action: ${action_id}"
  else
    log "Runner failed for action: ${action_id} (exit code: ${exit_code})"
  fi

  return $exit_code
}

# -----------------------------------------------------------------------------
# Main dispatcher loop
# -----------------------------------------------------------------------------

# Clone or pull the ops repo
ensure_ops_repo() {
  if [ ! -d "${OPS_REPO_ROOT}/.git" ]; then
    log "Cloning ops repo from ${FORGE_URL}/${FORGE_OPS_REPO}..."
    git clone "${FORGE_URL}/${FORGE_OPS_REPO}" "${OPS_REPO_ROOT}"
  else
    log "Pulling latest ops repo changes..."
    (cd "${OPS_REPO_ROOT}" && git pull --rebase)
  fi
}

# Main dispatcher loop
main() {
  log "Starting dispatcher..."
  log "Polling ops repo: ${VAULT_ACTIONS_DIR}"
  log "Admin users: ${ADMIN_USERS}"

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
    for toml_file in "${VAULT_ACTIONS_DIR}"/*.toml; do
      # Handle case where no .toml files exist
      [ -e "$toml_file" ] || continue

      local action_id
      action_id=$(basename "$toml_file" .toml)

      # Skip if already completed
      if is_action_completed "$action_id"; then
        log "Action ${action_id} already completed, skipping"
        continue
      fi

      # Launch runner for this action
      launch_runner "$toml_file" || true
    done

    # Wait before next poll
    sleep 60
  done
}

# Run main
main "$@"
