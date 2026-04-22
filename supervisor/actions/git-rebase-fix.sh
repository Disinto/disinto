#!/usr/bin/env bash
# supervisor/actions/git-rebase-fix.sh — P2 broken git rebase fix
#
# Placeholder: full implementation in #594 (direct remediation extraction).
# Current action: abort rebase and checkout primary branch.
set -euo pipefail

FACTORY_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"

echo "[git-rebase-fix] Aborting broken rebase..."
git -C "$FACTORY_ROOT" rebase --abort 2>/dev/null || true
echo "[git-rebase-fix] Git rebase fix complete."
