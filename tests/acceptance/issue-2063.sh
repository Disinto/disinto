#!/usr/bin/env bash
# shellcheck disable=SC2154  # RC/OUT/ERR set by run_sig (local to this test)
# =============================================================================
# tests/acceptance/issue-2063.sh
#
# Issue #2063: top signatures are counted per (loop, class, model)
#
# tools/calibration-signatures.sh (#1651) keyed its labels by <loop>/<class>.
# With calibration rows per (loop, class, model) (#2062) every model row of
# dev/backlog showed the pooled cell — the column that says *why* a class
# came back must say it per model. The outcome model comes from
# ${TAPE_MODEL_TOOL:-tools/tape-model.sh} (#2059) run with no arguments; the
# stuck model is the sample's own `model` field (#2061); anything unnamed
# lands on `-`. A model tool that exits non-zero or prints a non-JSON-object
# exits 1 with a `calibration-signatures:` line and writes nothing.
#
# Hermetic: fixture tape and table in tmp dirs; TAPE_STUCK_TOOL is a stub;
# AC 1 wires TAPE_MODEL_TOOL to the real tools/tape-model.sh (#2059 default),
# #2059), AC 2 points it at stubs.
#
# Acceptance:
#   AC 1  rows | dev | backlog | grok-4.7 | … | agent-loop:1 |,
#         | dev | backlog | unsloth/Qwen3.8-27B | … | agent-loop:1, stuck:1 |,
#         | dev | backlog | - | … | needs-ops:1, stuck:1 |
#   AC 2  TAPE_MODEL_TOOL exits 1 -> rc 1, empty stdout, exactly one
#         `calibration-signatures:` line on stderr; a model tool printing a
#         JSON array (not an object) is refused the same way
#   AC 3  bash -n tools/calibration-signatures.sh; the file is executable;
#         tests/acceptance/issue-1651.sh passes
#
# Run via: tools/run-acceptance.sh 2063
# Contract: executable bash, set -euo pipefail, exit 0, last stdout line PASS
# (or FAIL: <reason>). Uses tests/lib/acceptance-helpers.sh helpers.
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../tests/lib/acceptance-helpers.sh
source "$REPO_ROOT/tests/lib/acceptance-helpers.sh"

ac_require_cmd bash jq
ac_assert_file "$REPO_ROOT/tools/calibration-signatures.sh" \
  "tools/calibration-signatures.sh is missing"
ac_assert_file "$REPO_ROOT/tools/tape-model.sh" \
  "tools/tape-model.sh (#2059) is missing"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
SIG_TOOL="$REPO_ROOT/tools/calibration-signatures.sh"

# dev/backlog tape: p1 served by dsh/grok-4.7 (its last outcome is agent-loop;
# the earlier one must not count), p2 served by dsh/unsloth/Qwen3.8-27B
# (agent-loop), p3 with no run at all (needs-ops).
TAPE="$WORK/tape/tape.jsonl"
mkdir -p "$WORK/tape"
printf '%s\n' \
  '{"type":"proposal","t":"2026-02-01T00:00:00Z","id":"p1","loop":"dev","class":"backlog","context":{},"decision":"approved","ref":"2063-p1"}' \
  '{"type":"run","t":"2026-02-01T00:00:45Z","proposal_id":"p1","agent":"dsh/grok-4.7"}' \
  '{"type":"outcome","t":"2026-02-01T00:01:00Z","proposal_id":"p1","bits":{"merged":1},"signature":"old-sig","numbers":{},"children":{},"payloads":[]}' \
  '{"type":"outcome","t":"2026-02-01T00:02:00Z","proposal_id":"p1","bits":{"merged":1},"signature":"agent-loop","numbers":{},"children":{},"payloads":[]}' \
  '{"type":"proposal","t":"2026-02-01T00:00:00Z","id":"p2","loop":"dev","class":"backlog","context":{},"decision":"approved","ref":"2063-p2"}' \
  '{"type":"run","t":"2026-02-01T00:00:45Z","proposal_id":"p2","agent":"dsh/unsloth/Qwen3.8-27B"}' \
  '{"type":"outcome","t":"2026-02-01T00:03:00Z","proposal_id":"p2","bits":{"merged":1},"signature":"agent-loop","numbers":{},"children":{},"payloads":[]}' \
  '{"type":"proposal","t":"2026-02-01T00:00:00Z","id":"p3","loop":"dev","class":"backlog","context":{},"decision":"rejected","ref":"2063-p3"}' \
  '{"type":"outcome","t":"2026-02-01T00:04:00Z","proposal_id":"p3","bits":{},"signature":"needs-ops","numbers":{},"children":{},"payloads":[]}' \
  >"$TAPE"

# Two dev/backlog stuck samples (#2061): one names its model, one has none and
# lands on `-`. The stub refuses arguments.
STUB="$WORK/stuck_stub.sh"
printf '%s\n' \
  '#!/usr/bin/env bash' \
  '[ "$#" -eq 0 ] || { echo "stub: zero args expected, got $*" >&2; exit 1; }' \
  "printf '%s\n' '[{\"loop\":\"dev\",\"class\":\"backlog\",\"model\":\"unsloth/Qwen3.8-27B\"},{\"loop\":\"dev\",\"class\":\"backlog\"}]'" \
  >"$STUB"
chmod +x "$STUB"

# The ten-column calibration table of #2062, one row per model.
TABLE='| loop | class | model | n | promised | actual | error | mean duration_s | dur_promised | dur_error |
|---|---|---|---|---|---|---|---|---|---|
| dev | backlog | grok-4.7 | 1 | - | 100% | - | - | - | - |
| dev | backlog | unsloth/Qwen3.8-27B | 2 | - | 50% | - | - | - | - |
| dev | backlog | - | 2 | - | 100% | - | - | - | - |'

# run_sig <table> [model_tool]: the fixture TAPE_DIR and stuck stub are fixed;
# when a model tool is given it overrides the default tools/tape-model.sh.
run_sig() {
  local table="$1" model="${2:-$REPO_ROOT/tools/tape-model.sh}"
  RC=0
  OUT=""
  ERR=""
  TAPE_DIR="$WORK/tape" TAPE_STUCK_TOOL="$STUB" TAPE_MODEL_TOOL="$model" \
    bash "$SIG_TOOL" <<<"$table" >"$WORK/stdout.txt" 2>"$WORK/stderr.txt" || RC=$?
  OUT="$(cat "$WORK/stdout.txt" 2>/dev/null || true)"
  ERR="$(cat "$WORK/stderr.txt" 2>/dev/null || true)"
}

# ── AC 1: labels are counted per (loop, class, model) ─────────────────────────
ac_log "AC 1: each model row of dev/backlog gets its own signatures"
run_sig "$TABLE"
ac_assert_eq "$RC" "0" "AC 1: must exit 0 (rc=$RC) [stderr: $ERR]"
[ -z "$ERR" ] || ac_fail "AC 1: a clean run must not print stderr (got: $ERR)"
WANT='| loop | class | model | n | promised | actual | error | mean duration_s | dur_promised | dur_error | top signatures |
|---|---|---|---|---|---|---|---|---|---|---|
| dev | backlog | grok-4.7 | 1 | - | 100% | - | - | - | - | agent-loop:1 |
| dev | backlog | unsloth/Qwen3.8-27B | 2 | - | 50% | - | - | - | - | agent-loop:1, stuck:1 |
| dev | backlog | - | 2 | - | 100% | - | - | - | - | needs-ops:1, stuck:1 |'
ac_assert_eq "$OUT" "$WANT" "AC 1: appended table mismatch (got '$OUT')"
for row_suffix in \
  '| agent-loop:1 |' \
  '| agent-loop:1, stuck:1 |' \
  '| needs-ops:1, stuck:1 |'
do
  case "$OUT" in
    *"$row_suffix"*) ;;
    *) ac_fail "AC 1: a model row must end '$row_suffix' (got: $OUT)" ;;
  esac
done
ac_log "AC 1 OK: the model rows carry their own labels, stuck joins its own model"

# ── AC 2: a failing or wrong-shaped model tool refuses ────────────────────────
BUST_MODEL="$WORK/model_bust.sh"
printf '%s\n' '#!/usr/bin/env bash' 'exit 1' >"$BUST_MODEL"
chmod +x "$BUST_MODEL"

ac_log "AC 2: TAPE_MODEL_TOOL exits 1 -> rc 1, empty stdout, one calibration-signatures: line"
run_sig "$TABLE" "$BUST_MODEL"
ac_assert_eq "$RC" "1" "AC 2: a failing model tool must exit 1 (rc=$RC)"
ac_assert_eq "$OUT" "" "AC 2: a failing model tool must write nothing (got '$OUT')"
printf '%s\n' "$ERR" | grep -qF 'calibration-signatures:' \
  || ac_fail "AC 2: stderr must name the failure with a calibration-signatures: line (got: $ERR)"
sig_lines="$(printf '%s\n' "$ERR" | grep -c 'calibration-signatures:' || true)"
ac_assert_eq "$sig_lines" "1" "AC 2: exactly one calibration-signatures: line (got: $ERR)"

ARRAY_MODEL="$WORK/model_array.sh"
printf '%s\n' '#!/usr/bin/env bash' "printf '%s' '[]'" >"$ARRAY_MODEL"
chmod +x "$ARRAY_MODEL"

ac_log "AC 2: a model tool printing a JSON array is refused"
run_sig "$TABLE" "$ARRAY_MODEL"
ac_assert_eq "$RC" "1" "AC 2: a non-object model tool must exit 1 (rc=$RC)"
ac_assert_eq "$OUT" "" "AC 2: a non-object model tool must write nothing (got '$OUT')"
printf '%s\n' "$ERR" | grep -qF 'calibration-signatures:' \
  || ac_fail "AC 2: stderr must name the model-tool failure (got: $ERR)"
ac_log "AC 2 OK: model-tool failure exits 1 and writes nothing"

# ── AC 3: lint, executable bit, and the #1651 regression test ──────────────────
ac_log "AC 3: bash -n tools/calibration-signatures.sh"
bash -n "$REPO_ROOT/tools/calibration-signatures.sh" \
  || ac_fail "AC 3: bash -n failed on tools/calibration-signatures.sh"
[ -x "$SIG_TOOL" ] \
  || ac_fail "AC 3: tools/calibration-signatures.sh must be executable"

ac_log "AC 3: tests/acceptance/issue-1651.sh"
ac1651_rc=0
ac1651_out="$(bash "$REPO_ROOT/tests/acceptance/issue-1651.sh" 2>&1)" || ac1651_rc=$?
ac_assert_eq "$ac1651_rc" "0" \
  "AC 3: tests/acceptance/issue-1651.sh must pass (rc=$ac1651_rc): $ac1651_out"
ac_log "AC 3 OK: syntax, executable bit, and the #1651 fixture pass on the three-cell keys"

ac_pass "issue #2063: top signatures are counted per (loop, class, model)"
