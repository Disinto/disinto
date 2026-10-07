#!/usr/bin/env bash
# =============================================================================
# tests/acceptance/issue-1891.sh
#
# Issue #1891: a pitch closed unmerged reaches the tape as a rejected sprint
# proposal. A pitch is an ops-repo PR that adds sprints/<slug>.md.
#
# tools/pitch-decisions.sh lists closed ops-repo PRs (curl, page by page) and,
# for an unmerged pitch, appends a rejected sprint proposal with context.pitch.
# A PR that is not a pitch is marked and not recorded. A second run appends
# nothing. A failed listing exits 1 and leaves the tape untouched.
#
# gardener/gardener-run.sh calls the tool after ensure_ops_repo and before
# the precondition checks. A non-zero exit only logs a warning.
#
# Hermetic: no network, no live box. The curl stub is ac_write_pitch_stub
# (#1892 extends that helper rather than copying it).
#
# Acceptance: `bash tests/acceptance/issue-1891.sh` exits 0 and calls ac_pass.
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=../../tests/lib/acceptance-helpers.sh
source "$REPO_ROOT/tests/lib/acceptance-helpers.sh"

ac_require_cmd bash jq flock git grep
ac_assert_file "$REPO_ROOT/tools/pitch-decisions.sh" "tools/pitch-decisions.sh is missing"
ac_assert_file "$REPO_ROOT/gardener/gardener-run.sh" "gardener/gardener-run.sh is missing"

# ── Wiring: after ensure_ops_repo, before the precondition checks, guarded ──
GARDENER="$REPO_ROOT/gardener/gardener-run.sh"
OPS_LINE=$(grep -n 'ensure_ops_repo' "$GARDENER" | head -n1 | cut -d: -f1)
CALL_LINE=$(grep -n 'tools/pitch-decisions.sh' "$GARDENER" | grep '||' | head -n1 | cut -d: -f1)
PRE_LINE=$(grep -n 'Precondition checks' "$GARDENER" | head -n1 | cut -d: -f1)
[ -n "$OPS_LINE" ] || ac_fail "gardener-run.sh must call ensure_ops_repo"
[ -n "$CALL_LINE" ] || ac_fail "gardener-run.sh must call tools/pitch-decisions.sh with ||"
[ -n "$PRE_LINE" ] || ac_fail "gardener-run.sh must still name the precondition checks"
[ "$OPS_LINE" -lt "$CALL_LINE" ] \
  || ac_fail "pitch-decisions.sh (line $CALL_LINE) must follow ensure_ops_repo (line $OPS_LINE)"
[ "$CALL_LINE" -lt "$PRE_LINE" ] \
  || ac_fail "pitch-decisions.sh (line $CALL_LINE) must precede Precondition checks (line $PRE_LINE)"
ac_log "wiring OK: pitch-decisions.sh is guarded between ensure_ops_repo and the precondition checks"

# Mode is the git index, not the working-tree bit.
MODE_LINE="$(git -C "$REPO_ROOT" ls-files -s tools/pitch-decisions.sh)"
case "$MODE_LINE" in
  100755*) ac_log "mode OK: tools/pitch-decisions.sh is 100755" ;;
  *) ac_fail "git ls-files -s tools/pitch-decisions.sh must start with 100755 (got: ${MODE_LINE:-empty})" ;;
esac

# Docs the issue requires, so a later edit cannot drop the sentence.
grep -qF 'then runs `tools/pitch-decisions.sh` (#1891), also before the precondition checks:' \
  "$REPO_ROOT/gardener/AGENTS.md" \
  || ac_fail "gardener/AGENTS.md must describe pitch-decisions.sh (#1891)"
grep -qF 'pitch-decisions.sh — a decided pitch reaches the tape; a merged one becomes its milestone and sub-issues (#1891, #1892)' \
  "$REPO_ROOT/docs/AGENTS.md" \
  || ac_fail "docs/AGENTS.md must name pitch-decisions.sh (#1891, #1892)"

TOOL="$REPO_ROOT/tools/pitch-decisions.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

STUB_BIN="$WORK/bin"
ac_write_pitch_stub "$STUB_BIN"

TAPE_DIR="$WORK/tape"
mkdir -p "$TAPE_DIR"
export PATH="$STUB_BIN:$PATH"
export FORGE_API_BASE="https://forge.example/api/v1"
export FORGE_OPS_REPO="o/ops"
export FORGE_TOKEN="stub"
export TAPE_DIR

run_decisions() {
  local rc=0
  bash "$TOOL" >"$WORK/out" 2>"$WORK/err" || rc=$?
  printf '%s' "$rc"
}

# ── One run: one rejected sprint proposal, markers for 22 and 23 ───────────
rc="$(run_decisions)"
ac_assert_eq "$rc" "0" "first run must return 0 (rc=$rc; stderr: $(cat "$WORK/err"))"
[ -f "$TAPE_DIR/tape.jsonl" ] || ac_fail "first run must write a tape line"
line_count="$(grep -c . "$TAPE_DIR/tape.jsonl" || true)"
ac_assert_eq "$line_count" "1" "first run must write exactly one tape line (got $line_count)"

line="$(head -n1 "$TAPE_DIR/tape.jsonl")"
ac_assert_eq "$(printf '%s' "$line" | jq -r '.type')" "proposal" "type must be proposal"
ac_assert_eq "$(printf '%s' "$line" | jq -r '.loop')" "sprint" "loop must be sprint"
ac_assert_eq "$(printf '%s' "$line" | jq -r '.class')" "deploy" "class must be deploy"
ac_assert_eq "$(printf '%s' "$line" | jq -r '.decision')" "rejected" "decision must be rejected"
ac_assert_eq "$(printf '%s' "$line" | jq -r '.ref')" "pitch:22" "ref must be pitch:22"
ctx="$(printf '%s' "$line" | jq -c '.context')"
ac_assert_eq "$ctx" '{"pitch":22}' "context must be {\"pitch\":22} (got $ctx)"
[ -e "$TAPE_DIR/pitches/pr-22" ] || ac_fail "marker pitches/pr-22 must exist"
[ -e "$TAPE_DIR/pitches/pr-23" ] || ac_fail "marker pitches/pr-23 must exist"
ac_log "first run OK: rejected sprint proposal for pitch 22, both markers written"

# ── Second run appends nothing ──────────────────────────────────────────────
before="$(cksum "$TAPE_DIR/tape.jsonl")"
rc="$(run_decisions)"
ac_assert_eq "$rc" "0" "second run must return 0 (rc=$rc; stderr: $(cat "$WORK/err"))"
after="$(cksum "$TAPE_DIR/tape.jsonl")"
ac_assert_eq "$after" "$before" "second run must not append (before $before, after $after)"
ac_log "second run OK: tape unchanged"

# The selection disinto-ops probes/sprint-pitches-decided.sh applies to the tape.
probe_n="$(jq -s '[.[] | select(.type == "proposal" and .loop == "sprint") | select((.context.pitch // "" | tostring | length) > 0)] | length' "$TAPE_DIR/tape.jsonl")"
ac_assert_eq "$probe_n" "1" "sprint-pitches-decided selection must print 1 (got $probe_n)"
ac_log "probe selection OK: 1 decided sprint pitch on the tape"

# ── Listing failure: stub exits 22, tape untouched ──────────────────────────
FAIL_DIR="$WORK/tape-fail"
mkdir -p "$FAIL_DIR"
printf '%s\n' '{"type":"sentinel"}' >"$FAIL_DIR/tape.jsonl"
seed="$(cksum "$FAIL_DIR/tape.jsonl")"
rc=0
AC_PITCH_STUB_FAIL=1 TAPE_DIR="$FAIL_DIR" bash "$TOOL" >"$WORK/fail-out" 2>"$WORK/fail-err" || rc=$?
ac_assert_eq "$rc" "1" "a failed listing must return 1 (rc=$rc; stderr: $(cat "$WORK/fail-err"))"
ac_assert_eq "$(cksum "$FAIL_DIR/tape.jsonl")" "$seed" "a failed listing must leave the tape untouched"
[ ! -e "$FAIL_DIR/pitches/pr-22" ] || ac_fail "a failed listing must not mark PR 22"
[ ! -e "$FAIL_DIR/pitches/pr-23" ] || ac_fail "a failed listing must not mark PR 23"
ac_log "listing failure OK: rc 1, tape untouched"

ac_pass
