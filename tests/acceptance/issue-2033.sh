#!/usr/bin/env bash
# =============================================================================
# tests/acceptance/issue-2033.sh
#
# Issue #2033: feat(tools): calibration-purpose reads the owner's grade over
# effect-scale.
#
# Contract under test (tools/calibration-purpose.sh, #1652): once code writes
# a grade for every scored sprint (`who: effect-scale`, #2036), an owner grade
# written earlier would be shadowed by the later code grade. So the reading of
# an eligible proposal is the value of its last grade whose `who` is not
# `effect-scale`, and only when it carries no such grade does it read its last
# grade at all. A null or non-numeric reading still counts 0 and does not
# increment g. Cell format, eligibility and every other column are unchanged.
#
# Acceptance (hermetic — no network, fixture tape, graded pack `sprint = 48`,
# fixed CALIBRATION_NOW, every outcome older than the grace):
#   AC1 p1: effect-scale 0.75 then disinto-admin 0.5 -> reads 0.5.
#   AC2 p2: disinto-admin 0.5 then effect-scale 0.75 -> reads 0.5.
#   AC3 p3: effect-scale 0.25 only -> reads 0.25.
#   AC4 p4: no grade -> 0, g not incremented.
#   AC5 p5: disinto-admin null then effect-scale 1.0 -> reads 0.
#   AC6 all five in sprint/internal: the cell is `0.25 (3/5)`, the other
#       columns byte-for-byte.
#   AC7 a non-numeric owner grade shadows the code grade (reads 0, g 0).
#   AC8 the last owner grade wins over an earlier one.
#   AC9 gardener/AGENTS.md keeps the #1652 sentence and adds the owner-over-
#       code sentence right after it; bash -n passes; the tool is executable.
#
# Run via: tools/run-acceptance.sh 2033
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=../../tests/lib/acceptance-helpers.sh
source "$REPO_ROOT/tests/lib/acceptance-helpers.sh"

ac_require_cmd bash jq python3
TOOL="$REPO_ROOT/tools/calibration-purpose.sh"
ac_assert_file "$TOOL" "tools/calibration-purpose.sh is missing"
ac_assert_file "$REPO_ROOT/gardener/AGENTS.md" "gardener/AGENTS.md is missing"

# The rule must live in the tool, not just in its header.
grep -Fq 'who != "effect-scale"' "$TOOL" \
  || ac_fail "calibration-purpose.sh must read the owner's grade over effect-scale (#2033)"

DOC_SENTENCE='Then through `tools/calibration-purpose.sh` (#1652), which appends a `purpose` column from grades.'
OWNER_SENTENCE='When a proposal carries grades by both, the owner'"'"'s (any `who` but `effect-scale`) is read over the code'"'"'s (#2033).'
AGENTS_FLAT="$(tr '\n' ' ' < "$REPO_ROOT/gardener/AGENTS.md" | tr -s ' ')"
printf '%s\n' "$AGENTS_FLAT" | grep -qF "$DOC_SENTENCE" \
  || ac_fail "gardener/AGENTS.md must keep the #1652 purpose sentence verbatim"
printf '%s\n' "$AGENTS_FLAT" | grep -qF "$DOC_SENTENCE $OWNER_SENTENCE" \
  || ac_fail "gardener/AGENTS.md must add the owner-over-code sentence (#2033) directly after the #1652 one (got: $AGENTS_FLAT)"
ac_log "docs OK: the owner grade is read over the code's, right after the #1652 sentence"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# Clock 2026-06-03T00:00:00Z, grace 48h: an outcome at 2026-06-01T00:00:00Z is
# exactly at the grace and so eligible. Every fixture outcome is that old.
NOW="2026-06-03T00:00:00Z"
PACK="$WORK/graded.toml"
printf '%s\n' 'sprint = 48' >"$PACK"

ONE_ROW='| loop | class | n | promised | actual | error | mean duration_s | dur_promised | dur_error | top signatures |
|---|---|---|---|---|---|---|---|---|---|
| sprint | internal | 1 | - | 0% | - | - | - | - | world:1 |'

FIVE_ROWS='| loop | class | n | promised | actual | error | mean duration_s | dur_promised | dur_error | top signatures |
|---|---|---|---|---|---|---|---|---|---|
| sprint | internal | 5 | 20% | 40% | 20 | 2.0 | 3.0 | 1.0 | stuck:2 |
| dev | backlog | 4 | 40% | 50% | 10 | 8.0 | 9.0 | 1.0 | agent-loop:2 |'

# seed_tape DIR ID GRADE_LINES... — one sprint/internal proposal with an aged
# outcome, then the given grade lines verbatim.
seed_tape() {
  local dir="$1" pid="$2"
  shift 2
  mkdir -p "$dir"
  {
    printf '{"type":"proposal","t":"2026-05-01T00:00:00Z","id":"%s","loop":"sprint","class":"internal","context":{},"decision":"approved","ref":"milestone:1"}\n' "$pid"
    printf '{"type":"outcome","t":"2026-06-01T00:00:00Z","proposal_id":"%s","bits":{"effect":1},"numbers":{},"children":{},"payloads":[]}\n' "$pid"
    printf '%s\n' "$@"
  } >"$dir/tape.jsonl"
}

# run_purpose DIR TABLE — run the tool against tape dir DIR with the fixed
# pack/clock; RC/OUT/ERR globals receive status, stdout, stderr.
run_purpose() {
  local dir="$1" table="$2" errf
  errf="$WORK/err.txt"
  RC=0
  OUT="$(CALIBRATION_GRADED_FILE="$PACK" TAPE_DIR="$dir" CALIBRATION_NOW="$NOW" \
    bash "$TOOL" <<<"$table" 2>"$errf")" || RC=$?
  ERR="$(cat "$errf" 2>/dev/null || true)"
}

# cell_after DIR TABLE CELL — the purpose cell must be exactly CELL.
cell_after() {
  local dir="$1" table="$2" want="$3"
  run_purpose "$dir" "$table"
  ac_assert_eq "$RC" "0" "the tool must exit 0 (got $RC) [stderr: $ERR]"
  [ -z "$ERR" ] || ac_fail "a clean tape must print no stderr (got: $ERR)"
  case "$OUT" in
    *"$want"*) ;;
    *) ac_fail "the purpose cell must be '$want', got: $OUT" ;;
  esac
}

ac_log "AC1: an owner grade after the code grade reads the owner's 0.5"
seed_tape "$WORK/p1" p1 \
  '{"type":"grade","t":"2026-06-01T01:00:00Z","proposal_id":"p1","value":0.75,"when":"at_outcome","who":"effect-scale"}' \
  '{"type":"grade","t":"2026-06-01T02:00:00Z","proposal_id":"p1","value":0.5,"when":"at_outcome","who":"disinto-admin"}'
cell_after "$WORK/p1" "$ONE_ROW" '| 0.50 (1/1) |'

ac_log "AC2: an owner grade before the code grade still reads 0.5"
seed_tape "$WORK/p2" p2 \
  '{"type":"grade","t":"2026-06-01T01:00:00Z","proposal_id":"p2","value":0.5,"when":"at_outcome","who":"disinto-admin"}' \
  '{"type":"grade","t":"2026-06-01T03:00:00Z","proposal_id":"p2","value":0.75,"when":"at_outcome","who":"effect-scale"}'
cell_after "$WORK/p2" "$ONE_ROW" '| 0.50 (1/1) |'

ac_log "AC3: a proposal graded only by the code reads the code's 0.25"
seed_tape "$WORK/p3" p3 \
  '{"type":"grade","t":"2026-06-01T01:00:00Z","proposal_id":"p3","value":0.25,"when":"at_outcome","who":"effect-scale"}'
cell_after "$WORK/p3" "$ONE_ROW" '| 0.25 (1/1) |'

ac_log "AC4: no grade at all reads 0 and does not increment g"
seed_tape "$WORK/p4" p4
cell_after "$WORK/p4" "$ONE_ROW" '| 0.00 (0/1) |'

ac_log "AC5: a null owner grade is the reading, so the code grade is shadowed"
seed_tape "$WORK/p5" p5 \
  '{"type":"grade","t":"2026-06-01T01:00:00Z","proposal_id":"p5","value":null,"when":"at_outcome","who":"disinto-admin"}' \
  '{"type":"grade","t":"2026-06-01T02:00:00Z","proposal_id":"p5","value":1.0,"when":"at_outcome","who":"effect-scale"}'
cell_after "$WORK/p5" "$ONE_ROW" '| 0.00 (0/1) |'

ac_log "AC6: five eligible sprint/internal proposals give 0.25 (3/5), other columns untouched"
TAPE="$WORK/all/tape.jsonl"
mkdir -p "$WORK/all"
: >"$TAPE"
for pid in p1 p2 p3 p4 p5; do
  cat "$WORK/$pid/tape.jsonl" >>"$TAPE"
done
run_purpose "$WORK/all" "$FIVE_ROWS"
ac_assert_eq "$RC" "0" "the merged fixture must exit 0 (got $RC) [stderr: $ERR]"
WANT='| loop | class | n | promised | actual | error | mean duration_s | dur_promised | dur_error | top signatures | purpose |
|---|---|---|---|---|---|---|---|---|---|---|
| sprint | internal | 5 | 20% | 40% | 20 | 2.0 | 3.0 | 1.0 | stuck:2 | 0.25 (3/5) |
| dev | backlog | 4 | 40% | 50% | 10 | 8.0 | 9.0 | 1.0 | agent-loop:2 | - |'
ac_assert_eq "$OUT" "$WANT" "the appended table must match byte-for-byte (got: $OUT)"
ac_log "AC6 OK: 1.25 over five eligible, three numeric readings"

ac_log "AC7: a non-numeric owner grade shadows the code grade, counting 0 and not g"
seed_tape "$WORK/p7" p7 \
  '{"type":"grade","t":"2026-06-01T01:00:00Z","proposal_id":"p7","value":"high","when":"at_outcome","who":"disinto-admin"}' \
  '{"type":"grade","t":"2026-06-01T02:00:00Z","proposal_id":"p7","value":1.0,"when":"at_outcome","who":"effect-scale"}'
cell_after "$WORK/p7" "$ONE_ROW" '| 0.00 (0/1) |'

ac_log "AC8: the last owner grade wins over an earlier owner grade"
seed_tape "$WORK/p8" p8 \
  '{"type":"grade","t":"2026-06-01T01:00:00Z","proposal_id":"p8","value":0.2,"when":"at_outcome","who":"disinto-admin"}' \
  '{"type":"grade","t":"2026-06-01T02:00:00Z","proposal_id":"p8","value":0.75,"when":"at_outcome","who":"effect-scale"}' \
  '{"type":"grade","t":"2026-06-01T03:00:00Z","proposal_id":"p8","value":0.6,"when":"at_outcome","who":"disinto-admin"}'
cell_after "$WORK/p8" "$ONE_ROW" '| 0.60 (1/1) |'

bash -n "$TOOL" || ac_fail "tools/calibration-purpose.sh must parse"
bash -n "$SCRIPT_DIR/issue-2033.sh" || ac_fail "this acceptance test must parse"
[ -x "$TOOL" ] || ac_fail "tools/calibration-purpose.sh must be executable (#1748)"

ac_pass "issue #2033: calibration-purpose reads the owner's grade over effect-scale"
