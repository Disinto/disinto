#!/usr/bin/env bash
# =============================================================================
# tests/acceptance/issue-1082-stale-worktree-registration.sh
#
# Issue #1082: a git worktree registration can outlive the worktree directory
# (a container restart wipes /tmp while the shared host-volume clone keeps
# the record under .git/worktrees/). `git worktree add` on that path then
# fails with exit 128 ("missing, but already registered") and blocks every
# future claim of the path — for reviews this jams the PR forever.
#
# The fix must clear a stale registration ONLY for the exact path about to
# be claimed (lib/worktree.sh: worktree_clear_stale, wired into
# worktree_cleanup). A blanket `git worktree prune` is NOT acceptable: the
# clone is shared with other containers whose live worktrees look "missing"
# from here and would be destroyed.
#
# Acceptance exercised here (self-contained, no live services needed):
#   1. A registration pointing at a deleted directory (stale) and a second
#      registration pointing at an existing directory (live) are set up.
#   2. Claiming the stale path succeeds (registration cleared, add works).
#   3. The live registration is untouched throughout (still listed, its
#      directory intact, still functional).
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT

# ── Build a throwaway clone with one commit ─────────────────────────────────

git init -q "$T/clone"
cd "$T/clone"
git -c user.name=acceptance -c user.email=acceptance@localhost \
  commit -q --allow-empty -m init
HEAD_SHA="$(git rev-parse HEAD)"

# ── Set up two worktrees: one to go stale, one to stay live ─────────────────

git worktree add "$T/wt-claim" "$HEAD_SHA" --detach >/dev/null 2>&1
git worktree add "$T/wt-live" "$HEAD_SHA" --detach >/dev/null 2>&1

# Simulate a container restart: the claim path's directory is gone, but the
# registration in the clone survives.
rm -rf "$T/wt-claim"

if ! git worktree list --porcelain | grep -qFx "worktree $T/wt-claim"; then
  echo "FAIL: setup did not leave a stale registration for $T/wt-claim"
  exit 1
fi

# ── Load the helper under test (no env.sh here; stub the log it needs) ──────

PROJECT_REPO_ROOT="$T/clone"
export PROJECT_REPO_ROOT
log() { :; }
# shellcheck disable=SC1091
source "$REPO_ROOT/lib/worktree.sh"

# ── Phase 1: worktree_clear_stale clears only the claimed path's registration

worktree_clear_stale "$T/wt-claim"

if git worktree list --porcelain | grep -qFx "worktree $T/wt-claim"; then
  echo "FAIL: worktree_clear_stale left the stale registration in place"
  exit 1
fi

if ! git worktree list --porcelain | grep -qFx "worktree $T/wt-live"; then
  echo "FAIL: worktree_clear_stale destroyed the live worktree registration"
  exit 1
fi
[ -d "$T/wt-live" ] || { echo "FAIL: live worktree directory was removed"; exit 1; }
git -C "$T/wt-live" rev-parse --git-dir >/dev/null \
  || { echo "FAIL: live worktree no longer functional"; exit 1; }

# Claiming the path now succeeds.
ADD_ERR="$(git worktree add "$T/wt-claim" "$HEAD_SHA" --detach 2>&1)" || {
  echo "FAIL: git worktree add failed on the reclaimed path (registration not cleared): $ADD_ERR"
  exit 1
}
if ! git worktree list --porcelain | grep -qFx "worktree $T/wt-claim"; then
  echo "FAIL: claimed path was not re-registered"
  exit 1
fi

# ── Phase 2: worktree_cleanup (dev-agent / worktree_create path) does the same

rm -rf "$T/wt-claim"
worktree_cleanup "$T/wt-claim"

if git worktree list --porcelain | grep -qFx "worktree $T/wt-claim"; then
  echo "FAIL: worktree_cleanup left the stale registration in place"
  exit 1
fi

ADD_ERR="$(git worktree add "$T/wt-claim" "$HEAD_SHA" --detach 2>&1)" || {
  echo "FAIL: git worktree add failed after worktree_cleanup (registration not cleared): $ADD_ERR"
  exit 1
}

# ── Final: the live worktree survived both phases ───────────────────────────

if ! git worktree list --porcelain | grep -qFx "worktree $T/wt-live"; then
  echo "FAIL: live worktree registration was destroyed by cleanup"
  exit 1
fi
[ -d "$T/wt-live" ] || { echo "FAIL: live worktree directory was removed"; exit 1; }
git -C "$T/wt-live" rev-parse --git-dir >/dev/null \
  || { echo "FAIL: live worktree no longer functional"; exit 1; }

echo PASS
