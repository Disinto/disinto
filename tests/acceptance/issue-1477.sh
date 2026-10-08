#!/usr/bin/env bash
# =============================================================================
# tests/acceptance/issue-1477.sh
#
# Issue #1477: stop the planner-memory rewrite loop.
#
# The planner used to rewrite knowledge/planner-memory.md every fifth run and
# the next run would `cat` that file into the prompt. That is "learning through
# prose, beside the tape" — §11 says the LLM does not write the statistics and
# a prompt stuffed with prior-run insights is not the policy.
#
# Fix (no new behavior):
#   - formulas/run-planner.toml : no "Memory update" step and no
#     planner-memory.md. The prose tree is retired (#1977): the formula
#     contains "Do not file an issue." and does not name prerequisites.md,
#     tea_file_issue, prediction/unreviewed, or vault/pending.
#   - planner/planner-run.sh   : do not read knowledge/planner-memory.md and do
#     not insert it into PROMPT; delete the MEMORY_BLOCK construction.
#
# Acceptance criteria (grep the two files for the removed strings):
#   1. run-planner.toml has no "Memory update" step.
#   2. run-planner.toml does not reference planner-memory.md.
#   3. run-planner.toml contains "Do not file an issue." and does not contain
#      prerequisites.md, tea_file_issue, prediction/unreviewed, or vault/pending.
#   4. planner-run.sh has no MEMORY_BLOCK construction (no read, no insert).
#   5. planner-run.sh does not reference knowledge/planner-memory.md.
#
# Hermetic: pure grep, no network, no live services, no env vars.
#
# Run via: tools/run-acceptance.sh 1477
#
# Last stdout line is PASS or FAIL: <reason>.
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../lib/acceptance-helpers.sh
source "$REPO_ROOT/tests/lib/acceptance-helpers.sh"

ac_require_cmd grep

TOML="$REPO_ROOT/formulas/run-planner.toml"
SHELL="$REPO_ROOT/planner/planner-run.sh"
ac_assert_file "$TOML" "formulas/run-planner.toml is missing"
ac_assert_file "$SHELL" "planner/planner-run.sh is missing"

# ── 1. run-planner.toml: no "Memory update" step ──────────────────────────────
ac_log "checking run-planner.toml has no Memory update step"
if grep -q "Memory update" "$TOML"; then
  ac_fail "run-planner.toml still contains a 'Memory update' step"
fi

# ── 2. run-planner.toml: does not `git add` knowledge/planner-memory.md ─────
ac_log "checking run-planner.toml git add excludes planner-memory.md"
if grep -Fq "planner-memory.md" "$TOML"; then
  ac_fail "run-planner.toml still references planner-memory.md (git add / read)"
fi

# The prose tree is retired (#1977). The formula refuses to file, and it
# does not name the old triage / tree / vault paths.
ac_log "checking run-planner.toml refuses filing and drops the prose tree"
if ! grep -Fq "Do not file an issue." "$TOML"; then
  ac_fail "run-planner.toml must contain 'Do not file an issue.'"
fi
if grep -E 'prerequisites.md|tea_file_issue|prediction/unreviewed|vault/pending' "$TOML"; then
  ac_fail "run-planner.toml still names the retired prose-planning strings"
fi

# ── 4. planner-run.sh: no MEMORY_BLOCK construction ──────────────────────────
ac_log "checking planner-run.sh has no MEMORY_BLOCK construction"
if grep -q "MEMORY_BLOCK" "$SHELL"; then
  ac_fail "planner-run.sh still constructs MEMORY_BLOCK (planner memory read)"
fi
if grep -Fq "planner-memory.md" "$SHELL"; then
  ac_fail "planner-run.sh still references knowledge/planner-memory.md"
fi

# ── 5. planner-run.sh: no cat of the memory file into the prompt ─────────────
if grep -Fq "cat \"\$OPS_REPO_ROOT/knowledge/planner-memory.md\"" "$SHELL" ||
   grep -Fq "cat \"\$MEMORY_FILE\"" "$SHELL"; then
  ac_fail "planner-run.sh still cats the planner memory file into the prompt"
fi

ac_pass
