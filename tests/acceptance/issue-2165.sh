#!/usr/bin/env bash
# =============================================================================
# tests/acceptance/issue-2165.sh — the gardener's job also runs the architect
#
# Issue #2165: no live job runs the architect since 2026-11-01, when #2001
# removed the Grok jobs (agents-architect-grok among them). Without the
# architect, no pitch gets a `<!-- filer:begin -->` block — the only writer of
# that block is the decompose state — so every pitch the planner opens stays
# open with no sub-issues (gate: tools/pitch-approve.sh, #2038). The gardener's
# job already renders FORGE_ARCHITECT_TOKEN and architect-run.sh does not pull
# the ops clone (no ensure_ops_repo), so it cannot collide with the gardener's
# pull (#2163): the architect joins that job with AGENT_ROLES =
# "gardener,planner,architect".
#
# Read-only checks against the checkout:
#   1. agents-gardener-qwen.hcl pins AGENT_ROLES = "gardener,planner,architect"
#      exactly once, and among nomad/jobs/*.hcl other than agents.hcl it is the
#      only jobspec carrying an architect role.
#   2. The gardener job still renders FORGE_ARCHITECT_TOKEN from
#      kv/data/disinto/bots/architect.
#   3. The jobspec header and the comment above AGENT_ROLES name the architect
#      and #2165.
#   4. docker/agents/entrypoint.sh still gates the architect rung on
#      AGENT_ROLES and runs architect/architect-run.sh on ARCHITECT_INTERVAL.
#   5. architect/AGENTS.md and nomad/AGENTS.md say the architect runs in the
#      gardener's job.
#
# Run via: tools/run-acceptance.sh 2165
# Last stdout line is PASS or FAIL: <reason>.
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../lib/acceptance-helpers.sh
source "$REPO_ROOT/tests/lib/acceptance-helpers.sh"

ac_require_cmd grep awk

JOBSPEC="$REPO_ROOT/nomad/jobs/agents-gardener-qwen.hcl"
RUNG="$REPO_ROOT/docker/agents/entrypoint.sh"

ac_assert_file "$JOBSPEC" "jobspec nomad/jobs/agents-gardener-qwen.hcl must exist"
ac_assert_file "$RUNG" "docker/agents/entrypoint.sh must exist"

# ── AC1: the gardener job pins gardener,planner,architect exactly once ────────
ac_log "AC1: AGENT_ROLES = \"gardener,planner,architect\" appears exactly once"
role_lines="$(grep -cE '^[[:space:]]*AGENT_ROLES[[:space:]]*=' "$JOBSPEC" || true)"
ac_assert_eq "$role_lines" "1" \
  "agents-gardener-qwen.hcl must set AGENT_ROLES exactly once (got $role_lines)"
pins="$(grep -cE '^[[:space:]]*AGENT_ROLES[[:space:]]*=[[:space:]]*"gardener,planner,architect"' "$JOBSPEC" || true)"
ac_assert_eq "$pins" "1" \
  "agents-gardener-qwen.hcl must pin AGENT_ROLES = \"gardener,planner,architect\" exactly once (got $pins)"

# The architect rides exactly one per-role job: the gardener's.
ac_log "AC1b: among nomad/jobs/*.hcl other than agents.hcl, exactly one carries the architect role"
architect_jobs="$(awk '
  /^[[:space:]]*AGENT_ROLES[[:space:]]*=/ && /architect/ { print FILENAME }
' "$REPO_ROOT"/nomad/jobs/*.hcl \
  | grep -v '/agents\.hcl$' \
  | sort -u)"
count="$(printf '%s\n' "$architect_jobs" | awk 'NF { n++ } END { print n + 0 }')"
ac_assert_eq "$count" "1" \
  "exactly one jobspec besides agents.hcl may list the architect role (got '$architect_jobs')"
ac_assert_eq "$architect_jobs" "$JOBSPEC" \
  "the architect-riding jobspec must be agents-gardener-qwen.hcl (got '$architect_jobs')"

# No other env value moved: the job still pins its lane and the live ref.
ac_log "AC1c: the rest of the env block is untouched (lane 50, FACTORY_REF live)"
grep -qE '^[[:space:]]*CLAUDE_AUTOCOMPACT_PCT_OVERRIDE[[:space:]]*=[[:space:]]*"50"' "$JOBSPEC" \
  || ac_fail "the autocompact lane must stay at 50"
grep -qE '^[[:space:]]*FACTORY_REF[[:space:]]*=[[:space:]]*"live"' "$JOBSPEC" \
  || ac_fail "the job must still follow live (FACTORY_REF, #2118)"

# ── AC2: the architect token is still rendered from the architect bot KV ──────
ac_log "AC2: FORGE_ARCHITECT_TOKEN rendered from kv/data/disinto/bots/architect"
grep -q 'secret "kv/data/disinto/bots/architect"' "$JOBSPEC" \
  || ac_fail "the gardener job must still read the architect bot token from kv/data/disinto/bots/architect"
grep -q 'FORGE_ARCHITECT_TOKEN={{ .Data.data.token }}' "$JOBSPEC" \
  || ac_fail "the gardener job must render FORGE_ARCHITECT_TOKEN from the Vault template"

# ── AC3: the jobspec comments name the architect ──────────────────────────────
ac_log "AC3: the header and the AGENT_ROLES comment name the architect and #2165"
grep -qF '"gardener,planner,architect". Runs against the local llama-server' "$JOBSPEC" \
  || ac_fail "the header must say the job runs AGENT_ROLES \"gardener,planner,architect\""
grep -qF 'The architect joins this job (#2165)' "$JOBSPEC" \
  || ac_fail "the jobspec header must record that the architect joins the gardener's job (#2165)"
grep -qF 'gardener plus planner (#2151) plus architect (#2165)' "$JOBSPEC" \
  || ac_fail "the comment above AGENT_ROLES must name all three roles"

# ── AC4: the entrypoint still starts the architect off AGENT_ROLES ─────────────
ac_log "AC4: entrypoint.sh architect rung is gated on AGENT_ROLES and runs architect-run.sh"
grep -qF '== *",architect,"*' "$RUNG" \
  || ac_fail "entrypoint.sh must gate the architect rung on AGENT_ROLES containing architect"
grep -q 'architect/architect-run.sh' "$RUNG" \
  || ac_fail "entrypoint.sh must start architect/architect-run.sh on the architect rung"
grep -qE 'ARCHITECT_INTERVAL="\$\{ARCHITECT_INTERVAL:-900\}"' "$RUNG" \
  || ac_fail "entrypoint.sh must default ARCHITECT_INTERVAL to 900 s"

# ── AC5: the docs name the pairing ────────────────────────────────────────────
ac_log "AC5: architect/AGENTS.md and nomad/AGENTS.md name the architect in the gardener job"
grep -qF "gardener's job (\`nomad/jobs/agents-gardener-qwen.hcl\`, #2165)" \
  "$REPO_ROOT/architect/AGENTS.md" \
  || ac_fail "architect/AGENTS.md must say the role runs in the gardener's job (agents-gardener-qwen.hcl, #2165)"
grep -qF "model, as \`architect-bot\`" "$REPO_ROOT/architect/AGENTS.md" \
  || ac_fail "architect/AGENTS.md must say the architect runs on the local model as architect-bot"
grep -qF "and, since #2165, the \`architect\`" "$REPO_ROOT/nomad/AGENTS.md" \
  || ac_fail "nomad/AGENTS.md must describe the gardener job as running the gardener, the planner (#2151) and the architect (#2165)"

ac_pass
