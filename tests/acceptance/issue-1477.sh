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
#   - formulas/run-planner.toml : delete the "Memory update (every 5th run)"
#     step from the commit-ops-changes step; remove knowledge/planner-memory.md
#     from the `git add` line; leave prerequisites.md and vault/pending/
#     untouched.
#   - planner/planner-run.sh   : do not read knowledge/planner-memory.md and do
#     not insert it into PROMPT; delete the MEMORY_BLOCK construction.
#
# Acceptance criteria (grep the two files for the removed strings):
#   1. run-planner.toml has no "Memory update" step.
#   2. run-planner.toml does not `git add` knowledge/planner-memory.md
#      (the `git add` line carries only prerequisites.md + vault/pending/).
#   3. run-planner.toml still writes prerequisites.md and adds vault/pending/.
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

# The `git add` line must carry exactly the unchanged operands (tree + vault),
# with no planner-memory.md operand (checked separately above).
if ! grep -Fq "git add prerequisites.md vault/pending/" "$TOML"; then
  ac_fail "run-planner.toml git add no longer adds 'prerequisites.md vault/pending/'"
fi

# ── 3. run-planner.toml: prerequisites.md write + vault/pending/ intact ──────
ac_log "checking run-planner.toml still writes tree + vault/pending"
if ! grep -Fq "Write to: \$OPS_REPO_ROOT/prerequisites.md" "$TOML"; then
  ac_fail "run-planner.toml no longer writes prerequisites.md (changed)"
fi
if ! grep -Fq "vault/pending/" "$TOML"; then
  ac_fail "run-planner.toml no longer adds vault/pending/ (changed)"
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
