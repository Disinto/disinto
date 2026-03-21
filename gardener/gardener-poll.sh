#!/usr/bin/env bash
# =============================================================================
# gardener-poll.sh — Cron wrapper for the gardener agent
#
# Cron: daily (or 2x/day). Handles lock management, escalation reply
# injection, and delegates backlog grooming to gardener-agent.sh.
#
# Grooming (delegated to gardener-agent.sh):
#   - Duplicate titles / overlapping scope
#   - Missing acceptance criteria
#   - Stale issues (no activity > 14 days)
#   - Blockers starving the factory
#   - Tech-debt promotion / dust bundling
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
FACTORY_ROOT="$(dirname "$SCRIPT_DIR")"

# Load shared environment (with optional project TOML override)
# Usage: gardener-poll.sh [projects/harb.toml]
export PROJECT_TOML="${1:-}"
# shellcheck source=../lib/env.sh
source "$FACTORY_ROOT/lib/env.sh"

LOG_FILE="$SCRIPT_DIR/gardener.log"
LOCK_FILE="/tmp/gardener-poll.lock"

log() { echo "[$(date -u +%Y-%m-%dT%H:%M:%S)Z] $*" >> "$LOG_FILE"; }

# ── Lock ──────────────────────────────────────────────────────────────────
if [ -f "$LOCK_FILE" ]; then
  LOCK_PID=$(cat "$LOCK_FILE" 2>/dev/null || true)
  if [ -n "$LOCK_PID" ] && kill -0 "$LOCK_PID" 2>/dev/null; then
    log "poll: gardener running (PID $LOCK_PID)"
    exit 0
  fi
  rm -f "$LOCK_FILE"
fi
echo $$ > "$LOCK_FILE"
trap 'rm -f "$LOCK_FILE"' EXIT

log "--- Gardener poll start ---"

# Gitea labels API requires []int64 — look up the "backlog" label ID once
# Falls back to the known Codeberg repo ID if the API call fails
BACKLOG_LABEL_ID=$(codeberg_api GET "/labels" 2>/dev/null \
  | jq -r '.[] | select(.name == "backlog") | .id' 2>/dev/null || true)
BACKLOG_LABEL_ID="${BACKLOG_LABEL_ID:-1300815}"

# ── Check for escalation replies from Matrix ──────────────────────────────
ESCALATION_REPLY=""
if [ -s /tmp/gardener-escalation-reply ]; then
  ESCALATION_REPLY=$(cat /tmp/gardener-escalation-reply)
  rm -f /tmp/gardener-escalation-reply
  log "Got escalation reply: $(echo "$ESCALATION_REPLY" | head -1)"
fi
export ESCALATION_REPLY

# ── Inject human replies into needs_human dev sessions (backup to supervisor) ─
HUMAN_REPLY_FILE="/tmp/dev-escalation-reply"
for _gr_phase_file in /tmp/dev-session-"${PROJECT_NAME}"-*.phase; do
  [ -f "$_gr_phase_file" ] || continue
  _gr_phase=$(head -1 "$_gr_phase_file" 2>/dev/null | tr -d '[:space:]' || true)
  [ "$_gr_phase" = "PHASE:needs_human" ] || continue

  _gr_issue=$(basename "$_gr_phase_file" .phase)
  _gr_issue="${_gr_issue#dev-session-${PROJECT_NAME}-}"
  [ -z "$_gr_issue" ] && continue
  _gr_session="dev-${PROJECT_NAME}-${_gr_issue}"

  tmux has-session -t "$_gr_session" 2>/dev/null || continue

  # Atomic claim — only take the file once we know a session needs it
  _gr_claimed="/tmp/dev-escalation-reply.gardener.$$"
  [ -s "$HUMAN_REPLY_FILE" ] && mv "$HUMAN_REPLY_FILE" "$_gr_claimed" 2>/dev/null || continue
  _gr_reply=$(cat "$_gr_claimed")

  _gr_inject_msg="Human reply received for issue #${_gr_issue}:

${_gr_reply}

Instructions:
1. Read the human's guidance carefully.
2. Continue your work based on their input.
3. When done, push your changes and write the appropriate phase."

  _gr_tmpfile=$(mktemp /tmp/human-inject-XXXXXX)
  printf '%s' "$_gr_inject_msg" > "$_gr_tmpfile"
  tmux load-buffer -b "human-inject-${_gr_issue}" "$_gr_tmpfile" || true
  tmux paste-buffer -t "$_gr_session" -b "human-inject-${_gr_issue}" || true
  sleep 0.5
  tmux send-keys -t "$_gr_session" "" Enter || true
  tmux delete-buffer -b "human-inject-${_gr_issue}" 2>/dev/null || true
  rm -f "$_gr_tmpfile" "$_gr_claimed"

  rm -f "/tmp/dev-renotify-${PROJECT_NAME}-${_gr_issue}"
  log "${PROJECT_NAME}: #${_gr_issue} human reply injected into session ${_gr_session} (gardener)"
  break  # only one reply to deliver
done

# ── Backlog grooming (delegated to gardener-agent.sh) ────────────────────
log "Invoking gardener-agent.sh for backlog grooming"
bash "$SCRIPT_DIR/gardener-agent.sh" "${1:-}" || log "WARNING: gardener-agent.sh exited with error"


log "--- Gardener poll done ---"
