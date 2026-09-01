#!/usr/bin/env bash
# agent-sdk.sh — Shared SDK for synchronous Claude agent invocations
#
# Provides agent_run(): harness dispatcher (AGENT_HARNESS: claude | dsh,
# default claude) over one-shot `claude -p` / `dsh --profile headless`
# invocations with session persistence (the dsh harness is
# _agent_run_dsh in lib/agent-harness-dsh.sh, #1106).
# Source this from any agent script after defining:
#   SID_FILE  — path to persist session ID (e.g. /tmp/dev-session-proj-123.sid)
#   LOGFILE   — path for log output
#   log()     — logging function
#
# Usage:
#   source "$(dirname "$0")/../lib/agent-sdk.sh"
#   agent_run [--resume SESSION_ID] [--worktree DIR] [--task REF] PROMPT
#
# After each call, these globals are set:
#   _AGENT_SESSION_ID  — session ID (also persisted to SID_FILE)
#   _AGENT_LAST_OUTPUT — raw stream-json output of the last run
#                        (also written to $DISINTO_LOG_DIR/$LOG_AGENT/agent-run-last.json)
#
# Each call also appends one telemetry line to
# $DISINTO_LOG_DIR/metrics/agent-runs.jsonl (see lib/agent-metrics.sh, #1101).
#
# Call agent_recover_session() on startup to restore a previous session.

set -euo pipefail

# Per-session telemetry emitter (#1101) — always available in agent_run.
source "$(dirname "${BASH_SOURCE[0]}")/agent-metrics.sh"
# dsh harness (#1106) — provides _agent_run_dsh for AGENT_HARNESS=dsh.
source "$(dirname "${BASH_SOURCE[0]}")/agent-harness-dsh.sh"

_AGENT_SESSION_ID=""

# redact_log_secrets — stream filter that masks token-shaped env-var
# assignments before they hit disk (#910).
#
# A formula's claude session can shell out to commands that echo loaded
# environment (e.g. `env | grep -i forge`); the resulting tool_result
# stdout is captured into ${DISINTO_LOG_DIR}/<agent>/step.log verbatim.
# If FORGE_*_TOKEN / VAULT_* / GH_* / GITHUB_* / CLAW_* / CLAUDE_* /
# ANTHROPIC_* secrets are present in the process env, that log line
# leaks them onto a host volume.
#
# This filter masks the value half of any KEY=value where KEY matches
# one of the well-known secret-bearing prefixes (case-insensitive),
# regardless of whether the line is plain shell output or embedded in
# a JSON string. The variable name is preserved so operators can still
# audit *which* secret was about to leak; only the value is redacted.
#
# Reads stdin, writes redacted stdout. Pure sed — unbuffered where sed
# supports -u, safe to splice into a `tail -F` pipeline.
redact_log_secrets() {
  # -u (unbuffered) keeps the `tail -F` pipeline live, but it is a GNU sed
  # extension: busybox sed (the Alpine images — CI's bats step, #1151)
  # exits on it without writing a single line, so the filter would drop the
  # whole stream instead of redacting it. Probe once per call and fall back
  # to plain -E; the filter is spawned once per run, so the extra sed is
  # negligible. (Probed here, not at source time: top-level vars are lost
  # when the library is sourced from inside a function, #1143.)
  local opts=(-E)
  # `q` is a no-op script: with no -e argument sed takes the first
  # positional as the script, so the probe must supply one. GNU sed
  # accepts -u and exits 0; busybox rejects -u before parsing.
  if sed -u q /dev/null 2>/dev/null; then
    opts=(-uE)
  fi
  # Note on the regex:
  #   - Anchored on the well-known prefix list (FORGE/VAULT/GH/GITHUB/
  #     CLAW/CLAUDE/ANTHROPIC) so we don't redact unrelated KEY= pairs.
  #   - `[A-Za-z0-9_]*` (greedy with backtracking) chews everything up
  #     to the trailing TOKEN|PASS|KEY|SECRET — covers FORGE_TOKEN as
  #     well as FORGE_ARCHITECT_TOKEN, GH_API_KEY, etc.
  #   - Value class `[^[:space:]",}\\]+` stops at JSON quote/brace,
  #     whitespace, or backslash so we don't eat past the value when
  #     the line is JSON-embedded.
  #   - `I` flag = case-insensitive match while preserving the original
  #     case in the captured group (supported by both GNU and busybox sed;
  #     -u above is what busybox lacks).
  sed "${opts[@]}" \
    's/((FORGE|VAULT|GH|GITHUB|CLAW|CLAUDE|ANTHROPIC)[A-Za-z0-9_]*(TOKEN|PASS|KEY|SECRET))=[^[:space:]",}\\]+/\1=<redacted>/gI'
}

# agent_recover_session — restore session_id from SID_FILE if it exists.
# Call this before agent_run --resume to enable session continuity.
agent_recover_session() {
  if [ -f "$SID_FILE" ]; then
    _AGENT_SESSION_ID=$(cat "$SID_FILE")
    log "agent_recover_session: ${_AGENT_SESSION_ID:0:12}..."
  fi
}

# claude_run_with_watchdog — run claude with idle-after-final-message watchdog
#
# Mitigates upstream Claude Code hang (#591) by detecting when the final
# assistant message has been written and terminating the process after a
# short grace period instead of waiting for CLAUDE_TIMEOUT.
#
# The watchdog:
#   1. Streams claude stdout to a temp file
#   2. Polls for the final result marker ("type":"result" for stream-json
#      or closing } for regular json output)
#   3. After detecting the final marker, starts a CLAUDE_IDLE_GRACE countdown
#   4. SIGTERM claude if it hasn't exited cleanly within the grace period
#   5. Falls back to CLAUDE_TIMEOUT as the absolute hard ceiling
#
# Usage: claude_run_with_watchdog claude [args...]
# Expects: LOGFILE, CLAUDE_TIMEOUT, CLAUDE_IDLE_GRACE (default 30)
# Returns: exit code from claude or timeout
claude_run_with_watchdog() {
  local -a cmd=("$@")
  local out_file pid grace_pid rc limit start_ts end_ts elapsed

  # Create temp files for stdout capture and PTY runner script
  out_file=$(mktemp) || return 1
  local runner
  runner=$(mktemp) || { rm -f "$out_file"; return 1; }
  trap 'rm -f "$out_file" "$runner"' RETURN

  # Start claude under a PTY in a new process group.
  #
  # Why the PTY (issue #575): Claude Code 2.1.84's ink/TUI layer blocks during
  # turn-zero initialization when stdout is a plain pipe/file — node sleeps in
  # S state with 0 bytes emitted, no llama activity, no syscalls, until
  # CLAUDE_TIMEOUT fires. Verified: identical `claude -p` completes in ~10s
  # under `script -qfc` and hangs indefinitely without it.
  #
  # Why the runner tempfile (follow-up to #575): `script -c <cmdline>` passes
  # the cmdline to `/bin/sh -c`, which on Debian/Ubuntu is `dash`. Bash
  # `printf %q` output isn't dash-compatible — ANSI-C $'...' quoting blows up
  # dash's parser with "Syntax error: '(' unexpected" when the Claude prompt
  # contains parentheses (every issue body does). Writing the argv to a
  # `#!/bin/bash` script file bypasses sh re-parsing entirely — dash just
  # spawns the script via its shebang, and bash handles the %q'd args.
  {
    printf '#!/bin/bash\nexec '
    printf '%q ' "${cmd[@]}"
    printf '\n'
  } > "$runner"
  chmod +x "$runner"
  setsid script -qfc "$runner" /dev/null > "$out_file" 2>>"$LOGFILE" &
  pid=$!

  # Optional: record the claude process-group ID for the caller's exit-path
  # cleanup (#1070). setsid made $pid the session+group leader (pid == pgid),
  # so the caller (dev-agent.sh) can `kill -- -PGID` on any of its exit paths
  # and guarantee no claude survives its shell. Removed below once the group
  # is dead.
  if [ -n "${CLAUDE_PGID_FILE:-}" ]; then
    printf '%s\n' "$pid" > "$CLAUDE_PGID_FILE"
  fi

  # Background tailer: mirror $out_file into $LOGFILE as stream-json messages
  # arrive — without this, a run that hangs mid-stream shows no progress to
  # operators for up to CLAUDE_TIMEOUT seconds (issue #568).
  # Stream is piped through redact_log_secrets so token-shaped env-var
  # assignments (FORGE_TOKEN=…, GITHUB_TOKEN=…, etc.) are masked before
  # they land on the host volume (#910).
  (
    tail -F -n 0 --pid="$pid" "$out_file" 2>/dev/null \
      | redact_log_secrets >> "$LOGFILE"
  ) &
  local tail_pid=$!

  # Background watchdog: poll for final result marker
  (
    local grace="${CLAUDE_IDLE_GRACE:-30}"
    local detected=0

    while kill -0 "$pid" 2>/dev/null; do
      # Match the terminal result object specifically. `"type":"result"` alone
      # would also match if Claude's thinking/text content happens to echo
      # that literal string; `"type":"result","subtype":` only appears in the
      # real result frame emitted when the run completes (issue #581).
      if grep -q '"type":"result","subtype":' "$out_file" 2>/dev/null; then
        detected=1
        break
      fi
      # Pre-stream-json fallback removed (#581): in stream-json mode every
      # message ends `}\n` and carries `session_id`, so that heuristic fired
      # on the first system-init message, SIGTERMing Claude mid-run.
      sleep 2
    done

    # If we detected a final message, wait grace period then kill if still running
    if [ "$detected" -eq 1 ] && kill -0 "$pid" 2>/dev/null; then
      log "watchdog: final result detected, ${grace}s grace period before SIGTERM"
      sleep "$grace"
      if kill -0 "$pid" 2>/dev/null; then
        log "watchdog: claude -p idle for ${grace}s after final result; SIGTERM"
        kill -TERM -- "-$pid" 2>/dev/null || true
        # Give it a moment to clean up
        sleep 5
        if kill -0 "$pid" 2>/dev/null; then
          log "watchdog: force kill after SIGTERM timeout"
          kill -KILL -- "-$pid" 2>/dev/null || true
        fi
      fi
    fi
  ) &
  grace_pid=$!

  # Hard ceiling timeout — use tail --pid to wait for the process to die.
  #
  # #1070: this used to be an unguarded `timeout ...` line. Callers run this
  # function inside a command substitution that inherits `set -e`, and when the
  # ceiling fired, `timeout` exited 124 and ABORTED the subshell right here —
  # the process-group kill below never ran. The caller still saw rc=124 and
  # logged "timeout", but the claude group (already re-parented to PID 1 via
  # setsid) was orphaned and ran on until CLAUDE_MAX_TURNS or a manual pkill.
  # `|| rc=$?` captures the exit status without tripping set -e.
  limit="${CLAUDE_TIMEOUT:-7200}"
  start_ts=$(date +%s)
  rc=0
  timeout --foreground "$limit" tail --pid="$pid" -f /dev/null 2>/dev/null || rc=$?
  end_ts=$(date +%s)
  elapsed=$((end_ts - start_ts))
  # Log the watchdog's observed wall-clock and the timeout exit status on
  # EVERY run so timeout enforcement is auditable from $LOGFILE (#1070).
  log "watchdog: timeout_exit=${rc} elapsed_wall=${elapsed}s limit=${limit}s pgid=${pid}"

  # When the hard ceiling fires (rc=124), kill the whole claude process group.
  # tail --pid is a passive waiter, not a supervisor. $pid is the group leader
  # (setsid), so -PID reaches every child claude spawned, including hung
  # Bash-tool commands — no claude may survive its shell (#1070).
  if [ "$rc" -eq 124 ]; then
    log "watchdog: CLAUDE_TIMEOUT (${limit}s) exceeded after ${elapsed}s — SIGTERM group ${pid}"
    kill -TERM -- "-$pid" 2>/dev/null || true
    # Give it a moment to clean up
    sleep 5
    if kill -0 "$pid" 2>/dev/null; then
      log "watchdog: SIGKILL group ${pid} after SIGTERM grace"
      kill -KILL -- "-$pid" 2>/dev/null || true
    fi
  fi

  # Clean up the helper subshells.
  #
  # #1070: the old order was `kill -- "-$grace_pid"` — a silent no-op, because
  # the grace subshell is NOT a process-group leader (its pgid is the caller
  # shell's) — followed by `wait "$grace_pid"` BEFORE the claude group kill.
  # The grace loop only exits when claude dies, so the wait deadlocked and the
  # claude group leaked. Now: plain TERM (effective on the direct child), then
  # a bounded wait (the subshell finishes its current sleep and sees claude
  # gone), then the log tailer, then reap the claude group leader.
  kill "$grace_pid" 2>/dev/null || true
  wait "$grace_pid" 2>/dev/null || true
  # Clean up the log tailer — tail -F --pid exits automatically when claude
  # exits, but be defensive.
  kill "$tail_pid" 2>/dev/null || true
  wait "$tail_pid" 2>/dev/null || true
  # Reap the claude group leader so the pgid check below is reliable.
  wait "$pid" 2>/dev/null || true

  # Drop the pgid file once the group leader is dead so the caller's
  # exit-path cleanup doesn't act on a stale group ID (#1070).
  if [ -n "${CLAUDE_PGID_FILE:-}" ] && ! kill -0 "$pid" 2>/dev/null; then
    rm -f "$CLAUDE_PGID_FILE"
  fi

  # Output the captured stdout, redacting token-shaped vars on the way out
  # so the captured `output` (and anything written from it, e.g. diag_file)
  # is also clean (#910).
  redact_log_secrets < "$out_file"
  return "$rc"
}

# agent_run — harness dispatcher (#1104).
#
# Dispatches on AGENT_HARNESS (default: claude). An unknown value logs and
# returns 2 rather than running anything.
#
# Contract that every harness implementation must satisfy (this is already
# what the Claude path does):
#   - Signature: agent_run [--resume SESSION_ID] [--worktree DIR] PROMPT
#   - Sets: _AGENT_SESSION_ID (also persisted to SID_FILE) and
#     _AGENT_LAST_OUTPUT
#   - Writes: the diagnostics file ${diag_dir}/agent-run-last.json
#   - Returns: the run's exit code; 124 means the wall-clock timeout fired
#
# Caller contract (#1164): under set -e an unguarded call would abort the
# caller on a resource-limit exit (rc 124) — a TRANSIENT failure the caller
# should decide on. Every call site must therefore guard the invocation
# (`agent_run ... || RUN_RC=$?`) and inspect the rc (124 = wall-clock timeout).
# `|| true` is not acceptable: it discards the signal.
agent_run() {
  case "${AGENT_HARNESS:-claude}" in
    claude) _agent_run_claude "$@" ;;
    dsh) _agent_run_dsh "$@" ;;
    *) log "agent_run: unknown AGENT_HARNESS='${AGENT_HARNESS}'" ; return 2 ;;
  esac
}

# _agent_parse_run_args — option parsing shared by the agent_run harnesses.
# Usage: _agent_parse_run_args [--resume SESSION_ID] [--worktree DIR] [--task REF] PROMPT
# Sets: _AGENT_RESUME_ID, _AGENT_WORKTREE_DIR, _AGENT_TASK_REF, _AGENT_PROMPT
_agent_parse_run_args() {
  _AGENT_RESUME_ID=""
  _AGENT_WORKTREE_DIR=""
  _AGENT_TASK_REF=""
  _AGENT_PROMPT=""
  while [[ "${1:-}" == --* ]]; do
    case "$1" in
      --resume) shift; _AGENT_RESUME_ID="${1:-}"; shift ;;
      --worktree) shift; _AGENT_WORKTREE_DIR="${1:-}"; shift ;;
      --task) shift; _AGENT_TASK_REF="${1:-}"; shift ;;
      *) shift ;;
    esac
  done
  _AGENT_PROMPT="${1:-}"
}

# _agent_run_claude — synchronous Claude invocation (one-shot claude -p)
# Usage: agent_run [--resume SESSION_ID] [--worktree DIR] [--task REF] PROMPT
# Sets: _AGENT_SESSION_ID (updated each call, persisted to SID_FILE)
# --task REF attributes the session (e.g. issue/PR number) in the metrics
# record appended after the run; omit to leave it empty.
_agent_run_claude() {
  _agent_parse_run_args "$@"
  local resume_id="$_AGENT_RESUME_ID" worktree_dir="$_AGENT_WORKTREE_DIR" task_ref="$_AGENT_TASK_REF" prompt="$_AGENT_PROMPT"

  _AGENT_LAST_OUTPUT=""

  # stream-json streams each turn incrementally instead of buffering the whole
  # run — lets the watchdog see progress and the LOGFILE capture real-time
  # tool-use activity. With buffered `json` a hang before the first turn
  # produces zero output for the full CLAUDE_TIMEOUT (issue #568).
  #
  # max-turns lowered from 200 to CLAUDE_MAX_TURNS (default 30). Single-file
  # bug fixes never need 200 turns; tighter bound surfaces stuck runs faster.
  local max_turns="${CLAUDE_MAX_TURNS:-60}"
  local -a args=(-p "$prompt" --output-format stream-json --verbose --dangerously-skip-permissions --max-turns "$max_turns")
  [ -n "$resume_id" ] && args+=(--resume "$resume_id")
  [ -n "${CLAUDE_MODEL:-}" ] && args+=(--model "$CLAUDE_MODEL")

  local run_dir="${worktree_dir:-$(pwd)}"
  local lock_file="${HOME}/.claude/session.lock"
  local output rc
  log "agent_run: starting (resume=${resume_id:-(new)}, dir=${run_dir})"
  # External flock is redundant once CLAUDE_CONFIG_DIR rollout is verified (#647).
  # Gate behind CLAUDE_EXTERNAL_LOCK for rollback safety; default off.
  if [ -n "${CLAUDE_EXTERNAL_LOCK:-}" ]; then
    mkdir -p "$(dirname "$lock_file")"
    output=$(cd "$run_dir" && ( flock -w 600 9 || exit 1; claude_run_with_watchdog claude "${args[@]}" ) 9>"$lock_file" 2>>"$LOGFILE") && rc=0 || rc=$?
  else
    output=$(cd "$run_dir" && claude_run_with_watchdog claude "${args[@]}" 2>>"$LOGFILE") && rc=0 || rc=$?
  fi
  if [ "$rc" -eq 124 ]; then
    log "agent_run: timeout after ${CLAUDE_TIMEOUT:-7200}s (exit code $rc)"
  elif [ "$rc" -ne 0 ]; then
    log "agent_run: claude exited with code $rc"
    # Log last 3 lines of output for diagnostics
    if [ -n "$output" ]; then
      log "agent_run: last output lines: $(echo "$output" | tail -3)"
    fi
  fi
  if [ -z "$output" ]; then
    log "agent_run: empty output (claude may have crashed or failed, exit code: $rc)"
  fi

  # Extract and persist session_id.
  #
  # With --output-format stream-json (post #568) the output is a stream of
  # JSON objects, each carrying `session_id`. A naive `jq -r '.session_id'`
  # emits the same UUID once per message — concatenated with newlines the
  # value becomes `uuid\nuuid\n...` which breaks `--resume <sid>` in the
  # nudge path with "Session IDs must be in UUID format".
  #
  # Use `jq -s 'last'` to slurp the stream and take only the final object's
  # session_id. For plain `json` output (one object) this still works.
  local new_sid
  new_sid=$(printf '%s' "$output" | jq -rs 'last.session_id // empty' 2>/dev/null) || true
  if [ -n "$new_sid" ]; then
    _AGENT_SESSION_ID="$new_sid"
    printf '%s' "$new_sid" > "$SID_FILE"
    log "agent_run: session_id=${new_sid:0:12}..."
  fi

  # Save output for diagnostics (no_push, crashes)
  _AGENT_LAST_OUTPUT="$output"
  local diag_dir="${DISINTO_LOG_DIR:-/tmp}/${LOG_AGENT:-dev}"
  mkdir -p "$diag_dir" 2>/dev/null || true
  local diag_file="${diag_dir}/agent-run-last.json"
  printf '%s' "$output" > "$diag_file" 2>/dev/null || true

  # Has the session pushed anything beyond the primary branch? Computed once,
  # before the record is written, so the delivered field reflects the
  # worktree at the moment the line is recorded (#1167) — and the nudge
  # decision below reuses the same check.
  local has_pushed
  has_pushed=$(cd "$run_dir" && git log --oneline "${FORGE_REMOTE:-origin}/${PRIMARY_BRANCH:-main}..HEAD" 2>/dev/null | head -1) || true
  local delivered
  if [ -n "$has_pushed" ]; then delivered="true"; else delivered="false"; fi

  # Record one telemetry line for this session (#1101). metrics_record_run is
  # a total emitter and `|| true` guards it anyway: a metrics write failure
  # must never fail the run.
  metrics_record_run "$diag_file" "$rc" "$task_ref" "$delivered" || true

  # Nudge: if the model stopped without pushing, resume with encouragement.
  # Some models emit end_turn prematurely when confused. A nudge often unsticks them.
  if [ -n "$_AGENT_SESSION_ID" ] && [ -n "$output" ]; then
    local has_changes
    has_changes=$(cd "$run_dir" && git status --porcelain 2>/dev/null | head -1) || true
    if [ -z "$has_pushed" ]; then
      if [ -n "$has_changes" ]; then
        # Nudge: there are uncommitted changes
        local nudge="You stopped but did not push any code. You have uncommitted changes. Commit them and push."
        log "agent_run: nudging (uncommitted changes)"
        local nudge_rc
        if [ -n "${CLAUDE_EXTERNAL_LOCK:-}" ]; then
          output=$(cd "$run_dir" && ( flock -w 600 9 || exit 1; claude_run_with_watchdog claude -p "$nudge" --resume "$_AGENT_SESSION_ID" --output-format json --dangerously-skip-permissions --max-turns 50 ${CLAUDE_MODEL:+--model "$CLAUDE_MODEL"} ) 9>"$lock_file" 2>>"$LOGFILE") && nudge_rc=0 || nudge_rc=$?
        else
          output=$(cd "$run_dir" && claude_run_with_watchdog claude -p "$nudge" --resume "$_AGENT_SESSION_ID" --output-format json --dangerously-skip-permissions --max-turns 50 ${CLAUDE_MODEL:+--model "$CLAUDE_MODEL"} 2>>"$LOGFILE") && nudge_rc=0 || nudge_rc=$?
        fi
        if [ "$nudge_rc" -eq 124 ]; then
          log "agent_run: nudge timeout after ${CLAUDE_TIMEOUT:-7200}s (exit code $nudge_rc)"
        elif [ "$nudge_rc" -ne 0 ]; then
          log "agent_run: nudge claude exited with code $nudge_rc"
          # Log last 3 lines of output for diagnostics
          if [ -n "$output" ]; then
            log "agent_run: nudge last output lines: $(echo "$output" | tail -3)"
          fi
        fi
        new_sid=$(printf '%s' "$output" | jq -r '.session_id // empty' 2>/dev/null) || true
        if [ -n "$new_sid" ]; then
          _AGENT_SESSION_ID="$new_sid"
          printf '%s' "$new_sid" > "$SID_FILE"
        fi
        printf '%s' "$output" > "$diag_file" 2>/dev/null || true
        _AGENT_LAST_OUTPUT="$output"
      else
        log "agent_run: no push and no changes — skipping nudge"
      fi
    fi
  fi
  # Propagate the run's exit code per the agent_run contract above (a nudge
  # that succeeds or times out does not change the outcome of the run
  # itself). Callers can branch on 124 (timeout) — #1164.
  return "$rc"
}
