#!/usr/bin/env bash
# tests/acceptance/issue-1306.sh — dev-bot must not claim experiment issues
#
# Acceptance for #1306 (read-only against the repo, no network, no live forge):
#   1. issue_is_dev_claimable() in lib/issue-lifecycle.sh returns 1 when the
#      label set contains 'experiment' (and 'run' / 'judgment'), still returns
#      1 for 'bug-report' / 'vision', and leaves plain backlog issues
#      (including 'priority,backlog') claimable — whole-label matching only,
#      no substring false positives.
#   2. The backlog-scan skip regex in dev/dev-poll.sh includes 'experiment',
#      'run', 'judgment' alongside the pre-existing skip labels (#1072).
#
# bash + coreutils only (CI runs on alpine:3 with no python3).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

source "${SCRIPT_DIR}/../lib/acceptance-helpers.sh"

ac_require_cmd bash grep

ILC="$REPO_ROOT/lib/issue-lifecycle.sh"
DEV_POLL="$REPO_ROOT/dev/dev-poll.sh"
ac_assert_file "$ILC" "lib/issue-lifecycle.sh not found"
ac_assert_file "$DEV_POLL" "dev/dev-poll.sh not found"

# ── 1. issue_is_dev_claimable function test ─────────────────────────────────
# The library is safe to source without network: its top level only sets
# shell options, defines functions, and sources lib/secret-scan.sh
# (definition-only). issue_is_dev_claimable is a pure string check and makes
# no HTTP calls, so a dummy FORGE_TOKEN is never used.
claimable_rc() {
  FACTORY_ROOT="$REPO_ROOT" FORGE_TOKEN="dummy" FORGE_API="http://invalid/api/v1" \
  bash -c '
    source "$FACTORY_ROOT/lib/issue-lifecycle.sh"
    set +e
    issue_is_dev_claimable "$1"
    echo "$?"
  ' _ "$1"
}

ac_assert_eq "$(claimable_rc "backlog,experiment")" "1" \
  "issue_is_dev_claimable must return 1 when labels contain 'experiment' (even with backlog)"
ac_assert_eq "$(claimable_rc "experiment")" "1" \
  "issue_is_dev_claimable must return 1 for 'experiment' alone"
ac_assert_eq "$(claimable_rc "run")" "1" \
  "issue_is_dev_claimable must return 1 for 'run'"
ac_assert_eq "$(claimable_rc "judgment,backlog")" "1" \
  "issue_is_dev_claimable must return 1 when labels contain 'judgment'"

# Pre-existing non-dev skips must keep working.
ac_assert_eq "$(claimable_rc "bug-report")" "1" \
  "issue_is_dev_claimable must still return 1 for 'bug-report'"
ac_assert_eq "$(claimable_rc "vision")" "1" \
  "issue_is_dev_claimable must still return 1 for 'vision'"
ac_assert_eq "$(claimable_rc "backlog")" "0" \
  "plain backlog issues must stay claimable"
ac_assert_eq "$(claimable_rc "priority,backlog")" "0" \
  "priority backlog issues must stay claimable"

# Whole-label matching only (',<label>,' anchors) — no substring false positives.
ac_assert_eq "$(claimable_rc "artifacts-run,backlog")" "0" \
  "'run' must match as a whole label only"
ac_log "issue_is_dev_claimable: experiment/run/judgment unclaimable; bug-report/vision/backlog unchanged"

# ── 2. dev-poll backlog-scan skip list ───────────────────────────────────────
# Extract the SKIP_LABEL line and assert the anchored alternation includes the
# new research labels alongside the pre-existing ones.
SKIP_LINE="$(grep -E 'SKIP_LABEL=\$\(echo' "$DEV_POLL" | head -1)" || ac_fail "SKIP_LABEL line not found in dev/dev-poll.sh"
[ -n "$SKIP_LINE" ] || ac_fail "SKIP_LABEL line not found in dev/dev-poll.sh"
for lbl in formula prediction/dismissed prediction/unreviewed waiting-on-compute experiment run judgment; do
  printf '%s' "$SKIP_LINE" | grep -qF "$lbl" \
    || ac_fail "dev-poll backlog-scan skip list missing '${lbl}'"
done
ac_log "dev-poll backlog-scan skip list includes experiment/run/judgment (and the pre-existing labels)"

ac_pass "dev-bot cannot claim experiment issues: issue_is_dev_claimable rejects experiment/run/judgment, dev-poll backlog scan skips them, bug-report/vision skips unchanged"
