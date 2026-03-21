#!/usr/bin/env bash
# =============================================================================
# gardener-poll.sh — Cron wrapper for the gardener agent
#
# Cron: daily (or 2x/day). Handles lock management, escalation reply
# injection for dev sessions, and files an action issue for backlog
# grooming via formulas/run-gardener.toml (picked up by action-agent).
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

# ── Check for escalation replies from Matrix ──────────────────────────────
ESCALATION_REPLY=""
if [ -s /tmp/gardener-escalation-reply ]; then
  _raw_reply=$(cat /tmp/gardener-escalation-reply)
  rm -f /tmp/gardener-escalation-reply
  log "Got escalation reply: $(echo "$_raw_reply" | head -1)"

  # Filter stale escalation entries referencing already-closed issues (#289).
  # Escalation records can persist after the underlying issue resolves; acting
  # on them wastes cycles (e.g. creating investigation issues for merged PRs).
  while IFS= read -r _reply_line; do
    [ -z "$_reply_line" ] && continue
    _esc_nums=$(echo "$_reply_line" | grep -oP '#\K\d+' | sort -u || true)
    if [ -n "$_esc_nums" ]; then
      _any_open=false
      for _esc_n in $_esc_nums; do
        _esc_st=$(codeberg_api GET "/issues/${_esc_n}" 2>/dev/null \
          | jq -r '.state // "open"' 2>/dev/null || echo "open")
        if [ "$_esc_st" != "closed" ]; then
          _any_open=true
          break
        fi
      done
      if [ "$_any_open" = false ]; then
        log "Discarding stale escalation (all referenced issues closed): $(echo "$_reply_line" | head -c 120)"
        continue
      fi
    fi
    ESCALATION_REPLY="${ESCALATION_REPLY}${_reply_line}
"
  done <<< "$_raw_reply"

  if [ -n "$ESCALATION_REPLY" ]; then
    log "Escalation reply after filtering: $(echo "$ESCALATION_REPLY" | grep -c '.' || echo 0) line(s)"
  else
    log "All escalation entries were stale — discarded"
  fi
fi
# ESCALATION_REPLY is used below when constructing the action issue body

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

# ── Backlog grooming (file action issue for run-gardener formula) ─────────
# shellcheck source=../lib/file-action-issue.sh
source "$FACTORY_ROOT/lib/file-action-issue.sh"

ESCALATION_CONTEXT=""
if [ -n "${ESCALATION_REPLY:-}" ]; then
  ESCALATION_CONTEXT="

## Pending escalation replies

Human responses to previous gardener escalations. Process these FIRST.
Format: '1a 2c 3b' means question 1→option (a), 2→option (c), 3→option (b).

${ESCALATION_REPLY}"
fi

ISSUE_BODY="---
formula: run-gardener
model: opus
---

Periodic gardener housekeeping run. The action-agent reads \`formulas/run-gardener.toml\`
and executes the steps: preflight, grooming, blocked-review,
AGENTS.md update, and commit-and-pr.${ESCALATION_CONTEXT}

Filed automatically by \`gardener-poll.sh\`."

_rc=0
file_action_issue "run-gardener" "action: run-gardener — periodic housekeeping" "$ISSUE_BODY" || _rc=$?
case "$_rc" in
  0) log "Filed action issue #${FILED_ISSUE_NUM} for run-gardener formula"
     matrix_send "gardener" "Filed action #${FILED_ISSUE_NUM}: run-gardener — periodic housekeeping" 2>/dev/null || true
     ;;
  1) log "Open run-gardener action issue already exists — skipping" ;;
  2) log "ERROR: 'action' label not found — cannot file gardener issue" ;;
  4) log "ERROR: issue body contains potential secrets — skipping" ;;
  *) log "WARNING: failed to create action issue for run-gardener (rc=$_rc)" ;;
esac

log "--- Gardener poll done ---"
