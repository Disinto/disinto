#!/usr/bin/env bash
# =============================================================================
# tests/acceptance/issue-1169-pr-walk-task-ref.sh
#
# Issue #1169: every PR-walk session (the CI-fix, review-fix, and
# merge-conflict rebase paths in pr_walk_to_merge) called agent_run without
# --task, so metrics_record_run wrote task_ref: "" and 26-turn CI fixes were
# attributable to nothing in agent-runs.jsonl. `disinto stats` groups by role
# but not by task, so the cost of getting a PR through review was invisible.
#
# The fix: all three agent_run call sites in lib/pr-lifecycle.sh pass
# --task "$pr_num" (the PR number already in scope — no new variable
# plumbed), and lib/agent-metrics.sh records that task_ref mixes issue and
# PR numbers in one unprefixed namespace (fixing the ambiguity is a separate
# change — it would rewrite existing rows).
#
# Read-only: greps the call sites and the emitter comment from the checkout;
# no live services, no agent started.
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck disable=SC1091
source "$REPO_ROOT/tests/lib/acceptance-helpers.sh"

ac_require_cmd grep

LIFECYCLE="$REPO_ROOT/lib/pr-lifecycle.sh"
METRICS="$REPO_ROOT/lib/agent-metrics.sh"
ac_assert_file "$LIFECYCLE" "lib/pr-lifecycle.sh must exist"
ac_assert_file "$METRICS" "lib/agent-metrics.sh must exist"

# ── 1. Exactly three agent_run call sites exist in the walk ─────────────────
# One per path: CI-fix, merge-conflict rebase, review-feedback. The stub
# `agent_run() {` definition does not match (no --resume).
CALL_SITES=$(grep -cE '^[[:space:]]*agent_run --resume' "$LIFECYCLE")
ac_assert_eq "$CALL_SITES" 3 \
  "pr_walk_to_merge must have exactly three agent_run call sites (ci-fix, rebase, review-fix)"

# ── 2. Every call site passes --task "$pr_num" ──────────────────────────────
# --task must be on the same invocation line, with the PR number that is
# already in scope in pr_walk_to_merge (no new variable plumbed).
TASKED=$(grep -cE '^[[:space:]]*agent_run --resume .*--task[[:space:]]+"\$pr_num"' "$LIFECYCLE")
ac_assert_eq "$TASKED" 3 \
  "every agent_run call site must pass --task \"\$pr_num\""

# ── 3. The emitter records the namespace ambiguity ──────────────────────────
# task_ref holds either an issue number (dev-agent) or a PR number
# (review-pr, pr-walk), bare, with no prefix. The comment next to the
# emitter must record that a reader cannot tell which is which.
grep -q "cannot tell which is which" "$METRICS" \
  || ac_fail "lib/agent-metrics.sh must document that task_ref mixes issue and PR numbers"
grep -q "prefix" "$METRICS" \
  || ac_fail "lib/agent-metrics.sh must note a prefix scheme is deferred (would rewrite existing rows)"

ac_pass
