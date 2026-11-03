#!/usr/bin/env bash
# =============================================================================
# tests/acceptance/issue-2036.sh
#
# Issue #2036: feat(tools): sprint-grades.sh writes a sprint's grade from the
# effect scale.
#
# Contract under test (tools/sprint-grades.sh, wired into the gardener after
# sprint-outcomes.sh): for each sprint id file ${TAPE_DIR}/sprints/<N> (integer
# N, numeric order), holding the sprint's proposal id:
#   * skip if the tape has no outcome for the id, or already a grade for it
#     with who == "effect-scale" (a rerun appends nothing).
#   * description from forge_api GET "/milestones/<N>"; unreadable: log, skip.
#   * level via sprint_level (#2029); rc 1 logs "sprint N: unknown level —
#     not graded" and skips. effect via sprint_field.
#   * met = bits.effect of the id's last outcome in tape order (1/true -> 1).
#   * state = SPRINT_HELD_TOOL <id> (default tools/sprint-held.sh, #2030).
#   * grade: broke -> -1; effect none/missing -> sprint_level_value(state);
#     else met 1 -> sprint_level_value(level), met 0 -> sprint_level_value(state).
#   * tape_grade <id> <value> at_outcome effect-scale, then the log line
#     "sprint N: graded <value> (<level>, met <met>, <state>)".
# While ${TAPE_DIR}/sprints/HOLD exists nothing is appended.
#
# Acceptance (hermetic — no network, stubbed forge_api and SPRINT_HELD_TOOL,
# temp TAPE_DIR):
#   * AC1 reachable/probe met/held -> one grade {"value":0.75,"when":
#     "at_outcome","who":"effect-scale"}.
#   * AC2 met 0 held -> 0.25; met 0 none -> 0; broke with effect 1 -> -1.
#   * AC3 no level line, effect none: held -> 0.25; none -> 0.
#   * AC4 rerun appends nothing; an id already holding an effect-scale grade
#     is skipped; a proposal with no outcome is skipped; HOLD -> nothing.
#   * AC5 an unknown level word is skipped with the exact log line.
#   * AC6 gardener-run.sh calls the tool after sprint-outcomes.sh and before
#     tape-rejections.sh, with the fetch and SPRINT_HELD_REF; bash -n passes;
#     the tool is executable.
#
# Run via: tools/run-acceptance.sh 2036
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=../../tests/lib/acceptance-helpers.sh
source "$REPO_ROOT/tests/lib/acceptance-helpers.sh"
# shellcheck source=../../tests/lib/forge-stub.sh
source "$REPO_ROOT/tests/lib/forge-stub.sh"

ac_require_cmd bash jq date mktemp sort grep
ac_assert_file "$REPO_ROOT/tools/sprint-grades.sh" "tools/sprint-grades.sh is missing"
ac_assert_file "$REPO_ROOT/lib/tape.sh" "lib/tape.sh is missing"
ac_assert_file "$REPO_ROOT/lib/sprint-block.sh" "lib/sprint-block.sh is missing"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
STUB_BIN="$WORK/bin"
FIXTURES="$WORK/fixtures"
CALLS="$WORK/calls"
mkdir -p "$STUB_BIN" "$FIXTURES"
: >"$CALLS"

# forge_api stub + write_milestone come from tests/lib/forge-stub.sh.
stub_milestone_forge_api

# The held-state seam (#2030): a stub sprint-held that prints $HELD_STATE.
cat >"$STUB_BIN/held-stub" <<'HELD_STUB'
#!/usr/bin/env bash
# sprint-held stub for issue-2036: echoes the state named by HELD_STATE.
if [ -z "${HELD_STATE:-}" ]; then
  exit 1
fi
printf '%s\n' "$HELD_STATE"
HELD_STUB
chmod +x "$STUB_BIN/held-stub"

# Milestones 1 and 2 carry a sprint block; 3 is forced unreadable below;
# 4 has a level word the scale refuses.
write_milestone 1 open 1 0 "class: internal
level: reachable
effect: probes/p.sh
expect: >= 1
soak: 7d"
write_milestone 2 open 1 0 "class: internal
effect: none
soak: 7d"
write_milestone 3 open 1 0 "class: internal
level: reachable
effect: probes/p.sh
soak: 7d"
write_milestone 4 open 1 0 "class: internal
level: broke
effect: probes/p.sh
soak: 7d"

# seed_sprint DIR N PID EFFECT — a sprint id file, the sprint proposal, and
# one outcome whose bits.effect is EFFECT.
seed_sprint() {
  local dir="$1" n="$2" pid="$3" effect="$4"
  mkdir -p "$dir/sprints"
  : >"$dir/tape.jsonl"
  printf '%s\n' "$pid" >"$dir/sprints/${n}"
  jq -cn --arg pid "$pid" \
    '{type:"proposal",t:"2026-11-05T00:00:00Z",id:$pid,loop:"sprint",
      class:"internal",context:{},decision:"approved",ref:"milestone:1"}' \
    >>"$dir/tape.jsonl"
  jq -cn --arg pid "$pid" --argjson effect "$effect" \
    '{type:"outcome",t:"2026-11-05T01:00:00Z",proposal_id:$pid,
      bits:{effect:$effect},numbers:{},children:{},payloads:[]}' \
    >>"$dir/tape.jsonl"
}

# run_grades DIR STATE — run the tool with the stub forge_api and held tool.
# RC/OUT/ERR globals receive status, stdout, stderr.
run_grades() {
  local dir="$1" state="$2"
  RC=0 OUT="" ERR=""
  # shellcheck disable=SC2034  # RC/OUT/ERR consumed by the assertions below
  OUT="$(PATH="$STUB_BIN:$PATH" TAPE_DIR="$dir" \
    FORGE_CALLS="$CALLS" FORGE_FIXTURES="$FIXTURES" \
    SPRINT_HELD_TOOL="$STUB_BIN/held-stub" HELD_STATE="$state" \
    bash "$REPO_ROOT/tools/sprint-grades.sh" 2>"$WORK/err")" || RC=$?
  ERR="$(cat "$WORK/err" 2>/dev/null || true)"
}

# grade_count DIR PID — number of grade records for PID on the tape.
grade_count() {
  jq -sR --arg pid "$2" '
    [ split("\n")[] | (try fromjson catch null) | select(type == "object") ]
    | [ .[] | select(.type == "grade" and .proposal_id == $pid) ] | length' \
    "$1/tape.jsonl"
}

# grade_record DIR PID — the (first) grade record for PID, as JSON.
grade_record() {
  jq -sR --arg pid "$2" '
    [ split("\n")[] | (try fromjson catch null) | select(type == "object") ]
    | [ .[] | select(.type == "grade" and .proposal_id == $pid) ] | first' \
    "$1/tape.jsonl"
}

# expect_grade DIR PID VALUE — run once, expect rc 0 and exactly one grade
# whose value is VALUE.
expect_grade() {
  local dir="$1" pid="$2" value="$3" state="$4"
  run_grades "$dir" "$state"
  ac_assert_eq "$RC" "0" "sprint-grades must exit 0 (got $RC): $OUT / $ERR"
  ac_assert_eq "$(grade_count "$dir" "$pid")" "1" \
    "exactly one effect-scale grade expected for $pid, got: $(cat "$dir/tape.jsonl")"
  ac_assert_jq ".value == $value" "$(grade_record "$dir" "$pid")" \
    "grade for $pid must have value $value (state $state)"
  case "$OUT" in
    *"graded $value"*) ;;
    *) ac_fail "run must log the graded value $value, got: $OUT" ;;
  esac
}

# ── AC1: reachable level, probe met, merges held -> 0.75 at_outcome ─────────
ac_log "AC1: level reachable, effect met, held -> 0.75"
D="$WORK/ac1"; seed_sprint "$D" 1 p1 1
expect_grade "$D" p1 0.75 held
ac_assert_jq '.when == "at_outcome" and .who == "effect-scale"' \
  "$(grade_record "$D" p1)" "the grade must be at_outcome by effect-scale"

# ── AC2: met 0 reads the state; broke overrides regardless ───────────────────
ac_log "AC2a: met 0, held -> 0.25"
D="$WORK/ac2a"; seed_sprint "$D" 1 p2a 0
expect_grade "$D" p2a 0.25 held

ac_log "AC2b: met 0, none -> 0"
D="$WORK/ac2b"; seed_sprint "$D" 1 p2b 0
expect_grade "$D" p2b 0 none

ac_log "AC2c: broke state, effect met 1 -> -1"
D="$WORK/ac2c"; seed_sprint "$D" 1 p2c 1
expect_grade "$D" p2c -1 broke

# ── AC3: effect none reads only whether the merges held ──────────────────────
ac_log "AC3a: no level line, effect none, held -> 0.25"
D="$WORK/ac3a"; seed_sprint "$D" 2 p3a 0
expect_grade "$D" p3a 0.25 held

ac_log "AC3b: effect none, none -> 0"
D="$WORK/ac3b"; seed_sprint "$D" 2 p3b 1
expect_grade "$D" p3b 0 none

# ── AC4: idempotence, skips, and the hold ────────────────────────────────────
ac_log "AC4a: a rerun appends nothing"
D="$WORK/ac1"
run_grades "$D" held
ac_assert_eq "$RC" "0" "rerun must exit 0 (got $RC): $OUT / $ERR"
ac_assert_eq "$(grade_count "$D" p1)" "1" "a rerun must not append a second grade"

ac_log "AC4b: a pid with an effect-scale grade already is skipped"
D="$WORK/ac4b"; seed_sprint "$D" 1 p4b 1
jq -cn --arg pid p4b \
  '{type:"grade",t:"2026-11-05T02:00:00Z",proposal_id:$pid,value:0.5,
    when:"at_outcome",who:"effect-scale"}' >>"$D/tape.jsonl"
run_grades "$D" held
ac_assert_eq "$RC" "0" "skip of a graded sprint must exit 0 (got $RC)"
ac_assert_eq "$(grade_count "$D" p4b)" "1" "the existing grade must not be duplicated"

ac_log "AC4c: a proposal with no outcome is skipped"
D="$WORK/ac4c"; mkdir -p "$D/sprints"
: >"$D/tape.jsonl"
printf '%s\n' p4c >"$D/sprints/1"
jq -cn --arg pid p4c \
  '{type:"proposal",t:"2026-11-05T00:00:00Z",id:$pid,loop:"sprint",
    class:"internal",context:{},decision:"approved",ref:"milestone:1"}' \
  >>"$D/tape.jsonl"
run_grades "$D" held
ac_assert_eq "$RC" "0" "the no-outcome skip must exit 0 (got $RC)"
ac_assert_eq "$(grade_count "$D" p4c)" "0" "no outcome means no grade"

ac_log "AC4d: HOLD present -> nothing appended"
D="$WORK/ac4d"; seed_sprint "$D" 1 p4d 1
: >"$D/sprints/HOLD"
run_grades "$D" held
ac_assert_eq "$RC" "0" "the hold path must exit 0 (got $RC)"
ac_assert_eq "$(grade_count "$D" p4d)" "0" "the hold must append no grade"

ac_log "AC4e: an unreadable milestone is skipped, rc 0"
FAILS="$WORK/fail"
mkdir -p "$FAILS"
: >"$FAILS/3"
D="$WORK/ac4e"; seed_sprint "$D" 3 p3 1
RC=0 OUT="" ERR=""
# shellcheck disable=SC2034
OUT="$(PATH="$STUB_BIN:$PATH" TAPE_DIR="$D" FORGE_FAIL_DIR="$FAILS" \
  FORGE_CALLS="$CALLS" FORGE_FIXTURES="$FIXTURES" \
  SPRINT_HELD_TOOL="$STUB_BIN/held-stub" HELD_STATE=held \
  bash "$REPO_ROOT/tools/sprint-grades.sh")" || RC=$?
ac_assert_eq "$RC" "0" "an unreadable milestone must not fail the run (got $RC)"
ac_assert_eq "$(grade_count "$D" p3)" "0" "an unreadable milestone appends no grade"

# ── AC5: an unknown level word is skipped with the exact log line ────────────
ac_log "AC5: level: broke logs the unknown-level line and appends nothing"
D="$WORK/ac5"; seed_sprint "$D" 4 p5 1
run_grades "$D" held
ac_assert_eq "$RC" "0" "the unknown-level skip must exit 0 (got $RC)"
ac_assert_eq "$(grade_count "$D" p5)" "0" "an unknown level must not be graded"
case "$OUT" in
  *"sprint 4: unknown level — not graded"*) ;;
  *) ac_fail "unknown level must log the exact line, got: $OUT" ;;
esac

# ── AC6: the gardener wiring ─────────────────────────────────────────────────
ac_log "AC6: gardener-run.sh runs sprint-grades.sh between outcomes and rejections"
GARDENER="$REPO_ROOT/gardener/gardener-run.sh"
ac_assert_file "$GARDENER" "gardener/gardener-run.sh is missing"
grades_line="$(grep -n 'sprint-grades\.sh' "$GARDENER" | head -n 1 | cut -d: -f1)"
outcomes_line="$(grep -n 'sprint-outcomes\.sh' "$GARDENER" | head -n 1 | cut -d: -f1)"
rejections_line="$(grep -n 'tape-rejections\.sh' "$GARDENER" | head -n 1 | cut -d: -f1)"
[ -n "$grades_line" ] || ac_fail "gardener-run.sh must invoke tools/sprint-grades.sh"
[ -n "$outcomes_line" ] || ac_fail "gardener-run.sh must invoke tools/sprint-outcomes.sh"
[ -n "$rejections_line" ] || ac_fail "gardener-run.sh must invoke tools/tape-rejections.sh"
[ "$outcomes_line" -lt "$grades_line" ] \
  || ac_fail "sprint-grades.sh must run after sprint-outcomes.sh (lines $outcomes_line vs $grades_line)"
[ "$grades_line" -lt "$rejections_line" ] \
  || ac_fail "sprint-grades.sh must run before tape-rejections.sh (lines $grades_line vs $rejections_line)"
# The greps are literal: the ${...} text must match gardener-run.sh verbatim.
# shellcheck disable=SC2016
grep -Fq 'fetch "${FORGE_REMOTE}" "$PRIMARY_BRANCH" --quiet' "$GARDENER" \
  || ac_fail "gardener-run.sh must fetch the primary branch before grading"
grep -Fq 'SPRINT_HELD_REF="${FORGE_REMOTE}/${PRIMARY_BRANCH}"' "$GARDENER" \
  || ac_fail "the sprint-grades call must set SPRINT_HELD_REF to the fetched ref"

bash -n "$REPO_ROOT/tools/sprint-grades.sh" \
  || ac_fail "tools/sprint-grades.sh must parse"
bash -n "$GARDENER" || ac_fail "gardener/gardener-run.sh must parse"
[ -x "$REPO_ROOT/tools/sprint-grades.sh" ] \
  || ac_fail "tools/sprint-grades.sh must be executable (#1748)"

ac_pass
