#!/usr/bin/env bash
# =============================================================================
# tests/acceptance/issue-1765.sh — agent jobs point dsh at the capped proxy
#
# Issue #1765: every disinto agent reaches llama-server through the
# think-budget proxy on the host (http://10.10.10.1:8088/v1). The per-role
# qwen and grok jobspecs must seed a missing settings.yaml with that
# address, not llama-server's own port (:8081), which skips the cap.
# The count is the current agents-*-qwen.hcl + agents-*-grok.hcl set
# (3 qwen + dev/review/architect/planner grok). A new file in either
# glob must be added here in the same change.
#
# Read-only: greps the jobspecs. Does not submit a job or open a socket.
#
# Acceptance: `bash tests/acceptance/issue-1765.sh` exits 0 and prints PASS.
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck disable=SC1091
source "$REPO_ROOT/tests/lib/acceptance-helpers.sh"

ac_require_cmd grep

JOBS_DIR="$REPO_ROOT/nomad/jobs"
PROXY_URL="http://10.10.10.1:8088/v1"

# Glob so a renamed file fails closed rather than silently dropping out.
mapfile -t SPECS < <(printf '%s\n' \
  "$JOBS_DIR"/agents-*-qwen.hcl \
  "$JOBS_DIR"/agents-*-grok.hcl | sort)

ac_assert_eq "${#SPECS[@]}" "7" \
  "expected 7 agent jobspecs (agents-*-qwen.hcl + agents-*-grok.hcl), found ${#SPECS[@]}"

for spec in "${SPECS[@]}"; do
  ac_assert_file "$spec" "agent jobspec missing: $spec"
done

ac_log "checking DSH_BASE_URL is the think-budget proxy in every qwen and grok jobspec"
hits="$(grep -n 'DSH_BASE_URL' "${SPECS[@]}")" || ac_fail "no DSH_BASE_URL lines in the qwen and grok jobspecs"

if printf '%s\n' "$hits" | grep -q '8081'; then
  ac_fail "DSH_BASE_URL lines must not mention llama-server :8081:
$hits"
fi

for spec in "${SPECS[@]}"; do
  base="$(basename "$spec")"
  grep -Eq '^[[:space:]]*DSH_BASE_URL[[:space:]]*=[[:space:]]*"http://10\.10\.10\.1:8088/v1"' "$spec" \
    || ac_fail "$base must set DSH_BASE_URL = \"$PROXY_URL\""
done

echo PASS
