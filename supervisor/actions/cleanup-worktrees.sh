#!/usr/bin/env bash
# supervisor/actions/cleanup-worktrees.sh — P4 stale worktree cleanup
#
# Placeholder: full implementation in #594 (direct remediation extraction).
# Current action: git worktree remove/prune.
set -euo pipefail

FACTORY_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PROJECT_REPO="${WORKTREE_ROOT:-$FACTORY_ROOT}"

echo "[cleanup-worktrees] Pruning stale worktrees..."
git -C "$PROJECT_REPO" worktree prune 2>/dev/null || true
echo "[cleanup-worktrees] Worktree pruning complete."
