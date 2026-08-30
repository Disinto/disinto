#!/usr/bin/env bash
# =============================================================================
# tests/acceptance/issue-1123-gardener-job.sh
#
# Issue #1123: the gardener role was not deployed, so nothing ran
# gardener/classify.sh and none of its findings were ever produced. The
# six-role agents.hcl job was split into per-role jobs covering dev and
# review only; the gardener was never re-created.
#
# This test locks in the jobspec that restores the role, asserting the
# constraints the issue establishes:
#   1. The job pins exactly one role — AGENT_ROLES = "gardener".
#   2. Its agent-data host_volume source is distinct from the dev and
#      review jobs (no state collision), and is declared in nomad/client.hcl
#      (the jobspec/client.hcl pair must stay in sync or nomad
#      fingerprinting leaves the node in "initializing").
#   3. FORGE_TOKEN/FORGE_PASS are rendered from the
#      kv/data/disinto/bots/gardener Vault path in a template stanza —
#      never as a literal.
#
# Read-only: parses the jobspec HCL from the checkout; starts no job.
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck disable=SC1091
source "$REPO_ROOT/tests/lib/acceptance-helpers.sh"

ac_require_cmd awk
ac_require_cmd grep
ac_require_cmd sed

SPEC="$REPO_ROOT/nomad/jobs/agents-gardener-qwen.hcl"
ac_assert_file "$SPEC" "jobspec nomad/jobs/agents-gardener-qwen.hcl must exist"

DEV_SPEC="$REPO_ROOT/nomad/jobs/agents-dev-qwen.hcl"
ac_assert_file "$DEV_SPEC" "jobspec nomad/jobs/agents-dev-qwen.hcl must exist (baseline for the shared volume source)"
REVIEW_SPEC="$REPO_ROOT/nomad/jobs/agents-review-qwen.hcl"
ac_assert_file "$REVIEW_SPEC" "jobspec nomad/jobs/agents-review-qwen.hcl must exist (baseline for the shared volume source)"

# job "..." block name — one role per job means one job per role.
job_name="$(grep -E '^[[:space:]]*job[[:space:]]+"' "$SPEC" \
  | head -n1 | sed -E 's/.*job[[:space:]]+"([^"]+)".*/\1/')"
ac_assert_eq "$job_name" "agents-gardener-qwen" \
  "jobspec must define job \"agents-gardener-qwen\""

# ── 1. Exactly one role, pinned to "gardener" ───────────────────────────────
role_lines="$(grep -cE '^[[:space:]]*AGENT_ROLES[[:space:]]*=' "$SPEC" || true)"
ac_assert_eq "$role_lines" "1" \
  "jobspec must set AGENT_ROLES exactly once (one role per job)"

role="$(grep -E '^[[:space:]]*AGENT_ROLES[[:space:]]*=' "$SPEC" \
  | head -n1 | sed -E 's/^[[:space:]]*AGENT_ROLES[[:space:]]*=[[:space:]]*//; s/"//g; s/[[:space:]]+$//')"
ac_assert_eq "$role" "gardener" \
  "AGENT_ROLES must pin exactly the single role \"gardener\" (got '$role')"
case "$role" in
  *,*) ac_fail "AGENT_ROLES pins more than one role: '$role'" ;;
esac

# Same lane as the other llama agents — the pool is shared (--kv-unified),
# so the gardener gets the same 100k lane, not a wider one.
lane="$(grep -E '^[[:space:]]*CLAUDE_AUTOCOMPACT_PCT_OVERRIDE[[:space:]]*=' "$SPEC" \
  | head -n1 | sed -E 's/.*=[[:space:]]*//; s/"//g; s/[[:space:]]+$//')"
ac_assert_eq "$lane" "50" \
  "CLAUDE_AUTOCOMPACT_PCT_OVERRIDE must be 50, matching the other agents"

# ── 2. Distinct agent-data volume source ────────────────────────────────────
# Extract the `source` from the `volume "agent-data" { ... }` block.
volume_source() {
  awk '
    /volume[[:space:]]+"agent-data"[[:space:]]*\{/ { inblk = 1 }
    inblk && /source[[:space:]]*=/ {
      line = $0
      sub(/.*source[[:space:]]*=[[:space:]]*/, "", line)
      gsub(/"/, "", line)
      gsub(/[[:space:]]/, "", line)
      print line
      exit
    }
    inblk && /\}/ { inblk = 0 }
  ' "$1"
}

gardener_src="$(volume_source "$SPEC")"
[ -n "$gardener_src" ] \
  || ac_fail "could not extract the agent-data volume source from agents-gardener-qwen.hcl"

dev_src="$(volume_source "$DEV_SPEC")"
review_src="$(volume_source "$REVIEW_SPEC")"
[ -n "$dev_src" ] || ac_fail "could not extract the agent-data volume source from agents-dev-qwen.hcl"
[ -n "$review_src" ] || ac_fail "could not extract the agent-data volume source from agents-review-qwen.hcl"

[ "$gardener_src" != "$dev_src" ] \
  || ac_fail "gardener agent-data source '$gardener_src' collides with the dev job's source"
[ "$gardener_src" != "$review_src" ] \
  || ac_fail "gardener agent-data source '$gardener_src' collides with the review job's source"

# The source must be declared as a host_volume in nomad/client.hcl — offline
# `nomad job validate` does NOT catch a mismatch, and an undeclared source
# leaves the node in "initializing" (nomad/AGENTS.md, step 2).
grep -Eq "host_volume[[:space:]]+\"${gardener_src}\"" "$REPO_ROOT/nomad/client.hcl" \
  || ac_fail "host_volume \"$gardener_src\" is not declared in nomad/client.hcl — the job cannot schedule"

ac_log "gardener agent-data source: $gardener_src (dev: $dev_src, review: $review_src)"

# ── 3. Vault-templated token, never a literal ───────────────────────────────
# The primary bot identity comes from kv/data/disinto/bots/gardener.
grep -q 'secret "kv/data/disinto/bots/gardener"' "$SPEC" \
  || ac_fail "jobspec does not read the gardener bot token from kv/data/disinto/bots/gardener"
grep -q 'FORGE_TOKEN={{ .Data.data.token }}' "$SPEC" \
  || ac_fail "jobspec does not render FORGE_TOKEN from the Vault template"
grep -q 'FORGE_PASS={{ .Data.data.pass }}' "$SPEC" \
  || ac_fail "jobspec does not render FORGE_PASS from the Vault template"

# A literal would be an assignment whose value is neither a template
# expression nor the seed-me placeholder.
for var in FORGE_TOKEN FORGE_PASS; do
  if grep -E "${var}[[:space:]]*=" "$SPEC" | grep -vq -e '{{' -e 'seed-me'; then
    ac_fail "agents-gardener-qwen.hcl appears to carry a literal ${var}"
  fi
done

ac_pass
