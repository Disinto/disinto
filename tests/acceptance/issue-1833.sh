#!/usr/bin/env bash
# =============================================================================
# tests/acceptance/issue-1833.sh
#
# Issue #1833: the pre-lock merge scan must not merge a non-dev-labeled issue.
#
# dev/dev-poll.sh merges approved, CI-green PRs before it takes the agent lock
# and before the in-progress / stuck-PR scans. That loop called try_direct_merge
# for a PR assigned to $BOT_USER or unassigned without asking
# issue_is_dev_claimable, so a hand-applied awaiting-live-verification (or any
# other _ILC_NON_DEV_LABELS label) was merged and the linked issue closed
# before the #1825 skips ran.
#
# The claimable check has to sit inside the PL_ISSUE>0 arm and continue before
# try_direct_merge. Issue-less chore PRs (PL_ISSUE=0) stay on the merge path.
#
# Hermetic: no network. Structural awk over the pre-lock region only.
#
# Acceptance: `bash tests/acceptance/issue-1833.sh` exits 0 and calls ac_pass.
# Run via `tools/run-acceptance.sh 1833`.
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=../../tests/lib/acceptance-helpers.sh
source "$REPO_ROOT/tests/lib/acceptance-helpers.sh"

ac_require_cmd awk
TARGET_POLL="$REPO_ROOT/dev/dev-poll.sh"
TARGET_DOC="$REPO_ROOT/dev/AGENTS.md"
ac_assert_file "$TARGET_POLL" "dev-poll.sh is required to prove the #1833 pre-lock gate"
ac_assert_file "$TARGET_DOC" "dev/AGENTS.md is required to name the #1833 pre-lock gate"
ac_log "syntax-check dev/dev-poll.sh before the pre-lock non-dev gate (#1833)"
bash -n "$TARGET_POLL" || ac_fail "dev/dev-poll.sh failed bash -n while checking #1833"

# Bound the pre-lock loop, then prove:
#   * chore PRs are still classified as issue 0 before the claimable gate
#   * issue_is_dev_claimable runs inside the PL_ISSUE>0 arm
#   * its continue is still inside that arm and before try_direct_merge
#   * try_direct_merge itself sits outside the arm, so PL_ISSUE=0 still merges
awk '
  function opens(line) {
    return line ~ /^[[:space:]]*(if|for|while)[[:space:]]/
  }
  function closes(line) {
    return line ~ /^[[:space:]]*(fi|done)[[:space:]]*$/
  }
  /pre-lock: scanning for mergeable PRs/ && !region { region = NR; next }
  /pre-lock: no PRs merged, checking agent lock/ && region && !region_end {
    region_end = NR
    next
  }
  !region || NR <= region || (region_end && NR >= region_end) { next }
  {
    if (opens($0)) depth++
    if ($0 ~ /chore\/\(gardener\|planner\|predictor\)-/ && !chore_at) chore_at = NR
    if ($0 ~ /^[[:space:]]*PL_ISSUE=0[[:space:]]*$/ && !zero_at) zero_at = NR
    if ($0 ~ /\$PL_ISSUE" -gt 0/ && !gate_at) {
      gate_at = NR
      gate_depth = depth
    }
    if ($0 ~ /^[[:space:]]*if ! issue_is_dev_claimable / && !claim_at) {
      claim_at = NR
      claim_depth = depth
    }
    if ($0 ~ /skipping pre-lock merge \(#1833\)/ && claim_at && !logged) logged = NR
    if ($0 ~ /^[[:space:]]*continue[[:space:]]*$/ && claim_at && !skip_at && NR > claim_at) {
      skip_at = NR
      skip_depth = depth
    }
    if ($0 ~ /^[[:space:]]*try_direct_merge / && !merge_at) {
      merge_at = NR
      merge_depth = depth
    }
    if (closes($0) && depth > 0) depth--
  }
  END {
    bad = 0
    if (!region || !region_end || region >= region_end) {
      print "pre-lock scan bounds missing" > "/dev/stderr"
      bad = 1
    }
    if (!chore_at || !zero_at || !gate_at || chore_at >= gate_at || zero_at >= gate_at) {
      print "issue-less chore PRs are no longer classified before the pre-lock claimable gate" > "/dev/stderr"
      bad = 1
    }
    if (!claim_at || !gate_depth || claim_at <= gate_at || claim_depth <= gate_depth) {
      print "issue_is_dev_claimable is not inside the pre-lock PL_ISSUE>0 arm" > "/dev/stderr"
      bad = 1
    }
    if (!logged || !skip_at || logged <= claim_at || logged >= skip_at || skip_depth <= gate_depth) {
      print "pre-lock non-dev skip does not continue inside the PL_ISSUE>0 arm" > "/dev/stderr"
      bad = 1
    }
    if (!merge_at || skip_at >= merge_at || merge_depth >= gate_depth) {
      print "try_direct_merge is not after the non-dev continue, or it moved inside the PL_ISSUE>0 arm" > "/dev/stderr"
      bad = 1
    }
    exit bad
  }
' "$TARGET_POLL" || ac_fail "pre-lock scan still merges a non-dev-labeled issue, or it stopped merging issue-less chore PRs"

ac_log "dev/AGENTS.md names the #1833 pre-lock skip"
grep -qF "pre-lock merge scan applies the same check before try_direct_merge (#1833)" "$TARGET_DOC" \
  || ac_fail "dev/AGENTS.md must say the pre-lock merge scan checks claimability before try_direct_merge (#1833)"
grep -qF "awaiting-live-verification (#1833)" "$TARGET_DOC" \
  || ac_fail "dev/AGENTS.md must name awaiting-live-verification on the pre-lock skip (#1833)"

ac_pass "issue #1833: pre-lock merge scan continues past a non-dev label before try_direct_merge"
