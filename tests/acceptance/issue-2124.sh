#!/usr/bin/env bash
# =============================================================================
# tests/acceptance/issue-2124.sh
#
# Issue #2124: the ladder names update-self as rung 2.
#
# planner/ladder.sh orders the rungs sense, update-self, provision, reach,
# deploy, replicate; update-self matches the claim id can-update-self exactly.
# planner/gaps.sh excludes the rungs with
# ^can-(sense(-[a-z0-9-]+)?|update-self|provision|reach-porter|deploy-porter|
# replicate)$, so a challenged can-update-self is a ladder gap, not a
# `gaps:` line. planner/AGENTS.md names the six rungs.
#
# Acceptance:
#   AC1 empty claims dir            -> ladder_lowest_gap prints sense
#   AC2 held can-sense-machine only -> prints update-self
#   AC3 can-sense + can-update-self -> prints provision
#   AC4 all rungs present, can-update-self challenged -> prints update-self
#   AC5 planner_claim_gaps: challenged can-update-self prints nothing;
#       challenged can-fix-disk-pressure prints that id
#   AC6 issue-1975.sh and issue-2056.sh pass
#
# Hermetic: a temp CLAIMS_DIR and CLAIMS_CATALOG. No forge, no agent.
#
# Acceptance: `bash tests/acceptance/issue-2124.sh` exits 0 and calls ac_pass.
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=../../tests/lib/acceptance-helpers.sh
source "$REPO_ROOT/tests/lib/acceptance-helpers.sh"

ac_require_cmd bash grep mktemp
LADDER="$REPO_ROOT/planner/ladder.sh"
GAPS="$REPO_ROOT/planner/gaps.sh"
DOC="$REPO_ROOT/planner/AGENTS.md"
ac_assert_file "$LADDER" "planner/ladder.sh is missing"
ac_assert_file "$GAPS" "planner/gaps.sh is missing"
ac_assert_file "$DOC" "planner/AGENTS.md is missing"

ac_log "static: bash -n; ladder names update-self as rung 2; gaps excludes it"
bash -n "$LADDER"
bash -n "$GAPS"
grep -qE 'for rung in sense update-self provision reach deploy replicate' "$LADDER" \
  || ac_fail "planner/ladder.sh must order the rungs with update-self second"
grep -qF 'can-update-self' "$LADDER" \
  || ac_fail "planner/ladder.sh must match the claim id can-update-self"
grep -qF 'update-self|provision' "$GAPS" \
  || ac_fail "planner/gaps.sh must exclude update-self among the rungs"
grep -qF '(`sense`, `update-self`, `provision`, `reach`, `deploy`, `replicate`)' "$DOC" \
  || ac_fail "planner/AGENTS.md must name the six rungs in the ladder bullet"
if grep -E '^[[:space:]]*(source|\.)[[:space:]]' "$LADDER" | grep -q 'env.sh'; then
  ac_fail "planner/ladder.sh must not source lib/env.sh"
fi
if grep -E '^[[:space:]]*(source|\.)[[:space:]]' "$GAPS" | grep -q 'env.sh'; then
  ac_fail "planner/gaps.sh must not source lib/env.sh"
fi

T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT

CLAIMS_DIR="$T/claims"
CATALOG="$T/catalog/claims.md"
mkdir -p "$CLAIMS_DIR" "$(dirname "$CATALOG")"

add_claim() {
  printf 'statement = "x"\n' >"$CLAIMS_DIR/$1.toml"
}

write_catalog() {
  {
    printf '%s\n' '| claim | class | status | checks | last value | resting sprints | statement |'
    printf '%s\n' '|---|---|---|---|---|---|---|'
    if [ "$#" -gt 0 ]; then
      printf '%s\n' "$@"
    fi
  } >"$CATALOG"
}

# run_ladder — source planner/ladder.sh in a throwaway subshell and call
# ladder_lowest_gap. stdout -> $OUT, status -> $RC.
run_ladder() {
  RC=0 OUT=""
  (
    export CLAIMS_DIR CLAIMS_CATALOG="$CATALOG"
    unset OPS_REPO_ROOT || true
    # shellcheck disable=SC1091
    source "$LADDER"
    ladder_lowest_gap
  ) >"$T/out" 2>"$T/err" || RC=$?
  OUT="$(cat "$T/out" 2>/dev/null || true)"
}

run_gaps() {
  RC=0 OUT=""
  (
    export CLAIMS_DIR CLAIMS_CATALOG="$CATALOG"
    unset OPS_REPO_ROOT || true
    # shellcheck disable=SC1091
    source "$GAPS"
    planner_claim_gaps
  ) >"$T/out" 2>"$T/err" || RC=$?
  OUT="$(cat "$T/out" 2>/dev/null || true)"
}

# ── AC1: empty claims dir prints sense ───────────────────────────────────────
ac_log "AC1: empty claims dir prints sense"
write_catalog
run_ladder
ac_assert_eq "$OUT" "sense" "empty claims dir must print sense (got '$OUT')"
ac_assert_eq "$RC" "0" "empty claims dir must return 0 (rc=$RC)"

# ── AC2: only a held can-sense-machine prints update-self ────────────────────
ac_log "AC2: only a held can-sense-machine prints update-self"
add_claim can-sense-machine
write_catalog \
  '| can-sense-machine | internal | held | 1 | 1 | - | the box sees the host |'
run_ladder
ac_assert_eq "$OUT" "update-self" \
  "held can-sense-machine only must print update-self (got '$OUT')"
ac_assert_eq "$RC" "0" "rung 2 gap must return 0 (rc=$RC)"

# ── AC3: can-sense and can-update-self held prints provision ─────────────────
ac_log "AC3: can-sense and can-update-self held prints provision"
add_claim can-sense
add_claim can-update-self
write_catalog \
  '| can-sense | internal | held | 1 | 1 | - | sense |' \
  '| can-update-self | internal | held | 1 | 1 | - | the canary runs new versions |'
run_ladder
ac_assert_eq "$OUT" "provision" \
  "rungs 1 and 2 held must print provision (got '$OUT')"
ac_assert_eq "$RC" "0" "rung 3 gap must return 0 (rc=$RC)"

# ── AC4: every rung present, can-update-self challenged prints update-self ───
ac_log "AC4: all rungs present, can-update-self challenged prints update-self"
add_claim can-provision
add_claim can-reach-porter
add_claim can-deploy-porter
add_claim can-replicate
write_catalog \
  '| can-sense | internal | held | 1 | 1 | - | sense |' \
  '| can-update-self | internal | challenged | 1 | 0 | - | the canary broke |' \
  '| can-provision | internal | held | 1 | 1 | - | provision |' \
  '| can-reach-porter | internal | held | 1 | 1 | - | reach |' \
  '| can-deploy-porter | internal | held | 1 | 1 | - | deploy |' \
  '| can-replicate | internal | held | 1 | 1 | - | replicate |'
run_ladder
ac_assert_eq "$OUT" "update-self" \
  "challenged can-update-self must print update-self (got '$OUT')"
ac_assert_eq "$RC" "0" "challenged rung 2 must return 0 (rc=$RC)"

# ── AC5: gaps.sh — update-self is a rung, not a gap ──────────────────────────
ac_log "AC5a: challenged can-update-self is not a gaps line"
run_gaps
ac_assert_eq "$OUT" "" \
  "a challenged can-update-self is a ladder rung and must not print as a gap (got '$OUT')"
ac_assert_eq "$RC" "0" "planner_claim_gaps must return 0 (rc=$RC)"

ac_log "AC5b: challenged can-fix-disk-pressure prints that id"
add_claim can-fix-disk-pressure
write_catalog \
  '| can-sense | internal | held | 1 | 1 | - | sense |' \
  '| can-update-self | internal | challenged | 1 | 0 | - | the canary broke |' \
  '| can-fix-disk-pressure | internal | challenged | 1 | 0 | - | the remedy clears the pressure |'
run_gaps
ac_assert_eq "$OUT" "can-fix-disk-pressure" \
  "the challenged non-rung claim must print (got '$OUT')"
ac_assert_eq "$RC" "0" "planner_claim_gaps must return 0 (rc=$RC)"

# ── AC6: the pinned acceptance suites still pass ─────────────────────────────
ac_log "AC6: issue-1975.sh and issue-2056.sh pass"
bash "$REPO_ROOT/tests/acceptance/issue-1975.sh" >/dev/null
bash "$REPO_ROOT/tests/acceptance/issue-2056.sh" >/dev/null

ac_pass "issue #2124: the ladder names update-self as rung 2"
