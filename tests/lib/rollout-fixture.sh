#!/usr/bin/env bash
# =============================================================================
# tests/lib/rollout-fixture.sh — shared fixture for the rollout acceptance
# tests (tools/rollout.sh)
#
# Sourced by tests/acceptance/issue-2114.sh and tests/acceptance/issue-2115.sh
# so the origin/clone fixture and its readers live in one place instead of
# being copy-pasted per test.
#
# Usage (after sourcing tests/lib/acceptance-helpers.sh):
#   rollout_fixture <name>   — fresh origin/clone pair: main at M2, live and
#                              canary at M1; sets ORIGIN, CLONE, TAPE_DIR, M1, M2
#   commit_on <branch> <msg> — one commit on <branch> in the clone, echo its SHA
#   origin_head <branch>     — the SHA origin has for <branch>, "missing" if absent
#   tape_count <type>        — how many records of <type> the tape holds
#
# These helpers read the globals WORK (the test's temp dir) and, for
# commit_on/origin_head/tape_count, the ORIGIN/CLONE/TAPE_DIR set by
# rollout_fixture.
# =============================================================================

# commit_on BRANCH MESSAGE — one commit on BRANCH in the clone $CLONE, echo its
# SHA. (The same shape issue-2112's fixture helper uses.)
commit_on() {
  local branch="$1" message="$2"
  if git -C "$CLONE" rev-parse --verify --quiet "refs/heads/$branch" >/dev/null; then
    git -C "$CLONE" checkout --quiet "$branch"
  elif git -C "$CLONE" rev-parse --verify --quiet HEAD >/dev/null; then
    git -C "$CLONE" checkout --quiet -b "$branch"
  fi
  printf '%s\n' "$message" >>"$CLONE/history.txt"
  git -C "$CLONE" add -A
  git -C "$CLONE" commit --quiet -m "$message"
  git -C "$CLONE" rev-parse HEAD
}

# rollout_fixture NAME — a fresh origin/clone pair: main at M2, live and canary
# at M1. Sets the globals ORIGIN, CLONE, TAPE_DIR, M1, M2.
rollout_fixture() {
  local name="$1"
  ORIGIN="$WORK/$name/origin"
  CLONE="$WORK/$name/clone"
  TAPE_DIR="$WORK/$name/tape"
  mkdir -p "$CLONE" "$TAPE_DIR/rollout/evidence"
  git init -b main --bare "$ORIGIN" >/dev/null
  git init -b main "$CLONE" >/dev/null
  git -C "$CLONE" config user.name "rollout-fixture"
  git -C "$CLONE" config user.email "rollout-fixture@example.com"
  git -C "$CLONE" remote add origin "$ORIGIN"

  M1="$(commit_on main "M1")"
  git -C "$CLONE" push --quiet origin main
  git -C "$CLONE" push --quiet origin "$M1:refs/heads/live" "$M1:refs/heads/canary"
  # shellcheck disable=SC2034  # M2 is consumed by the sourcing test file
  M2="$(commit_on main "M2")"
  git -C "$CLONE" push --quiet origin main
}

# origin_head BRANCH — the SHA origin has for BRANCH, "missing" if absent.
origin_head() {
  git -C "$ORIGIN" rev-parse "refs/heads/$1" 2>/dev/null || echo missing
}

# tape_count TYPE — how many records of TYPE the tape holds.
tape_count() {
  [ -r "$TAPE_DIR/tape.jsonl" ] || { echo 0; return; }
  jq -s --arg type "$1" '[.[] | select(.type == $type)] | length' "$TAPE_DIR/tape.jsonl"
}
