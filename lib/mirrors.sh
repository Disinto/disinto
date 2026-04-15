#!/usr/bin/env bash
# mirrors.sh — Mirror helpers: push to remotes + register pull mirrors via API.
#
# Usage: source lib/mirrors.sh; mirror_push
#        source lib/mirrors.sh; mirror_pull_register <clone_url> <owner> <repo_name> [interval]
# Requires: PROJECT_REPO_ROOT, PRIMARY_BRANCH, MIRROR_* vars from load-project.sh
#           FORGE_API_BASE, FORGE_TOKEN for pull-mirror registration

# shellcheck disable=SC2154  # globals set by load-project.sh / calling script

mirror_push() {
  [ -z "${MIRROR_NAMES:-}" ] && return 0
  [ -z "${PROJECT_REPO_ROOT:-}" ] && return 0
  [ -z "${PRIMARY_BRANCH:-}" ] && return 0

  local name url
  for name in $MIRROR_NAMES; do
    # Convert name to uppercase env var name safely (only alphanumeric allowed)
    local upper_name
    upper_name=$(printf '%s' "$name" | tr '[:lower:]' '[:upper:]')
    # Validate: only allow alphanumeric + underscore in var name
    if [[ ! "$upper_name" =~ ^[A-Z_][A-Z0-9_]*$ ]]; then
      continue
    fi
    # Use indirect expansion safely (no eval) — MIRROR_ prefix required
    local varname="MIRROR_${upper_name}"
    url="${!varname:-}"
    [ -z "$url" ] && continue

    # Ensure remote exists with correct URL
    if git -C "$PROJECT_REPO_ROOT" remote get-url "$name" &>/dev/null; then
      git -C "$PROJECT_REPO_ROOT" remote set-url "$name" "$url" 2>/dev/null || true
    else
      git -C "$PROJECT_REPO_ROOT" remote add "$name" "$url" 2>/dev/null || true
    fi

    # Fire-and-forget push (background, no failure propagation)
    git -C "$PROJECT_REPO_ROOT" push "$name" "$PRIMARY_BRANCH" --tags 2>/dev/null &
    log "mirror: pushed to ${name} (pid $!)"
  done
}

# ---------------------------------------------------------------------------
# mirror_pull_register — register a Forgejo pull mirror via the /repos/migrate API.
#
# Creates a new repo as a pull mirror of an external source.  Works against
# empty target repos (the repo is created by the API call itself).
#
# Usage:
#   mirror_pull_register <clone_url> <owner> <repo_name> [interval]
#
# Args:
#   clone_url  — HTTPS URL of the source repo (e.g. https://codeberg.org/johba/disinto.git)
#   owner      — Forgejo org or user that will own the mirror repo
#   repo_name  — name of the new mirror repo on Forgejo
#   interval   — sync interval (default: "8h0m0s"; Forgejo duration format)
#
# Requires:
#   FORGE_API_BASE, FORGE_TOKEN (from env.sh)
#
# Returns 0 on success, 1 on failure.  Prints the new repo JSON to stdout.
# ---------------------------------------------------------------------------
mirror_pull_register() {
  local clone_url="$1"
  local owner="$2"
  local repo_name="$3"
  local interval="${4:-8h0m0s}"

  if [ -z "${FORGE_API_BASE:-}" ] || [ -z "${FORGE_TOKEN:-}" ]; then
    echo "ERROR: FORGE_API_BASE and FORGE_TOKEN must be set" >&2
    return 1
  fi

  if [ -z "$clone_url" ] || [ -z "$owner" ] || [ -z "$repo_name" ]; then
    echo "Usage: mirror_pull_register <clone_url> <owner> <repo_name> [interval]" >&2
    return 1
  fi

  local payload
  payload=$(jq -n \
    --arg clone_addr "$clone_url" \
    --arg repo_name  "$repo_name" \
    --arg repo_owner "$owner" \
    --arg interval   "$interval" \
    '{
      clone_addr:      $clone_addr,
      repo_name:       $repo_name,
      repo_owner:      $repo_owner,
      mirror:          true,
      mirror_interval: $interval,
      service:         "git"
    }')

  local http_code body
  body=$(curl -s -w "\n%{http_code}" -X POST \
    -H "Authorization: token ${FORGE_TOKEN}" \
    -H "Content-Type: application/json" \
    "${FORGE_API_BASE}/repos/migrate" \
    -d "$payload")

  http_code=$(printf '%s' "$body" | tail -n1)
  body=$(printf '%s' "$body" | sed '$d')

  if [ "$http_code" -ge 200 ] && [ "$http_code" -lt 300 ]; then
    printf '%s\n' "$body"
    return 0
  else
    echo "ERROR: mirror_pull_register failed (HTTP ${http_code}): ${body}" >&2
    return 1
  fi
}
