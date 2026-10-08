#!/usr/bin/env bash
# =============================================================================
# tests/acceptance/issue-1968.sh
#
# Issue #1968: architect-run.sh must set SID_FILE before agent_run. Under
# set -u the dsh harness writes the session id to $SID_FILE after the
# session ends; an unset variable aborts the run before the draft is
# committed. The architect starts a new session every run, so one file per
# project is enough.
#
# Acceptance (no network, no model; dsh and curl are stubs):
#   1. architect/architect-run.sh assigns SID_FILE before its first
#      agent_run call. bash -n and shellcheck pass on the file.
#   2. Do not export SID_FILE. With AGENT_HARNESS=dsh, a dsh stub that
#      leaves one session directory, and the architect's environment, the
#      decompose path gets past agent_run, exits 0, and writes the session
#      id to /tmp/architect-session-<project>.sid (PROJECT_NAME is the
#      test's override of the project name).
#
# Run via: tools/run-acceptance.sh 1968
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../lib/acceptance-helpers.sh
source "$REPO_ROOT/tests/lib/acceptance-helpers.sh"

ac_require_cmd bash shellcheck git jq python3 timeout base64

ARCHITECT_RUN="$REPO_ROOT/architect/architect-run.sh"
ac_assert_file "$ARCHITECT_RUN" "architect/architect-run.sh is missing"

# ── 1. SID_FILE is assigned before the first agent_run; syntax ──────────────
ac_log "AC 1: SID_FILE is set before the first agent_run; bash -n and shellcheck"
sid_line="$(grep -n '^SID_FILE=' "$ARCHITECT_RUN" | head -1 | cut -d: -f1)"
run_line="$(grep -n 'agent_run ' "$ARCHITECT_RUN" | head -1 | cut -d: -f1)"
[ -n "$sid_line" ] || ac_fail "architect-run.sh does not assign SID_FILE"
[ -n "$run_line" ] || ac_fail "architect-run.sh has no agent_run call"
[ "$sid_line" -lt "$run_line" ] \
  || ac_fail "SID_FILE (line $sid_line) must be assigned before the first agent_run (line $run_line)"
grep -qF 'SID_FILE="/tmp/architect-session-${PROJECT_NAME}.sid"' "$ARCHITECT_RUN" \
  || ac_fail "SID_FILE must be /tmp/architect-session-\${PROJECT_NAME}.sid"
bash -n "$ARCHITECT_RUN" || ac_fail "bash -n architect/architect-run.sh failed"
(
  cd "$REPO_ROOT" || exit 1
  shellcheck architect/architect-run.sh
) || ac_fail "shellcheck architect/architect-run.sh failed"
ac_log "AC 1 OK"

# ── 2. Decompose path writes the session id without a test-exported SID_FILE ─
ac_log "AC 2: decompose path past agent_run writes the session id"

# A parent export must not satisfy the harness. The script has to set it.
unset SID_FILE

TMP_DIR="$(mktemp -d)"
PROJECT_NAME="i1968-$$"
SID_PATH="/tmp/architect-session-${PROJECT_NAME}.sid"
WORKTREE="/tmp/${PROJECT_NAME}-architect-run"
STATE_FILE="$REPO_ROOT/state/.architect-active"
created_state=0

cleanup() {
  rm -rf "$TMP_DIR" "$WORKTREE" "$SID_PATH" \
    "/tmp/${PROJECT_NAME}-graph-report.json" 2>/dev/null || true
  if [ "$created_state" = 1 ]; then
    rm -f "$STATE_FILE" 2>/dev/null || true
  fi
  # The script's own trap removes this. Drop a leftover whose pid is gone.
  if [ -f /tmp/architect-run.lock ]; then
    lock_pid="$(cat /tmp/architect-run.lock 2>/dev/null || true)"
    if [ -n "$lock_pid" ] && ! kill -0 "$lock_pid" 2>/dev/null; then
      rm -f /tmp/architect-run.lock 2>/dev/null || true
    fi
  fi
}
trap cleanup EXIT

if [ ! -e "$STATE_FILE" ]; then
  mkdir -p "$REPO_ROOT/state"
  : >"$STATE_FILE"
  created_state=1
fi

HOME_DIR="$TMP_DIR/home"
BIN_DIR="$HOME_DIR/.local/bin"
PROJECT_REPO="$TMP_DIR/project"
OPS_REPO="$TMP_DIR/ops"
ORIGIN="$TMP_DIR/origin.git"
mkdir -p "$BIN_DIR" "$PROJECT_REPO" "$OPS_REPO" "$HOME_DIR/data"

PITCH_FIXTURE="$TMP_DIR/sid-file.md"
cat >"$PITCH_FIXTURE" <<'EOF'
# Sprint: sid-file

## What this enables

This sprint enables the sid-file check.

<!-- sprint:begin -->
class: internal
effect: none
expect: >= 0
soak: 0d
<!-- sprint:end -->

## Sub-issues

<!-- filer:begin -->
<!-- filer:end -->
EOF

# Stub curl: the decompose gate reads one open architect PR, its pitch file,
# and an empty comment thread. Writes succeed so publish_draft can post.
cat >"$BIN_DIR/curl" <<'EOF'
#!/usr/bin/env bash
url=""
for arg in "$@"; do
  case "$arg" in
    http://*|https://*) url="$arg" ;;
  esac
done
printf '%s\n' "$url" >>"${CURL_STUB_LOG:?}"
case "$url" in
  */pulls\?state=open*)
    printf '%s\n' '[{"number":7,"title":"architect: sid-file","updated_at":"2026-01-01T00:00:00Z"}]'
    ;;
  */pulls/7/files)
    printf '%s\n' '[{"filename":"sprints/sid-file.md","status":"added"}]'
    ;;
  */contents/*)
    b64="$(base64 -w0 "${PITCH_FIXTURE:?}")"
    printf '{"content":"%s","sha":"abc123sid"}\n' "$b64"
    ;;
  */issues\?*)
    printf '%s\n' '[]'
    ;;
  */issues/*/comments*)
    printf '%s\n' '[]'
    ;;
  */pulls/7)
    printf '%s\n' '{"number":7,"body":"pitch","head":{"ref":"architect-sid"}}'
    ;;
  *)
    printf '%s\n' '{}'
    ;;
esac
exit 0
EOF

# Stub dsh: one session directory, created during the run, so the harness
# can persist its name. The log is not valid zstd; an unreadable log stays
# a candidate when it is the only one (#1186).
cat >"$BIN_DIR/dsh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
slug="${DSH_HOME:?}/sessions/fake-slug"
mkdir -p "$slug/session-1968"
printf 'not a zstd stream' >"$slug/session-1968/session.jsonl.zstd"
printf 'ran\n' >>"${DSH_STUB_LOG:?}"
printf 'drafted\n'
exit 0
EOF
chmod +x "$BIN_DIR/curl" "$BIN_DIR/dsh"

git init -q --bare -b main "$ORIGIN"
git -C "$PROJECT_REPO" init -q -b main
git -C "$PROJECT_REPO" config user.email "test@example.com"
git -C "$PROJECT_REPO" config user.name "test"
git -C "$PROJECT_REPO" commit -q --allow-empty -m "init"
git -C "$PROJECT_REPO" remote add origin "$ORIGIN"
git -C "$PROJECT_REPO" push -q origin main

rm -f "$SID_PATH"
export HOME="$HOME_DIR"
export USER="${USER:-agent}"
export DISINTO_CONTAINER=1
export AGENT_HARNESS=dsh
export DSH_HOME="$TMP_DIR/dsh-home"
export PITCH_FIXTURE
export CURL_STUB_LOG="$TMP_DIR/curl.log"
export DSH_STUB_LOG="$TMP_DIR/dsh.log"
export PROJECT_NAME
export PROJECT_REPO_ROOT="$PROJECT_REPO"
export OPS_REPO_ROOT="$OPS_REPO"
export PRIMARY_BRANCH=main
export FORGE_REMOTE=origin
export FORGE_REPO="test/${PROJECT_NAME}"
export FORGE_OPS_REPO="test/${PROJECT_NAME}-ops"
export FORGE_URL="http://127.0.0.1:9"
export FORGE_TOKEN=""
export FORGE_ARCHITECT_TOKEN=""
export FORGE_TOKEN_OVERRIDE=""
# Bound but empty: the live script sets this from forge_whoami. An unset
# value trips set -u inside load_formula_or_profile before agent_run.
export AGENT_IDENTITY=""
# A leaked forge base would bypass FORGE_URL and talk to a real host.
unset FORGE_API FORGE_API_BASE FORGE_WEB
# PATH is rebuilt by env.sh with $HOME/.local/bin first; keep the stubs
# ahead of any inherited dsh/curl as well.
export PATH="$BIN_DIR:$PATH"

# SID_FILE stays unset. Do not export it.
if [ -n "${SID_FILE+x}" ]; then
  ac_fail "SID_FILE must not be set in the test environment"
fi

rc=0
bash "$ARCHITECT_RUN" >"$TMP_DIR/stdout" 2>"$TMP_DIR/stderr" || rc=$?

log_file="$HOME_DIR/data/logs/architect/architect.log"
if [ "$rc" -ne 0 ] || [ ! -s "$DSH_STUB_LOG" ] || [ ! -f "$SID_PATH" ]; then
  ac_log "architect-run exit $rc"
  ac_log "--- stdout ---"
  cat "$TMP_DIR/stdout" 2>/dev/null || true
  ac_log "--- stderr ---"
  cat "$TMP_DIR/stderr" 2>/dev/null || true
  ac_log "--- architect log ---"
  cat "$log_file" 2>/dev/null || true
  ac_log "--- curl urls ---"
  cat "$CURL_STUB_LOG" 2>/dev/null || true
fi

ac_assert_eq "$rc" "0" "decompose path should exit 0 (got $rc)"
[ -s "$DSH_STUB_LOG" ] || ac_fail "dsh stub never ran; decompose did not reach agent_run"
grep -q 'decompose state' "$log_file" \
  || ac_fail "log has no decompose state line"
grep -q 'opus decompose session complete' "$log_file" \
  || ac_fail "decompose did not get past agent_run"
grep -q 'SID_FILE: unbound variable' "$log_file" "$TMP_DIR/stderr" \
  && ac_fail "SID_FILE was unbound during the run"
ac_assert_eq "$(cat "$SID_PATH")" "session-1968" \
  "session id should be written to $SID_PATH (got $(cat "$SID_PATH" 2>/dev/null || echo missing))"
ac_log "AC 2 OK"

ac_pass
