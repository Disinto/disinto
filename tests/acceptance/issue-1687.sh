#!/usr/bin/env bash
# =============================================================================
# tests/acceptance/issue-1687.sh
#
# Issue #1687: the dsh harness takes only a session started in its own
# directory. After the run, _agent_run_dsh must not take the newest
# $DSH_HOME/sessions/ directory by mtime alone — a dsh session another
# process starts during the run (a test the agent runs) has a newer mtime
# and a cwd that is not the run directory, and must be skipped. A log that
# cannot be read yet stays a candidate (#1186).
#
# Self-contained: no network. A stub `dsh` on PATH writes zstd session logs
# under a temp DSH_HOME; the real _agent_run_dsh selects among them.
#
# Acceptance criteria:
#   1. Stub writes its own session (first record cwd = the run dir), then a
#      second session dir with a newer mtime (touch -d) whose first record
#      has cwd /somewhere/else: _AGENT_SESSION_ID is the first one.
#      Both logs are multi-line (60000 trailing records). A one-line log
#      never makes zstdcat die with SIGPIPE when head closes the pipe, so
#      pipefail would not wipe a printed cwd and the filter would look like
#      it works (#1687 review).
#   2. A session whose first record has a top-level cwd equal to the run dir
#      (the real dsh 0.1.1-rc.2 format) is taken over a newer foreign one.
#      Same multi-line logs, so the top-level cwd path is also read under
#      SIGPIPE.
#   3. A session dir whose log is not valid zstd is still taken when it is
#      the only candidate.
#   4. This test exits 0 and calls ac_pass.
#
# Run via: tools/run-acceptance.sh 1687
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck disable=SC1091
source "$REPO_ROOT/tests/lib/acceptance-helpers.sh"

ac_require_cmd bash jq zstd zstdcat touch stat awk

# The review requires the session-selection sentence in the same PR.
DOCS="$REPO_ROOT/lib/AGENTS.md"
ac_assert_file "$DOCS" "lib/AGENTS.md must exist"
grep -qF "and whose session log's first record names the run directory as its cwd (a log that cannot be read yet stays a candidate), so a dsh session another process starts during the run, such as a test the agent runs, is never taken (#1687)" "$DOCS" \
  || ac_fail "lib/AGENTS.md session-selection sentence missing the #1687 cwd clause"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

export SID_FILE="$TMP/sid"
export LOGFILE="$TMP/agent.log"
export LOG_AGENT=test
export DISINTO_LOG_DIR="$TMP/logs"
export DSH_HOME="$TMP/dsh-home"
export AGENT_HARNESS=dsh

mkdir -p "$TMP/bin"
cat > "$TMP/bin/dsh" <<'EOF'
#!/usr/bin/env bash
# Stub dsh: writes a session log under $DSH_HOME the way headless dsh does.
# DSH_STUB_MODE selects which logs to plant (see the test header).
set -euo pipefail
slug="$DSH_HOME/sessions/fake-slug"
mkdir -p "$slug"

# PAD lines after the first record. A two-line log is racy under
# pipefail+SIGPIPE (head closes zstdcat's pipe); tens of thousands of
# lines fail every time if the harness discards a printed cwd.
PAD_LINES=60000

write_log() {
  local dest="$1" json="$2"
  mkdir -p "$dest"
  {
    printf '%s\n' "$json"
    awk -v n="$PAD_LINES" 'BEGIN { for (i = 0; i < n; i++) print "{\"type\":\"chunk\",\"seq\":" i "}" }'
  } | zstd -q > "$dest/session.jsonl.zstd"
}

case "${DSH_STUB_MODE:-own-plus-foreign}" in
  own-plus-foreign)
    # Own session: test-stub shape, data.cwd = the run directory.
    write_log "$slug/session-own" "{\"type\":\"session\",\"data\":{\"cwd\":\"$PWD\"}}"
    # A session another process started during the run, newer mtime, other cwd.
    write_log "$slug/session-foreign" '{"type":"session","data":{"cwd":"/somewhere/else"}}'
    touch -d 'tomorrow' "$slug/session-foreign"
    ;;
  toplevel)
    # Real dsh 0.1.1-rc.2 shape: cwd at the top level of the first record.
    write_log "$slug/session-real" "{\"cwd\":\"$PWD\",\"type\":\"session\"}"
    write_log "$slug/session-foreign" '{"cwd":"/somewhere/else","type":"session"}'
    touch -d 'tomorrow' "$slug/session-foreign"
    ;;
  badzstd)
    mkdir -p "$slug/session-truncated"
    printf 'not a zstd stream' > "$slug/session-truncated/session.jsonl.zstd"
    ;;
  *)
    echo "unknown DSH_STUB_MODE: ${DSH_STUB_MODE}" >&2
    exit 2
    ;;
esac
echo "fake dsh final text"
EOF
chmod +x "$TMP/bin/dsh"
export PATH="$TMP/bin:$PATH"

log() { echo "$*" >> "$LOGFILE"; }

# shellcheck disable=SC1091
source "$REPO_ROOT/lib/agent-sdk.sh"

run_dir="$TMP/wt"
mkdir -p "$run_dir"

# ── 1. Newer foreign session (other cwd) is not taken ────────────────────────
export DSH_STUB_MODE=own-plus-foreign
rm -rf "$DSH_HOME"
rc=0
agent_run --worktree "$run_dir" "do the thing" || rc=$?
ac_assert_eq "$rc" "0" "own-plus-foreign run should exit 0, got $rc"
ac_assert_eq "$_AGENT_SESSION_ID" "session-own" \
  "newer session with cwd /somewhere/else must not be taken (got ${_AGENT_SESSION_ID:-empty})"
# The foreign dir really was newer, so this is not a vacuous pass.
own_mtime="$(stat -c %Y "$DSH_HOME/sessions/fake-slug/session-own")"
foreign_mtime="$(stat -c %Y "$DSH_HOME/sessions/fake-slug/session-foreign")"
[ "$foreign_mtime" -gt "$own_mtime" ] \
  || ac_fail "fixture error: foreign session mtime ($foreign_mtime) is not newer than own ($own_mtime)"

# ── 2. Real dsh format: top-level cwd equal to the run dir is taken ──────────
export DSH_STUB_MODE=toplevel
rm -rf "$DSH_HOME"
rc=0
agent_run --worktree "$run_dir" "do the thing" || rc=$?
ac_assert_eq "$rc" "0" "toplevel run should exit 0, got $rc"
ac_assert_eq "$_AGENT_SESSION_ID" "session-real" \
  "top-level cwd matching the run dir must be taken over a newer foreign session (got ${_AGENT_SESSION_ID:-empty})"

# ── 3. Unreadable log stays a candidate when it is the only one ──────────────
export DSH_STUB_MODE=badzstd
rm -rf "$DSH_HOME"
rc=0
agent_run --worktree "$run_dir" "do the thing" || rc=$?
ac_assert_eq "$rc" "0" "badzstd run should exit 0, got $rc"
ac_assert_eq "$_AGENT_SESSION_ID" "session-truncated" \
  "a session whose log is not valid zstd must still be taken when it is the only candidate (got ${_AGENT_SESSION_ID:-empty})"

ac_pass
