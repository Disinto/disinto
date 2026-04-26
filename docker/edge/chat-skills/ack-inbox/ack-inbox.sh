#!/usr/bin/env bash
# =============================================================================
# ack-inbox.sh — dismiss/accept/snooze an inbox item (chat-skill wrapper)
#
# Part of the chat-Claude operator surface (#797). Thin wrapper over
# bin/inbox-ack.sh that gives the voice/chat tool layer a single command
# surface for ack actions, parallel to how `narrate` wraps qwen and
# `factory-state` wraps the snapshot read.
#
# Usage:
#   ack-inbox.sh <id> <dismiss|accept|snooze>
#
# Actions:
#   dismiss  — calls `inbox-ack.sh <id>`. Item never surfaces again.
#   accept   — same storage as dismiss; semantic "user is acting on it
#              now". Voice/chat model is responsible for the follow-up.
#   snooze   — calls `inbox-ack.sh --snooze <id>`. Item reappears in 1h.
#
# Output: short confirmation on stdout (`dismissed`, `accepted`,
# `snoozed for 1h`). Errors go to stderr.
#
# Exit codes:
#   0 — success
#   1 — id not found, invalid action, or missing args
#
# Environment:
#   INBOX_ACK_BIN  — path to bin/inbox-ack.sh (default: search common paths)
#   SNAPSHOT_PATH  — state.json (default /var/lib/disinto/snapshot/state.json)
# =============================================================================
set -euo pipefail

SNAPSHOT_PATH="${SNAPSHOT_PATH:-/var/lib/disinto/snapshot/state.json}"

usage() {
  printf 'usage: ack-inbox.sh <id> <dismiss|accept|snooze>\n' >&2
}

# ── Parse args ───────────────────────────────────────────────────────────────

if [ $# -ne 2 ]; then
  usage
  exit 1
fi

id="$1"
action="$2"

if [ -z "$id" ]; then
  usage
  exit 1
fi

case "$action" in
  dismiss|accept|snooze) ;;
  *)
    printf 'invalid action: %s (expected dismiss|accept|snooze)\n' "$action" >&2
    exit 1
    ;;
esac

# ── Resolve inbox-ack.sh ─────────────────────────────────────────────────────

resolve_inbox_ack() {
  if [ -n "${INBOX_ACK_BIN:-}" ] && [ -x "$INBOX_ACK_BIN" ]; then
    printf '%s' "$INBOX_ACK_BIN"
    return 0
  fi

  local candidates=(
    "/opt/disinto/bin/inbox-ack.sh"
    "/usr/local/bin/inbox-ack.sh"
  )

  # Repo-relative fallback: <repo>/bin/inbox-ack.sh, where this script
  # lives at <repo>/docker/edge/chat-skills/ack-inbox/ack-inbox.sh.
  local script_dir
  script_dir="$(cd "$(dirname "$0")" && pwd)"
  candidates+=("${script_dir}/../../../../bin/inbox-ack.sh")

  local c
  for c in "${candidates[@]}"; do
    if [ -x "$c" ]; then
      printf '%s' "$c"
      return 0
    fi
  done

  # Last resort: PATH lookup.
  if command -v inbox-ack.sh >/dev/null 2>&1; then
    command -v inbox-ack.sh
    return 0
  fi

  return 1
}

# ── Verify id exists in current snapshot ────────────────────────────────────

id_in_snapshot() {
  local needle="$1"
  [ -f "$SNAPSHOT_PATH" ] || return 1
  jq -e --arg id "$needle" \
    '(.inbox.items // []) | map(.id) | index($id) != null' \
    "$SNAPSHOT_PATH" >/dev/null 2>&1
}

if ! id_in_snapshot "$id"; then
  printf 'inbox item not found: %s\n' "$id" >&2
  exit 1
fi

# ── Dispatch to bin/inbox-ack.sh ────────────────────────────────────────────

ack_bin="$(resolve_inbox_ack)" || {
  printf 'inbox-ack.sh not found (set INBOX_ACK_BIN to override)\n' >&2
  exit 1
}

case "$action" in
  dismiss|accept)
    "$ack_bin" "$id" >/dev/null
    ;;
  snooze)
    "$ack_bin" --snooze "$id" >/dev/null
    ;;
esac

# ── Confirmation ─────────────────────────────────────────────────────────────

case "$action" in
  dismiss) printf 'dismissed\n' ;;
  accept)  printf 'accepted\n' ;;
  snooze)  printf 'snoozed for 1h\n' ;;
esac
