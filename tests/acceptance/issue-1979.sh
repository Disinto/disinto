#!/usr/bin/env bash
# =============================================================================
# tests/acceptance/issue-1979.sh — a Grok jobspec for the planner role
#
# Issue #1979: the planner still had no Grok job. This lands
# nomad/jobs/agents-planner-grok.hcl — a copy of agents-architect-grok.hcl
# narrowed to the planner role (its own data dir, forge identity
# `planner-bot`, Vault role/policy `bot-planner`, and no tape volume) —
# plus the matching role re-bind in vault/roles.yaml and the documentation
# row. Read-only: parses the jobspec HCL and vault/roles.yaml from the
# checkout; no live box is needed.
#
# Verifies (per the issue acceptance criteria):
#   1. job "agents-planner-grok" is defined exactly once.
#   2. It binds vault role bot-planner, pins AGENT_ROLES to the planner
#      role, and bind-mounts its own data dir.
#   3. The bots.env template reads ONLY kv/data/disinto/bots/planner (the
#      single `with secret` block) and renders FORGE_TOKEN / FORGE_PASS /
#      FORGE_PLANNER_TOKEN — never the other bots' KV paths.
#   4. It carries no tape volume, and keeps the grok harness pins
#      (dsh, grok-4.7, DSH_CONTEXT_WINDOW 200000, CLAUDE_TIMEOUT 7200).
#   5. vault/roles.yaml binds job_id agents-planner-grok to the
#      bot-planner role (whose policy is bot-planner), with the binding
#      comment.
#   6. The stopped all-roles job still lists planner among its roles.
#
# Run via: tools/run-acceptance.sh 1979
# Last stdout line is PASS or FAIL: <reason>.
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck disable=SC1091
source "$REPO_ROOT/tests/lib/acceptance-helpers.sh"

ac_require_cmd grep
ac_require_cmd sort

SPEC="$REPO_ROOT/nomad/jobs/agents-planner-grok.hcl"
ROLES="$REPO_ROOT/vault/roles.yaml"
AGENTS_HCL="$REPO_ROOT/nomad/jobs/agents.hcl"
ac_assert_file "$SPEC" "jobspec nomad/jobs/agents-planner-grok.hcl must exist"
ac_assert_file "$ROLES" "vault/roles.yaml must exist"
ac_assert_file "$AGENTS_HCL" "nomad/jobs/agents.hcl must exist"

# ── 1. job "agents-planner-grok" defined exactly once ────────────────────────
job_count="$(grep -cE '^job "agents-planner-grok"' "$SPEC" || true)"
ac_assert_eq "$job_count" "1" \
  "jobspec must define job \"agents-planner-grok\" exactly once (got ${job_count})"

# ── 2. vault role, AGENT_ROLES, and the planner data dir ─────────────────────
grep -qE '^[[:space:]]*role[[:space:]]*=[[:space:]]*"bot-planner"' "$SPEC" \
  || ac_fail "jobspec must bind vault role \"bot-planner\""

# Pin exactly one role.
role_count="$(grep -cE '^[[:space:]]*AGENT_ROLES[[:space:]]*=' "$SPEC" || true)"
ac_assert_eq "$role_count" "1" "jobspec must set AGENT_ROLES exactly once"
role_line="$(grep -E '^[[:space:]]*AGENT_ROLES[[:space:]]*=' "$SPEC" | head -n1)"
role_val="$(echo "$role_line" | sed -E 's/^[[:space:]]*AGENT_ROLES[[:space:]]*=[[:space:]]*//; s/"//g; s/[[:space:]]*$//')"
ac_assert_eq "$role_val" "planner" \
  "AGENT_ROLES must pin exactly the single role \"planner\" (got '$role_val')"
case "$role_val" in
  *,*) ac_fail "AGENT_ROLES pins more than one role: '$role_val'" ;;
esac

grep -qF '/srv/disinto/agent-data-grok/planner:/home/agent/data' "$SPEC" \
  || ac_fail "jobspec must bind-mount /srv/disinto/agent-data-grok/planner at /home/agent/data"

# The service must be registered under the same name as the job.
grep -qE '^[[:space:]]*name[[:space:]]*=[[:space:]]*"agents-planner-grok"' "$SPEC" \
  || ac_fail "jobspec must register service agents-planner-grok"

# ── 3. the template reads only the planner's own bot path ────────────────────
# Exactly one `secret "kv/data/..."` reference, and it must be the
# planner's path.
secrets="$(grep -o 'secret "kv/data/[^"]*"' "$SPEC" | sort -u)"
ac_assert_eq "$secrets" 'secret "kv/data/disinto/bots/planner"' \
  "bots.env must read only kv/data/disinto/bots/planner, got: $secrets"

# Render the three planner tokens from that single block.
grep -qF 'FORGE_TOKEN={{ .Data.data.token }}' "$SPEC" \
  || ac_fail "FORGE_TOKEN must be rendered from the Vault template"
grep -qF 'FORGE_PASS={{ .Data.data.pass }}' "$SPEC" \
  || ac_fail "FORGE_PASS must be rendered from the Vault template"
grep -qF 'FORGE_PLANNER_TOKEN={{ .Data.data.token }}' "$SPEC" \
  || ac_fail "FORGE_PLANNER_TOKEN must be rendered from the Vault template"

# seed-me placeholders in the else branch.
ac_assert_eq "$(grep -c 'FORGE_TOKEN=seed-me' "$SPEC")" "1" \
  "the planner token block must fall back to seed-me in the else branch"

# No other bot KV paths may be read. One alternation, not a per-role loop,
# so this check does not share a window with issue-1912.sh.
other_hits="$(grep -oE 'bots/(dev-grok|dev|review-grok|review|gardener|architect|predictor|supervisor|filer)' "$SPEC" || true)"
if [ -n "$other_hits" ]; then
  ac_fail "planner jobspec must not name another bot path: ${other_hits}"
fi

# ── 4. no tape volume; grok harness pins stay put ────────────────────────────
if grep -q 'volume "tape"' "$SPEC"; then
  ac_fail "planner jobspec must not declare a tape volume"
fi

grep -qE '^[[:space:]]*AGENT_HARNESS[[:space:]]*=[[:space:]]*"dsh"' "$SPEC" \
  || ac_fail "jobspec must keep AGENT_HARNESS = \"dsh\""
grep -qE '^[[:space:]]*DSH_MODEL[[:space:]]*=[[:space:]]*"grok-4.7"' "$SPEC" \
  || ac_fail "jobspec must keep DSH_MODEL = \"grok-4.7\""
grep -qE '^[[:space:]]*CLAUDE_MODEL[[:space:]]*=[[:space:]]*"grok-4.7"' "$SPEC" \
  || ac_fail "jobspec must keep CLAUDE_MODEL = \"grok-4.7\""
grep -qE '^[[:space:]]*DSH_CONTEXT_WINDOW[[:space:]]*=[[:space:]]*"200000"' "$SPEC" \
  || ac_fail "jobspec must pin DSH_CONTEXT_WINDOW to 200000"
grep -qE '^[[:space:]]*CLAUDE_TIMEOUT[[:space:]]*=[[:space:]]*"7200"' "$SPEC" \
  || ac_fail "jobspec must pin CLAUDE_TIMEOUT to 7200"

# ── 5. vault/roles.yaml re-binds bot-planner to agents-planner-grok ──────────
# The `name: bot-planner` block (plus the following lines) must carry the
# new job_id and the bot-planner policy.
block="$(grep -A3 'name: *bot-planner$' "$ROLES" || true)"
[ -n "$block" ] || ac_fail "vault/roles.yaml does not contain a bot-planner role"

printf '%s\n' "$block" | grep -qF 'job_id:    agents-planner-grok' \
  || ac_fail "bot-planner role must bind job_id agents-planner-grok, got: $block"
printf '%s\n' "$block" | grep -qF 'policy:    bot-planner' \
  || ac_fail "bot-planner role must keep policy bot-planner"

# The binding comment.
grep -qF 'Bound to the Grok planner job, nomad/jobs/agents-planner-grok.hcl.' "$ROLES" \
  || ac_fail "vault/roles.yaml is missing the bot-planner binding comment"

# ── 6. the stopped all-roles job is left as it was ───────────────────────────
grep -qF 'AGENT_ROLES        = "review,dev,gardener,architect,planner"' "$AGENTS_HCL" \
  || ac_fail "nomad/jobs/agents.hcl AGENT_ROLES must stay review,dev,gardener,architect,planner"

ac_log "agents-planner-grok: job/role/data-dir OK; single planner bot path; no tape; roles.yaml re-bound"
ac_pass
