#!/usr/bin/env bash
# =============================================================================
# tests/acceptance/issue-1847.sh
#
# Issue #1847: dsh_oneshot sends one prompt through dsh headless and prints
# the redacted text. It must not go through agent_run, so it must not touch
# the session id, the diagnostics file, or the metrics record, and it must
# ignore AGENT_HARNESS.
#
# Acceptance (no network, no model; dsh and claude are stubs):
#   1. Stub prints "entry FORGE_TOKEN=abc123" and exits 0. dsh_oneshot
#      "hello" returns 0, stdout is "entry FORGE_TOKEN=<redacted>", argv is
#      "--profile headless hello", DSH_PERMISSION_MODE=danger-full-access,
#      and DSH_RESUME_SESSION is empty.
#   2. The claude stub never ran. SID_FILE does not exist. Neither
#      $DISINTO_LOG_DIR/test/agent-run-last.json nor
#      $DISINTO_LOG_DIR/metrics/agent-runs.jsonl exists.
#   3. Stub exits 3: dsh_oneshot x returns 3.
#   4. Stub runs sleep 5: dsh_oneshot --timeout 1 x returns 124.
#   5. bash -n and shellcheck pass on lib/dsh-oneshot.sh.
#
# Run via: tools/run-acceptance.sh 1847
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../lib/acceptance-helpers.sh
source "$REPO_ROOT/tests/lib/acceptance-helpers.sh"

ac_require_cmd bash shellcheck timeout

# ── 5. Syntax and shellcheck, before any stub is involved ───────────────────
ac_log "AC 5: bash -n and shellcheck on lib/dsh-oneshot.sh"
bash -n "$REPO_ROOT/lib/dsh-oneshot.sh" \
  || ac_fail "bash -n lib/dsh-oneshot.sh failed"
(
  cd "$REPO_ROOT" || exit 1
  shellcheck lib/dsh-oneshot.sh
) || ac_fail "shellcheck lib/dsh-oneshot.sh failed"
ac_log "AC 5 OK"

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

BIN_DIR="$TMP_DIR/bin"
WORK_DIR="$TMP_DIR/work"
LOG_DIR="$TMP_DIR/logs"
mkdir -p "$BIN_DIR" "$WORK_DIR" "$LOG_DIR/test" "$LOG_DIR/metrics"

export SID_FILE="$TMP_DIR/session.sid"
export DISINTO_LOG_DIR="$LOG_DIR"
export LOG_AGENT=test
export LOGFILE="$TMP_DIR/oneshot.log"
export DSH_HOME="$TMP_DIR/dsh-home"
export AGENT_HARNESS=claude
export DSH_RESUME_SESSION=old
export DSH_STUB_LOG="$TMP_DIR/dsh-record"
export CLAUDE_STUB_LOG="$TMP_DIR/claude-record"
# Exercise the documented default, not a value inherited from the runner.
unset CLAUDE_TIMEOUT

cat > "$BIN_DIR/dsh" << 'EOF'
#!/usr/bin/env bash
# Stub: record argv and the env dsh_oneshot must pass, then act on the mode.
{
  printf 'argv=%s\n' "$*"
  printf 'perm=%s\n' "${DSH_PERMISSION_MODE-UNSET}"
  printf 'resume=%s\n' "${DSH_RESUME_SESSION-UNSET}"
  printf 'home=%s\n' "${DSH_HOME-UNSET}"
  printf 'cwd=%s\n' "$PWD"
} > "${DSH_STUB_LOG:?}"
case "${DSH_STUB_MODE:-text}" in
  text)
    printf 'entry FORGE_TOKEN=abc123\n'
    exit 0
    ;;
  fail)
    exit 3
    ;;
  slow)
    sleep 5
    exit 0
    ;;
esac
printf 'unknown DSH_STUB_MODE\n' >&2
exit 9
EOF
cat > "$BIN_DIR/claude" << 'EOF'
#!/usr/bin/env bash
printf 'claude-ran\n' >> "${CLAUDE_STUB_LOG:?}"
exit 0
EOF
chmod +x "$BIN_DIR/dsh" "$BIN_DIR/claude"
export PATH="$BIN_DIR:$PATH"

log() { printf '%s\n' "$*" >> "$LOGFILE"; }

# shellcheck source=lib/agent-sdk.sh
source "$REPO_ROOT/lib/agent-sdk.sh"
# shellcheck source=lib/dsh-oneshot.sh
source "$REPO_ROOT/lib/dsh-oneshot.sh"

cd "$WORK_DIR" || ac_fail "cannot cd to the work dir"

# ── 1. Redacted text, dsh argv, and the permission/resume env ───────────────
ac_log "AC 1: one prompt, redacted text, headless argv, empty resume"
export DSH_STUB_MODE=text
rc=0
out="$(dsh_oneshot "hello")" || rc=$?
ac_assert_eq "$rc" "0" "dsh_oneshot hello should return 0 (got $rc)"
ac_assert_eq "$out" "entry FORGE_TOKEN=<redacted>" \
  "stdout should be redacted (got: ${out})"
record="$(cat "$DSH_STUB_LOG")"
ac_assert_eq "$(printf '%s\n' "$record" | sed -n 's/^argv=//p')" \
  "--profile headless hello" \
  "dsh argv mismatch (record: ${record})"
ac_assert_eq "$(printf '%s\n' "$record" | sed -n 's/^perm=//p')" \
  "danger-full-access" \
  "DSH_PERMISSION_MODE mismatch (record: ${record})"
ac_assert_eq "$(printf '%s\n' "$record" | sed -n 's/^resume=//p')" \
  "" \
  "DSH_RESUME_SESSION should be empty, not inherited (record: ${record})"
ac_assert_eq "$(printf '%s\n' "$record" | sed -n 's/^home=//p')" \
  "$DSH_HOME" \
  "dsh should see the caller's DSH_HOME (record: ${record})"
ac_assert_eq "$(printf '%s\n' "$record" | sed -n 's/^cwd=//p')" \
  "$WORK_DIR" \
  "dsh should run in the current directory (record: ${record})"
ac_assert_eq "$DSH_RESUME_SESSION" "old" \
  "dsh_oneshot must not clear the caller's DSH_RESUME_SESSION"
ac_log "AC 1 OK"

# ── 2. claude never ran; no session, diagnostics, or metrics write ──────────
ac_log "AC 2: no claude, no SID_FILE, no diagnostics, no metrics"
[ ! -e "$CLAUDE_STUB_LOG" ] \
  || ac_fail "claude stub ran (AGENT_HARNESS=claude must be ignored)"
[ ! -e "$SID_FILE" ] \
  || ac_fail "SID_FILE must not be written (got $(cat "$SID_FILE"))"
[ ! -e "$DISINTO_LOG_DIR/test/agent-run-last.json" ] \
  || ac_fail "agent-run-last.json must not be written"
[ ! -e "$DISINTO_LOG_DIR/metrics/agent-runs.jsonl" ] \
  || ac_fail "metrics/agent-runs.jsonl must not be written"
ac_log "AC 2 OK"

# ── 3. Non-zero exit passes through ─────────────────────────────────────────
ac_log "AC 3: stub exit 3 is returned"
export DSH_STUB_MODE=fail
rc=0
dsh_oneshot x || rc=$?
ac_assert_eq "$rc" "3" "dsh_oneshot x should return 3 (got $rc)"
ac_log "AC 3 OK"

# ── 4. GNU timeout limit fires as 124 ───────────────────────────────────────
ac_log "AC 4: --timeout 1 against sleep 5 returns 124"
export DSH_STUB_MODE=slow
rc=0
dsh_oneshot --timeout 1 x || rc=$?
ac_assert_eq "$rc" "124" "dsh_oneshot --timeout 1 x should return 124 (got $rc)"
ac_log "AC 4 OK"

# A later call must not have started writing session state either.
[ ! -e "$CLAUDE_STUB_LOG" ] || ac_fail "claude stub ran on a later call"
[ ! -e "$SID_FILE" ] || ac_fail "SID_FILE appeared after a later call"
[ ! -e "$DISINTO_LOG_DIR/test/agent-run-last.json" ] \
  || ac_fail "diagnostics file appeared after a later call"
[ ! -e "$DISINTO_LOG_DIR/metrics/agent-runs.jsonl" ] \
  || ac_fail "metrics record appeared after a later call"

ac_pass
