#!/usr/bin/env bash
# =============================================================================
# inbox-ack.sh — per-item ack/shown/snooze sentinel for inbox inbox-state
#
# Writes sentinel files under /var/lib/disinto/inbox/.{acked,shown,snoozed}/<id>
# to control which items snapshot-inbox.sh surfaces.
#
# Usage:
#   inbox-ack.sh <id>              — mark item as acknowledged
#   inbox-ack.sh --shown <id>      — mark item as shown (still surfaces on explicit query)
#   inbox-ack.sh --snooze <id>     — snooze item for 1h (mtime = now + 3600)
#
# Idempotent: repeated calls are safe (touch overwrites).
# Atomic: per-id files — no shared-file races between parallel calls.
# =============================================================================
set -euo pipefail

INBOX_ROOT="${INBOX_ROOT:-/var/lib/disinto/inbox}"
readonly ACKED_DIR="${INBOX_ROOT}/.acked"
readonly SHOWN_DIR="${INBOX_ROOT}/.shown"
readonly SNOOZED_DIR="${INBOX_ROOT}/.snoozed"
readonly SNOOZE_DURATION=3600

log() {
  printf '[%s] inbox-ack: %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$*" >&2
}

die() {
  printf 'Usage: inbox-ack.sh [--shown|--snooze] <id>\n' >&2
  exit 1
}

ensure_dir() {
  mkdir -p "$1"
}

write_sentinel() {
  local dir="$1"
  local id="$2"
  ensure_dir "$dir"
  printf '%s' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" > "${dir}/${id}"
}

snooze_item() {
  local id="$1"
  ensure_dir "$SNOOZED_DIR"
  local sentinel="${SNOOZED_DIR}/${id}"
  # Write timestamp then set mtime to now + SNOOZE_DURATION.
  # touch -d can set both atime/mtime; we use -t for explicit timestamp.
  local future_epoch
  future_epoch="$(date -d "+${SNOOZE_DURATION} seconds" +%s 2>/dev/null)" || future_epoch="$(date -d "@$(( $(date +%s) + SNOOZE_DURATION ))" +%s 2>/dev/null)" || future_epoch="$(date -v+${SNOOZE_DURATION}S +%s 2>/dev/null)" || future_epoch="$(date -d "+1 hour" +%s 2>/dev/null)"
  printf '%s' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" > "$sentinel"
  touch -d "@${future_epoch}" "$sentinel"
}

main() {
  local mode="ack"
  local id=""

  # Parse args: support --shown, --snooze as prefix, id as last arg.
  case "${1:-}" in
    --shown)
      mode="shown"
      id="${2:-}"
      ;;
    --snooze)
      mode="snooze"
      id="${2:-}"
      ;;
    *)
      id="${1:-}"
      ;;
  esac

  if [ -z "$id" ]; then
    die
  fi

  case "$mode" in
    ack)
      write_sentinel "$ACKED_DIR" "$id"
      log "acked id=${id}"
      ;;
    shown)
      write_sentinel "$SHOWN_DIR" "$id"
      log "shown id=${id}"
      ;;
    snooze)
      snooze_item "$id"
      log "snoozed id=${id} (expires in ${SNOOZE_DURATION}s)"
      ;;
  esac
}

main "$@"
