#!/usr/bin/env bash
# mirrors.sh — Push primary branch + tags to configured mirror remotes.
#
# Usage: source lib/mirrors.sh; mirror_push
# Requires: PROJECT_REPO_ROOT, PRIMARY_BRANCH, MIRROR_* vars from load-project.sh

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
