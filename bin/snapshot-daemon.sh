#!/usr/bin/env bash
# =============================================================================
# snapshot-daemon.sh — factory-state snapshot writer
#
# Polls every SNAPSHOT_INTERVAL_SECS (default 5) and writes a JSON stub to
# SNAPSHOT_PATH (/var/lib/disinto/snapshot/state.json) via atomic mv from a
# tmpfile in the same directory.
#
# Each tick starts from the *previous* snapshot file (if present) so that
# collectors running as separate tasks can merge their sub-key data
# incrementally. The top-level shape is:
#   {"version":1,"ts":"<iso8601>","collectors":{}}
#
# Environment:
#   SNAPSHOT_INTERVAL_SECS  — poll interval in seconds (default 5)
#   SNAPSHOT_PATH           — output path (default /var/lib/disinto/snapshot/state.json)
# =============================================================================
set -euo pipefail

SNAPSHOT_INTERVAL_SECS="${SNAPSHOT_INTERVAL_SECS:-5}"
SNAPSHOT_PATH="${SNAPSHOT_PATH:-/var/lib/disinto/snapshot/state.json}"
SNAPSHOT_DIR="$(dirname "$SNAPSHOT_PATH")"

# Ensure output directory exists.
mkdir -p "$SNAPSHOT_DIR"

# Read previous snapshot if it exists (for additive collector merges).
read_previous_snapshot() {
  if [ -f "$SNAPSHOT_PATH" ]; then
    cat "$SNAPSHOT_PATH"
  else
    printf '{"version":1,"ts":"","collectors":{}}'
  fi
}

# Merge two JSON objects: overlay $2 into $1 (deep merge).
# Returns merged JSON on stdout. Used by collectors to add sub-keys.
json_merge() {
  local base="$1" overlay="$2"
  jq -n --argjson a "$base" --argjson b "$overlay" '$a * $b' 2>/dev/null || printf '%s' "$base"
}

# Write one snapshot tick.
# Reads the previous file, updates only "ts", writes atomically.
write_tick() {
  local prev
  prev="$(read_previous_snapshot)"

  local ts
  ts="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"

  # Start from previous snapshot, replace "ts" with fresh timestamp.
  local payload
  payload=$(printf '%s' "$prev" | jq -c --arg ts "$ts" '.ts = $ts')

  local tmpfile
  tmpfile="$(mktemp "${SNAPSHOT_DIR}/state.json.XXXXXX")"

  printf '%s\n' "$payload" > "$tmpfile"
  mv -f "$tmpfile" "$SNAPSHOT_PATH"
}

# Main loop.
log() {
  printf '[%s] snapshot: %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$*"
}

log "starting — interval=${SNAPSHOT_INTERVAL_SECS}s path=${SNAPSHOT_PATH}"

# Write the initial tick immediately so a reader never races the loop.
write_tick

while true; do
  sleep "$SNAPSHOT_INTERVAL_SECS"
  write_tick
done
