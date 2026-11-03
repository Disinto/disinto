#!/usr/bin/env bash
# =============================================================================
# tests/acceptance/issue-2074.sh
#
# Issue #2074: a model session runs with a scratch TAPE_DIR, never the live tape.
#
# Before: _agent_run_dsh and dsh_oneshot invoked `dsh --profile headless` with
# the container's TAPE_DIR (/srv/disinto/tape) still in the environment, so any
# factory code the session ran appended to the live tape and its repair state,
# which the supervisor then acted on.
#
# After: both harness paths create a fresh scratch tape under
# ${DISINTO_DATA_DIR:-/tmp} and pass TAPE_DIR/NOTICES_DIR as prefix assignments
# to the dsh command, removing the scratch dir after the call on every path.
#
# Acceptance (no network; stub dsh on PATH; temp live tape):
#   1. _agent_run_dsh: the live tape.jsonl still has exactly one line and
#      live/repair/ does not exist; the stub saw a scratch TAPE_DIR under
#      DISINTO_DATA_DIR, NOTICES_DIR = <scratch>/notices, and the scratch dir
#      is gone after the call.
#   2. The caller's TAPE_DIR still names the live dir afterwards.
#   3. The same three checks hold for dsh_oneshot.
#   4. A stub dsh that exits 1 still leaves no scratch dir behind.
#   5. bats tests/lib-agent-harness-dsh.bats passes; bash -n passes for both
#      changed files.
#
# Run via: tools/run-acceptance.sh 2074
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck disable=SC1091
source "$REPO_ROOT/tests/lib/acceptance-helpers.sh"

ac_require_cmd bash bats mktemp timeout jq

TMP="$(mktemp -d)"
LIVE="$TMP/live"
RUNDIR="$TMP/run"
STUB_LOG="$TMP/stub-log.txt"
export STUB_LOG

# The "live" tape: one line, no repair state.
mkdir -p "$LIVE" "$RUNDIR"
printf '%s\n' '{"type":"seed","note":"the only line on the live tape"}' > "$LIVE/tape.jsonl"

# Harness environment.
export TAPE_DIR="$LIVE"
export DISINTO_DATA_DIR="$TMP/data"
mkdir -p "$DISINTO_DATA_DIR"
export DISINTO_LOG_DIR="$TMP/logs"
export DSH_HOME="$TMP/dsh-home"
export SID_FILE="$TMP/sid"
export LOGFILE="$TMP/agent.log"
export LOG_AGENT=acceptance
log() { printf '[acceptance] %s\n' "$*" >> "${LOGFILE:-/dev/null}"; }

# Stub dsh: behaves like factory code a session runs — appends a run record to
# the tape it is handed, writes a repair marker under it, and records the
# TAPE_DIR/NOTICES_DIR it saw, one line per call: run=<n> TAPE_DIR=... NOTICES_DIR=...
mkdir -p "$TMP/bin"
cat > "$TMP/bin/dsh" <<'EOF'
#!/usr/bin/env bash
echo "run=${STUB_CALL_N:-0} TAPE_DIR=${TAPE_DIR:-} NOTICES_DIR=${NOTICES_DIR:-}" >> "${STUB_LOG:-/dev/null}"
printf '%s\n' '{"type":"run","t":"x"}' >> "${TAPE_DIR:-/dev/null}/tape.jsonl"
mkdir -p "${TAPE_DIR:-.}/repair"
touch "${TAPE_DIR:-.}/repair/x.suspended"
echo "fake dsh final text"
if [ -n "${STUB_EXIT:-}" ] && [ "${STUB_EXIT:-0}" != "0" ]; then
  exit "$STUB_EXIT"
fi
EOF
chmod +x "$TMP/bin/dsh"
export PATH="$TMP/bin:$PATH"

# shellcheck disable=SC1091
source "$REPO_ROOT/lib/agent-sdk.sh"
# shellcheck disable=SC1091
source "$REPO_ROOT/lib/dsh-oneshot.sh"

# Extract the scratch dir the stub of call N ran under, verify the live tape is
# untouched, the scratch env is as specified, and the scratch dir is gone.
check_run() {
  local id="$1" line scratch notices
  line="$(sed -n "s/^run=$id //p" "$STUB_LOG" | tail -n 1)"
  [ -n "$line" ] || ac_fail "stub dsh for run $id did not record its environment"
  scratch="${line#TAPE_DIR=}"; scratch="${scratch%% NOTICES_DIR=*}"
  notices="${line#* NOTICES_DIR=}"

  if [ "$scratch" = "$LIVE" ]; then
    ac_fail "run $id: stub saw the live TAPE_DIR, not a scratch one"
  fi
  case "$scratch" in
    "${DISINTO_DATA_DIR:-/tmp}/session-tape."*) ;;
    *) ac_fail "run $id: scratch TAPE_DIR '$scratch' is not under ${DISINTO_DATA_DIR:-/tmp}" ;;
  esac
  ac_assert_eq "$notices" "$scratch/notices" "run $id: NOTICES_DIR '$notices' is not '$scratch/notices'"
  [ ! -d "$scratch" ] || ac_fail "run $id: scratch dir '$scratch' still exists after the call"
  ac_assert_eq "$(wc -l < "$LIVE/tape.jsonl")" "1" "run $id: live tape.jsonl no longer has exactly one line"
  [ ! -d "$LIVE/repair" ] || ac_fail "run $id: live repair/ directory was created"
}

# ── 1. _agent_run_dsh ────────────────────────────────────────────────────────
ac_log "running _agent_run_dsh with a stub dsh (run 1)"
export STUB_CALL_N=1
rc=0
_agent_run_dsh --worktree "$RUNDIR" "verify locally" || rc=$?
ac_assert_eq "$rc" "0" "_agent_run_dsh returned $rc with a succeeding stub"
check_run 1
ac_assert_eq "$TAPE_DIR" "$LIVE" "the caller's TAPE_DIR was changed by _agent_run_dsh"

# ── 2. dsh_oneshot ───────────────────────────────────────────────────────────
ac_log "running dsh_oneshot with a stub dsh (run 2)"
export STUB_CALL_N=2
rc=0
dsh_oneshot "one prompt" || rc=$?
ac_assert_eq "$rc" "0" "dsh_oneshot returned $rc with a succeeding stub"
check_run 2
ac_assert_eq "$TAPE_DIR" "$LIVE" "the caller's TAPE_DIR was changed by dsh_oneshot"

# ── 3. failing stub leaves no scratch dir ────────────────────────────────────
ac_log "running _agent_run_dsh with a stub dsh that exits 1 (run 3)"
export STUB_CALL_N=3 STUB_EXIT=1
rc=0
_agent_run_dsh --worktree "$RUNDIR" "verify locally" || rc=$?
ac_assert_eq "$rc" "1" "the failing stub's exit code was not returned"
check_run 3
ac_assert_eq "$TAPE_DIR" "$LIVE" "the caller's TAPE_DIR was changed by a failing _agent_run_dsh run"

# ── 4. existing harness suite still passes ───────────────────────────────────
ac_log "running bats tests/lib-agent-harness-dsh.bats"
bats "$REPO_ROOT/tests/lib-agent-harness-dsh.bats" >/dev/null || ac_fail "tests/lib-agent-harness-dsh.bats failed"

ac_log "bash -n on both changed files"
bash -n "$REPO_ROOT/lib/agent-harness-dsh.sh" || ac_fail "bash -n failed on lib/agent-harness-dsh.sh"
bash -n "$REPO_ROOT/lib/dsh-oneshot.sh" || ac_fail "bash -n failed on lib/dsh-oneshot.sh"

rm -rf "$TMP"
ac_pass
