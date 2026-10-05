#!/usr/bin/env bash
# =============================================================================
# tests/acceptance/issue-1798.sh — subdomain registration no longer adds a
# chat.<project> route
#
# Issue #1798: do_register() registers forge.<project> and ci.<project> only,
# and no longer returns subdomains.chat. The fallback plan no longer documents
# chat. Deregister still removes a leftover chat route from older registrations.
#
# Read-only: grep and bash -n. No live box.
#
# Acceptance: `bash tests/acceptance/issue-1798.sh` exits 0 and prints PASS.
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
cd "$REPO_ROOT"

# shellcheck disable=SC1091
source "$REPO_ROOT/tests/lib/acceptance-helpers.sh"

ac_require_cmd grep bash

ac_log "checking do_register iterates forge and ci only"
count="$(grep -c 'for subdomain in forge ci; do' tools/edge-control/register.sh || true)"
if [ "$count" != "1" ]; then
  ac_fail "expected exactly one 'for subdomain in forge ci; do', got ${count}"
fi

ac_log "checking register.sh does not emit chat.\${project}"
# shellcheck disable=SC2016  # literal ${project}, matching the issue's grep -nF
if grep -nF 'chat.${project}' tools/edge-control/register.sh; then
  ac_fail "register.sh still contains chat.\${project}"
fi

ac_log "checking the fallback plan does not mention chat"
if grep -ni chat docs/edge-routing-fallback.md; then
  ac_fail "docs/edge-routing-fallback.md still mentions chat"
fi

ac_log "checking register.sh parses (bash -n)"
bash -n tools/edge-control/register.sh || ac_fail "bash -n tools/edge-control/register.sh failed"

echo PASS
