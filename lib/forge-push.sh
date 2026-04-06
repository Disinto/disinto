#!/usr/bin/env bash
# =============================================================================
# forge-push.sh — push_to_forge() function
#
# Handles pushing a local clone to the Forgejo remote and verifying the push.
#
# Globals expected:
#   FORGE_URL    - Forge instance URL (e.g. http://localhost:3000)
#   FORGE_TOKEN  - API token for Forge operations
#   FACTORY_ROOT - Root of the disinto factory
#   PRIMARY_BRANCH - Primary branch name (e.g. main)
#
# Usage:
#   source "${FACTORY_ROOT}/lib/forge-push.sh"
#   push_to_forge <repo_root> <forge_url> <repo_slug>
# =============================================================================
set -euo pipefail

# Assert required globals are set before using this module.
_assert_forge_push_globals() {
  local missing=()
  [ -z "${FORGE_URL:-}" ]      && missing+=("FORGE_URL")
  [ -z "${FORGE_TOKEN:-}" ]    && missing+=("FORGE_TOKEN")
  [ -z "${FACTORY_ROOT:-}" ]   && missing+=("FACTORY_ROOT")
  [ -z "${PRIMARY_BRANCH:-}" ] && missing+=("PRIMARY_BRANCH")
  if [ "${#missing[@]}" -gt 0 ]; then
    echo "Error: forge-push.sh requires these globals to be set: ${missing[*]}" >&2
    exit 1
  fi
}

# Push local clone to the Forgejo remote.
push_to_forge() {
  local repo_root="$1" forge_url="$2" repo_slug="$3"

  # Build authenticated remote URL: http://dev-bot:<token>@host:port/org/repo.git
  if [ -z "${FORGE_TOKEN:-}" ]; then
    echo "Error: FORGE_TOKEN not set — cannot push to Forgejo" >&2
    return 1
  fi
  local auth_url
  auth_url=$(printf '%s' "$forge_url" | sed "s|://|://dev-bot:${FORGE_TOKEN}@|")
  local remote_url="${auth_url}/${repo_slug}.git"
  # Display URL without token
  local display_url="${forge_url}/${repo_slug}.git"

  # Always set the remote URL to ensure credentials are current
  if git -C "$repo_root" remote get-url forgejo >/dev/null 2>&1; then
    git -C "$repo_root" remote set-url forgejo "$remote_url"
  else
    git -C "$repo_root" remote add forgejo "$remote_url"
  fi
  echo "Remote:  forgejo -> ${display_url}"

  # Skip push if local repo has no commits (e.g. cloned from empty Forgejo repo)
  if ! git -C "$repo_root" rev-parse HEAD >/dev/null 2>&1; then
    echo "Push:    skipped (local repo has no commits)"
    return 0
  fi

  # Push all branches and tags
  echo "Pushing: branches to forgejo"
  if ! git -C "$repo_root" push forgejo --all 2>&1; then
    echo "Error: failed to push branches to Forgejo" >&2
    return 1
  fi
  echo "Pushing: tags to forgejo"
  if ! git -C "$repo_root" push forgejo --tags 2>&1; then
    echo "Error: failed to push tags to Forgejo" >&2
    return 1
  fi

  # Verify the repo is no longer empty (Forgejo may need a moment to index pushed refs)
  local is_empty="true"
  local verify_attempt
  for verify_attempt in $(seq 1 5); do
    local repo_info
    repo_info=$(curl -sf --max-time 10 \
      -H "Authorization: token ${FORGE_TOKEN}" \
      "${forge_url}/api/v1/repos/${repo_slug}" 2>/dev/null) || repo_info=""
    if [ -z "$repo_info" ]; then
      is_empty="skipped"
      break  # API unreachable, skip verification
    fi
    is_empty=$(printf '%s' "$repo_info" | jq -r '.empty // "unknown"')
    if [ "$is_empty" != "true" ]; then
      echo "Verify:  repo is not empty (push confirmed)"
      break
    fi
    if [ "$verify_attempt" -lt 5 ]; then
      sleep 2
    fi
  done
  if [ "$is_empty" = "true" ]; then
    echo "Warning: Forgejo repo still reports empty after push" >&2
    return 1
  fi
}
