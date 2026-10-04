#!/usr/bin/env bash
# =============================================================================
# tests/acceptance/issue-1676.sh
#
# Issue #1676: feat(gardener): write the sprint outcome from its effect probe.
#
# Contract under test (tools/sprint-outcomes.sh, driven by the gardener):
#   For each due sprint (tools/sprint-due.sh line `<N><TAB><sprint id>`):
#     * description: forge_api GET "/milestones/<N>", field `description`.
#     * effect, expect: sprint_field (lib/sprint-block.sh, #1629).
#     * children: tools/sprint-children.sh <sprint id> (#1674).
#     * effect a path -> probe_value "<effect>" (#1673); non-zero: one log
#       line, no outcome this run; then sprint_expect_met: rc0 -> met 1, rc1
#       -> met 0, rc2 -> one log line, no outcome.
#     * effect `none`/missing -> met 1 when n_failed is 0 else 0.
#     * tape_outcome with bits {"effect":<met>,"returned":0}; numbers:
#       effect_value (when a probe ran) + duration_s; .done touched only after
#       the append succeeds.
#
# Acceptance (hermetic — no network, stubbed forge_api and tools/sprint-due.sh,
# fixture probes in a temp OPS_REPO_ROOT, temp TAPE_DIR):
#   * AC1 a due sprint whose probe prints 5, expect >= 3: one outcome with
#       effect: 1, effect_value: 5, and the child counts; <N>.done exists.
#   * AC2 the same with a probe printing 2: effect: 0.
#   * AC3 effect: none with one failed child: effect: 0.
#   * AC4 effect: ../x.sh: no outcome, no .done.
#   * AC5 a second run writes no second outcome.
#   * AC6 bash tests/acceptance/issue-1676.sh exits 0 and calls ac_pass.
#
# Run via: tools/run-acceptance.sh 1676
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=../../tests/lib/acceptance-helpers.sh
source "$REPO_ROOT/tests/lib/acceptance-helpers.sh"
# shellcheck source=../../tests/lib/forge-stub.sh
source "$REPO_ROOT/tests/lib/forge-stub.sh"

ac_require_cmd bash jq date sort mktemp cmp stat
ac_assert_file "$REPO_ROOT/tools/sprint-outcomes.sh" "tools/sprint-outcomes.sh is missing"
ac_assert_file "$REPO_ROOT/tools/sprint-due.sh" "tools/sprint-due.sh is missing"
ac_assert_file "$REPO_ROOT/tools/sprint-children.sh" "tools/sprint-children.sh is missing"
ac_assert_file "$REPO_ROOT/lib/probe.sh" "lib/probe.sh is missing"
ac_assert_file "$REPO_ROOT/lib/tape.sh" "lib/tape.sh is missing"

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

OPS_REPO_ROOT="$TMP_DIR/ops"
export OPS_REPO_ROOT
mkdir -p "$OPS_REPO_ROOT/probes"

STUB_BIN="$TMP_DIR/bin"
FIXTURES="$TMP_DIR/fixtures"
CALLS="$TMP_DIR/calls"
mkdir -p "$STUB_BIN" "$FIXTURES"
: >"$CALLS"

# forge_api stub + write_milestone come from tests/lib/forge-stub.sh.
stub_milestone_forge_api

# seed_tape TAPEDIR PARENT M1 M2 ... — one proposal per argument, plus a
# merged:1 outcome for each, so the sprint-children rollup is deterministic.
# A trailing "none" token means a child with no outcome at all.
seed_tape() {
  local dir="$1" parent="$2"
  shift 2
  : >"$dir/tape.jsonl"
  local i id role
  i=0
  for role in "$@"; do
    i=$((i+1))
    id="c${i}"
    jq -cn \
      --arg id "$id" --arg parent "$parent" \
      '{type:"proposal",t:"2026-02-10T00:00:00Z",id:$id,loop:"dev",
        class:"internal",parent:$parent,context:{},decision:"approved",
        ref:"x"}' >>"$dir/tape.jsonl"
    case "$role" in
      merged)
        jq -cn --arg id "$id" \
          '{type:"outcome",t:"2026-02-10T01:00:00Z",proposal_id:$id,
            bits:{merged:1},numbers:{},children:{},payloads:[]}' >>"$dir/tape.jsonl"
        ;;
      rejected)
        jq -cn --arg id "$id" \
          '{type:"outcome",t:"2026-02-10T01:00:00Z",proposal_id:$id,
            bits:{rejected:1},numbers:{},children:{},payloads:[]}' >>"$dir/tape.jsonl"
        ;;
      none)
        :
        ;;
      *) ac_fail "seed_tape: unknown role ${role}" ;;
    esac
  done
}

# run AC TAPEDIR — run the tool against one tape. out/err/rc land in globals.
run() {
  local dir="$1"
  RC=0
  OUT=""
  env -u FORGE_API -u FORGE_TOKEN \
    TAPE_DIR="$dir" \
    PATH="$STUB_BIN:${PATH}" \
    FORGE_CALLS="$CALLS" \
    FORGE_FIXTURES="$FIXTURES" \
    bash "$REPO_ROOT/tools/sprint-outcomes.sh" \
    >"$TMP_DIR/out" 2>"$TMP_DIR/err" || RC=$?
  OUT="$(cat "$TMP_DIR/out" 2>/dev/null || true)"
}

# outcome_of TAPEDIR PID — compact the tape's last outcome for PID (or empty).
outcome_of() {
  local dir="$1" pid="$2"
  jq -r -c 'select(.type == "outcome" and .proposal_id == $pid)' \
    --arg pid "$pid" \
    "$dir/tape.jsonl" 2>/dev/null | tail -n 1
}

# count_outcomes TAPEDIR PID — how many outcome records name PID.
count_outcomes() {
  local dir="$1" pid="$2"
  jq -c 'select(.type == "outcome" and .proposal_id == $pid)' \
    --arg pid "$pid" \
    "$dir/tape.jsonl" 2>/dev/null | grep -c . || true
}

# ── fixtures: probes (bash scripts whose last stdout line is a number) ──────
printf '%s\n' 'echo 5' >"$OPS_REPO_ROOT/probes/five.sh"
printf '%s\n' 'echo 2' >"$OPS_REPO_ROOT/probes/two.sh"

write_milestone 1 closed 0 1 "class: deploy
effect: probes/five.sh
expect: >= 3
soak: 0h"
write_milestone 2 closed 0 1 "class: deploy
effect: probes/two.sh
expect: >= 3
soak: 0h"
write_milestone 3 closed 0 1 "class: internal
effect: none
expect: >= 3
soak: 0h"
write_milestone 4 closed 0 1 "class: deploy
effect: ../x.sh
expect: >= 3
soak: 0h"
write_milestone 5 closed 0 1 "class: deploy
effect: probes/five.sh
expect: >= 3
soak: 0h"

# ── AC1: probe 5, expect >= 3 -> effect 1, effect_value 5, .done ────────────
ac_log "AC1: probe five (5 >= 3) -> effect 1, effect_value 5, child counts, .done"
TAPEDIR="$TMP_DIR/tape-ac1"; mkdir -p "$TAPEDIR/sprints"
printf '%s\n' "s-1" >"$TAPEDIR/sprints/1"
seed_tape "$TAPEDIR" s-1 merged rejected none
run "$TAPEDIR"
ac_assert_eq "$RC" "0" "AC1: tool must exit 0 (rc=$RC): $OUT"
out="$(outcome_of "$TAPEDIR" s-1)"
[ -n "$out" ] || ac_fail "AC1: no outcome for s-1"
ac_assert_eq "$(jq -r '.bits.effect' <<<"$out" 2>/dev/null)" "1" \
  "AC1: outcome effect must be 1 (got '$out')"
ac_assert_eq "$(jq -r '.numbers.effect_value' <<<"$out" 2>/dev/null)" "5" \
  "AC1: outcome numbers.effect_value must be 5 (got '$out')"
ac_assert_eq "$(jq -r '.numbers.duration_s | (type == "number")' <<<"$out" 2>/dev/null)" \
  "true" \
  "AC1: outcome numbers.duration_s must be a number (got '$out')"
ac_assert_eq "$(jq -r '.children.n_children' <<<"$out" 2>/dev/null)" "3" \
  "AC1: outcome children.n_children must be 3 (got '$out')"
ac_assert_eq "$(jq -r '.children.n_failed' <<<"$out" 2>/dev/null)" "1" \
  "AC1: outcome children.n_failed must be 1 (got '$out')"
[ -f "$TAPEDIR/sprints/1.done" ] || ac_fail "AC1: $TAPEDIR/sprints/1.done must exist"
ac_assert_eq "$RC" "0" "AC1: exit 0 after a successful outcome"

# ── AC2: probe 2, expect >= 3 -> effect 0 ───────────────────────────────────
ac_log "AC2: probe two (2 < 3) -> effect 0"
TAPEDIR="$TMP_DIR/tape-ac2"; mkdir -p "$TAPEDIR/sprints"
printf '%s\n' "s-2" >"$TAPEDIR/sprints/2"
seed_tape "$TAPEDIR" s-2 merged rejected none
run "$TAPEDIR"
ac_assert_eq "$RC" "0" "AC2: tool must exit 0 (rc=$RC): $OUT"
out="$(outcome_of "$TAPEDIR" s-2)"
[ -n "$out" ] || ac_fail "AC2: no outcome for s-2"
ac_assert_eq "$(jq -r '.bits.effect' <<<"$out" 2>/dev/null)" "0" \
  "AC2: outcome effect must be 0 (got '$out')"
ac_assert_eq "$(jq -r '.numbers.effect_value' <<<"$out" 2>/dev/null)" "2" \
  "AC2: outcome numbers.effect_value must be 2 (got '$out')"
[ -f "$TAPEDIR/sprints/2.done" ] || ac_fail "AC2: $TAPEDIR/sprints/2.done must exist"

# ── AC3: effect none, one failed child -> effect 0 ──────────────────────────
ac_log "AC3: effect none with one failed child -> effect 0"
TAPEDIR="$TMP_DIR/tape-ac3"; mkdir -p "$TAPEDIR/sprints"
printf '%s\n' "s-3" >"$TAPEDIR/sprints/3"
seed_tape "$TAPEDIR" s-3 none
run "$TAPEDIR"
ac_assert_eq "$RC" "0" "AC3: tool must exit 0 (rc=$RC): $OUT"
out="$(outcome_of "$TAPEDIR" s-3)"
[ -n "$out" ] || ac_fail "AC3: no outcome for s-3"
ac_assert_eq "$(jq -r '.bits.effect' <<<"$out" 2>/dev/null)" "0" \
  "AC3: outcome effect must be 0 (got '$out')"
ac_assert_eq "$(jq -r '.children.n_failed' <<<"$out" 2>/dev/null)" "1" \
  "AC3: outcome children.n_failed must be 1 (got '$out')"
ac_assert_eq "$(jq -r '.numbers | has("effect_value")' <<<"$out" 2>/dev/null)" "false" \
  "AC3: no probe ran, so numbers must not carry effect_value (got '$out')"
[ -f "$TAPEDIR/sprints/3.done" ] || ac_fail "AC3: $TAPEDIR/sprints/3.done must exist"

# ── AC4: effect ../x.sh -> no outcome, no .done ─────────────────────────────
ac_log "AC4: effect ../x.sh (bad path) -> no outcome, no .done"
TAPEDIR="$TMP_DIR/tape-ac4"; mkdir -p "$TAPEDIR/sprints"
printf '%s\n' "s-4" >"$TAPEDIR/sprints/4"
seed_tape "$TAPEDIR" s-4 merged
run "$TAPEDIR"
ac_assert_eq "$RC" "0" "AC4: tool must exit 0 (rc=$RC): $OUT"
out="$(outcome_of "$TAPEDIR" s-4)"
[ -z "$out" ] || ac_fail "AC4: no outcome expected, got '$out'"
[ ! -f "$TAPEDIR/sprints/4.done" ] || ac_fail "AC4: $TAPEDIR/sprints/4.done must NOT exist"
ac_assert_eq "$RC" "0" "AC4: a failed probe is not a tool failure (rc=$RC)"

# ── AC5: a second run writes no second outcome ──────────────────────────────
ac_log "AC5: a second run writes no second outcome for an already-done sprint"
TAPEDIR="$TMP_DIR/tape-ac5"; mkdir -p "$TAPEDIR/sprints"
printf '%s\n' "s-5" >"$TAPEDIR/sprints/5"
seed_tape "$TAPEDIR" s-5 merged
run "$TAPEDIR"
first_count="$(count_outcomes "$TAPEDIR" s-5)"
ac_assert_eq "$first_count" "1" \
  "AC5: first run writes exactly one outcome (got $first_count)"
[ -f "$TAPEDIR/sprints/5.done" ] || ac_fail "AC5: .done must exist after the first run"
# The second run must add no outcome: .done makes sprint-due.sh skip the sprint.
run "$TAPEDIR"
ac_assert_eq "$RC" "0" "AC5: second run must exit 0 (rc=$RC): $OUT"
second_count="$(count_outcomes "$TAPEDIR" s-5)"
ac_assert_eq "$second_count" "$first_count" \
  "AC5: a second run must write no second outcome (was $first_count, now $second_count)"

# ── AC6: the test itself must exit 0 and ac_pass ────────────────────────────
ac_pass "issue #1676: write the sprint outcome from its effect probe"
