#!/usr/bin/env bash
# supervisor/actions/cleanup-worktrees.sh — P4 stale worktree cleanup
#
# No-op since #1082: the project clone is shared across dev/review/supervisor
# containers that each have their own /tmp. From any one container the other
# containers' live worktrees look "missing", so a blanket `git worktree prune`
# here was destroying their registrations and jamming their next run.
# Worktrees are reclaimed at claim time instead: `worktree_cleanup` /
# `worktree_clear_stale` in lib/worktree.sh clear only the registration of
# the exact path about to be claimed.
set -euo pipefail

echo '[cleanup-worktrees] No-op: blanket "git worktree prune" is unsafe on the shared clone (see #1082); stale worktrees are reclaimed at claim time by lib/worktree.sh'
