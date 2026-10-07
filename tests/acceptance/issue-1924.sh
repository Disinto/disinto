#!/usr/bin/env bash
# =============================================================================
# tests/acceptance/issue-1924.sh — supervisor checks the public forge and CI
#
# Issue #1924: the supervisor job must set PUBLIC_URLS so the #1923 check
# probes the public forge and CI URLs instead of reporting unconfigured.
#
# Read-only: greps nomad/jobs/agents-supervisor-opus.hcl. No job is
# dispatched, no network is reached.
#
# Acceptance: `bash tests/acceptance/issue-1924.sh` exits 0 and prints PASS.
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../lib/acceptance-helpers.sh
source "$REPO_ROOT/tests/lib/acceptance-helpers.sh"

ac_require_cmd grep

HCL="$REPO_ROOT/nomad/jobs/agents-supervisor-opus.hcl"
ac_assert_file "$HCL" "nomad/jobs/agents-supervisor-opus.hcl must exist"

ac_log "PUBLIC_URLS is the public forge and CI URLs, exactly once"
count="$(grep -cE '^ *PUBLIC_URLS *= *"https://self.disinto.ai/forge/ https://self.disinto.ai/ci/"' "$HCL" || true)"
ac_assert_eq "$count" "1" \
  "supervisor job must set PUBLIC_URLS to the public forge and CI URLs exactly once (got: ${count})"

ac_pass
