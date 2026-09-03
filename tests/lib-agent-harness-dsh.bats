#!/usr/bin/env bats
# =============================================================================
# tests/lib-agent-harness-dsh.bats — Unit tests for _agent_run_dsh (#1106)
#
# The `dsh` binary is stubbed (a fake on PATH that writes a session
# directory under $DSH_HOME/sessions/ the way dsh headless does) — no dsh
# install, no model, no network. The session log the stub writes is a
# real zstd-compressed JSONL in the dsh 0.1.1-rc.2 on-disk format, so the
# normalisation path runs through the real dsh_session_normalise (#1105).
# =============================================================================

setup() {
  REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
  TMP_DIR="$(mktemp -d)"

  export SID_FILE="$TMP_DIR/sid"
  export LOGFILE="$TMP_DIR/agent.log"
  export LOG_AGENT=test
  export DISINTO_LOG_DIR="$TMP_DIR/logs"
  export DSH_HOME="$TMP_DIR/dsh-home"
  export DSH_STUB_LOG="$TMP_DIR/dsh-args.txt"

  # Fake dsh: records its argv + env, then writes a session directory the
  # way dsh headless does ($DSH_HOME/sessions/<slug>/<uuid>/session.jsonl.zstd).
  mkdir -p "$TMP_DIR/bin"
  cat > "$TMP_DIR/bin/dsh" <<'EOF'
#!/usr/bin/env bash
{
  echo "args: $*"
  echo "DSH_PERMISSION_MODE=${DSH_PERMISSION_MODE:-}"
  echo "DSH_RESUME_SESSION=${DSH_RESUME_SESSION:-}"
  echo "DSH_HOME=${DSH_HOME:-}"
  echo "cwd: $PWD"
} > "${DSH_STUB_LOG:-/dev/null}"
[ -n "${DSH_STUB_SLEEP:-}" ] && sleep "$DSH_STUB_SLEEP"
[ -n "${DSH_STUB_EXIT:-}" ] && [ "${DSH_STUB_EXIT:-0}" != "0" ] && exit "$DSH_STUB_EXIT"
dir="$DSH_HOME/sessions/fake-slug/sess-$(date +%s)-$$"
mkdir -p "$dir"
case "${DSH_STUB_MODE:-ok}" in
  corrupt) printf 'not a zstd stream' > "$dir/session.jsonl.zstd" ;;
  *)
    printf '%s\n' \
      '{"type":"session","seq":0,"time":"2026-09-01T10:00:00.000Z","data":{"id":"stub","cwd":"'"$PWD"'"}}' \
      '{"type":"step/start","seq":1,"time":"2026-09-01T10:00:01.000Z","data":{"turn":1,"step":1}}' \
      '{"type":"turn/end","seq":2,"time":"2026-09-01T10:00:02.000Z","data":{"turn":1,"reason":{"kind":"completed"}}}' \
      | zstd -q > "$dir/session.jsonl.zstd"
    ;;
esac
echo "fake dsh final text"
EOF
  chmod +x "$TMP_DIR/bin/dsh"
  export PATH="$TMP_DIR/bin:$PATH"

  log() { echo "$*" >> "$LOGFILE"; }

  # shellcheck disable=SC1091
  source "$REPO_ROOT/lib/agent-sdk.sh"
}

teardown() {
  rm -rf "$TMP_DIR"
}

# ── Contract: run, normalised diagnostics, globals ─────────────────────────

@test "AGENT_HARNESS=dsh agent_run runs the task, writes normalised diagnostics, sets both globals" {
  export AGENT_HARNESS=dsh
  local wt="$TMP_DIR/wt" rc=0
  mkdir -p "$wt"
  agent_run --worktree "$wt" --task "123" "do the thing" || rc=$?
  [ "$rc" -eq 0 ]

  # _AGENT_SESSION_ID is the session directory name, persisted to SID_FILE
  [ -n "$_AGENT_SESSION_ID" ]
  [ "$(cat "$SID_FILE")" = "$_AGENT_SESSION_ID" ]

  # Diagnostics land at the same path the Claude path uses
  local diag="$DISINTO_LOG_DIR/test/agent-run-last.json"
  [ -f "$diag" ]
  [ "$(wc -l < "$diag")" -eq 2 ]
  [ "$(jq -r '.type' <<<"$(head -1 "$diag")")" = "system" ]
  [ "$(jq -r '.session_id' <<<"$(head -1 "$diag")")" = "$_AGENT_SESSION_ID" ]
  [ "$(jq -rs '[ .[].session_id ] | unique | length' "$diag")" = "1" ]
  [ "$(jq -r '.subtype' <<<"$(tail -1 "$diag")")" = "success" ]

  # _AGENT_LAST_OUTPUT is the normalised output
  [ -n "$_AGENT_LAST_OUTPUT" ]
  [ "$_AGENT_LAST_OUTPUT" = "$(cat "$diag")" ]

  # The stub was invoked in the worktree with the documented CLI surface
  grep -q "args: --profile headless do the thing" "$DSH_STUB_LOG"
  grep -q "DSH_PERMISSION_MODE=danger-full-access" "$DSH_STUB_LOG"
  grep -q "cwd: $wt" "$DSH_STUB_LOG"

  # One metrics record, attributed to the task ref (#1101)
  local metrics="$DISINTO_LOG_DIR/metrics/agent-runs.jsonl"
  [ -f "$metrics" ]
  local rec
  rec=$(tail -1 "$metrics")
  [ "$(jq -r '.task_ref' <<<"$rec")" = "123" ]
  [ "$(jq -r '.session_id' <<<"$rec")" = "$_AGENT_SESSION_ID" ]
  [ "$(jq -r '.outcome' <<<"$rec")" = "success" ]
  [ "$(jq -r '.exit_code' <<<"$rec")" = "0" ]
}

@test "no --worktree: dsh runs in the current directory" {
  export AGENT_HARNESS=dsh
  local wt="$TMP_DIR/cwd-run" rc=0
  mkdir -p "$wt"
  ( cd "$wt" && agent_run "go" ) || rc=$?
  [ "$rc" -eq 0 ]
  grep -q "cwd: $wt" "$DSH_STUB_LOG"
}

# ── Session directory selection: mtime-after-start ──────────────────────────

@test "a pre-existing session directory (older mtime) is not selected" {
  export AGENT_HARNESS=dsh
  local wt="$TMP_DIR/wt" stale="$DSH_HOME/sessions/fake-slug/stale-sess" rc=0
  mkdir -p "$wt" "$stale"
  # A stale session from a previous run, mtime far in the past
  printf 'old' > "$stale/session.jsonl.zstd"
  touch -t 202608010000 "$stale"
  agent_run --worktree "$wt" "go" || rc=$?
  [ "$rc" -eq 0 ]
  [ "$_AGENT_SESSION_ID" != "stale-sess" ]
  [ -n "$_AGENT_SESSION_ID" ]
  [ -f "$DISINTO_LOG_DIR/test/agent-run-last.json" ]
}

# ── Exit codes ──────────────────────────────────────────────────────────────

@test "wall-clock timeout returns 124 (matching the Claude path)" {
  export AGENT_HARNESS=dsh
  local rc=0
  export CLAUDE_TIMEOUT=1 DSH_STUB_SLEEP=5
  agent_run "go" || rc=$?
  [ "$rc" -eq 124 ]
  # No session directory was written (the stub was killed mid-sleep), so no
  # stale diagnostics file may be left behind or re-recorded.
  [ ! -f "$DISINTO_LOG_DIR/test/agent-run-last.json" ]
}

@test "a non-zero dsh exit code is propagated" {
  export AGENT_HARNESS=dsh
  local rc=0
  export DSH_STUB_EXIT=3
  agent_run "go" || rc=$?
  [ "$rc" -eq 3 ]
}

# ── Resume (#1224) ────────────────────────────────────────────────────────────

@test "--resume with an existing session dir passes DSH_RESUME_SESSION and keeps the session id" {
  export AGENT_HARNESS=dsh
  local rc=0
  # The resume target: an existing session dir with a valid log, whose mtime
  # predates the run (a resumed dir's mtime does not change — only the log
  # file inside is appended — so the mtime scan must not be relied on).
  local target="$DSH_HOME/sessions/some-slug/session-old-1234"
  mkdir -p "$target"
  printf '%s\n' \
    '{"type":"session","seq":0,"time":"2026-09-01T10:00:00.000Z","data":{"id":"stub","cwd":"/tmp"}}' \
    '{"type":"step/start","seq":1,"time":"2026-09-01T10:00:01.000Z","data":{"turn":1,"step":1}}' \
    '{"type":"turn/end","seq":2,"time":"2026-09-01T10:00:02.000Z","data":{"turn":1,"reason":{"kind":"completed"}}}' \
    | zstd -q > "$target/session.jsonl.zstd"
  touch -t 202608010000 "$target"
  agent_run --resume "session-old-1234" "go" || rc=$?
  [ "$rc" -eq 0 ]
  [ "$_AGENT_SESSION_ID" = "session-old-1234" ]
  [ "$(cat "$SID_FILE")" = "session-old-1234" ]
  grep -q "DSH_RESUME_SESSION=session-old-1234" "$DSH_STUB_LOG"
  # The resumed session's log was normalised into diagnostics
  [ -f "$DISINTO_LOG_DIR/test/agent-run-last.json" ]
}

@test "--resume with a missing session dir logs and starts a fresh session" {
  export AGENT_HARNESS=dsh
  local rc=0
  agent_run --resume "session-missing-9999" "go" || rc=$?
  [ "$rc" -eq 0 ]
  [ "$_AGENT_SESSION_ID" != "session-missing-9999" ]
  [ -n "$_AGENT_SESSION_ID" ]
  grep -q "not found under" "$LOGFILE"
  # No resume env reached dsh: a fresh session was requested
  grep -q "^DSH_RESUME_SESSION=$" "$DSH_STUB_LOG"
  grep -q "args: --profile headless go" "$DSH_STUB_LOG"
}

# ── Normalisation failure: no stale diagnostics ─────────────────────────────

@test "unnormalisable session log: no diagnostics written, previous run's file not re-recorded" {
  export AGENT_HARNESS=dsh
  local diag="$DISINTO_LOG_DIR/test/agent-run-last.json" rc=0
  mkdir -p "$DISINTO_LOG_DIR/test"
  printf '{"stale":true}\n' > "$diag"
  export DSH_STUB_MODE=corrupt
  agent_run "go" || rc=$?
  [ "$rc" -eq 0 ]
  # The session directory was found (sid set) but its log is unreadable
  [ -n "$_AGENT_SESSION_ID" ]
  [ -z "$_AGENT_LAST_OUTPUT" ]
  [ ! -f "$diag" ]
}

# ── Dispatcher behaviour ────────────────────────────────────────────────────

@test "AGENT_HARNESS unset: _agent_run_claude is still dispatched" {
  # Replace the real implementation with a marker — the point is that the
  # dispatcher's default branch is unchanged.
  _agent_run_claude() { touch "$TMP_DIR/claude-dispatched"; return 0; }
  unset AGENT_HARNESS
  agent_run "go"
  [ -f "$TMP_DIR/claude-dispatched" ]
}

@test "AGENT_HARNESS=dsh dispatches to _agent_run_dsh" {
  _agent_run_dsh() { touch "$TMP_DIR/dsh-dispatched"; return 0; }
  export AGENT_HARNESS=dsh
  agent_run "go"
  [ -f "$TMP_DIR/dsh-dispatched" ]
}

@test "unknown AGENT_HARNESS returns 2 and runs nothing" {
  export AGENT_HARNESS=bogus
  local rc=0
  agent_run "go" || rc=$?
  [ "$rc" -eq 2 ]
  [ ! -f "$DSH_STUB_LOG" ]
  [ -z "$_AGENT_SESSION_ID" ]
}
