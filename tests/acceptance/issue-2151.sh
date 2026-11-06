#!/usr/bin/env bash
# =============================================================================
# tests/acceptance/issue-2151.sh — the gardener's job also runs the planner
#
# Issue #2151: no live job runs the planner. The four agent jobs pin
# AGENT_ROLES to dev, review, gardener and supervisor; the job that ran the
# planner (the Grok one) was removed on 2026-11-01 (#2001), so nothing pitches
# the next sprint once the backlog empties. The gardener's job already renders
# FORGE_PLANNER_TOKEN and the local model server has no slot cap since
# 2026-11-01, so the planner rides that job: AGENT_ROLES = "gardener,planner".
#
# Read-only checks against the checkout (plus the two existing gardener-job
# tests, re-run here):
#   1. agents-gardener-qwen.hcl pins AGENT_ROLES = "gardener,planner" exactly
#      once.
#   2. Among nomad/jobs/*.hcl other than agents.hcl, exactly one file has an
#      AGENT_ROLES line containing "planner" — that file is the gardener job.
#   3. The gardener job still renders FORGE_PLANNER_TOKEN from
#      kv/data/disinto/bots/planner.
#   4. docker/agents/entrypoint.sh still gates the planner rung on AGENT_ROLES.
#   5. nomad/AGENTS.md and planner/AGENTS.md say the planner runs in the
#      gardener's job.
#   6. issue-1123-gardener-job.sh and issue-1357.sh pass.
#
# Run via: tools/run-acceptance.sh 2151
# Last stdout line is PASS or FAIL: <reason>.
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../lib/acceptance-helpers.sh
source "$REPO_ROOT/tests/lib/acceptance-helpers.sh"

ac_require_cmd bash grep awk

GQ="$REPO_ROOT/nomad/jobs/agents-gardener-qwen.hcl"
EP="$REPO_ROOT/docker/agents/entrypoint.sh"

ac_assert_file "$GQ" "jobspec nomad/jobs/agents-gardener-qwen.hcl must exist"
ac_assert_file "$EP" "docker/agents/entrypoint.sh must exist"

# ── AC1: the gardener job pins gardener,planner exactly once ─────────────────
ac_log "AC1: AGENT_ROLES = \"gardener,planner\" appears exactly once"
pins="$(grep -cE '^[[:space:]]*AGENT_ROLES[[:space:]]*=[[:space:]]*"gardener,planner"' "$GQ" || true)"
ac_assert_eq "$pins" "1" \
  "agents-gardener-qwen.hcl must pin AGENT_ROLES = \"gardener,planner\" exactly once (got $pins)"

# The header documents the two roles it pins.
grep -qF 'with AGENT_ROLES' "$GQ" \
  || ac_fail "the jobspec header must name the AGENT_ROLES it pins"
grep -qF '"gardener,planner". Runs against the local llama-server' "$GQ" \
  || ac_fail "the header must say the job runs AGENT_ROLES \"gardener,planner\""

# ── AC2: exactly one per-role job carries the planner ────────────────────────
ac_log "AC2: among nomad/jobs/*.hcl other than agents.hcl, exactly one carries a planner role"
planner_jobs="$(awk '
  /^[[:space:]]*AGENT_ROLES[[:space:]]*=/ && /planner/ { print FILENAME }
' "$REPO_ROOT"/nomad/jobs/*.hcl \
  | grep -v '/agents\.hcl$' \
  | sort -u)"
count="$(printf '%s\n' "$planner_jobs" | awk 'NF { n++ } END { print n + 0 }')"
ac_assert_eq "$count" "1" \
  "exactly one jobspec besides agents.hcl may list the planner role (got '$planner_jobs')"
ac_assert_eq "$planner_jobs" "$GQ" \
  "the planner-riding jobspec must be agents-gardener-qwen.hcl (got '$planner_jobs')"

# ── AC3: the planner token is still rendered from the planner bot's KV path ──
ac_log "AC3: FORGE_PLANNER_TOKEN rendered from kv/data/disinto/bots/planner"
grep -q 'secret "kv/data/disinto/bots/planner"' "$GQ" \
  || ac_fail "the gardener job must still read the planner bot token from kv/data/disinto/bots/planner"
grep -q 'FORGE_PLANNER_TOKEN={{ .Data.data.token }}' "$GQ" \
  || ac_fail "the gardener job must render FORGE_PLANNER_TOKEN from the Vault template"

# ── AC4: the entrypoint still starts the planner off AGENT_ROLES ──────────────
ac_log "AC4: entrypoint.sh planner rung is gated on AGENT_ROLES and runs planner-run.sh"
grep -qF '== *",planner,"*' "$EP" \
  || ac_fail "entrypoint.sh must gate the planner rung on AGENT_ROLES containing planner"
grep -q 'planner/planner-run.sh' "$EP" \
  || ac_fail "entrypoint.sh must start planner/planner-run.sh on the planner rung"
grep -qF 'The planner shares this job (#2151)' "$GQ" \
  || ac_fail "the jobspec header must record that the planner shares the gardener job (#2151)"

# ── AC5: the docs name the pairing ────────────────────────────────────────────
ac_log "AC5: nomad/AGENTS.md and planner/AGENTS.md name the planner in the gardener job"
grep -qF 'and, since #2151, the' "$REPO_ROOT/nomad/AGENTS.md" \
  || ac_fail "nomad/AGENTS.md must describe the gardener job as running the gardener and, since #2151, the planner"
grep -qF "of the gardener's job" "$REPO_ROOT/planner/AGENTS.md" \
  || ac_fail "planner/AGENTS.md must say the polling loop is the gardener's job"
grep -qF 'agents-gardener-qwen.hcl' "$REPO_ROOT/planner/AGENTS.md" \
  || ac_fail "planner/AGENTS.md must cite nomad/jobs/agents-gardener-qwen.hcl for #2151"

# ── AC6: the existing gardener-job tests still pass ───────────────────────────
ac_log "AC6: issue-1123 and issue-1357 pass against the two-role gardener job"
rc=0
bash "$REPO_ROOT/tests/acceptance/issue-1123-gardener-job.sh" >/dev/null || rc=$?
ac_assert_eq "$rc" "0" "issue-1123-gardener-job.sh must pass (rc=$rc)"
rc=0
bash "$REPO_ROOT/tests/acceptance/issue-1357.sh" >/dev/null || rc=$?
ac_assert_eq "$rc" "0" "issue-1357.sh must pass (rc=$rc)"

ac_pass
