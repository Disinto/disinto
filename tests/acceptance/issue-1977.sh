#!/usr/bin/env bash
# =============================================================================
# tests/acceptance/issue-1977.sh
#
# Issue #1977: retire the prose planning formula.
#
# formulas/run-planner.toml is one step, propose. It writes at most one pitch
# file, or nothing. It does not file an issue, does not pitch an access
# request, and does not name the retired prose-planning strings.
#
# Hermetic: pure grep. No network, no live services, no env vars.
#
# Acceptance: `bash tests/acceptance/issue-1977.sh` exits 0 and calls ac_pass.
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=../../tests/lib/acceptance-helpers.sh
source "$REPO_ROOT/tests/lib/acceptance-helpers.sh"

ac_require_cmd grep
ac_assert_file "$REPO_ROOT/formulas/run-planner.toml" "formulas/run-planner.toml is missing"
ac_assert_file "$REPO_ROOT/planner/AGENTS.md" "planner/AGENTS.md is missing"

TOML="$REPO_ROOT/formulas/run-planner.toml"
DOC="$REPO_ROOT/planner/AGENTS.md"

ac_log "formula is one propose step and refuses filing"
grep -qE '^id[[:space:]]*=[[:space:]]*"propose"' "$TOML" \
  || ac_fail "formulas/run-planner.toml must have step id propose"
grep -qF 'Do not file an issue.' "$TOML" \
  || ac_fail "formulas/run-planner.toml must contain 'Do not file an issue.'"
grep -qF 'It is not an access request.' "$TOML" \
  || ac_fail "formulas/run-planner.toml must contain 'It is not an access request.'"
grep -qF 'PLANNER_PROBE_FILE' "$TOML" \
  || ac_fail "formulas/run-planner.toml must name PLANNER_PROBE_FILE"
grep -qF 'Planner: propose one sprint pitch, or nothing' "$TOML" \
  || ac_fail "formulas/run-planner.toml description must be the v5 pitch line"
grep -qE '^version[[:space:]]*=[[:space:]]*5$' "$TOML" \
  || ac_fail "formulas/run-planner.toml version must be 5"
if grep -qE '^model[[:space:]]*=' "$TOML"; then
  ac_fail "formulas/run-planner.toml must not set model"
fi
if grep -E 'prerequisites\.md|tea_file_issue|prediction/unreviewed|vault/pending' "$TOML"; then
  ac_fail "formulas/run-planner.toml still names a retired prose-planning string"
fi
if grep -cE '^id[[:space:]]*=' "$TOML" | grep -qx '1'; then
  :
else
  ac_fail "formulas/run-planner.toml must have exactly one step id"
fi

ac_log "planner/AGENTS.md names the one-step formula and the retired tree"
grep -qF 'has one step, **propose**' "$DOC" \
  || ac_fail "planner/AGENTS.md must describe the one propose step"
grep -qF 'PLANNER_PITCH_FILE' "$DOC" \
  || ac_fail "planner/AGENTS.md must name PLANNER_PITCH_FILE"
grep -qF 'Retired. The planner does not read or write it.' "$DOC" \
  || ac_fail "planner/AGENTS.md must retire the prerequisite tree"
grep -qF 'The planner pitches one sprint or writes nothing.' "$DOC" \
  || ac_fail "planner/AGENTS.md must say the planner pitches one sprint or writes nothing"

ac_pass
