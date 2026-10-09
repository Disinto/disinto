#!/usr/bin/env bash
# =============================================================================
# tests/acceptance/issue-1973.sh
#
# Issue #1973: nomad/jobs/healer.hcl must document the real owner-notify
# sender, not a removed function. The pre-#1972 jobspec comment named the
# pre-rewrite function (notify_owner) and its old log line (notify: not
# configured). After #1972 the real sender is bin/notify-owner.sh, which
# logs "notify-owner: not configured" (exit 0) when a Telegram env var is
# missing.
#
# Accepts:
#   * healer.hcl no longer references the removed notify_owner function.
#   * healer.hcl names bin/notify-owner.sh and the real log line
#     "notify-owner: not configured".
#   * No other jobspec or doc in the repo still references the removed
#     notify_owner name.
#
# Read-only: greps healer.hcl and the repo. No job submit, no socket.
# Runs offline; no forge/nomad/daemon env required.
#
# Run via: tools/run-acceptance.sh 1973
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck disable=SC1091
source "$REPO_ROOT/tests/lib/acceptance-helpers.sh"

ac_require_cmd git grep

SPEC="$REPO_ROOT/nomad/jobs/healer.hcl"
ac_assert_file "$SPEC" "nomad/jobs/healer.hcl must exist"

ac_log "healer.hcl must not reference the removed notify_owner function"
if git -C "$REPO_ROOT" grep -q 'notify_owner' -- "$SPEC"; then
  ac_fail "nomad/jobs/healer.hcl must not reference removed function notify_owner"
fi

ac_log "healer.hcl must name the real sender bin/notify-owner.sh"
grep -qF 'bin/notify-owner.sh' "$SPEC" \
  || ac_fail "nomad/jobs/healer.hcl must reference bin/notify-owner.sh"

ac_log "healer.hcl must cite the real log line"
grep -qF -- 'notify-owner: not configured' "$SPEC" \
  || ac_fail "nomad/jobs/healer.hcl must log 'notify-owner: not configured'"

ac_log "no jobspec may still reference the removed notify_owner name"
jobspec_hits="$(git -C "$REPO_ROOT" grep -n 'notify_owner' -- nomad/ 2>/dev/null || true)"
[ -z "$jobspec_hits" ] \
  || ac_fail "nomad/ must not reference removed function notify_owner (got: $jobspec_hits)"

ac_log "no doc may still reference the removed notify_owner name"
doc_hits="$(git -C "$REPO_ROOT" grep -n 'notify_owner' -- '**/*.md' 2>/dev/null || true)"
[ -z "$doc_hits" ] \
  || ac_fail "docs must not reference removed function notify_owner (got: $doc_hits)"

echo PASS
