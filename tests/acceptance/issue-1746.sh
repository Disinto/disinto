#!/usr/bin/env bash
# =============================================================================
# tests/acceptance/issue-1746.sh
#
# Issue #1746: chore(nomad): the supervisor job mounts no Claude credentials
#
# #705 decided to remove the claude-creds path rather than repair it; #1746
# does the jobspec half of that. The supervisor has been bash-only since
# #1681 (SUPERVISOR_LLM_ESCALATION = "off"), this deployment runs no
# Anthropic models, and the expired credentials (April 2026) behind the
# claude-creds host volume are dead weight.
#
# Contract under test (read-only, pure grep over the checkout):
#   1. nomad/jobs/agents-supervisor-opus.hcl names no claude-creds host volume
#      (no volume stanza, no volume_mount, no comment) and sets no
#      CLAUDE_CONFIG_DIR — `grep -nE 'claude-creds|CLAUDE_CONFIG_DIR'` over the
#      jobspec prints nothing.
#   2. The new header line "Escalation needs Claude credentials, which this
#      job does not mount." is present, after the SUPERVISOR_LLM_ESCALATION
#      sentence.
#   3. SUPERVISOR_LLM_ESCALATION = "off" (bash-only default from #1681) is
#      still set, and CLAUDE_TIMEOUT / CLAUDE_MAX_TURNS are kept unchanged.
#   4. INFRASTRUCTURE.md no longer lists a claude-creds host-volume row.
#   5. (run-level, enforced by tools/run-acceptance.sh) the three related
#      acceptance tests that read this jobspec still pass: issue-1681.sh,
#      issue-1599.sh, issue-1698.sh.
#
# Read-only: pure grep over the jobspec and the docs; no job is dispatched,
# no network is reached.
#
# Run via: tools/run-acceptance.sh 1746
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../lib/acceptance-helpers.sh
source "$REPO_ROOT/tests/lib/acceptance-helpers.sh"

ac_require_cmd grep

HCL="$REPO_ROOT/nomad/jobs/agents-supervisor-opus.hcl"
DOCS="$REPO_ROOT/INFRASTRUCTURE.md"
ac_assert_file "$HCL" "nomad/jobs/agents-supervisor-opus.hcl must exist"
ac_assert_file "$DOCS" "INFRASTRUCTURE.md must exist"

# ── AC1: the jobspec names no claude-creds volume and no CLAUDE_CONFIG_DIR ──
# Exactly the grep from the issue; it must print nothing.
ac_log "AC1: jobspec must not name claude-creds or CLAUDE_CONFIG_DIR"
MATCHES="$(grep -nE 'claude-creds|CLAUDE_CONFIG_DIR' "$HCL" || true)"
ac_assert_eq "$MATCHES" "" \
  "jobspec must not name claude-creds or CLAUDE_CONFIG_DIR (got: $MATCHES)"

# ── AC2: the new header line is present ─────────────────────────────────────
ac_log "AC2: header adds the 'Escalation needs Claude credentials' line"
grep -qF '# Escalation needs Claude credentials, which this job does not mount.' "$HCL" \
  || ac_fail "jobspec header must add 'Escalation needs Claude credentials, which this job does not mount.'"

# ── AC3: bash-only defaults are preserved ───────────────────────────────────
ac_log "AC3: SUPERVISOR_LLM_ESCALATION = \"off\" and the escalation env vars remain"
grep -qF 'SUPERVISOR_LLM_ESCALATION = "off"' "$HCL" \
  || ac_fail 'jobspec must still set SUPERVISOR_LLM_ESCALATION = "off"'
grep -Eq 'CLAUDE_TIMEOUT[[:space:]]*=[[:space:]]*"7200"' "$HCL" \
  || ac_fail 'jobspec must still set CLAUDE_TIMEOUT = "7200"'
grep -Eq 'CLAUDE_MAX_TURNS[[:space:]]*=[[:space:]]*"60"' "$HCL" \
  || ac_fail 'jobspec must still set CLAUDE_MAX_TURNS = "60"'

# ── AC4: INFRASTRUCTURE.md lists no claude-creds host volume ────────────────
ac_log "AC4: INFRASTRUCTURE.md has no claude-creds host-volume row"
MATCHES="$(grep -n 'claude-creds' "$DOCS" || true)"
ac_assert_eq "$MATCHES" "" \
  "INFRASTRUCTURE.md must not name claude-creds (got: $MATCHES)"

ac_pass
