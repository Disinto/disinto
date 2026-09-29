#!/usr/bin/env bash
# =============================================================================
# tests/acceptance/issue-1599.sh
#
# Issue #1599: feat(nomad): dev agent job points at the Porter door.
#
# Contract under test: the jobs that run the `dev` role must export the three
# env vars that tools/jev-scope.sh (#1597) reads to dial Porter for a scope
# reading on each pick (#1598 wiring):
#
#     PORTER_SSH_TARGET      = "porter@165.227.129.61"
#     PORTER_JEV_KEY         = "/home/agent/data/porter/id_ed25519"
#     PORTER_JEV_KNOWN_HOSTS = "/home/agent/data/porter/known_hosts"
#
# and must do so WITHOUT an API key of any kind (the private key file lives on
# the agent-data volume, never in the jobspec). The Jev-incapable jobs
# (gardener / review / supervisor) must not gain these vars.
#
# Read-only: pure grep over the jobspecs in the checkout. No job is dispatched,
# no network is reached, no key material is printed.
#
# Run via: tools/run-acceptance.sh 1599
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck disable=SC1091
source "$REPO_ROOT/tests/lib/acceptance-helpers.sh"

ac_require_cmd grep head

DEV_SPEC="$REPO_ROOT/nomad/jobs/agents-dev-qwen.hcl"
AGENTS_SPEC="$REPO_ROOT/nomad/jobs/agents.hcl"
GARDENER_SPEC="$REPO_ROOT/nomad/jobs/agents-gardener-qwen.hcl"
REVIEW_SPEC="$REPO_ROOT/nomad/jobs/agents-review-qwen.hcl"
SUPERVISOR_SPEC="$REPO_ROOT/nomad/jobs/agents-supervisor-opus.hcl"

for f in "$DEV_SPEC" "$AGENTS_SPEC" "$GARDENER_SPEC" "$REVIEW_SPEC" "$SUPERVISOR_SPEC"; do
  ac_assert_file "$f" "$f is missing"
done

# The door values, exactly as the issue specifies (no API key).
SSH_TARGET="porter@165.227.129.61"
JEV_KEY="/home/agent/data/porter/id_ed25519"
KNOWN_HOSTS="/home/agent/data/porter/known_hosts"

# ── Helper: assert <file> assigns <var> to exactly the quoted <val> ──────────
# 1. Find the assignment line — leading indent, the var name, then '='.
#    Anchoring at the line start excludes comments / prose mentions.
# 2. Require the exact double-quoted value verbatim on that same line.
#    grep -F (literal) + the surrounding quotes make the match exact: a value
#    that is a prefix/superset of <val> would NOT contain "\"${val}\"".
assert_var_value() {
  local file="$1" var="$2" val="$3" label="$4"
  local line
  line="$(grep -E "^[[:space:]]*${var}[[:space:]]*=" "$file" | head -n1 || true)"
  [ -n "$line" ] || ac_fail "$label: ${var} is not assigned"
  printf '%s\n' "$line" | grep -Fq -- "\"${val}\"" \
    || ac_fail "$label: ${var} is not set to \"$val\" (got: $line)"
}

# ── AC1: both dev-capable jobs export the Porter door to the exact values ─────
ac_log "AC1: checking the dev-role jobs export the Porter door"
assert_var_value "$DEV_SPEC" PORTER_SSH_TARGET     "$SSH_TARGET"   "agents-dev-qwen.hcl"
assert_var_value "$DEV_SPEC" PORTER_JEV_KEY        "$JEV_KEY"      "agents-dev-qwen.hcl"
assert_var_value "$DEV_SPEC" PORTER_JEV_KNOWN_HOSTS "$KNOWN_HOSTS" "agents-dev-qwen.hcl"
assert_var_value "$AGENTS_SPEC" PORTER_SSH_TARGET   "$SSH_TARGET"   "agents.hcl"
assert_var_value "$AGENTS_SPEC" PORTER_JEV_KEY      "$JEV_KEY"      "agents.hcl"
assert_var_value "$AGENTS_SPEC" PORTER_JEV_KNOWN_HOSTS "$KNOWN_HOSTS" "agents.hcl"
ac_log "AC1: both dev-capable jobs carry the three PORTER_ vars with the expected values"

# ── AC2: the key path is valid (under the agent-data mount destination) ───────
ac_log "AC2: checking the key path is under the mounted agent-data destination"
for spec in "$DEV_SPEC" "$AGENTS_SPEC"; do
  # The key lives on the agent-data volume (#1599: "the key file is already on
  # the agent-data volume"); both jobs mount that volume at /home/agent/data,
  # which is the parent of /home/agent/data/porter/*.
  grep -Eq 'destination[[:space:]]*=[[:space:]]*"/home/agent/data"' "$spec" \
    || ac_fail "$spec does not mount agent-data at /home/agent/data (the PORTER_JEV_KEY path would be invalid)"
done
ac_log "AC2: both dev-capable jobs mount agent-data at /home/agent/data"

# ── AC3: neither dev-role job carries an API key ─────────────────────────────
ac_log "AC3: checking neither dev-role job carries an API key"
for spec in "$DEV_SPEC" "$AGENTS_SPEC"; do
  if grep -qF -- "TYPESAFE_API_KEY" "$spec"; then
    ac_fail "$spec contains TYPESAFE_API_KEY (no API key goes in the job)"
  fi
  if grep -qF -- "sk-or-" "$spec"; then
    ac_fail "$spec contains an sk-or- key (no API key goes in the job)"
  fi
done
ac_log "AC3: no API key in either dev-role job"

# ── AC4: gardener/review/supervisor jobs gain none of the three vars ──────────
ac_log "AC4: checking the Jev-incapable jobs gain none of the Porter vars"
for spec in "$GARDENER_SPEC" "$REVIEW_SPEC" "$SUPERVISOR_SPEC"; do
  base="${spec##*/}"
  for var in PORTER_SSH_TARGET PORTER_JEV_KEY PORTER_JEV_KNOWN_HOSTS; do
    if grep -Eq "^[[:space:]]*${var}[[:space:]]*=" "$spec"; then
      ac_fail "$base gained ${var} (Jev is dev-only)"
    fi
  done
done
ac_log "AC4: gardener/review/supervisor jobs are untouched (no PORTER_ vars)"

ac_pass