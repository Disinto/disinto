#!/usr/bin/env bash
# supervisor/actions/memory-crisis.sh — P0 memory crisis remediation
#
# Placeholder: full implementation in #594 (direct remediation extraction).
# Current action: kill stale claude processes and drop caches.
set -euo pipefail

echo "[memory-crisis] Killing stale claude processes (>3h old)..."
pgrep -f "claude -p" --older 10800 2>/dev/null | xargs kill 2>/dev/null || true
echo "[memory-crisis] Dropping filesystem caches..."
if sync; then echo 3 | tee /proc/sys/vm/drop_caches >/dev/null 2>&1 || true; fi
echo "[memory-crisis] Memory crisis remediation complete."
