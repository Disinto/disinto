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
# _vault_commit_direct — Commit low-tier action directly to ops main
# Args: ops_api tmp_toml_file action_id
# Uses FORGE_ADMIN_TOKEN to bypass PR workflow
# -----------------------------------------------------------------------------
_vault_commit_direct() {
  local ops_api="$1"
  local tmp_toml="$2"
  local action_id="$3"
  local file_path="vault/actions/${action_id}.toml"

  # Use FORGE_ADMIN_TOKEN for direct commit (vault-bot identity)
  local admin_token="${FORGE_ADMIN_TOKEN:-${FORGE_TOKEN}}"
  if [ -z "$admin_token" ]; then
    echo "ERROR: FORGE_ADMIN_TOKEN is required for low-tier commits" >&2
    return 1
  fi

  # Get main branch SHA
  local main_sha
  main_sha=$(curl -sf -H "Authorization: token ${admin_token}" \
    "${ops_api}/git/branches/${PRIMARY_BRANCH:-main}" 2>/dev/null | \
    jq -r '.commit.id // empty' || true)

  if [ -z "$main_sha" ]; then
    main_sha=$(curl -sf -H "Authorization: token ${admin_token}" \
      "${ops_api}/git/refs/heads/${PRIMARY_BRANCH:-main}" 2>/dev/null | \
      jq -r '.object.sha // empty' || true)
  fi

  if [ -z "$main_sha" ]; then
    echo "ERROR: could not get main branch SHA" >&2
    return 1
  fi

  _vault_log "Committing ${file_path} directly to ${PRIMARY_BRANCH:-main}"

  # Encode TOML content as base64
  local encoded_content
  encoded_content=$(base64 -w 0 < "$tmp_toml")

  # Commit directly to main branch using Forgejo content API
  if ! curl -sf -X PUT \
    -H "Authorization: token ${admin_token}" \
    -H "Content-Type: application/json" \
    "${ops_api}/contents/${file_path}" \
    -d "{\"message\":\"vault: add ${action_id} (low-tier)\",\"branch\":\"${PRIMARY_BRANCH:-main}\",\"content\":\"${encoded_content}\",\"committer\":{\"name\":\"vault-bot\",\"email\":\"vault-bot@${FORGE_REPO}\"},\"overwrite\":true}" >/dev/null 2>&1; then
    echo "ERROR: failed to write ${file_path} to ${PRIMARY_BRANCH:-main}" >&2
    return 1
  fi

  _vault_log "Direct commit successful for ${action_id}"
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

  # Get admin token for API calls (FORGE_ADMIN_TOKEN for low-tier, FORGE_TOKEN otherwise)
  local admin_token="${FORGE_ADMIN_TOKEN:-${FORGE_TOKEN}}"

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

  # Get ops repo API URL
  local ops_api
  ops_api="$(_vault_ops_api)"

  # Classify the action to determine if PR bypass is allowed
  local classify_script="${FACTORY_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}/vault/classify.sh"
  local vault_tier
  vault_tier=$("$classify_script" "${VAULT_ACTION_FORMULA:-}" "${VAULT_BLAST_RADIUS_OVERRIDE:-}") || {
    # Classification failed, default to high tier (require PR)
    vault_tier="high"
    _vault_log "Warning: classification failed, defaulting to high tier"
  }
  export VAULT_TIER="${vault_tier}"

  # For low-tier actions, commit directly to ops main using FORGE_ADMIN_TOKEN
  if [ "$vault_tier" = "low" ]; then
    _vault_log "low-tier — committed directly to ops main"
    _vault_commit_direct "$ops_api" "$tmp_toml" "${action_id}"
    return 0
  fi

  # Extract values for PR creation (medium/high tier)
  local pr_title pr_body
  pr_title="vault: ${action_id}"
  pr_body="Vault action: ${action_id}

Context: ${VAULT_ACTION_CONTEXT:-No context provided}

Formula: ${VAULT_ACTION_FORMULA:-}
Secrets: ${VAULT_ACTION_SECRETS:-}

---
This vault action has been created by an agent and requires admin approval
before execution. See the TOML file for details."

  # Create branch
  local branch="vault/${action_id}"
  local branch_exists

  branch_exists=$(curl -s -o /dev/null -w "%{http_code}" \
    -H "Authorization: token ${admin_token}" \
    "${ops_api}/git/branches/${branch}" 2>/dev/null || echo "0")

  if [ "$branch_exists" != "200" ]; then
    # Branch doesn't exist, create it from main
    _vault_log "Creating branch ${branch} on ops repo"

    # Get the commit SHA of main branch
    local main_sha
    main_sha=$(curl -sf -H "Authorization: token ${admin_token}" \
      "${ops_api}/git/branches/${PRIMARY_BRANCH:-main}" 2>/dev/null | \
      jq -r '.commit.id // empty' || true)

    if [ -z "$main_sha" ]; then
      # Fallback: get from refs
      main_sha=$(curl -sf -H "Authorization: token ${admin_token}" \
        "${ops_api}/git/refs/heads/${PRIMARY_BRANCH:-main}" 2>/dev/null | \
        jq -r '.object.sha // empty' || true)
    fi

    if [ -z "$main_sha" ]; then
      echo "ERROR: could not get main branch SHA" >&2
      return 1
    fi

    # Create the branch
    if ! curl -sf -X POST \
      -H "Authorization: token ${admin_token}" \
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
    -H "Authorization: token ${admin_token}" \
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

  # Enable auto-merge on the PR — Forgejo will auto-merge after approval
  _vault_log "Enabling auto-merge for PR #${pr_num}"
  curl -sf -X POST \
    -H "Authorization: token ${admin_token}" \
    -H "Content-Type: application/json" \
    "${ops_api}/pulls/${pr_num}/merge" \
    -d '{"Do":"merge","merge_when_checks_succeed":true}' >/dev/null 2>&1 || {
    _vault_log "Warning: failed to enable auto-merge (may already be enabled or not supported)"
  }

  # Add labels to PR (vault, pending-approval)
  _vault_log "PR #${pr_num} created, adding labels"

  # Get label IDs
  local vault_label_id pending_label_id
  vault_label_id=$(curl -sf -H "Authorization: token ${admin_token}" \
    "${ops_api}/labels" 2>/dev/null | \
    jq -r --arg n "vault" '.[] | select(.name == $n) | .id // empty' || true)

  pending_label_id=$(curl -sf -H "Authorization: token ${admin_token}" \
    "${ops_api}/labels" 2>/dev/null | \
    jq -r --arg n "pending-approval" '.[] | select(.name == $n) | .id // empty' || true)

  # Add labels if they exist
  if [ -n "$vault_label_id" ]; then
    curl -sf -X POST \
      -H "Authorization: token ${admin_token}" \
      -H "Content-Type: application/json" \
      "${ops_api}/issues/${pr_num}/labels" \
      -d "[{\"id\":${vault_label_id}}]" >/dev/null 2>&1 || true
  fi

  if [ -n "$pending_label_id" ]; then
    curl -sf -X POST \
      -H "Authorization: token ${admin_token}" \
      -H "Content-Type: application/json" \
      "${ops_api}/issues/${pr_num}/labels" \
      -d "[{\"id\":${pending_label_id}}]" >/dev/null 2>&1 || true
  fi

  printf '%s' "$pr_num"
  return 0
}
