#!/usr/bin/env bash
# supervisor/actions/cleanup-locks.sh — P4 dead lock file cleanup
#
# Placeholder: full implementation in #594 (direct remediation extraction).
# Current action: remove lock files whose PID is no longer alive.
set -euo pipefail

echo "[cleanup-locks] Cleaning dead lock files..."
for _lf in /tmp/*-poll.lock /tmp/*-run.lock /tmp/dev-agent-*.lock; do
  [ -f "$_lf" ] || continue
  _pid=$(cat "$_lf" 2>/dev/null || true)
  [ -n "${_pid:-}" ] && kill -0 "$_pid" 2>/dev/null && continue
  rm -f "$_lf"
  echo "  Removed: $(basename "$_lf") (PID $_pid dead)"
done
echo "[cleanup-locks] Lock file cleanup complete."
