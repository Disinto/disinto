#!/usr/bin/env bash
# =============================================================================
# tests/acceptance/issue-1825.sh
#
# Issue #1825: a non-dev label on an in-progress issue must leave the scan.
#
# dev/dev-poll.sh used to log "skipping" and set OTHER_AGENT_INPROGRESS=true
# without leaving the iteration. The assignee block below still ran, so a
# $BOT_USER-assigned in-progress issue labelled awaiting-live-verification
# (or any other non-dev label) was relaunched — review fix, CI fix, or
# stale-branch / post-crash recovery. The stale sweep was already gated on
# the flag; that unassigned path must stay.
#
# Hermetic: no network. One awk pass over dev/dev-poll.sh.
#
# Acceptance: `bash tests/acceptance/issue-1825.sh` exits 0 and calls ac_pass.
# Run via `tools/run-acceptance.sh 1825`.
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=../../tests/lib/acceptance-helpers.sh
source "$REPO_ROOT/tests/lib/acceptance-helpers.sh"

# Names and messages differ from issue-1736.sh on purpose: the duplicate
# detector hashes every 5 non-comment lines, and that test already owns the
# shared poll-file preamble.
ac_require_cmd awk
POLL_SH="$REPO_ROOT/dev/dev-poll.sh"
AGENTS_DOC="$REPO_ROOT/dev/AGENTS.md"
ac_assert_file "$POLL_SH" "dev-poll.sh missing for the #1825 skip check"
ac_assert_file "$AGENTS_DOC" "dev/AGENTS.md missing for the #1825 skip check"
ac_log "syntax-check dev/dev-poll.sh for the non-dev continue (#1825)"
bash -n "$POLL_SH" || ac_fail "dev/dev-poll.sh failed bash -n while checking #1825"

# Prove, inside the in-progress scan:
#   * the non-dev check sits in a loop and continues before the assignee block
#   * spawn line numbers are compared to that continue in END (a forward
#     guard that waits for cont to be set can never see an earlier spawn)
#   * review-fix / CI-fix / stale-branch / post-crash recovery logs follow it
#   * the unassigned stale sweep is still behind OTHER_AGENT_INPROGRESS=false
#     and OPEN_PR=false
awk '
  /checking for in-progress issues/ && !start { start = NR; next }
  /checking for stuck PRs/ && start && !end { end = NR }
  END {
    if (!start || !end || start >= end) {
      print "in-progress scan bounds missing" > "/dev/stderr"
      exit 1
    }
  }
' "$POLL_SH" || ac_fail "could not bound the in-progress scan in dev/dev-poll.sh"

awk '
  /checking for in-progress issues/ && !start { start = NR; next }
  /checking for stuck PRs/ && start && !end { end = NR; next }
  !start || NR <= start || (end && NR >= end) { next }
  /^([[:space:]]*)(for|while)[[:space:]]/ { loop = NR }
  $0 ~ /if ! issue_is_dev_claimable "\$issue_labels"; then/ { nondev = NR }
  /^[[:space:]]*continue[[:space:]]*$/ && nondev && !cont && NR > nondev { cont = NR }
  /if \[ -n "\$assignee" \]; then/ && !assign { assign = NR }
  /dev-agent\.sh/ && /SCRIPT_DIR/ { spawn_at[++spawn_n] = NR }
  /\(review fix\)/ { review = NR }
  /\(CI fix\)/ { ci = NR }
  /\(stale-branch recovery\)/ { stale_rec = NR }
  /\(post-crash recovery\)/ { crash = NR }
  /^[[:space:]]*done[[:space:]]*$/ && !done_at && nondev && NR > nondev { done_at = NR }
  /OTHER_AGENT_INPROGRESS" = false/ && /BLOCKED_BY_INPROGRESS" = false/ { gate = NR }
  /OPEN_PR" = false/ && /BLOCKED_BY_INPROGRESS" = false/ { open_pr = NR }
  /handle_stale_in_progress "\$ISSUE_NUM"/ { sweep = NR }
  END {
    fail = 0
    if (!loop || !nondev || loop >= nondev) {
      print "non-dev check is not inside an in-progress for/while" > "/dev/stderr"
      fail = 1
    }
    if (!cont || !assign || cont >= assign) {
      print "non-dev skip must continue before the assignee block" > "/dev/stderr"
      fail = 1
    }
    if (!done_at || assign >= done_at || cont >= done_at) {
      print "continue/assignee block are not inside the in-progress loop" > "/dev/stderr"
      fail = 1
    }
    early = 0
    inside = 0
    for (i = 1; i <= spawn_n; i++) {
      if (spawn_at[i] <= cont) early++
      if (spawn_at[i] > nondev && spawn_at[i] < cont) inside++
    }
    if (early != 0 || inside != 0) {
      print "dev-agent.sh is spawned at or before the non-dev continue" > "/dev/stderr"
      fail = 1
    }
    if (!review || !ci || !stale_rec || !crash) {
      print "review-fix, CI-fix, or recovery log missing from the in-progress scan" > "/dev/stderr"
      fail = 1
    }
    if (review <= cont || ci <= cont || stale_rec <= cont || crash <= cont) {
      print "a spawn path is not after the non-dev continue" > "/dev/stderr"
      fail = 1
    }
    if (review >= done_at || ci >= done_at || stale_rec >= done_at || crash >= done_at) {
      print "a spawn path is outside the in-progress loop" > "/dev/stderr"
      fail = 1
    }
    if (!gate || !open_pr || !sweep || cont >= gate || gate >= open_pr || open_pr >= sweep) {
      print "unassigned stale sweep no longer sits behind OTHER_AGENT_INPROGRESS and OPEN_PR=false" > "/dev/stderr"
      fail = 1
    }
    exit fail
  }
' "$POLL_SH" || ac_fail "in-progress non-dev skip does not continue before dev-agent.sh, or the unassigned stale sweep moved"

# The in-progress continue falls through to stuck PRs. That scan must skip a
# non-dev label before try_direct_merge and before every dev-agent.sh spawn.
# Spawn lines are stored and compared in END, same as the scan above.
awk '
  /checking for stuck PRs/ && !stuck_start { stuck_start = NR; next }
  /scanning backlog for ready issues/ && stuck_start && !stuck_end { stuck_end = NR; next }
  !stuck_start || NR <= stuck_start || (stuck_end && NR >= stuck_end) { next }
  /issue_is_dev_claimable/ && !claim { claim = NR }
  /^[[:space:]]*continue[[:space:]]*$/ && claim && !skip_cont && NR > claim { skip_cont = NR }
  /try_direct_merge/ && !merge_at { merge_at = NR }
  /dev-agent\.sh/ && /SCRIPT_DIR/ { stuck_spawn[++stuck_spawn_n] = NR }
  /handle_ci_exhaustion/ { exhaust_at[++exhaust_n] = NR }
  END {
    bad = 0
    if (!stuck_start || !stuck_end || stuck_start >= stuck_end) {
      print "stuck-PR scan bounds missing" > "/dev/stderr"
      bad = 1
    }
    if (!claim || !skip_cont || claim >= skip_cont) {
      print "stuck-PR scan does not continue past a non-dev label" > "/dev/stderr"
      bad = 1
    }
    if (!merge_at || skip_cont >= merge_at) {
      print "stuck-PR non-dev continue is not before try_direct_merge" > "/dev/stderr"
      bad = 1
    }
    if (stuck_spawn_n+0 < 1) {
      print "stuck-PR scan has no dev-agent.sh spawn to guard" > "/dev/stderr"
      bad = 1
    }
    for (i = 1; i <= stuck_spawn_n; i++) {
      if (stuck_spawn[i] <= skip_cont) {
        print "stuck-PR dev-agent.sh spawn at line " stuck_spawn[i] " is not after the non-dev continue" > "/dev/stderr"
        bad = 1
      }
    }
    if (exhaust_n+0 < 1) {
      print "stuck-PR scan has no handle_ci_exhaustion to guard" > "/dev/stderr"
      bad = 1
    }
    for (j = 1; j <= exhaust_n; j++) {
      if (exhaust_at[j] <= skip_cont) {
        print "handle_ci_exhaustion at line " exhaust_at[j] " is not after the non-dev continue" > "/dev/stderr"
        bad = 1
      }
    }
    exit bad
  }
' "$POLL_SH" || ac_fail "stuck-PR scan still merges or relaunches a non-dev-labeled issue"

ac_log "dev/AGENTS.md names the #1825 continue"
grep -qF 'the in-progress scan `continue`s past that issue (#1825)' "$AGENTS_DOC" \
  || ac_fail "dev/AGENTS.md must say the in-progress scan continues past a non-dev label (#1825)"
grep -qF "awaiting-live-verification" "$AGENTS_DOC" \
  || ac_fail "dev/AGENTS.md must still name awaiting-live-verification as a skipped label"
grep -qF "stuck-PR scan skips the same non-dev label" "$AGENTS_DOC" \
  || ac_fail "dev/AGENTS.md must say the stuck-PR scan also skips a non-dev label (#1825)"

ac_pass "issue #1825: non-dev skip continues the in-progress scan and the stuck-PR scan before any merge or dev-agent spawn"
