#!/usr/bin/env bash
# =============================================================================
# tests/acceptance/issue-1975.sh
#
# Issue #1975: name the lowest missing capability rung.
#
# planner/ladder.sh (called by planner/pitch-or-idle.sh) sources lib/claims.sh and does not source
# lib/env.sh. ladder_lowest_gap prints the lowest rung of
# sense, provision, reach, deploy, replicate that no claim id matches, or
# that any matching id has catalog status challenged. Nothing when there is
# no gap. Always rc 0 for that decision. No network, no writes.
#
# Hermetic: a temp CLAIMS_DIR and CLAIMS_CATALOG. No forge, no agent.
#
# Acceptance: `bash tests/acceptance/issue-1975.sh` exits 0 and calls ac_pass.
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=../../tests/lib/acceptance-helpers.sh
source "$REPO_ROOT/tests/lib/acceptance-helpers.sh"

ac_require_cmd bash grep
ac_assert_file "$REPO_ROOT/planner/ladder.sh" "planner/ladder.sh is missing"
ac_assert_file "$REPO_ROOT/lib/claims.sh" "lib/claims.sh is missing"
ac_assert_file "$REPO_ROOT/planner/AGENTS.md" "planner/AGENTS.md is missing"

# ── static: no network helper, sources claims, docs bullet ───────────────────
ac_log "static: bash -n, no curl, sources claims.sh, not env.sh"
bash -n "$REPO_ROOT/planner/ladder.sh"
ac_assert_eq "$(grep -c curl "$REPO_ROOT/planner/ladder.sh" || true)" "0" \
  "planner/ladder.sh must not mention curl"
grep -q 'lib/claims.sh' "$REPO_ROOT/planner/ladder.sh" \
  || ac_fail "planner/ladder.sh must source lib/claims.sh"
if grep -E '^[[:space:]]*(source|\.)[[:space:]]' "$REPO_ROOT/planner/ladder.sh" | grep -q 'env.sh'; then
  ac_fail "planner/ladder.sh must not source lib/env.sh"
fi
ac_assert_eq "$(grep -cE '^[a-zA-Z_][a-zA-Z0-9_]*\(\)' "$REPO_ROOT/planner/ladder.sh")" "1" \
  "planner/ladder.sh must define only ladder_lowest_gap"

groom_line="$(grep -n 'formulas/groom-backlog.toml' "$REPO_ROOT/planner/AGENTS.md" | head -n 1 | cut -d: -f1)"
ladder_line="$(grep -n 'planner/ladder.sh' "$REPO_ROOT/planner/AGENTS.md" | head -n 1 | cut -d: -f1)"
[ -n "$groom_line" ] || ac_fail "planner/AGENTS.md must keep the groom-backlog bullet"
[ -n "$ladder_line" ] || ac_fail "planner/AGENTS.md must document planner/ladder.sh"
[ "$ladder_line" -gt "$groom_line" ] \
  || ac_fail "planner/ladder.sh bullet must follow the groom-backlog bullet"
grep -qF 'ladder_lowest_gap' "$REPO_ROOT/planner/AGENTS.md" \
  || ac_fail "planner/AGENTS.md must name ladder_lowest_gap"
grep -qF 'Called by `planner/pitch-or-idle.sh`.' "$REPO_ROOT/planner/AGENTS.md" \
  || ac_fail "planner/AGENTS.md must say the ladder is called by planner/pitch-or-idle.sh"

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

CLAIMS_DIR="$TMP_DIR/claims"
CATALOG="$TMP_DIR/catalog/claims.md"
mkdir -p "$CLAIMS_DIR" "$(dirname "$CATALOG")"

# add_claim ID — an empty claim file. ladder_lowest_gap reads the name only.
add_claim() {
  printf 'statement = "x"\n' >"$CLAIMS_DIR/$1.toml"
}

# write_catalog [row...] — a claims-report shaped table. Rows are full lines.
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
# ladder_lowest_gap. stdout -> $OUT, stderr -> $ERR, status -> $RC.
run_ladder() {
  RC=0 OUT="" ERR=""
  (
    export CLAIMS_DIR CLAIMS_CATALOG="$CATALOG"
    unset OPS_REPO_ROOT || true
    # shellcheck disable=SC1091
    source "$REPO_ROOT/planner/ladder.sh"
    ladder_lowest_gap
  ) >"$TMP_DIR/out" 2>"$TMP_DIR/err" || RC=$?
  OUT="$(cat "$TMP_DIR/out" 2>/dev/null || true)"
  ERR="$(cat "$TMP_DIR/err" 2>/dev/null || true)"
}

# ── AC1: empty CLAIMS_DIR prints sense, even if the catalog lists rungs ─────
ac_log "AC1: empty CLAIMS_DIR prints sense"
write_catalog \
  '| can-sense | internal | held | 1 | 1 | - | sense |' \
  '| can-provision | internal | held | 1 | 1 | - | provision |'
run_ladder
ac_assert_eq "$OUT" "sense" \
  "empty CLAIMS_DIR must print sense (got '$OUT') [stderr: $ERR]"
ac_assert_eq "$RC" "0" "empty CLAIMS_DIR must return 0 (rc=$RC)"
[ -z "$ERR" ] || ac_fail "empty CLAIMS_DIR must not print stderr (got: $ERR)"

# ── AC2: held can-sense-box, no other can-* claim, prints provision ──────────
ac_log "AC2: held can-sense-box prints provision"
add_claim can-sense-box
add_claim dev-comes-back
write_catalog \
  '| can-sense-box | internal | held | 1 | 1 | - | sense |' \
  '| can-provision | internal | held | 1 | 1 | - | catalog row is not a claim file |'
run_ladder
ac_assert_eq "$OUT" "provision" \
  "held can-sense-box must print provision (got '$OUT') [stderr: $ERR]"
ac_assert_eq "$RC" "0" "held can-sense-box must return 0 (rc=$RC)"
[ -z "$ERR" ] || ac_fail "held can-sense-box must not print stderr (got: $ERR)"

# ── AC3: all five present, none challenged, prints nothing ───────────────────
ac_log "AC3: all five present, none challenged, prints nothing"
add_claim can-sense
add_claim can-provision
add_claim can-reach-porter
add_claim can-deploy-porter
add_claim can-replicate
# replicate has no catalog row: a missing row is not challenged.
# not-a-rung challenged must not open a gap on a rung it does not match.
write_catalog \
  '| can-sense | internal | held | 1 | 1 | - | sense |' \
  '| can-sense-box | internal | held | 1 | 1 | - | sense host |' \
  '| can-provision | internal | provisional | 0 | - | - | provision |' \
  '| can-reach-porter | internal | not proposed | 0 | - | - | reach |' \
  '| can-deploy-porter | internal | held | 2 | 1 | - | deploy |' \
  '| not-a-rung | internal | challenged | 1 | 0 | - | unrelated |'
run_ladder
ac_assert_eq "$OUT" "" \
  "all five held-or-other must print nothing (got '$OUT') [stderr: $ERR]"
ac_assert_eq "$RC" "0" "all five present must return 0 (rc=$RC)"
[ -z "$ERR" ] || ac_fail "all five present must not print stderr (got: $ERR)"

# ── AC4: can-provision challenged, can-sense held, prints provision ──────────
ac_log "AC4: challenged can-provision prints provision"
write_catalog \
  '| can-sense | internal | held | 1 | 1 | - | sense |' \
  '|  can-provision  | internal |  challenged  | 1 | 0 | - | provision |'
run_ladder
ac_assert_eq "$OUT" "provision" \
  "challenged can-provision must print provision (got '$OUT') [stderr: $ERR]"
ac_assert_eq "$RC" "0" "challenged can-provision must return 0 (rc=$RC)"
[ -z "$ERR" ] || ac_fail "challenged can-provision must not print stderr (got: $ERR)"

# Any matching sense id challenged is a sense gap, even if another is held.
ac_log "any challenged sense match prints sense"
write_catalog \
  '| can-sense | internal | held | 1 | 1 | - | sense |' \
  '| can-sense-box | internal | challenged | 1 | 0 | - | sense host |'
run_ladder
ac_assert_eq "$OUT" "sense" \
  "a challenged can-sense-box must print sense (got '$OUT')"
ac_assert_eq "$RC" "0" "challenged sense match must return 0 (rc=$RC)"

# A missing catalog file is not challenged.
ac_log "missing catalog is not challenged"
rm -f "$CATALOG"
run_ladder
ac_assert_eq "$OUT" "" \
  "missing catalog with all five claims must print nothing (got '$OUT')"
ac_assert_eq "$RC" "0" "missing catalog must return 0 (rc=$RC)"
[ -z "$ERR" ] || ac_fail "missing catalog must not print stderr (got: $ERR)"

# Default catalog path is ${OPS_REPO_ROOT}/catalog/claims.md.
ac_log "CLAIMS_CATALOG defaults to OPS_REPO_ROOT/catalog/claims.md"
OPS_ROOT="$TMP_DIR/ops"
mkdir -p "$OPS_ROOT/claims" "$OPS_ROOT/catalog"
printf 'statement = "x"\n' >"$OPS_ROOT/claims/can-sense.toml"
printf '%s\n' '| can-sense | internal | challenged | 1 | 0 | - | sense |' \
  >"$OPS_ROOT/catalog/claims.md"
RC=0 OUT="" ERR=""
(
  unset CLAIMS_DIR CLAIMS_CATALOG || true
  export OPS_REPO_ROOT="$OPS_ROOT"
  # shellcheck disable=SC1091
  source "$REPO_ROOT/planner/ladder.sh"
  ladder_lowest_gap
) >"$TMP_DIR/out" 2>"$TMP_DIR/err" || RC=$?
OUT="$(cat "$TMP_DIR/out" 2>/dev/null || true)"
ERR="$(cat "$TMP_DIR/err" 2>/dev/null || true)"
ac_assert_eq "$OUT" "sense" \
  "default catalog path must see challenged can-sense (got '$OUT') [stderr: $ERR]"
ac_assert_eq "$RC" "0" "default catalog path must return 0 (rc=$RC)"

ac_pass "issue #1975: name the lowest missing capability rung"
