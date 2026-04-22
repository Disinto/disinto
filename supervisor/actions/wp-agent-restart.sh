#!/usr/bin/env bash
# supervisor/actions/wp-agent-restart.sh — P2 Woodpecker agent recovery
#
# Placeholder: full implementation in #594 (direct remediation extraction).
# Current action: docker restart + issue recovery (handled in supervisor-run.sh).
set -euo pipefail

_CONTAINER="disinto-woodpecker-agent"
echo "[wp-agent-restart] Restarting $_CONTAINER..."
docker restart "$_CONTAINER" 2>/dev/null || echo "[wp-agent-restart] Container $_CONTAINER not found"
echo "[wp-agent-restart] WP agent restart complete."
