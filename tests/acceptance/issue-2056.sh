#!/usr/bin/env bash
# =============================================================================
# tests/acceptance/issue-2056.sh
#
# Issue #2056: challenged can-fix claims reach the planning session as gaps.
#
# planner/gaps.sh sources lib/claims.sh — not lib/env.sh, no network — and
# planner_claim_gaps prints the ids from claim_ids that match ^can-, are not
# ladder rungs (^can-(sense(-[a-z0-9-]+)?|provision|reach-porter|
# deploy-porter|replicate)$), and are challenged in
# ${CLAIMS_CATALOG:-${OPS_REPO_ROOT:-}/catalog/claims.md}: one id per line,
# sorted; nothing when none match or the catalog is missing; always rc 0.
#
# planner/planner-run.sh sources it directly after pitch-or-idle.sh and
# appends `gaps: <ids>` (or `gaps: none`) under `ladder: none` in the session
# prompt. formulas/run-planner.toml documents the gaps line; planner/AGENTS.md
# carries the gaps.sh bullet and the run-planner.toml note.
#
# Hermetic: temp CLAIMS_DIR and temp CLAIMS_CATALOG. No forge, no agent.
#
# Acceptance: `bash tests/acceptance/issue-2056.sh` exits 0 and calls ac_pass.
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=../lib/acceptance-helpers.sh
source "$REPO_ROOT/tests/lib/acceptance-helpers.sh"

ac_require_cmd bash grep awk paste sed mktemp

GAPS="$REPO_ROOT/planner/gaps.sh"
RUN="$REPO_ROOT/planner/planner-run.sh"
FORMULA="$REPO_ROOT/formulas/run-planner.toml"
DOC="$REPO_ROOT/planner/AGENTS.md"
ac_assert_file "$GAPS" "planner/gaps.sh is missing"
ac_assert_file "$RUN" "planner/planner-run.sh is missing"

ac_log "static: bash -n on both scripts; gaps.sh sources claims.sh, not env.sh"
bash -n "$GAPS" || ac_fail "bash -n failed on planner/gaps.sh"
bash -n "$RUN" || ac_fail "bash -n failed on planner/planner-run.sh"
grep -q 'lib/claims.sh' "$GAPS" \
  || ac_fail "planner/gaps.sh must source lib/claims.sh"
if grep -E '^[[:space:]]*(source|\.)[[:space:]]' "$GAPS" | grep -q 'env.sh'; then
  ac_fail "planner/gaps.sh must not source lib/env.sh"
fi

T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT

mkdir -p "$T/claims"
printf 'statement = "the boom remedy clears the condition it acts on"\n' \
  >"$T/claims/can-fix-boom.toml"
printf 'statement = "the box sees the host volume"\n' \
  >"$T/claims/can-sense-box.toml"
printf 'statement = "a dev proposal comes back within 48 hours"\n' \
  >"$T/claims/dev-x.toml"

# catalog — the exact claims-report.sh table shape.
cat >"$T/catalog.md" <<'EOF'
| claim | class | status | checks | last value | resting sprints | statement |
|---|---|---|---|---|---|---|
| can-fix-boom | internal | challenged | 1 | 0.0 | - | the boom remedy clears the condition |
| can-sense-box | internal | challenged | 2 | 1 | - | the box sees the host volume |
| dev-x | internal | challenged | 3 | 0.1 | - | a dev proposal comes back |
EOF

# run_gaps CATALOG — planner_claim_gaps against the temp claims dir; sets RC/OUT.
run_gaps() {
  RC=0
  OUT="$(CLAIMS_DIR="$T/claims" CLAIMS_CATALOG="$1" planner_claim_gaps)" || RC=$?
}

ac_log "AC1: challenged can-fix-boom prints exactly can-fix-boom, rc 0"
# shellcheck source=../../planner/gaps.sh
source "$GAPS"
run_gaps "$T/catalog.md"
ac_assert_eq "$RC" "0" "planner_claim_gaps must always return 0 (got $RC)"
ac_assert_eq "$OUT" "can-fix-boom" \
  "only the challenged non-rung can-* claim may print (got '$OUT')"

ac_log "AC2: can-fix-boom held prints nothing"
# Rewrite only boom's status cell; every other row is untouched.
awk 'BEGIN{OFS="|"} /^(\| )?can-fix-boom \|/ { sub(/challenged/, "held"); } {print}' \
  "$T/catalog.md" >"$T/catalog-held.md"
run_gaps "$T/catalog-held.md"
ac_assert_eq "$OUT" "" "a held claim is not a gap (got '$OUT')"
ac_assert_eq "$RC" "0" "no gaps must still return 0 (got $RC)"

ac_log "AC3: a missing catalog prints nothing"
run_gaps "$T/does-not-exist.md"
ac_assert_eq "$OUT" "" "a missing catalog must print nothing (got '$OUT')"
ac_assert_eq "$RC" "0" "a missing catalog must still return 0 (got $RC)"

ac_log "AC4: a challenged row with no claim file is not a gap"
cat >"$T/catalog-ghost.md" <<'EOF'
| claim | class | status | checks | last value | resting sprints | statement |
|---|---|---|---|---|---|---|
| can-fix-boom | internal | challenged | 1 | 0.0 | - | the boom remedy clears the condition |
| can-fix-zzz | internal | challenged | 0 | - | - | no claim file exists |
EOF
run_gaps "$T/catalog-ghost.md"
ac_assert_eq "$OUT" "can-fix-boom" \
  "a challenged row with no claim file must not print (got '$OUT')"

ac_log "AC5: two challenged can-fix claims print sorted, one per line"
printf 'statement = "the apache remedy clears the condition it acts on"\n' \
  >"$T/claims/can-fix-apache.toml"
cat >"$T/catalog-two.md" <<'EOF'
| claim | class | status | checks | last value | resting sprints | statement |
|---|---|---|---|---|---|---|
| can-fix-boom | internal | challenged | 1 | 0.0 | - | the boom remedy clears the condition |
| can-fix-apache | internal | challenged | 2 | 0.5 | - | the apache remedy clears the condition |
EOF
run_gaps "$T/catalog-two.md"
lines="$(printf '%s\n' "$OUT" | grep -c '.' || true)"
ac_assert_eq "$lines" "2" "two gaps must print on two lines (got '$OUT')"
ac_assert_eq "$OUT" "$(printf 'can-fix-apache\ncan-fix-boom')" \
  "the gaps must print sorted, one per line (got '$OUT')"

ac_log "static: planner-run.sh sources gaps.sh exactly once and prints the gaps line"
ac_assert_eq "$(grep -c 'gaps.sh' "$RUN")" "1" \
  "planner-run.sh must source planner/gaps.sh exactly once"
grep -A1 -F 'ladder: none' "$RUN" | grep -q '^gaps: $(planner_claim_gaps' \
  || ac_fail "the session prompt must add a gaps: line built from planner_claim_gaps"

ac_log "static: the formula documents the gaps line; AGENTS.md carries the bullets"
grep -F 'gaps:' "$FORMULA" >/dev/null \
  || ac_fail "formulas/run-planner.toml must document the gaps line"
grep -qF 'can-fix-<condition>' "$FORMULA" \
  || ac_fail "formulas/run-planner.toml must explain what a can-fix claim is"
grep -qF 'planner/gaps.sh' "$DOC" \
  || ac_fail "planner/AGENTS.md must document planner/gaps.sh"
grep -qF 'A `gaps:` line names challenged `can-fix-*` claims' "$DOC" \
  || ac_fail "planner/AGENTS.md must note the gaps line in the run-planner.toml bullet"

ac_log "issue-1975, issue-1976 and issue-1978 still pass unchanged"
bash "$REPO_ROOT/tests/acceptance/issue-1975.sh" >/dev/null
bash "$REPO_ROOT/tests/acceptance/issue-1976.sh" >/dev/null
bash "$REPO_ROOT/tests/acceptance/issue-1978.sh" >/dev/null

ac_pass
