#!/usr/bin/env bash
# =============================================================================
# tests/acceptance/issue-1119-deploy-drift-check.sh
#
# Issue #1119: the deployed checkout /opt/disinto — the source tree for every
# Nomad job — sat 140 commits behind origin/main with uncommitted jobspec
# changes, so merged fixes were never deployed. The fix adds
# tools/check-deploy-drift.sh, which fails when the deployed checkout is
# behind origin/main or carries uncommitted changes under nomad/, and runs it
# from the gardener step (classify.sh priority 10 → formulas/deploy-drift.toml
# files the finding).
#
# Acceptance (self-contained — fixture git trees under mktemp, local bare
# origin; no live checkout touched, no network):
#   1. Clean checkout (HEAD == origin/main, nomad/ clean) → exit 0, VERDICT=clean.
#   2. Checkout falls behind origin/main → exit 1, VERDICT=drift, BEHIND=1.
#   3. Uncommitted changes under nomad/ (modified + untracked) → exit 1,
#      VERDICT=drift, DIRTY_FILES names the paths, BEHIND=0.
#   4. Uncommitted changes OUTSIDE nomad/ are not drift → exit 0, VERDICT=clean.
#   5. Missing checkout → exit 2, VERDICT=error (gardener skips silently).
#   6. Wiring: classify.sh invokes the check and emits the deploy-drift task;
#      formulas/deploy-drift.toml exists with its throttle sentinel.
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck disable=SC1091
source "$REPO_ROOT/tests/lib/acceptance-helpers.sh"

ac_require_cmd git jq

CHECK="$REPO_ROOT/tools/check-deploy-drift.sh"
ac_assert_file "$CHECK" "tools/check-deploy-drift.sh must exist"

BASE="$(mktemp -d)"
trap 'rm -rf "$BASE"' EXIT

GIT_ID=(-c user.name=fixture -c user.email=fixture@example.com)

# run_check <checkout-dir> — run the check, capture stdout+stderr and rc.
# Sets CHECK_OUT, CHECK_LAST (final line), and RC.
run_check() {
  RC=0
  CHECK_OUT=$("$CHECK" "$1" 2>&1) || RC=$?
  CHECK_LAST="$(printf '%s\n' "$CHECK_OUT" | tail -n1)"
}

# ── Fixture: local bare origin seeded with one commit under nomad/ ─────────
git init -q --bare "$BASE/origin.git"
(
  cd "$BASE"
  mkdir -p work/nomad/jobs
  cd work
  git init -q
  git checkout -qb main
  echo v1 > nomad/jobs/agent.hcl
  git add nomad
  git "${GIT_ID[@]}" commit -qm seed
  git remote add origin "$BASE/origin.git"
  git push -q origin main
)

# ── 1. Clean checkout: HEAD == origin/main, nomad/ clean ───────────────────
git clone -q -b main "$BASE/origin.git" "$BASE/deploy"
run_check "$BASE/deploy"
ac_assert_eq "$RC" "0" "clean checkout must exit 0 (got $RC): $CHECK_OUT"
ac_assert_eq "$CHECK_LAST" "VERDICT=clean" "clean checkout must be VERDICT=clean (got: $CHECK_LAST)"

# ── 2. Checkout falls behind origin/main ────────────────────────────────────
# A second commit lands on origin/main while the deployed checkout stays put.
(
  cd "$BASE"
  git clone -q -b main origin.git pusher
  cd pusher
  echo v2 >> nomad/jobs/agent.hcl
  git add nomad
  git "${GIT_ID[@]}" commit -qm second
  git push -q origin main
)
run_check "$BASE/deploy"
ac_assert_eq "$RC" "1" "behind checkout must exit 1 (got $RC): $CHECK_OUT"
ac_assert_eq "$CHECK_LAST" "VERDICT=drift" "behind checkout must be VERDICT=drift (got: $CHECK_LAST)"
printf '%s\n' "$CHECK_OUT" | grep -qx 'BEHIND=1' \
  || ac_fail "behind checkout must report BEHIND=1 (got: $CHECK_OUT)"

# ── 3. Uncommitted changes under nomad/ (modified + untracked) ─────────────
git clone -q -b main "$BASE/origin.git" "$BASE/deploy-dirty"
(
  cd "$BASE/deploy-dirty"
  echo live-edit >> nomad/jobs/agent.hcl
  echo 'kind: job' > nomad/jobs/qwen-dev.hcl
)
run_check "$BASE/deploy-dirty"
ac_assert_eq "$RC" "1" "dirty nomad/ checkout must exit 1 (got $RC): $CHECK_OUT"
ac_assert_eq "$CHECK_LAST" "VERDICT=drift" "dirty nomad/ checkout must be VERDICT=drift (got: $CHECK_LAST)"
printf '%s\n' "$CHECK_OUT" | grep -qx 'BEHIND=0' \
  || ac_fail "dirty-nomad checkout must report BEHIND=0 (got: $CHECK_OUT)"
DIRTY_JSON="$(printf '%s\n' "$CHECK_OUT" | sed -n 's/^DIRTY_FILES=//p')"
printf '%s' "$DIRTY_JSON" | jq -e 'any(endswith("agent.hcl"))' >/dev/null \
  || ac_fail "DIRTY_FILES must name the modified jobspec: $DIRTY_JSON"
printf '%s' "$DIRTY_JSON" | jq -e 'any(endswith("qwen-dev.hcl"))' >/dev/null \
  || ac_fail "DIRTY_FILES must name the untracked jobspec: $DIRTY_JSON"

# ── 4. Uncommitted changes outside nomad/ are not drift ─────────────────────
git clone -q -b main "$BASE/origin.git" "$BASE/deploy-outside"
echo scratch > "$BASE/deploy-outside/scratch.txt"
run_check "$BASE/deploy-outside"
ac_assert_eq "$RC" "0" "changes outside nomad/ are not drift (got $RC): $CHECK_OUT"
ac_assert_eq "$CHECK_LAST" "VERDICT=clean" "outside-nomad dirt must be VERDICT=clean (got: $CHECK_LAST)"

# ── 5. Missing checkout → infrastructure error, not drift ───────────────────
run_check "$BASE/does-not-exist"
ac_assert_eq "$RC" "2" "missing checkout must exit 2 (got $RC): $CHECK_OUT"
ac_assert_eq "$CHECK_LAST" "VERDICT=error" "missing checkout must be VERDICT=error (got: $CHECK_LAST)"

# ── 6. Gardener wiring ──────────────────────────────────────────────────────
grep -q 'check-deploy-drift' "$REPO_ROOT/gardener/classify.sh" \
  || ac_fail "gardener/classify.sh does not invoke tools/check-deploy-drift.sh"
grep -q '"deploy-drift"' "$REPO_ROOT/gardener/classify.sh" \
  || ac_fail "gardener/classify.sh does not emit the deploy-drift task"
ac_assert_file "$REPO_ROOT/formulas/deploy-drift.toml" \
  "formulas/deploy-drift.toml must exist to handle the task"
grep -q 'gardener: deploy-drift' "$REPO_ROOT/formulas/deploy-drift.toml" \
  || ac_fail "deploy-drift formula is missing its throttle sentinel"

ac_pass
