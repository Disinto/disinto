#!/usr/bin/env bash
# agent-harness-dsh.sh — dsh harness for agent_run (#1106)
#
# Implements _agent_run_dsh(), the dsh half of the harness dispatcher in
# lib/agent-sdk.sh (#1104). It satisfies exactly the contract documented
# above agent_run() there, so the caller scripts need no changes:
#
#   _agent_run_dsh [--resume SESSION_ID] [--worktree DIR] [--task REF] PROMPT
#
#   - runs `dsh --profile headless PROMPT` in the worktree with DSH_HOME
#     at the agent's config dir (dsh's own default is $HOME/.dsh) and
#     DSH_PERMISSION_MODE=danger-full-access — the dsh analogue of the
#     Claude path's --dangerously-skip-permissions
#   - wraps the run in `timeout -k 10 "${CLAUDE_TIMEOUT:-7200}"` — TERM at
#     the limit, KILL 10s later as a hard backstop; 124 = the wall-clock
#     ceiling fired. busybox `timeout` (alpine CI) reports the child's
#     signal-death status (143/137) instead of GNU's 124, so a signal death
#     at/after the limit is normalised to 124. No PTY: dsh headless writes
#     to stdout directly and mounts no TUI, so the Claude path's
#     `script -qfc` apparatus is not needed
#   - locates the session directory dsh just wrote under
#     $DSH_HOME/sessions/<cwd-slug>/ and takes the most recently modified
#     one created AFTER a start timestamp recorded before the invocation —
#     a stale directory from an earlier run can never be selected (the
#     wrong directory yields a plausible but wrong diagnostics file, which
#     then produces wrong metrics and wrong no-push decisions)
#   - calls dsh_session_normalise (#1105) and writes its output to the
#     same diagnostics path the Claude path uses, ${diag_dir}/agent-run-last.json
#   - sets _AGENT_SESSION_ID (the session directory name, persisted to
#     SID_FILE) and _AGENT_LAST_OUTPUT (the normalised output)
#   - returns the run's exit code
#
# Resume: dsh headless has no --resume. If one is passed, it is logged and
# a fresh session is started — callers treat resume as an optimisation,
# not a requirement. Recorded limitation; see lib/AGENTS.md.
#
# Depends on the documented dsh CLI surface only: `--profile headless`,
# DSH_HOME, DSH_PERMISSION_MODE. Everything structural about the on-disk
# session record comes from lib/dsh-session.sh.
#
# Sourced by lib/agent-sdk.sh. Tests: tests/lib-agent-harness-dsh.bats
# (the `dsh` binary is stubbed — no dsh, model, or network required).

set -euo pipefail

# Session reader (#1105) — the only place that knows dsh's on-disk format.
source "$(dirname "${BASH_SOURCE[0]}")/dsh-session.sh"

# _agent_run_dsh — run a task under the dsh harness (#1106).
# Usage: _agent_run_dsh [--resume SESSION_ID] [--worktree DIR] [--task REF] PROMPT
# Sets: _AGENT_SESSION_ID (persisted to SID_FILE) and _AGENT_LAST_OUTPUT
# (the normalised session record). Writes the normalised record to
# ${diag_dir}/agent-run-last.json, appends one metrics record (#1101),
# and returns the run's exit code — 124 = wall-clock timeout.
_agent_run_dsh() {
  _agent_parse_run_args "$@"
  local resume_id="$_AGENT_RESUME_ID" worktree_dir="$_AGENT_WORKTREE_DIR" task_ref="$_AGENT_TASK_REF" prompt="$_AGENT_PROMPT"

  _AGENT_LAST_OUTPUT=""
  local run_dir="${worktree_dir:-$(pwd)}"
  local dsh_home="${DSH_HOME:-$HOME/.dsh}"
  local limit="${CLAUDE_TIMEOUT:-7200}"
  local diag_dir="${DISINTO_LOG_DIR:-/tmp}/${LOG_AGENT:-dev}"
  local diag_file="${diag_dir}/agent-run-last.json"
  local start_ts output rc session_dir="" best_mtime=0 mtime dir slug_dir normalised
  local has_pushed delivered

  log "agent_run(dsh): starting (resume=${resume_id:-(new)}, dir=${run_dir})"
  if [ -n "$resume_id" ]; then
    log "agent_run(dsh): --resume ${resume_id:0:12}... not supported under the dsh harness — starting a fresh session"
  fi

  # Record the start BEFORE invoking dsh: the session directory is selected
  # by mtime-after-start, so a directory left by an earlier run can never
  # be picked up (see the file header — the wrong directory yields a
  # plausible but wrong diagnostics file).
  start_ts=$(date +%s)

  # dsh headless writes the last assistant text to stdout; the full record
  # lands on disk under $DSH_HOME/sessions/ (lib/dsh-session.sh). No PTY:
  # dsh headless writes to stdout directly and mounts no TUI.
  output=$(cd "$run_dir" && \
    DSH_HOME="$dsh_home" DSH_PERMISSION_MODE=danger-full-access \
    timeout -k 10 "$limit" dsh --profile headless "$prompt" 2>>"$LOGFILE") && rc=0 || rc=$?

  # busybox `timeout` (alpine CI) reports the child's signal-death status
  # (143=TERM, 137=KILL via -k) where GNU coreutils reports 124; a signal
  # death at/after the limit is a wall-clock timeout either way. A 143/137
  # before the limit (e.g. an OOM kill) is left as-is.
  if { [ "$rc" -eq 143 ] || [ "$rc" -eq 137 ]; } && [ "$(( $(date +%s) - start_ts ))" -ge "$limit" ]; then
    rc=124
  fi

  if [ "$rc" -eq 124 ]; then
    log "agent_run(dsh): timeout after ${limit}s (exit code $rc)"
  elif [ "$rc" -ne 0 ]; then
    log "agent_run(dsh): dsh exited with code $rc"
    if [ -n "$output" ]; then
      log "agent_run(dsh): last output lines: $(printf '%s' "$output" | tail -3)"
    fi
  fi

  # The session directory dsh just wrote: the most recently modified
  # subdirectory of any $DSH_HOME/sessions/<cwd-slug>/ dir whose mtime is
  # not older than the recorded start. Session dirs sit one level below
  # the <cwd-slug> dir and dsh's slug scheme is internal, so scan every
  # slug dir rather than deriving the name.
  for slug_dir in "$dsh_home/sessions"/*/; do
    [ -d "$slug_dir" ] || continue
    for dir in "$slug_dir"*/; do
      [ -d "$dir" ] || continue
      mtime=$(stat -c %Y "$dir" 2>/dev/null) || continue
      case "$mtime" in '' | *[!0-9]*) continue ;; esac
      if [ "$mtime" -ge "$start_ts" ] && [ "$mtime" -gt "$best_mtime" ]; then
        best_mtime=$mtime
        session_dir="${dir%/}"
      fi
    done
  done

  if [ -n "$session_dir" ]; then
    _AGENT_SESSION_ID=$(basename "$session_dir")
    printf '%s' "$_AGENT_SESSION_ID" > "$SID_FILE"
    log "agent_run(dsh): session_id=${_AGENT_SESSION_ID}"

    # Normalise the on-disk session log into the stream-json shape the rest
    # of disinto consumes. dsh_session_normalise never emits a partial parse:
    # on a missing/truncated/corrupt log it returns 1 with no stdout (a
    # timeout kill can leave a truncated record — expect this). Drop any
    # diagnostics file a previous run left so a failed normalisation can
    # never re-record a stale session in the metrics line below.
    rm -f "$diag_file" 2>/dev/null || true
    if normalised=$(dsh_session_normalise "$session_dir" 2>>"$LOGFILE"); then
      _AGENT_LAST_OUTPUT="$normalised"
      mkdir -p "$diag_dir" 2>/dev/null || true
      printf '%s\n' "$normalised" > "$diag_file" 2>/dev/null || true
    else
      log "agent_run(dsh): session log could not be normalised — no diagnostics written"
    fi
  else
    log "agent_run(dsh): no session directory created after start under ${dsh_home}/sessions — no diagnostics"
    rm -f "$diag_file" 2>/dev/null || true
  fi

  # Telemetry (#1101): metrics_record_run is a total emitter (missing file
  # → no record) and `|| true` guards it anyway — a metrics write failure
  # must never fail the run.
  has_pushed=$(cd "$run_dir" && git log --oneline "${FORGE_REMOTE:-origin}/${PRIMARY_BRANCH:-main}..HEAD" 2>/dev/null | head -1) || true
  if [ -n "$has_pushed" ]; then delivered="true"; else delivered="false"; fi
  metrics_record_run "$diag_file" "$rc" "$task_ref" "$delivered" || true

  return "$rc"
}
