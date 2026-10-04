#!/usr/bin/env bash
# =============================================================================
# tests/acceptance/issue-1728.sh
#
# Issue #1728: disinto-factory/operations.md told operators that a CI timeout
# labels the issue `blocked` and to close the PR, and told them to
# `nomad job restart agents` — a job that is not the live per-role agent job.
#
# Since #1705 a CI timeout is not terminal: the issue stays `in-progress`,
# assigned, and dev-poll keeps the open PR. Only a terminal walk reason
# (CI fix budget exhausted, review rounds exhausted, merge blocked, no push)
# labels the issue `blocked`.
#
# This test is read-only: it greps the "Unstick a blocked issue" section and
# the restart commands. It does not mutate the doc or talk to a forge.
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck disable=SC1091
source "$REPO_ROOT/tests/lib/acceptance-helpers.sh"

ac_require_cmd grep

OPS_MD="$REPO_ROOT/disinto-factory/operations.md"
ac_assert_file "$OPS_MD" "docs file missing: $OPS_MD"

# Section runs from the heading through the line before the next ### heading.
section="$(awk '
  /^### Unstick a blocked issue$/ { capture = 1; print; next }
  capture && /^### / { exit }
  capture { print }
' "$OPS_MD")"
[ -n "$section" ] || ac_fail "operations.md has no 'Unstick a blocked issue' section"

ac_log "CI timeout is not listed as a cause of blocked"
# The old opening named a CI timeout inside the failure that labels the issue
# blocked. The replacement says a timeout is not terminal, so a hit on the old
# parenthetical — or on "CI timeout" before "labeled blocked" — is a regression.
if printf '%s\n' "$section" | grep -qF 'fails (CI timeout'; then
  ac_fail "Unstick section still lists a CI timeout as a cause of blocked"
fi
label_clause="$(printf '%s\n' "$section" | sed 's/A CI timeout is not terminal.*//' | grep -F 'labeled `blocked`' || true)"
[ -n "$label_clause" ] || ac_fail "Unstick section does not say when the issue is labeled blocked"
if printf '%s\n' "$label_clause" | grep -q 'CI timeout'; then
  ac_fail "the blocked-label clause still names a CI timeout: $label_clause"
fi

ac_log "CI timeout leaves the issue in-progress with its PR open"
printf '%s\n' "$section" | grep -qF 'A CI timeout is not terminal' \
  || ac_fail "Unstick section does not say a CI timeout is not terminal"
printf '%s\n' "$section" | grep -qF 'stays `in-progress`' \
  || ac_fail "Unstick section does not say a CI timeout leaves the issue in-progress"
printf '%s\n' "$section" | grep -qF 'open PR' \
  || ac_fail "Unstick section does not say the PR stays open after a CI timeout"
printf '%s\n' "$section" | grep -qF 'do not close that PR' \
  || ac_fail "Unstick section does not warn against closing the CI-timeout PR"

ac_log "Nomad restart names a per-role agent job, not the bare agents job"
if grep -nE 'nomad job restart agents([^-]|$)' "$OPS_MD"; then
  ac_fail "operations.md still restarts a job named agents"
fi
printf '%s\n' "$section" | grep -qF 'nomad job restart <the agent'"'"'s job, e.g. agents-dev-qwen>' \
  || ac_fail "Nomad step 2 does not restart <the agent's job, e.g. agents-dev-qwen>"

ac_pass
