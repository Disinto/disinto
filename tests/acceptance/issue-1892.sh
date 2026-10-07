#!/usr/bin/env bash
# =============================================================================
# tests/acceptance/issue-1892.sh
#
# Issue #1892: a merged pitch becomes its sprint. The owner merging the
# ops-repo PR that adds sprints/<slug>.md gives the project the milestone
# and the sub-issues, and the tape an approved sprint proposal.
#
# The curl stub is ac_write_pitch_stub (#1891), extended rather than copied.
# AC_PITCH_STUB_MERGED=1 lists closed PR 21 (merged, adds sprints/a.md)
# beside the unmerged pitch 22. The milestone arm answers id 9.
#
# Hermetic: no network, no live box.
#
# Acceptance: `bash tests/acceptance/issue-1892.sh` exits 0 and calls ac_pass.
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=../../tests/lib/acceptance-helpers.sh
source "$REPO_ROOT/tests/lib/acceptance-helpers.sh"

ac_require_cmd bash jq flock git grep
ac_assert_file "$REPO_ROOT/tools/pitch-decisions.sh" "tools/pitch-decisions.sh is missing"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
TOOL="$REPO_ROOT/tools/pitch-decisions.sh"
ac_write_pitch_stub "$WORK/bin"

OPS_REPO_ROOT="$WORK/ops"
mkdir -p "$OPS_REPO_ROOT/sprints"
FILER_LOG="$WORK/filer.log"
: >"$FILER_LOG"

# Appends its arguments. Exits AC_FILER_RC (default 0). A leaked FACTORY_ROOT
# is a failure: the filer must source lib/env.sh itself.
cat >"$WORK/filer.sh" <<'FILER'
#!/usr/bin/env bash
if [ -n "${FACTORY_ROOT:-}" ]; then
  printf 'FACTORY_ROOT leaked\n' >>"${FILER_LOG:?}"
  exit 1
fi
printf '%s\n' "$*" >>"${FILER_LOG:?}"
exit "${AC_FILER_RC:-0}"
FILER
chmod +x "$WORK/filer.sh"

export PATH="$WORK/bin:$PATH"
export FORGE_API_BASE="https://forge.example/api/v1"
export FORGE_OPS_REPO="o/ops"
export FORGE_TOKEN="stub"
export FORGE_API="https://forge.example/api/v1/repos/o/p"
export FORGE_FILER_TOKEN="stub"
export OPS_REPO_ROOT
export SPRINT_FILER="$WORK/filer.sh"
export FILER_LOG
export AC_PITCH_STUB_MERGED=1
# The tool must not pass this through to the filer.
export FACTORY_ROOT="leaked"

write_pitch() {
  local kind="$1"
  case "$kind" in
    full)
      cat >"$OPS_REPO_ROOT/sprints/a.md" <<'PITCH'
# Sprint: A pitch becomes a sprint

## What this enables

A merged pitch becomes its sprint.

<!-- sprint:begin -->
class: internal
effect: none
expect: >= 1
soak: 1d
<!-- sprint:end -->

<!-- filer:begin -->
- id: one
  title: file me
<!-- filer:end -->
PITCH
      ;;
    no-block)
      cat >"$OPS_REPO_ROOT/sprints/a.md" <<'PITCH'
# Sprint: A pitch becomes a sprint

## What this enables

This file has a purpose paragraph and a filer block, but no sprint block.

<!-- filer:begin -->
- id: one
  title: file me
<!-- filer:end -->
PITCH
      ;;
    *)
      ac_fail "unknown pitch kind: $kind"
      ;;
  esac
}

approved_line() {
  jq -c 'select(.type == "proposal" and .ref == "milestone:9")' "$1/tape.jsonl"
}

# ── One run: approved proposal, id file, one filer call, marker ─────────────
write_pitch full
TAPE_DIR="$WORK/tape"
mkdir -p "$TAPE_DIR"
export TAPE_DIR
: >"$FILER_LOG"

rc=0
bash "$TOOL" >"$WORK/out" 2>"$WORK/err" || rc=$?
ac_assert_eq "$rc" "0" "first run must return 0 (rc=$rc; stderr: $(cat "$WORK/err"))"
[ -f "$TAPE_DIR/tape.jsonl" ] || ac_fail "first run must write a tape line"

line="$(approved_line "$TAPE_DIR")"
[ -n "$line" ] || ac_fail "first run must write an approved proposal (tape: $(cat "$TAPE_DIR/tape.jsonl"))"
ac_assert_eq "$(printf '%s' "$line" | jq -r '.loop')" "sprint" "loop must be sprint"
ac_assert_eq "$(printf '%s' "$line" | jq -r '.class')" "internal" "class must be internal"
ac_assert_eq "$(printf '%s' "$line" | jq -r '.decision')" "approved" "decision must be approved"
ac_assert_eq "$(printf '%s' "$line" | jq -r '.ref')" "milestone:9" "ref must be milestone:9"
ctx="$(printf '%s' "$line" | jq -c '.context')"
ac_assert_eq "$ctx" '{"pitch":21}' "context must be {\"pitch\":21} (got $ctx)"
prop_id="$(printf '%s' "$line" | jq -r '.id')"
ac_assert_eq "$(cat "$TAPE_DIR/sprints/9")" "$prop_id" \
  "id file sprints/9 must hold the proposal id (got $(cat "$TAPE_DIR/sprints/9" 2>/dev/null || echo missing))"
approved_n="$(jq -s '[.[] | select(.type == "proposal" and .ref == "milestone:9")] | length' "$TAPE_DIR/tape.jsonl")"
ac_assert_eq "$approved_n" "1" "first run must write exactly one milestone:9 proposal (got $approved_n)"
ac_assert_eq "$(cat "$FILER_LOG")" "${OPS_REPO_ROOT}/sprints/a.md 9" \
  "filer log must be the sprint file and milestone 9 (got: $(cat "$FILER_LOG"))"
[ -e "$TAPE_DIR/pitches/pr-21" ] || ac_fail "marker pitches/pr-21 must exist"
ac_log "first run OK: approved sprint proposal for pitch 21, filer called once, marker written"

# The selection disinto-ops probes/sprint-pitches-decided.sh applies to the tape
# (21 approved, 22 rejected).
probe_n="$(jq -s '[.[] | select(.type == "proposal" and .loop == "sprint") | select((.context.pitch // "" | tostring | length) > 0)] | length' "$TAPE_DIR/tape.jsonl")"
ac_assert_eq "$probe_n" "2" "sprint-pitches-decided selection must print 2 (got $probe_n)"
ac_log "probe selection OK: 2 decided sprint pitches on the tape"

# ── Filer exits 1: proposal written, no marker; retry files once ────────────
FAIL_TAPE="$WORK/tape-fail"
mkdir -p "$FAIL_TAPE"
: >"$FILER_LOG"
rc=0
AC_FILER_RC=1 TAPE_DIR="$FAIL_TAPE" bash "$TOOL" >"$WORK/fail-out" 2>"$WORK/fail-err" || rc=$?
ac_assert_eq "$rc" "1" "a failing filer must return 1 (rc=$rc; stderr: $(cat "$WORK/fail-err"))"
[ -f "$FAIL_TAPE/tape.jsonl" ] || ac_fail "a failing filer must still write the proposal"
fail_line="$(approved_line "$FAIL_TAPE")"
[ -n "$fail_line" ] || ac_fail "a failing filer must leave the approved proposal on the tape"
ac_assert_eq "$(printf '%s' "$fail_line" | jq -c '.context')" '{"pitch":21}' \
  "the proposal written before the filer fails must carry pitch 21"
[ ! -e "$FAIL_TAPE/pitches/pr-21" ] || ac_fail "a failing filer must not mark PR 21"
ac_log "filer failure OK: proposal written, marker absent, rc 1"

before="$(cksum "$FAIL_TAPE/tape.jsonl")"
: >"$FILER_LOG"
rc=0
AC_FILER_RC=0 TAPE_DIR="$FAIL_TAPE" bash "$TOOL" >"$WORK/retry-out" 2>"$WORK/retry-err" || rc=$?
ac_assert_eq "$rc" "0" "retry with the filer fixed must return 0 (rc=$rc; stderr: $(cat "$WORK/retry-err"))"
after="$(cksum "$FAIL_TAPE/tape.jsonl")"
ac_assert_eq "$after" "$before" "retry must append no second proposal (before $before, after $after)"
ac_assert_eq "$(cat "$FILER_LOG")" "${OPS_REPO_ROOT}/sprints/a.md 9" \
  "retry must call the filer once (got: $(cat "$FILER_LOG"))"
[ -e "$FAIL_TAPE/pitches/pr-21" ] || ac_fail "retry must write the marker for 21"
ac_log "retry OK: no second proposal, filer called once, marker written"

# ── No sprint block: marker, nothing appended, filer not called ─────────────
write_pitch no-block
BARE_TAPE="$WORK/tape-bare"
mkdir -p "$BARE_TAPE/pitches"
# Only the merged pitch is undecided, so "nothing appended" is the whole tape.
touch "$BARE_TAPE/pitches/pr-22" "$BARE_TAPE/pitches/pr-23"
: >"$FILER_LOG"
rc=0
AC_FILER_RC=0 TAPE_DIR="$BARE_TAPE" bash "$TOOL" >"$WORK/bare-out" 2>"$WORK/bare-err" || rc=$?
ac_assert_eq "$rc" "0" "a pitch with no sprint block must return 0 (rc=$rc; stderr: $(cat "$WORK/bare-err"))"
[ ! -e "$BARE_TAPE/tape.jsonl" ] || ac_fail "a pitch with no sprint block must append nothing"
[ -z "$(cat "$FILER_LOG")" ] || ac_fail "a pitch with no sprint block must not call the filer (got: $(cat "$FILER_LOG"))"
[ -e "$BARE_TAPE/pitches/pr-21" ] || ac_fail "a pitch with no sprint block must still be marked"
grep -qF 'pitch #21 has no sprint block' "$WORK/bare-err" \
  || ac_fail "a pitch with no sprint block must log that (stderr: $(cat "$WORK/bare-err"))"
ac_log "no sprint block OK: marker written, tape untouched, filer not called"

ac_pass
