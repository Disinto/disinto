#!/usr/bin/env bash
# git-creds.sh — Shared git credential helper configuration
#
# Configures a static credential helper for Forgejo password-based HTTP auth.
# Forgejo 11.x rejects API tokens for git push (#361); password auth works.
# This ensures all git operations (clone, fetch, push) use password auth
# without needing tokens embedded in remote URLs (#604).
#
# Usage:
#   source "${FACTORY_ROOT}/lib/git-creds.sh"
#   configure_git_creds [HOME_DIR] [RUN_AS_CMD]
#   repair_baked_cred_urls [--as RUN_AS_CMD] DIR [DIR ...]
#
# Globals expected:
#   FORGE_PASS  — bot password for git HTTP auth
#   FORGE_URL   — Forge instance URL (e.g. http://forgejo:3000)
#   FORGE_TOKEN — API token (used to resolve bot username)

set -euo pipefail

# configure_git_creds [HOME_DIR] [RUN_AS_CMD]
#   HOME_DIR    — home directory for the git user (default: $HOME or /home/agent)
#   RUN_AS_CMD  — command prefix to run as another user (e.g. "gosu agent")
#
# Writes a credential helper script and configures git to use it globally.
configure_git_creds() {
  local home_dir="${1:-${HOME:-/home/agent}}"
  local run_as="${2:-}"

  if [ -z "${FORGE_PASS:-}" ] || [ -z "${FORGE_URL:-}" ]; then
    return 0
  fi

  local forge_host forge_proto
  forge_host=$(printf '%s' "$FORGE_URL" | sed 's|https\?://||; s|/.*||')
  forge_proto=$(printf '%s' "$FORGE_URL" | sed 's|://.*||')

  local log_fn="${_GIT_CREDS_LOG_FN:-echo}"

  # Determine the bot username from FORGE_TOKEN identity with retry/backoff.
  # Never fall back to a hardcoded default — a wrong username paired with the
  # real password produces a cryptic 401 that's much harder to diagnose than
  # a missing credential helper (#741).
  local bot_user=""
  if [ -n "${FORGE_TOKEN:-}" ]; then
    local attempt
    for attempt in 1 2 3 4 5; do
      bot_user=$(curl -sf --max-time 5 -H "Authorization: token ${FORGE_TOKEN}" \
        "${FORGE_URL}/api/v1/user" 2>/dev/null | jq -r '.login // empty') || bot_user=""
      if [ -n "$bot_user" ]; then
        break
      fi
      $log_fn "WARNING: Forgejo not reachable (attempt ${attempt}/5) — retrying in ${attempt}s"
      sleep "$attempt"
    done
  fi

  if [ -z "$bot_user" ]; then
    $log_fn "ERROR: Could not determine bot username from FORGE_TOKEN after 5 attempts — credential helper NOT configured"
    $log_fn "ERROR: git push will fail until this is resolved. Restart the container after Forgejo is healthy."
    return 1
  fi

  # Export BOT_USER so downstream functions (e.g. configure_git_identity) can
  # reuse the resolved value without a redundant API call.
  export BOT_USER="$bot_user"

  local helper_path="${home_dir}/.git-credentials-helper"

  # Write a static credential helper script (git credential protocol)
  cat > "$helper_path" <<CREDEOF
#!/bin/sh
# Auto-generated git credential helper for Forgejo password auth (#361, #604)
# Reads \$FORGE_PASS from env at runtime — file is safe to read on disk.
# Only respond to "get" action; ignore "store" and "erase".
[ "\$1" = "get" ] || exit 0
# Read and discard stdin (git sends protocol/host info)
cat >/dev/null
echo "protocol=${forge_proto}"
echo "host=${forge_host}"
echo "username=${bot_user}"
echo "password=\$FORGE_PASS"
CREDEOF
  chmod 755 "$helper_path"

  # Set ownership and configure git if running as a different user
  if [ -n "$run_as" ]; then
    local target_user
    target_user=$(echo "$run_as" | awk '{print $NF}')
    chown "${target_user}:${target_user}" "$helper_path" 2>/dev/null || true
    $run_as bash -c "git config --global credential.helper '${helper_path}'"
  else
    git config --global credential.helper "$helper_path"
  fi

  # Set safe.directory to work around dubious ownership after container restart
  if [ -n "$run_as" ]; then
    $run_as bash -c "git config --global --add safe.directory '*'"
  else
    git config --global --add safe.directory '*'
  fi

  # Verify the credential helper actually authenticates (#741).
  # A helper that was written with a valid username but a mismatched password
  # would silently 401 on every push — catch it now.
  if ! curl -sf --max-time 5 -u "${bot_user}:${FORGE_PASS}" \
    "${FORGE_URL}/api/v1/user" >/dev/null 2>&1; then
    $log_fn "ERROR: credential helper verification failed — ${bot_user}:FORGE_PASS rejected by Forgejo"
    rm -f "$helper_path"
    return 1
  fi
  $log_fn "Git credential helper verified: ${bot_user}@${forge_host}"
}

# repair_baked_cred_urls [--as RUN_AS_CMD] DIR [DIR ...]
#   Scans git repos under each DIR and rewrites remote URLs that contain
#   embedded credentials (user:pass@host) to clean URLs.
#   Logs each repair so operators can see the migration happened.
#
#   Optional --as flag runs git operations under the specified user wrapper
#   (e.g. "gosu agent") to avoid dubious-ownership issues on user-owned repos.
#
# Set _GIT_CREDS_LOG_FN to a custom log function name (default: echo).
repair_baked_cred_urls() {
  local log_fn="${_GIT_CREDS_LOG_FN:-echo}"
  local run_as=""
  local -a dirs=()
  while [ $# -gt 0 ]; do
    case "$1" in
      --as) shift; run_as="$1"; shift ;;
      *) dirs+=("$1"); shift ;;
    esac
  done

  for dir in "${dirs[@]}"; do
    [ -d "$dir" ] || continue

    # Find git repos: either dir itself or immediate subdirectories
    local -a repos=()
    if [ -d "${dir}/.git" ]; then
      repos+=("$dir")
    else
      local sub
      for sub in "$dir"/*/; do
        [ -d "${sub}.git" ] && repos+=("${sub%/}")
      done
    fi

    local repo
    for repo in "${repos[@]}"; do
      local url
      if [ -n "$run_as" ]; then
        url=$($run_as git -C "$repo" config --get remote.origin.url 2>/dev/null || true)
      else
        url=$(git -C "$repo" config --get remote.origin.url 2>/dev/null || true)
      fi
      [ -n "$url" ] || continue

      # Check if URL contains embedded credentials: http(s)://user:pass@host
      if printf '%s' "$url" | grep -qE '^https?://[^/]+@'; then
        # Strip credentials: http(s)://user:pass@host/path -> http(s)://host/path
        local clean_url
        clean_url=$(printf '%s' "$url" | sed -E 's|(https?://)[^@]+@|\1|')
        if [ -n "$run_as" ]; then
          $run_as git -C "$repo" remote set-url origin "$clean_url"
        else
          git -C "$repo" remote set-url origin "$clean_url"
        fi
        $log_fn "Repaired baked credentials in ${repo} (remote origin -> ${clean_url})"
      fi
    done
  done
}
