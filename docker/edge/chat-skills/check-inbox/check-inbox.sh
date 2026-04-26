#!/usr/bin/env bash
# =============================================================================
# check-inbox.sh — read prioritized inbox items, mark shown on return
#
# Reads the snapshot's inbox section, returns a voice-friendly prioritized list,
# and marks each returned item as "shown" so the next call doesn't re-surface
# them.
#
# Usage:
#   check-inbox.sh                      — all unshown items, all priorities
#   check-inbox.sh --min-priority P0    — only P0 items
#   check-inbox.sh --min-priority P1    — P0 and P1 items
#   check-inbox.sh --min-priority P2    — all items (default)
#
# Output:
#   Plain-text, voice-friendly:
#     3 unread inbox items:
#       P0: incident-2026-04-12-sunday — "Incident analysis just finished"
#       P1: action-vault/sprint-12.md — "Architect drafted sprint 12"
#       P2: del-abc123def456 — "ci-flaky thread completed"
#
#   Empty output (exit 0) when nothing to surface.
#
# Side-effect: marks each returned item as shown via inbox-ack.sh --shown.
# =============================================================================
set -euo pipefail

SNAPSHOT_PATH="${SNAPSHOT_PATH:-/var/lib/disinto/snapshot/state.json}"
INBOX_ROOT="${INBOX_ROOT:-/var/lib/disinto/inbox}"
readonly ACKED_DIR="${INBOX_ROOT}/.acked"
readonly SHOWN_DIR="${INBOX_ROOT}/.shown"
readonly SNOOZED_DIR="${INBOX_ROOT}/.snoozed"
ACK_SCRIPT="$(dirname "$0")/../../../../bin/inbox-ack.sh"

# ── Parse arguments ──────────────────────────────────────────────────────────

min_priority="P2"

while [ $# -gt 0 ]; do
  case "$1" in
    --min-priority)
      min_priority="${2:-P2}"
      case "$min_priority" in
        P0|P1|P2) shift 2 ;;
        *) printf 'check-inbox: invalid priority: %s (use P0, P1, or P2)\n' "$min_priority" >&2; exit 2 ;;
      esac
      ;;
    -h|--help)
      printf 'usage: check-inbox.sh [--min-priority P0|P1|P2]\n'
      exit 0
      ;;
    *)
      printf 'check-inbox: unknown arg: %s\n' "$1" >&2
      exit 2
      ;;
  esac
done

# ── Priority helpers ─────────────────────────────────────────────────────────

# Returns the numeric rank for a priority level (lower = higher priority).
prio_rank() {
  case "$1" in
    P0) echo 0 ;;
    P1) echo 1 ;;
    P2) echo 2 ;;
    *)  echo 2 ;;
  esac
}

min_rank="$(prio_rank "$min_priority")"

# ── Sentinel check ───────────────────────────────────────────────────────────

# Returns 0 (true) if the item should be excluded (acked, snoozed, or shown).
item_excluded() {
  local id="$1"

  # Acked: always exclude
  [ -f "${ACKED_DIR}/${id}" ] && return 0

  # Shown: exclude (read-once semantics)
  [ -f "${SHOWN_DIR}/${id}" ] && return 0

  # Snoozed: exclude while mtime > now
  local snooze_file="${SNOOZED_DIR}/${id}"
  if [ -f "$snooze_file" ]; then
    local snooze_mtime now_epoch
    snooze_mtime="$(stat -c '%Y' "$snooze_file" 2>/dev/null)" || return 0
    now_epoch="$(date +%s)"
    [ "$snooze_mtime" -gt "$now_epoch" ] && return 0
  fi

  return 1
}

# ── Read snapshot ─────────────────────────────────────────────────────────────

if [ ! -f "$SNAPSHOT_PATH" ]; then
  exit 0
fi

snapshot=$(cat "$SNAPSHOT_PATH")

if ! printf '%s' "$snapshot" | jq empty 2>/dev/null; then
  exit 0
fi

# ── Filter and collect items ─────────────────────────────────────────────────

# Extract inbox items, filter by priority + sentinels, collect eligible items.
eligible_file="$(mktemp)"
trap 'rm -f "$eligible_file"' EXIT

printf '%s' "$snapshot" | jq -r -c '.inbox.items // [] | .[] | [.id, .priority, .title] | @tsv' 2>/dev/null | \
while IFS=$'\t' read -r item_id item_priority item_title; do
  # Skip empty lines
  [ -z "$item_id" ] && continue

  # Filter by priority threshold
  item_rank="$(prio_rank "$item_priority")"
  [ "$item_rank" -gt "$min_rank" ] && continue

  # Filter by sentinels (acked, shown, snoozed)
  item_excluded "$item_id" && continue

  printf '%s\t%s\t%s\n' "$item_id" "$item_priority" "$item_title"
done > "$eligible_file"

# ── Check if there are items ─────────────────────────────────────────────────

item_count=$(wc -l < "$eligible_file")
if [ "$item_count" -eq 0 ]; then
  exit 0
fi

# ── Mark items as shown and build output ─────────────────────────────────────

# Build output lines first, then mark shown, then print.
# This way we only mark shown if there actually is output.
output_lines=""
while IFS=$'\t' read -r item_id item_priority item_title; do
  line="  ${item_priority}: ${item_id} — \"${item_title}\""
  if [ -z "$output_lines" ]; then
    output_lines="$line"
  else
    output_lines="${output_lines}
${line}"
  fi
done < "$eligible_file"

# Mark each item as shown
while IFS=$'\t' read -r item_id _ _; do
  INBOX_ROOT="$INBOX_ROOT" bash "$ACK_SCRIPT" --shown "$item_id" 2>/dev/null || true
done < "$eligible_file"

# ── Print result ─────────────────────────────────────────────────────────────

printf '%d unread inbox items:\n' "$item_count"
printf '%s\n' "$output_lines"
