#!/usr/bin/env bash
# dsh-oneshot.sh — one prompt through dsh headless, text back (#1847).
#
# Sourced library: no top-level `set` line. Callers source lib/agent-sdk.sh
# first (for redact_log_secrets) and define log() the way that file requires.
#
# dsh_oneshot [--timeout SECS] PROMPT
#   One prompt in, the model's final text out. Always runs dsh, whatever
#   AGENT_HARNESS says. Writes no SID_FILE, diagnostics file, metrics
#   record, or globals.
#
#   limit is SECS when --timeout is given, otherwise ${CLAUDE_TIMEOUT:-7200}.
#   In the current directory:
#     DSH_HOME="${DSH_HOME:-$HOME/.dsh}" \
#     DSH_PERMISSION_MODE=danger-full-access \
#     DSH_RESUME_SESSION="" \
#     timeout -k 10 "$limit" dsh --profile headless "$PROMPT"
#   stderr is appended to ${LOGFILE:-/dev/null}. An empty DSH_RESUME_SESSION
#   stops an inherited value from resuming an agent session.
#   Stdout (dsh headless prints the last assistant text there) is printed
#   through redact_log_secrets. Returns dsh's exit code; 124 means the
#   time limit fired (GNU timeout).
dsh_oneshot() {
  local limit="${CLAUDE_TIMEOUT:-7200}"
  local prompt=""
  local rc=0
  local out=""
  if [ "${1-}" = "--timeout" ]; then
    limit="${2-}"
    shift 2
  fi
  prompt="${1-}"
  # Prefix assignments apply only to this command, so the caller's
  # DSH_RESUME_SESSION (and AGENT_HARNESS) are left alone.
  out=$(DSH_HOME="${DSH_HOME:-$HOME/.dsh}" DSH_PERMISSION_MODE=danger-full-access DSH_RESUME_SESSION="" timeout -k 10 "$limit" dsh --profile headless "$prompt" 2>>"${LOGFILE:-/dev/null}") || rc=$?
  printf '%s\n' "$out" | redact_log_secrets
  return "$rc"
}
