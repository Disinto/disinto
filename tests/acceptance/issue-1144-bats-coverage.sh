#!/usr/bin/env bash
# =============================================================================
# tests/acceptance/issue-1144-bats-coverage.sh
#
# Issue #1144: CI ran only one of the sixteen bats suites
# (tests/disinto-init-nomad.bats, via .woodpecker/nomad-validate.yml), so the
# other fifteen could fail indefinitely without turning any pipeline red.
#
# The fix adds a `bats` step to .woodpecker/ci.yml that runs every
# tests/*.bats file by glob discovery, so a new suite is covered the moment
# it lands and any failing suite fails the pipeline.
#
# This test is read-only: it parses .woodpecker/ci.yml and asserts that
#   1. a `bats` step exists,
#   2. it discovers suites with a glob (bats tests/*.bats) rather than
#      listing individual .bats files, and
#   3. it carries no failure-suppressing suffix (no `|| true` / `|| :` /
#      `|| exit 0` / `; true`), so a failing suite turns the pipeline red.
#
# It touches no repo state — it only reads the pipeline definition.
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck disable=SC1091
source "$REPO_ROOT/tests/lib/acceptance-helpers.sh"

ac_require_cmd awk grep

CI_FILE="$REPO_ROOT/.woodpecker/ci.yml"
ac_assert_file "$CI_FILE" ".woodpecker/ci.yml must exist"

# Extract the `bats` step block: from its `  - name: bats` line until the
# next step (a `  - name:` line at the same indent) or end of file. Comments
# preceding the step are excluded because in_step is only set on the name
# line itself.
STEP_BLOCK="$(awk '
  {
    if (in_step && $0 ~ /^  - name:/ && $0 !~ /^  - name:[[:space:]]*bats[[:space:]]*$/) {
      in_step = 0
    }
    if ($0 ~ /^  - name:[[:space:]]*bats[[:space:]]*$/) {
      in_step = 1
    }
    if (in_step) print
  }
' "$CI_FILE")"

# ── AC 1: a bats step exists ────────────────────────────────────────────────
ac_log "checking .woodpecker/ci.yml declares a bats step"
[ -n "$STEP_BLOCK" ] \
  || ac_fail "no 'bats' step found in .woodpecker/ci.yml"

# ── AC 2: suites are discovered by glob, not listed ─────────────────────────
ac_log "checking the bats step discovers suites by glob"
if ! printf '%s\n' "$STEP_BLOCK" | grep -Eq 'bats[[:space:]]+tests/.*\*\.bats'; then
  ac_fail "bats step does not invoke bats with a tests/ glob (expected e.g. 'bats tests/*.bats')"
fi
if printf '%s\n' "$STEP_BLOCK" | grep -Eq 'tests/[A-Za-z0-9_.-]+\.bats'; then
  ac_fail "bats step lists individual .bats files instead of discovering them by glob"
fi

# ── AC 3: no failure-suppressing suffix ─────────────────────────────────────
ac_log "checking the bats step cannot swallow a failing suite"
if printf '%s\n' "$STEP_BLOCK" \
  | grep -Eq '\|\|[[:space:]]*(true|:|exit[[:space:]]+0)\b|;[[:space:]]*true\b'; then
  ac_fail "bats step carries a failure-suppressing suffix (|| true / || : / || exit 0 / ; true)"
fi

ac_pass
