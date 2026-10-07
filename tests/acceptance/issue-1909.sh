#!/usr/bin/env bash
# =============================================================================
# tests/acceptance/issue-1909.sh — run-architect drafts and revises sub-issues
#
# Issue #1909: formulas/run-architect.toml is the architect session's
# instructions for drafting or revising a pitch's sub-issues. Read-only:
# no forge, no network, no repo mutation.
#
# Verifies:
#   1. The step ids are ground draft lint reply, in that order.
#   2. The formula names the three paths, the linter, and the note.
#   3. The retired pitching flow is gone (no target-issue list, no pitch
#      budget, no one-shot harness invocation, no model key, no forge write).
#   4. architect/AGENTS.md names those four steps (#1909).
#
# Run via: tools/run-acceptance.sh 1909
# Last stdout line is PASS or FAIL: <reason>.
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck disable=SC1091
source "$REPO_ROOT/tests/lib/acceptance-helpers.sh"

ac_require_cmd python3
ac_require_cmd grep

FORMULA="$REPO_ROOT/formulas/run-architect.toml"
AGENTS="$REPO_ROOT/architect/AGENTS.md"

ac_assert_file "$FORMULA" "formulas/run-architect.toml is missing"
ac_assert_file "$AGENTS" "architect/AGENTS.md is missing"

ac_log "checking step ids are ground draft lint reply"
STEPS="$(python3 -c 'import sys,tomllib; d=tomllib.load(open(sys.argv[1],"rb")); print(" ".join(s["id"] for s in d["steps"]))' "$FORMULA")"
ac_assert_eq "$STEPS" "ground draft lint reply" \
  "expected step ids 'ground draft lint reply', got '${STEPS}'"

ac_log "checking the formula names the three paths, the linter, and the note"
for needle in PITCH_FILE BACKLOG_FILE COMMENT_FILE tools/pitch-lint.sh docs/design/notes/issue-writing.md; do
  grep -qF "$needle" "$FORMULA" \
    || ac_fail "formulas/run-architect.toml does not contain ${needle}"
done

ac_log "checking the retired pitching flow is gone"
RETIRED="$(grep -nE 'ARCHITECT_TARGET_ISSUES|pitch_budget|claude -p|^model|POST /repos' "$FORMULA" || true)"
[ -z "$RETIRED" ] \
  || ac_fail "retired pitching markers still in formulas/run-architect.toml: ${RETIRED}"

ac_log "checking architect/AGENTS.md names the four steps"
EXPECTED="$(cat <<'EOF'
- `ground`, `draft`, `lint`, `reply`: draft the sub-issues of a pitch that has none, or revise them on the owner's comments, by `docs/design/notes/issue-writing.md`; bash commits the pitch file and posts the reply (#1909)
EOF
)"
grep -qF -- "$EXPECTED" "$AGENTS" \
  || ac_fail "architect/AGENTS.md Formula section does not name the #1909 steps"

ac_pass
