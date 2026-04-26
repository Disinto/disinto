#!/usr/bin/env bash
# inbox-sentinels.sh — Inbox sentinel helpers (acked / snoozed / shown)
#
# Shared across inbox-aware scripts (snapshot-inbox.sh, check-inbox.sh, etc.)
#
# Required variables (set by caller):
#   INBOX_ROOT  — root directory for inbox data (default: /var/lib/disinto/inbox)
#   SNAPSHOT_PATH — path to snapshot state.json (for snapshot-inbox.sh)

INBOX_ROOT="${INBOX_ROOT:-/var/lib/disinto/inbox}"
# shellcheck disable=SC2034
readonly ACKED_DIR="${INBOX_ROOT}/.acked"
# shellcheck disable=SC2034
readonly SHOWN_DIR="${INBOX_ROOT}/.shown"
readonly SNOOZED_DIR="${INBOX_ROOT}/.snoozed"

# ── Sentinel helpers ─────────────────────────────────────────────────────────

# item_snoozed <id>
#   Returns 0 (true) if the item is snoozed and not yet expired.
item_snoozed() {
  local id="$1"
  local snooze_file="${SNOOZED_DIR}/${id}"
  if [ -f "$snooze_file" ]; then
    local snooze_mtime now_epoch
    snooze_mtime="$(stat -c '%Y' "$snooze_file" 2>/dev/null)" || return 0
    now_epoch="$(date +%s)"
    [ "$snooze_mtime" -gt "$now_epoch" ] && return 0
  fi
  return 1
}
