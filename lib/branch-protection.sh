#!/usr/bin/env bash
# branch-protection.sh — Helper for setting up branch protection on repos
#
# Source after lib/env.sh:
#   source "$(dirname "$0")/../lib/env.sh"
#   source "$(dirname "$0")/lib/branch-protection.sh"
#
# Required globals: FORGE_TOKEN, FORGE_URL, FORGE_OPS_REPO
#
# Functions:
#   setup_vault_branch_protection — Set up admin-only branch protection for main
#   verify_branch_protection — Verify protection is configured correctly
#   remove_branch_protection — Remove branch protection (for cleanup/testing)
#
# Branch protection settings:
# - Require 1 approval before merge
# - Restrict merge to admin role (not regular collaborators or bots)
# - Block direct pushes to main (all changes must go through PR)

set -euo pipefail

# Internal log helper
_bp_log() {
  if declare -f log >/dev/null 2>&1; then
    log "branch-protection: $*"
  else
    printf '[%s] branch-protection: %s\n' "$(date -u '+%Y-%m-%d %H:%M:%S UTC')" "$*" >&2
  fi
}

# Get ops repo API URL
_ops_api() {
  printf '%s' "${FORGE_URL}/api/v1/repos/${FORGE_OPS_REPO}"
}

# -----------------------------------------------------------------------------
# setup_vault_branch_protection — Set up admin-only branch protection for main
#
# Configures the following protection rules:
# - Require 1 approval before merge
# - Restrict merge to admin role (not regular collaborators or bots)
# - Block direct pushes to main (all changes must go through PR)
#
# Returns: 0 on success, 1 on failure
# -----------------------------------------------------------------------------
setup_vault_branch_protection() {
  local branch="${1:-main}"
  local api_url
  api_url="$(_ops_api)"

  _bp_log "Setting up branch protection for ${branch} on ${FORGE_OPS_REPO}"

  # Check if branch exists
  local branch_exists
  branch_exists=$(curl -s -o /dev/null -w "%{http_code}" \
    -H "Authorization: token ${FORGE_TOKEN}" \
    "${api_url}/git/branches/${branch}" 2>/dev/null || echo "0")

  if [ "$branch_exists" != "200" ]; then
    _bp_log "ERROR: Branch ${branch} does not exist"
    return 1
  fi

  # Check if protection already exists
  local protection_exists
  protection_exists=$(curl -s -o /dev/null -w "%{http_code}" \
    -H "Authorization: token ${FORGE_TOKEN}" \
    "${api_url}/branches/${branch}/protection" 2>/dev/null || echo "0")

  if [ "$protection_exists" = "200" ]; then
    _bp_log "Branch protection already exists for ${branch}"
    _bp_log "Updating existing protection rules"
  fi

  # Create/update branch protection
  # Note: Forgejo API uses "require_signed_commits" and "required_approvals" for approval requirements
  # The "admin_enforced" field ensures only admins can merge
  local protection_json
  protection_json=$(cat <<EOF
{
  "enable_push": false,
  "enable_force_push": false,
  "enable_merge_commit": true,
  "enable_rebase": true,
  "enable_rebase_merge": true,
  "required_approvals": 1,
  "required_signatures": false,
  "admin_enforced": true,
  "required_status_checks": false,
  "required_linear_history": false
}
EOF
)

  local http_code
  if [ "$protection_exists" = "200" ]; then
    # Update existing protection
    http_code=$(curl -s -o /dev/null -w "%{http_code}" \
      -X PUT \
      -H "Authorization: token ${FORGE_TOKEN}" \
      -H "Content-Type: application/json" \
      "${api_url}/branches/${branch}/protection" \
      -d "$protection_json" || echo "0")
  else
    # Create new protection
    http_code=$(curl -s -o /dev/null -w "%{http_code}" \
      -X POST \
      -H "Authorization: token ${FORGE_TOKEN}" \
      -H "Content-Type: application/json" \
      "${api_url}/branches/${branch}/protection" \
      -d "$protection_json" || echo "0")
  fi

  if [ "$http_code" != "200" ] && [ "$http_code" != "201" ]; then
    _bp_log "ERROR: Failed to set up branch protection (HTTP ${http_code})"
    return 1
  fi

  _bp_log "Branch protection configured successfully for ${branch}"
  _bp_log "  - Pushes blocked: true"
  _bp_log "  - Force pushes blocked: true"
  _bp_log "  - Required approvals: 1"
  _bp_log "  - Admin enforced: true"

  return 0
}

# -----------------------------------------------------------------------------
# verify_branch_protection — Verify protection is configured correctly
#
# Returns: 0 if protection is configured correctly, 1 otherwise
# -----------------------------------------------------------------------------
verify_branch_protection() {
  local branch="${1:-main}"
  local api_url
  api_url="$(_ops_api)"

  _bp_log "Verifying branch protection for ${branch}"

  # Get current protection settings
  local protection_json
  protection_json=$(curl -sf -H "Authorization: token ${FORGE_TOKEN}" \
    "${api_url}/branches/${branch}/protection" 2>/dev/null || true)

  if [ -z "$protection_json" ] || [ "$protection_json" = "null" ]; then
    _bp_log "ERROR: No branch protection found for ${branch}"
    return 1
  fi

  # Extract and validate settings
  local enable_push enable_merge_commit required_approvals admin_enforced
  enable_push=$(printf '%s' "$protection_json" | jq -r '.enable_push // true')
  enable_merge_commit=$(printf '%s' "$protection_json" | jq -r '.enable_merge_commit // false')
  required_approvals=$(printf '%s' "$protection_json" | jq -r '.required_approvals // 0')
  admin_enforced=$(printf '%s' "$protection_json" | jq -r '.admin_enforced // false')

  local errors=0

  # Check push is disabled
  if [ "$enable_push" = "true" ]; then
    _bp_log "ERROR: enable_push should be false"
    errors=$((errors + 1))
  else
    _bp_log "OK: Pushes are blocked"
  fi

  # Check merge commit is enabled
  if [ "$enable_merge_commit" != "true" ]; then
    _bp_log "ERROR: enable_merge_commit should be true"
    errors=$((errors + 1))
  else
    _bp_log "OK: Merge commits are allowed"
  fi

  # Check required approvals
  if [ "$required_approvals" -lt 1 ]; then
    _bp_log "ERROR: required_approvals should be at least 1"
    errors=$((errors + 1))
  else
    _bp_log "OK: Required approvals: ${required_approvals}"
  fi

  # Check admin enforced
  if [ "$admin_enforced" != "true" ]; then
    _bp_log "ERROR: admin_enforced should be true"
    errors=$((errors + 1))
  else
    _bp_log "OK: Admin enforcement enabled"
  fi

  if [ "$errors" -gt 0 ]; then
    _bp_log "Verification failed with ${errors} error(s)"
    return 1
  fi

  _bp_log "Branch protection verified successfully"
  return 0
}

# -----------------------------------------------------------------------------
# remove_branch_protection — Remove branch protection (for cleanup/testing)
#
# Returns: 0 on success, 1 on failure
# -----------------------------------------------------------------------------
remove_branch_protection() {
  local branch="${1:-main}"
  local api_url
  api_url="$(_ops_api)"

  _bp_log "Removing branch protection for ${branch}"

  # Check if protection exists
  local protection_exists
  protection_exists=$(curl -s -o /dev/null -w "%{http_code}" \
    -H "Authorization: token ${FORGE_TOKEN}" \
    "${api_url}/branches/${branch}/protection" 2>/dev/null || echo "0")

  if [ "$protection_exists" != "200" ]; then
    _bp_log "No branch protection found for ${branch}"
    return 0
  fi

  # Delete protection
  local http_code
  http_code=$(curl -s -o /dev/null -w "%{http_code}" \
    -X DELETE \
    -H "Authorization: token ${FORGE_TOKEN}" \
    "${api_url}/branches/${branch}/protection" 2>/dev/null || echo "0")

  if [ "$http_code" != "204" ]; then
    _bp_log "ERROR: Failed to remove branch protection (HTTP ${http_code})"
    return 1
  fi

  _bp_log "Branch protection removed successfully for ${branch}"
  return 0
}

# -----------------------------------------------------------------------------
# Test mode — run when executed directly
# -----------------------------------------------------------------------------
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  # Check required env vars
  if [ -z "${FORGE_TOKEN:-}" ]; then
    echo "ERROR: FORGE_TOKEN is required" >&2
    exit 1
  fi

  if [ -z "${FORGE_URL:-}" ]; then
    echo "ERROR: FORGE_URL is required" >&2
    exit 1
  fi

  if [ -z "${FORGE_OPS_REPO:-}" ]; then
    echo "ERROR: FORGE_OPS_REPO is required" >&2
    exit 1
  fi

  # Parse command line args
  case "${1:-help}" in
    setup)
      setup_vault_branch_protection "${2:-main}"
      ;;
    verify)
      verify_branch_protection "${2:-main}"
      ;;
    remove)
      remove_branch_protection "${2:-main}"
      ;;
    help|*)
      echo "Usage: $0 {setup|verify|remove} [branch]"
      echo ""
      echo "Commands:"
      echo "  setup [branch]  Set up branch protection (default: main)"
      echo "  verify [branch] Verify branch protection is configured correctly"
      echo "  remove [branch] Remove branch protection (for cleanup/testing)"
      echo ""
      echo "Required environment variables:"
      echo "  FORGE_TOKEN     Forgejo API token (admin user recommended)"
      echo "  FORGE_URL       Forgejo instance URL (e.g., https://codeberg.org)"
      echo "  FORGE_OPS_REPO  Ops repo in format owner/repo (e.g., johba/disinto-ops)"
      exit 0
      ;;
  esac
fi
