#!/usr/bin/env bash
# vault.sh — Helper for agents to create vault PRs on ops repo
#
# Source after lib/env.sh:
#   source "$(dirname "$0")/../lib/env.sh"
#   source "$(dirname "$0")/lib/vault.sh"
#
# Required globals: FORGE_TOKEN, FORGE_URL, FORGE_REPO, FORGE_OPS_REPO
# Optional: OPS_REPO_ROOT (local path for ops repo)
#
# Functions:
#   vault_request <action_id> <toml_content>  — Create vault PR, return PR number
#
# The function:
# 1. Validates TOML content using validate_vault_action() from vault/vault-env.sh
# 2. Creates a branch on the ops repo: vault/<action-id>
# 3. Writes TOML to vault/actions/<action-id>.toml on that branch
# 4. Creates PR targeting main with title "vault: <action-id>"
# 5. Body includes context field from TOML
# 6. Returns PR number (existing or newly created)
#
# Idempotent: if PR for same action-id exists, returns its number
#
# Uses Forgejo REST API (not git push) — works from containers without SSH

set -euo pipefail

# Internal log helper
_vault_log() {
  if declare -f log >/dev/null 2>&1; then
    log "vault: $*"
  else
    printf '[%s] vault: %s\n' "$(date -u '+%Y-%m-%d %H:%M:%S UTC')" "$*" >&2
  fi
}

# Get ops repo API URL
_vault_ops_api() {
  printf '%s' "${FORGE_URL}/api/v1/repos/${FORGE_OPS_REPO}"
}

# -----------------------------------------------------------------------------
# vault_request — Create a vault PR or return existing one
# Args: action_id toml_content
# Stdout: PR number
# Returns: 0=success, 1=validation failed, 2=API error
# -----------------------------------------------------------------------------
vault_request() {
  local action_id="$1"
  local toml_content="$2"

  if [ -z "$action_id" ]; then
    echo "ERROR: action_id is required" >&2
    return 1
  fi

  if [ -z "$toml_content" ]; then
    echo "ERROR: toml_content is required" >&2
    return 1
  fi

  # Check if PR already exists for this action
  local existing_pr
  existing_pr=$(pr_find_by_branch "vault/${action_id}" "$(_vault_ops_api)") || true
  if [ -n "$existing_pr" ]; then
    _vault_log "PR already exists for action $action_id: #${existing_pr}"
    printf '%s' "$existing_pr"
    return 0
  fi

  # Validate TOML content
  local tmp_toml
  tmp_toml=$(mktemp /tmp/vault-XXXXXX.toml)
  trap 'rm -f "$tmp_toml"' RETURN

  printf '%s' "$toml_content" > "$tmp_toml"

  # Source vault-env.sh for validate_vault_action
  local vault_env="${FACTORY_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}/vault/vault-env.sh"
  if [ ! -f "$vault_env" ]; then
    echo "ERROR: vault-env.sh not found at $vault_env" >&2
    return 1
  fi

  # Save caller's FORGE_TOKEN, source vault-env.sh for validate_vault_action,
  # then restore caller's token so PR creation uses agent's identity (not vault-bot)
  local _saved_forge_token="${FORGE_TOKEN:-}"
  if ! source "$vault_env"; then
    FORGE_TOKEN="${_saved_forge_token:-}"
    echo "ERROR: failed to source vault-env.sh" >&2
    return 1
  fi
  # Restore caller's FORGE_TOKEN after validation
  FORGE_TOKEN="${_saved_forge_token:-}"

  # Run validation
  if ! validate_vault_action "$tmp_toml"; then
    echo "ERROR: TOML validation failed" >&2
    return 1
  fi

  # Extract values for PR creation
  local pr_title pr_body
  pr_title="vault: ${action_id}"
  pr_body="Vault action: ${action_id}

Context: ${VAULT_ACTION_CONTEXT:-No context provided}

Formula: ${VAULT_ACTION_FORMULA:-}
Secrets: ${VAULT_ACTION_SECRETS:-}

---
This vault action has been created by an agent and requires admin approval
before execution. See the TOML file for details."

  # Get ops repo API URL
  local ops_api
  ops_api="$(_vault_ops_api)"

  # Create branch
  local branch="vault/${action_id}"
  local branch_exists

  branch_exists=$(curl -s -o /dev/null -w "%{http_code}" \
    -H "Authorization: token ${FORGE_TOKEN}" \
    "${ops_api}/git/branches/${branch}" 2>/dev/null || echo "0")

  if [ "$branch_exists" != "200" ]; then
    # Branch doesn't exist, create it from main
    _vault_log "Creating branch ${branch} on ops repo"

    # Get the commit SHA of main branch
    local main_sha
    main_sha=$(curl -sf -H "Authorization: token ${FORGE_TOKEN}" \
      "${ops_api}/git/branches/${PRIMARY_BRANCH:-main}" 2>/dev/null | \
      jq -r '.commit.id // empty' || true)

    if [ -z "$main_sha" ]; then
      # Fallback: get from refs
      main_sha=$(curl -sf -H "Authorization: token ${FORGE_TOKEN}" \
        "${ops_api}/git/refs/heads/${PRIMARY_BRANCH:-main}" 2>/dev/null | \
        jq -r '.object.sha // empty' || true)
    fi

    if [ -z "$main_sha" ]; then
      echo "ERROR: could not get main branch SHA" >&2
      return 1
    fi

    # Create the branch
    if ! curl -sf -X POST \
      -H "Authorization: token ${FORGE_TOKEN}" \
      -H "Content-Type: application/json" \
      "${ops_api}/git/branches" \
      -d "{\"ref\":\"${branch}\",\"sha\":\"${main_sha}\"}" >/dev/null 2>&1; then
      echo "ERROR: failed to create branch ${branch}" >&2
      return 1
    fi
  else
    _vault_log "Branch ${branch} already exists"
  fi

  # Write TOML file to branch via API
  local file_path="vault/actions/${action_id}.toml"
  _vault_log "Writing ${file_path} to branch ${branch}"

  # Encode TOML content as base64
  local encoded_content
  encoded_content=$(printf '%s' "$toml_content" | base64 -w 0)

  # Upload file using Forgejo content API
  if ! curl -sf -X PUT \
    -H "Authorization: token ${FORGE_TOKEN}" \
    -H "Content-Type: application/json" \
    "${ops_api}/contents/${file_path}" \
    -d "{\"message\":\"vault: add ${action_id}\",\"branch\":\"${branch}\",\"content\":\"${encoded_content}\",\"committer\":{\"name\":\"vault-bot\",\"email\":\"vault-bot@${FORGE_REPO}\"},\"overwrite\":true}" >/dev/null 2>&1; then
    echo "ERROR: failed to write ${file_path} to branch ${branch}" >&2
    return 1
  fi

  # Create PR
  _vault_log "Creating PR for ${branch}"

  local pr_num
  pr_num=$(pr_create "$branch" "$pr_title" "$pr_body" "$PRIMARY_BRANCH" "$ops_api") || {
    echo "ERROR: failed to create PR" >&2
    return 1
  }

  # Add labels to PR (vault, pending-approval)
  _vault_log "PR #${pr_num} created, adding labels"

  # Get label IDs
  local vault_label_id pending_label_id
  vault_label_id=$(curl -sf -H "Authorization: token ${FORGE_TOKEN}" \
    "${ops_api}/labels" 2>/dev/null | \
    jq -r --arg n "vault" '.[] | select(.name == $n) | .id // empty' || true)

  pending_label_id=$(curl -sf -H "Authorization: token ${FORGE_TOKEN}" \
    "${ops_api}/labels" 2>/dev/null | \
    jq -r --arg n "pending-approval" '.[] | select(.name == $n) | .id // empty' || true)

  # Add labels if they exist
  if [ -n "$vault_label_id" ]; then
    curl -sf -X POST \
      -H "Authorization: token ${FORGE_TOKEN}" \
      -H "Content-Type: application/json" \
      "${ops_api}/issues/${pr_num}/labels" \
      -d "[{\"id\":${vault_label_id}}]" >/dev/null 2>&1 || true
  fi

  if [ -n "$pending_label_id" ]; then
    curl -sf -X POST \
      -H "Authorization: token ${FORGE_TOKEN}" \
      -H "Content-Type: application/json" \
      "${ops_api}/issues/${pr_num}/labels" \
      -d "[{\"id\":${pending_label_id}}]" >/dev/null 2>&1 || true
  fi

  printf '%s' "$pr_num"
  return 0
}
