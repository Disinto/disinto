#!/usr/bin/env bash
set -euo pipefail

# entrypoint-chat.sh — Start the disinto-chat backend server
#
# Exec-replace pattern: this script is the container entrypoint and runs
# the server directly (no wrapper needed). Logs to stdout for docker logs.

LOGFILE="/var/chat/chat.log"

log() {
    printf '[%s] %s\n' "$(date -u '+%Y-%m-%d %H:%M:%S UTC')" "$*" | tee -a "$LOGFILE"
}

# Verify Claude CLI is available (expected via volume mount from host).
if ! command -v claude &>/dev/null; then
    log "FATAL: claude CLI not found in PATH"
    log "Mount the host binary into the container, e.g.:"
    log "  volumes:"
    log "    - /usr/local/bin/claude:/usr/local/bin/claude:ro"
    exit 1
fi
log "Claude CLI: $(claude --version 2>&1 || true)"

# Start the Python server (exec-replace so signals propagate correctly)
log "Starting disinto-chat server on port 8080..."
exec python3 /usr/local/bin/server.py
