#!/usr/bin/env bash
# =============================================================================
# tests/acceptance/issue-1804.sh — a merged issue is closed, not labelled
#
# Issue #1804: the post-merge path called issue_close_after_verification,
# which kept the issue open under awaiting-live-verification. The forge
# already closes the issue from "Fixes #N", and nothing consumes that label.
# The merged branch of dev-agent.sh now calls issue_close; the helper and
# its label-id cache are gone. The label stays in _ILC_NON_DEV_LABELS so a
# hand-applied label is still skipped by dev-poll.
#
# Acceptance (read-only — greps and bash -n; no network, no live forge):
#   1. issue_close_after_verification and _ilc_awaiting_live_id are gone
#      from dev/, lib/, and the three AGENTS.md files the flow is documented in.
#   2. The merged branch of dev/dev-agent.sh calls issue_close "$ISSUE".
#   3. AGENTS.md's flow no longer ends in awaiting-live-verification.
#   4. bash -n dev/dev-agent.sh lib/issue-lifecycle.sh passes.
#   5. awaiting-live-verification remains in _ILC_NON_DEV_LABELS.
#
# Run via: tools/run-acceptance.sh 1804
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../tests/lib/acceptance-helpers.sh
source "$REPO_ROOT/tests/lib/acceptance-helpers.sh"

ac_require_cmd bash git grep

cd "$REPO_ROOT"

# 1. Dead helper and its private label-id lookup are gone from the named paths.
stale=$(git grep -n 'issue_close_after_verification\|_ilc_awaiting_live_id' \
  -- dev lib AGENTS.md dev/AGENTS.md lib/AGENTS.md || true)
if [ -n "$stale" ]; then
  ac_fail "issue_close_after_verification / _ilc_awaiting_live_id still present: ${stale}"
fi
ac_log "no issue_close_after_verification or _ilc_awaiting_live_id in the named paths"

# 2. The walk-success branch (the only `if [ "$rc" -eq 0 ]` in dev-agent.sh)
#    calls issue_close, not the deleted helper.
merged=$(grep -A5 -F 'if [ "$rc" -eq 0 ]; then' dev/dev-agent.sh || true)
printf '%s\n' "$merged" | grep -qF 'issue_close "$ISSUE"' \
  || ac_fail "merged branch of dev/dev-agent.sh must call issue_close \"\$ISSUE\" (got: ${merged})"
ac_log "merged branch calls issue_close"

# 3. The documented flow ends at closed, not awaiting-live-verification.
flow=$(grep -n 'merge → .awaiting-live-verification' AGENTS.md || true)
if [ -n "$flow" ]; then
  ac_fail "AGENTS.md still documents merge → awaiting-live-verification: ${flow}"
fi
ac_log "AGENTS.md flow does not route merge through awaiting-live-verification"

# 4. The edited scripts still parse.
bash -n dev/dev-agent.sh lib/issue-lifecycle.sh \
  || ac_fail "bash -n dev/dev-agent.sh lib/issue-lifecycle.sh failed"
ac_log "bash -n dev/dev-agent.sh lib/issue-lifecycle.sh"

# 5. A hand-applied label is still a non-dev label (dev-poll skips it).
grep -q 'awaiting-live-verification' lib/issue-lifecycle.sh \
  || ac_fail "awaiting-live-verification must stay in lib/issue-lifecycle.sh (_ILC_NON_DEV_LABELS)"
grep -q '_ILC_NON_DEV_LABELS=.*awaiting-live-verification' lib/issue-lifecycle.sh \
  || ac_fail "awaiting-live-verification must remain in _ILC_NON_DEV_LABELS"
ac_log "awaiting-live-verification remains a non-dev label"

ac_pass "issue #1804: a merged issue is closed, not labelled awaiting-live-verification"
