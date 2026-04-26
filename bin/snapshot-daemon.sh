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
export SNAPSHOT_PATH
SNAPSHOT_DIR="$(dirname "$SNAPSHOT_PATH")"

SNAPSHOT_COLLECTOR_TIMEOUT_SECS="${SNAPSHOT_COLLECTOR_TIMEOUT_SECS:-3}"

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

# ── Collector runner ──────────────────────────────────────────────────────────

run_collector() {
  local script="$1"
  if [ ! -f "$script" ]; then
    return 0
  fi
  if [ ! -x "$script" ]; then
    return 0
  fi
  if ! timeout "${SNAPSHOT_COLLECTOR_TIMEOUT_SECS}" "$script" 2>>"$daemon_stderr_log"; then
    log "collector $(basename "$script") failed (continuing)"
  fi
}

# Main loop.
log() {
  printf '[%s] snapshot: %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$*"
}

daemon_stderr_log="$(mktemp "${SNAPSHOT_DIR}/snapshot-daemon.stderr.XXXXXX")"

log "starting — interval=${SNAPSHOT_INTERVAL_SECS}s path=${SNAPSHOT_PATH}"

# Warn once at startup if collectors are missing.
for collector in snapshot-nomad.sh snapshot-forge.sh snapshot-agents.sh snapshot-inbox.sh; do
  collector_path="$(dirname "$0")/$collector"
  if [ ! -f "$collector_path" ]; then
    log "collector $collector not found — skipping"
  fi
done

# Write the initial tick immediately so a reader never races the loop.
write_tick

while true; do
  sleep "$SNAPSHOT_INTERVAL_SECS"

  # Run collectors in series (concurrent would race the atomic-mv write).
  run_collector "$(dirname "$0")/snapshot-nomad.sh"
  run_collector "$(dirname "$0")/snapshot-forge.sh"
  run_collector "$(dirname "$0")/snapshot-agents.sh"
  run_collector "$(dirname "$0")/snapshot-inbox.sh"

  write_tick
done
