#!/usr/bin/env bash
# =============================================================================
# tests/acceptance/issue-1912.sh — a Grok jobspec for the architect role
#
# Issue #1912: no jobspec ran the `architect` role. This lands
# nomad/jobs/agents-architect-grok.hcl — a copy of agents-dev-grok.hcl
# narrowed to the architect role (its own data dir, its own xAI grant in
# DSH_HOME, forge identity `architect-bot`, Vault role/policy
# `bot-architect`, and no tape volume because an undecided pitch serves no
# proposal) — plus the matching role re-bind in vault/roles.yaml and the
# documentation rows. Read-only: parses the jobspec HCL and vault/roles.yaml
# from the checkout; no live box is needed.
#
# Verifies (per the issue acceptance criteria):
#   1. job "agents-architect-grok" is defined exactly once.
#   2. It binds vault role bot-architect, pins AGENT_ROLES to the
#      architect role, and bind-mounts its own data dir.
#   3. The bots.env template reads ONLY kv/data/disinto/bots/architect (the
#      single `with secret` block) and renders FORGE_TOKEN / FORGE_PASS /
#      FORGE_ARCHITECT_TOKEN — never the other bots' KV paths.
#   4. It carries no tape volume.
#   5. vault/roles.yaml binds job_id agents-architect-grok to the
#      bot-architect role (whose policy is bot-architect), with the binding
#      comment.
#
# Run via: tools/run-acceptance.sh 1912
# Last stdout line is PASS or FAIL: <reason>.
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck disable=SC1091
source "$REPO_ROOT/tests/lib/acceptance-helpers.sh"

ac_require_cmd grep
ac_require_cmd sort
ac_require_cmd awk

SPEC="$REPO_ROOT/nomad/jobs/agents-architect-grok.hcl"
ROLES="$REPO_ROOT/vault/roles.yaml"
ac_assert_file "$SPEC" "jobspec nomad/jobs/agents-architect-grok.hcl must exist"
ac_assert_file "$ROLES" "vault/roles.yaml must exist"

# ── 1. job "agents-architect-grok" defined exactly once ─────────────────────
job_count="$(grep -cE '^job "agents-architect-grok"' "$SPEC" || true)"
ac_assert_eq "$job_count" "1" \
  "jobspec must define job \"agents-architect-grok\" exactly once (got ${job_count})"

# ── 2. vault role, AGENT_ROLES, and the architect data dir ──────────────────
grep -qE '^[[:space:]]*role[[:space:]]*=[[:space:]]*"bot-architect"' "$SPEC" \
  || ac_fail "jobspec must bind vault role \"bot-architect\""

# Pin exactly one role.
role_count="$(grep -cE '^[[:space:]]*AGENT_ROLES[[:space:]]*=' "$SPEC" || true)"
ac_assert_eq "$role_count" "1" "jobspec must set AGENT_ROLES exactly once"
role_line="$(grep -E '^[[:space:]]*AGENT_ROLES[[:space:]]*=' "$SPEC" | head -n1)"
role_val="$(echo "$role_line" | sed -E 's/^[[:space:]]*AGENT_ROLES[[:space:]]*=[[:space:]]*//; s/"//g; s/[[:space:]]*$//')"
ac_assert_eq "$role_val" "architect" \
  "AGENT_ROLES must pin exactly the single role \"architect\" (got '$role_val')"
case "$role_val" in
  *,*) ac_fail "AGENT_ROLES pins more than one role: '$role_val'" ;;
esac

grep -qF '/srv/disinto/agent-data-grok/architect:/home/agent/data' "$SPEC" \
  || ac_fail "jobspec must bind-mount /srv/disinto/agent-data-grok/architect at /home/agent/data"

# The service must be registered under the same name as the job.
grep -qE '^[[:space:]]*name[[:space:]]*=[[:space:]]*"agents-architect-grok"' "$SPEC" \
  || ac_fail "jobspec must register service agents-architect-grok"

# ── 3. the template reads only the architect's own bot path ─────────────────
# Exactly one `secret "kv/data/..."` reference, and it must be the
# architect's path.
secrets="$(grep -o 'secret "kv/data/[^"]*"' "$SPEC" | sort -u)"
ac_assert_eq "$secrets" 'secret "kv/data/disinto/bots/architect"' \
  "bots.env must read only kv/data/disinto/bots/architect, got: $secrets"

# Render the three architect tokens from that single block.
grep -qF 'FORGE_TOKEN={{ .Data.data.token }}' "$SPEC" \
  || ac_fail "FORGE_TOKEN must be rendered from the Vault template"
grep -qF 'FORGE_PASS={{ .Data.data.pass }}' "$SPEC" \
  || ac_fail "FORGE_PASS must be rendered from the Vault template"
grep -qF 'FORGE_ARCHITECT_TOKEN={{ .Data.data.token }}' "$SPEC" \
  || ac_fail "FORGE_ARCHITECT_TOKEN must be rendered from the Vault template"

# seed-me placeholders in the else branch.
ac_assert_eq "$(grep -c 'FORGE_TOKEN=seed-me' "$SPEC")" "1" \
  "the architect token block must fall back to seed-me in the else branch"

# No other bot KV paths may be read.
for other in dev dev-grok review review-grok gardener planner predictor supervisor filer; do
  if grep -qF "bots/$other" "$SPEC"; then
    ac_fail "bots.env must not read kv/data/disinto/bots/$other"
  fi
done

# ── 4. no tape volume (an undecided pitch serves no proposal) ───────────────
tape_count="$(grep -c 'volume "tape"' "$SPEC" || true)"
ac_assert_eq "$tape_count" "0" \
  "jobspec must not declare a tape volume (got ${tape_count})"

# ── 5. vault/roles.yaml re-binds bot-architect to agents-architect-grok ─────
# The `name: bot-architect` block (plus the following lines) must carry the
# new job_id and the bot-architect policy.
block="$(grep -A3 'name: *bot-architect$' "$ROLES" || true)"
[ -n "$block" ] || ac_fail "vault/roles.yaml does not contain a bot-architect role"

printf '%s\n' "$block" | grep -qF 'job_id:    agents-architect-grok' \
  || ac_fail "bot-architect role must bind job_id agents-architect-grok, got: $block"
printf '%s\n' "$block" | grep -qF 'policy:    bot-architect' \
  || ac_fail "bot-architect role must keep policy bot-architect"

# The binding comment.
grep -qF 'Bound to the Grok architect job, nomad/jobs/agents-architect-grok.hcl (#1912).' "$ROLES" \
  || ac_fail "vault/roles.yaml is missing the bot-architect binding comment"

ac_log "agents-architect-grok: job/role/data-dir OK; single architect bot path; no tape; roles.yaml re-bound"
ac_pass
