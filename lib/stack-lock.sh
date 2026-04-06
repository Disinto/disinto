#!/usr/bin/env bash
# stack-lock.sh — File-based lock protocol for singleton project stack access
#
# Prevents CI pipelines and the reproduce-agent from stepping on each other
# when sharing a single project stack (e.g. harb docker compose).
#
# Lock file: /home/agent/data/locks/<project>-stack.lock
# Contents:  {"holder": "reproduce-agent-42", "since": "...", "heartbeat": "..."}
#
# Protocol:
#   1. stack_lock_check   — inspect current lock state
#   2. stack_lock_acquire — wait until lock is free, then claim it
#   3. stack_lock_release — delete lock file when done
#
# Heartbeat: callers must update the heartbeat every 2 minutes while holding
# the lock by calling stack_lock_heartbeat. A heartbeat older than 10 minutes
# is considered stale — the next acquire will break it.
#
# Usage:
#   source "$(dirname "$0")/../lib/stack-lock.sh"
#   stack_lock_acquire "ci-pipeline-$BUILD_NUMBER" "myproject"
#   trap 'stack_lock_release "myproject"' EXIT
#   # ... do work ...
#   stack_lock_release "myproject"

set -euo pipefail

STACK_LOCK_DIR="${HOME}/data/locks"
STACK_LOCK_POLL_INTERVAL=30   # seconds between retry polls
STACK_LOCK_STALE_SECONDS=600  # 10 minutes — heartbeat older than this = stale
STACK_LOCK_MAX_WAIT=3600      # 1 hour — give up after this many seconds

# _stack_lock_path <project>
#   Print the path of the lock file for the given project.
_stack_lock_path() {
  local project="$1"
  echo "${STACK_LOCK_DIR}/${project}-stack.lock"
}

# _stack_lock_now
#   Print current UTC timestamp in ISO-8601 format.
_stack_lock_now() {
  date -u +"%Y-%m-%dT%H:%M:%SZ"
}

# _stack_lock_epoch <iso_timestamp>
#   Convert an ISO-8601 UTC timestamp to a Unix epoch integer.
_stack_lock_epoch() {
  local ts="$1"
  # Strip trailing Z, replace T with space for `date -d`
  date -u -d "${ts%Z}" +%s 2>/dev/null || date -u -j -f "%Y-%m-%dT%H:%M:%S" "${ts%Z}" +%s 2>/dev/null
}

# stack_lock_check <project>
#   Print lock status to stdout: "free", "held:<holder>", or "stale:<holder>".
#   Returns 0 in all cases (status is in stdout).
stack_lock_check() {
  local project="$1"
  local lock_file
  lock_file="$(_stack_lock_path "$project")"

  if [ ! -f "$lock_file" ]; then
    echo "free"
    return 0
  fi

  local holder heartbeat
  holder=$(python3 -c 'import sys,json; d=json.load(open(sys.argv[1])); print(d.get("holder","unknown"))' "$lock_file" 2>/dev/null || echo "unknown")
  heartbeat=$(python3 -c 'import sys,json; d=json.load(open(sys.argv[1])); print(d.get("heartbeat",""))' "$lock_file" 2>/dev/null || echo "")

  if [ -z "$heartbeat" ]; then
    echo "stale:${holder}"
    return 0
  fi

  local hb_epoch now_epoch age
  hb_epoch=$(_stack_lock_epoch "$heartbeat" 2>/dev/null || echo "0")
  now_epoch=$(date -u +%s)
  age=$(( now_epoch - hb_epoch ))

  if [ "$age" -gt "$STACK_LOCK_STALE_SECONDS" ]; then
    echo "stale:${holder}"
  else
    echo "held:${holder}"
  fi
}

# stack_lock_acquire <holder_id> <project> [max_wait_seconds]
#   Acquire the lock for <project> on behalf of <holder_id>.
#   Polls every STACK_LOCK_POLL_INTERVAL seconds.
#   Breaks stale locks automatically.
#   Exits non-zero if the lock cannot be acquired within max_wait_seconds.
stack_lock_acquire() {
  local holder="$1"
  local project="$2"
  local max_wait="${3:-$STACK_LOCK_MAX_WAIT}"
  local lock_file
  lock_file="$(_stack_lock_path "$project")"
  local deadline
  deadline=$(( $(date -u +%s) + max_wait ))

  mkdir -p "$STACK_LOCK_DIR"

  while true; do
    local status
    status=$(stack_lock_check "$project")

    case "$status" in
      free)
        # Write to temp file then rename to avoid partial reads by other processes
        local tmp_lock
        tmp_lock=$(mktemp "${STACK_LOCK_DIR}/.lock-tmp-XXXXXX")
        local now
        now=$(_stack_lock_now)
        printf '{"holder": "%s", "since": "%s", "heartbeat": "%s"}\n' \
          "$holder" "$now" "$now" > "$tmp_lock"
        mv "$tmp_lock" "$lock_file"
        echo "[stack-lock] acquired lock for ${project} as ${holder}" >&2
        return 0
        ;;
      stale:*)
        local stale_holder="${status#stale:}"
        echo "[stack-lock] breaking stale lock held by ${stale_holder} for ${project}" >&2
        rm -f "$lock_file"
        # Loop back immediately to re-check and claim
        ;;
      held:*)
        local cur_holder="${status#held:}"
        local remaining
        remaining=$(( deadline - $(date -u +%s) ))
        if [ "$remaining" -le 0 ]; then
          echo "[stack-lock] timed out waiting for lock on ${project} (held by ${cur_holder})" >&2
          return 1
        fi
        echo "[stack-lock] ${project} locked by ${cur_holder}, waiting ${STACK_LOCK_POLL_INTERVAL}s (${remaining}s left)..." >&2
        sleep "$STACK_LOCK_POLL_INTERVAL"
        ;;
      *)
        echo "[stack-lock] unexpected status '${status}' for ${project}" >&2
        return 1
        ;;
    esac
  done
}

# stack_lock_heartbeat <holder_id> <project>
#   Update the heartbeat timestamp in the lock file.
#   Should be called every 2 minutes while holding the lock.
#   No-op if the lock file is absent or held by a different holder.
stack_lock_heartbeat() {
  local holder="$1"
  local project="$2"
  local lock_file
  lock_file="$(_stack_lock_path "$project")"

  [ -f "$lock_file" ] || return 0

  local current_holder
  current_holder=$(python3 -c 'import sys,json; d=json.load(open(sys.argv[1])); print(d.get("holder",""))' "$lock_file" 2>/dev/null || echo "")
  [ "$current_holder" = "$holder" ] || return 0

  local since
  since=$(python3 -c 'import sys,json; d=json.load(open(sys.argv[1])); print(d.get("since",""))' "$lock_file" 2>/dev/null || echo "")
  local now
  now=$(_stack_lock_now)

  local tmp_lock
  tmp_lock=$(mktemp "${STACK_LOCK_DIR}/.lock-tmp-XXXXXX")
  printf '{"holder": "%s", "since": "%s", "heartbeat": "%s"}\n' \
    "$holder" "$since" "$now" > "$tmp_lock"
  mv "$tmp_lock" "$lock_file"
}

# stack_lock_release <project> [holder_id]
#   Release the lock for <project>.
#   If holder_id is provided, only releases if the lock is held by that holder
#   (prevents accidentally releasing someone else's lock).
stack_lock_release() {
  local project="$1"
  local holder="${2:-}"
  local lock_file
  lock_file="$(_stack_lock_path "$project")"

  [ -f "$lock_file" ] || return 0

  if [ -n "$holder" ]; then
    local current_holder
    current_holder=$(python3 -c 'import sys,json; d=json.load(open(sys.argv[1])); print(d.get("holder",""))' "$lock_file" 2>/dev/null || echo "")
    if [ "$current_holder" != "$holder" ]; then
      echo "[stack-lock] refusing to release: lock held by '${current_holder}', not '${holder}'" >&2
      return 1
    fi
  fi

  rm -f "$lock_file"
  echo "[stack-lock] released lock for ${project}" >&2
}
