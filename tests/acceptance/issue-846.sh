#!/usr/bin/env bash
# =============================================================================
# tests/acceptance/issue-846.sh — fetch_alloc_logs uses HTTP API, not CLI
#
# Issue #846: bin/snapshot-agents.sh had fetch_alloc_logs() still calling the
# `nomad alloc logs` CLI with legacy `-token`/`-address`/`-timeout` flags that
# the deployed Nomad 1.9.5 no longer accepts. PR #845 already converted the
# `job list`/`alloc list` paths to the HTTP API; this fix completes the
# migration for the log-streaming path.
#
# Acceptance:
#   1. bin/snapshot-agents.sh::fetch_alloc_logs no longer invokes
#      `nomad alloc logs`.
#   2. fetch_alloc_logs uses the HTTP logs endpoint
#      (/v1/client/fs/logs/<alloc_id>).
#   3. shellcheck still passes on bin/snapshot-agents.sh.
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
cd "$REPO_ROOT"

target=bin/snapshot-agents.sh

[ -f "$target" ] || { echo "FAIL: $target missing"; exit 1; }

# Extract the body of fetch_alloc_logs (between the function header and the
# next top-level `}`). awk is sufficient: the function is at brace-depth 1.
fn_body="$(awk '
  /^fetch_alloc_logs\(\)/ { in_fn = 1; next }
  in_fn && /^\}/ { exit }
  in_fn { print }
' "$target")"

[ -n "$fn_body" ] \
  || { echo "FAIL: could not locate fetch_alloc_logs() in $target"; exit 1; }

# 1. Must not invoke the CLI.
if printf '%s\n' "$fn_body" | grep -qE '^[[:space:]]*nomad[[:space:]]+alloc[[:space:]]+logs\b'; then
  echo "FAIL: fetch_alloc_logs still calls 'nomad alloc logs' CLI"
  exit 1
fi

# 2. Must hit the HTTP logs endpoint.
if ! printf '%s\n' "$fn_body" | grep -q '/v1/client/fs/logs/'; then
  echo "FAIL: fetch_alloc_logs does not reference /v1/client/fs/logs/ HTTP endpoint"
  exit 1
fi

# 3. shellcheck must still pass.
if command -v shellcheck >/dev/null 2>&1; then
  shellcheck "$target" \
    || { echo "FAIL: shellcheck failed on $target"; exit 1; }
fi

echo PASS
