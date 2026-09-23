#!/usr/bin/env bash
# =============================================================================
# tests/acceptance/issue-1480.sh
#
# Issue #1480: docs(gardener): the poll runs gardener-run.sh, not classify.sh.
#
# The gardener poll (docker/agents/entrypoint.sh) starts only
# gardener/gardener-run.sh. The old comments claimed otherwise:
#   - nomad/jobs/agents-gardener-qwen.hcl said its poll ran "classify.sh findings"
#   - docs/AGENTS.md called gardener-step.sh a "polling-loop participant"
#   - gardener/gardener-step.sh's header implied it was started by the poll
# This is a docs/comment fix only — no behavior change, and classify.sh must
# remain on disk (still referenced by the unscheduled ranker, #989, and the
# deploy-drift acceptance test, #1119).
#
# Acceptance (read-only — no live services, no agents started; the three files
# are grepped from the repo):
#   1. nomad/jobs/agents-gardener-qwen.hcl: the poll runs gardener/gardener-run.sh,
#      not classify.sh (hcl comment, #1480)
#   2. docs/AGENTS.md: gardener-step.sh is not called a polling-loop participant
#      and classify.sh is not on the scheduler
#   3. gardener/gardener-step.sh: header notes it is not started by
#      docker/agents/entrypoint.sh
#   4. classify.sh is still in the tree
#   5. docker/agents/entrypoint.sh is unchanged (still the sole starter of
#      gardener/gardener-run.sh on the poll)
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck disable=SC1091
source "$REPO_ROOT/tests/lib/acceptance-helpers.sh"

ac_require_cmd grep

HCL="$REPO_ROOT/nomad/jobs/agents-gardener-qwen.hcl"
DOCS="$REPO_ROOT/docs/AGENTS.md"
STEP="$REPO_ROOT/gardener/gardener-step.sh"
CLASSIFY="$REPO_ROOT/gardener/classify.sh"
ENTRYPOINT="$REPO_ROOT/docker/agents/entrypoint.sh"

# ── 1. HCL: the poll runs gardener-run.sh, not classify.sh ────────────────────

ac_assert_file "$HCL" "nomad/jobs/agents-gardener-qwen.hcl must exist"
if grep -F 'not classify.sh (#1480)' "$HCL" | grep -q 'gardener/gardener-run.sh'; then
  ac_log "AC 1 OK: HCL states the poll runs gardener/gardener-run.sh, not classify.sh"
else
  ac_fail "HCL must state 'the poll runs gardener/gardener-run.sh, not classify.sh (#1480)'"
fi
# The stale claim must be gone.
if grep -qF 'its classify.sh findings (including the deploy-drift check, #1119) run' "$HCL"; then
  ac_fail "stale HCL comment 'its classify.sh findings ... run' still present"
fi

# ── 2. docs/AGENTS.md: gardener-step.sh / classify.sh not on the scheduler ───

ac_assert_file "$DOCS" "docs/AGENTS.md must exist"
if grep -qF 'gardener-step.sh — polling-loop participant' "$DOCS" \
   || grep -qF 'gardener-step.sh: polling-loop participant' "$DOCS"; then
  ac_fail "docs/AGENTS.md still calls gardener-step.sh a polling-loop participant"
fi
if grep -qF 'classify.sh — bash-only task classifier (emits JSON)' "$DOCS"; then
  ac_fail "docs/AGENTS.md still lists classify.sh without the 'not on the scheduler' note"
fi
# The gardener tree is a multi-line entry in the tree block — each script name
# appears on its own line with "not started by entrypoint.sh" notes on the
# following lines.
if ! grep -qF 'gardener-step.sh — per-iteration step' "$DOCS"; then
  ac_fail "docs/AGENTS.md must describe gardener-step.sh as the per-iteration step executor"
fi
# Check both notes are present in the gardener block (each entry is a multi-line
# entry; both "not started by entrypoint.sh" notes must appear with "#1480" on
# or near the same entry).
# Both notes are present in the gardener tree (multi-line entries in the
# tree block; check that "not started by entrypoint.sh" appears and
# "#1480" is referenced in the same tree block).
if ! grep -qF 'not started by entrypoint.sh' "$DOCS"; then
  ac_fail "docs/AGENTS.md must note that gardener-step.sh/classify.sh are not started by entrypoint.sh"
fi
if ! grep -qF '#1480' "$DOCS"; then
  ac_fail "docs/AGENTS.md must reference #1480 in the gardener tree notes"
fi
if ! grep -qF 'classify.sh — bash-only task classifier' "$DOCS"; then
  ac_fail "docs/AGENTS.md must still list classify.sh as the bash-only task classifier (not deleted, #1119)"
fi
ac_log "AC 2 OK: docs/AGENTS.md no longer lists gardener-step.sh/classify.sh as scheduler participants"

# ── 3. gardener/gardener-step.sh header: not started by entrypoint.sh ─────────

ac_assert_file "$STEP" "gardener/gardener-step.sh must exist"
if ! grep -F 'Not started by docker/agents/entrypoint.sh' "$STEP"; then
  ac_fail "gardener/gardener-step.sh header must say it is not started by docker/agents/entrypoint.sh"
fi
if ! grep -qF 'gardener/gardener-run.sh only' "$STEP"; then
  ac_fail "gardener/gardener-step.sh header must note the poll runs gardener/gardener-run.sh only (#1480)"
fi
ac_log "AC 3 OK: header notes the poll runs gardener/gardener-run.sh only (#1480)"

# ── 4. classify.sh is still in the tree ───────────────────────────────────────

ac_assert_file "$CLASSIFY" "gardener/classify.sh must still exist (referenced by #989 / #1119)"
ac_log "AC 4 OK: gardener/classify.sh still in tree (unscheduled ranker, not deleted)"

# ── 5. entrypoint.sh unchanged: gardener-run.sh is the poll starter ───────────

ac_assert_file "$ENTRYPOINT" "docker/agents/entrypoint.sh must exist"
if ! grep -F 'gardener/gardener-run.sh' "$ENTRYPOINT"; then
  ac_fail "entrypoint.sh no longer runs gardener/gardener-run.sh on the GARDENER_INTERVAL"
fi
# entrypoint.sh must NOT start gardener-step.sh or classify.sh (that would be
# "fixing" it by scheduling the dead ranker — explicitly out of scope).
if grep -qF 'gardener-step.sh' "$ENTRYPOINT"; then
  ac_fail "entrypoint.sh must not start gardener/gardener-step.sh (#1480 is docs only)"
fi
if grep -qF 'classify.sh' "$ENTRYPOINT"; then
  ac_fail "entrypoint.sh must not start gardener/classify.sh (#1480 is docs only)"
fi
ac_log "AC 5 OK: entrypoint.sh runs only gardener/gardener-run.sh on the poll"

echo PASS
