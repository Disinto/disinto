#!/usr/bin/env bash
# shellcheck disable=SC2154  # bats_rc/bats_out set by ac_run_bats_suite
# =============================================================================
# tests/acceptance/issue-1853.sh
#
# Issue #1853: hire-an-agent defaults to the dsh harness.
#
# Before: disinto hire-an-agent started with harness=claude, so a hire
# without --harness rendered the Claude env block.
#
# After: the default harness is dsh. An explicit --harness claude still
# renders the Claude block. The compose generator's default is #1854.
#
# Acceptance (no Vault, no Nomad, no network):
#   1. lib/hire-agent.sh defaults both call sites to dsh and no longer
#      hardcodes local harness="claude".
#   2. jobspec-default.hcl is the dsh block; jobspec-claude.hcl is the
#      Claude block.
#   3. bats tests/hire-an-agent-harness.bats and
#      tests/hire-an-agent-nomad.bats pass.
#   4. this test exits 0 and calls ac_pass.
#
# Run via: tools/run-acceptance.sh 1853
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../lib/acceptance-helpers.sh
source "$REPO_ROOT/tests/lib/acceptance-helpers.sh"

ac_require_cmd bash grep bats

HIRE="$REPO_ROOT/lib/hire-agent.sh"
DEFAULT_FIXTURE="$REPO_ROOT/tests/fixtures/hire-an-agent-harness/jobspec-default.hcl"
CLAUDE_FIXTURE="$REPO_ROOT/tests/fixtures/hire-an-agent-harness/jobspec-claude.hcl"
ac_assert_file "$HIRE" "lib/hire-agent.sh must exist"
ac_assert_file "$DEFAULT_FIXTURE" "jobspec-default.hcl must exist"
ac_assert_file "$CLAUDE_FIXTURE" "jobspec-claude.hcl must exist"

# ── 1. Both hire defaults are dsh; claude is no longer a hardcoded default ──
ac_log "AC 1: hire-an-agent defaults to dsh"
# shellcheck disable=SC2016  # the ${9:-dsh} default is a literal grep pattern
nomad_default="$(grep -cF 'harness="${9:-dsh}"' "$HIRE" || true)"
entry_default="$(grep -c '^  local harness="dsh"$' "$HIRE" || true)"
claude_hardcode="$(grep -cF 'local harness="claude"' "$HIRE" || true)"
ac_assert_eq "$nomad_default" "1" \
  "disinto_hire_an_agent_nomad must default harness to dsh (count=$nomad_default)"
ac_assert_eq "$entry_default" "1" \
  "disinto_hire_an_agent must start with local harness=\"dsh\" (count=$entry_default)"
ac_assert_eq "$claude_hardcode" "0" \
  "lib/hire-agent.sh must not hardcode local harness=\"claude\" (count=$claude_hardcode)"
ac_log "AC 1 OK: defaults are dsh"

# ── 2. Fixtures pin the dsh default and the claude opt-in ────────────────────
ac_log "AC 2: jobspec fixtures"
grep -qF 'AGENT_HARNESS       = "dsh"' "$DEFAULT_FIXTURE" \
  || ac_fail "jobspec-default.hcl must contain AGENT_HARNESS = \"dsh\""
if grep -Eq 'CLAUDE_|ANTHROPIC_' "$DEFAULT_FIXTURE"; then
  ac_fail "jobspec-default.hcl must not contain CLAUDE_ or ANTHROPIC_"
fi
grep -qF 'AGENT_HARNESS      = "claude"' "$CLAUDE_FIXTURE" \
  || ac_fail "jobspec-claude.hcl must contain AGENT_HARNESS = \"claude\""
ac_log "AC 2 OK: fixtures match the dsh default and the claude opt-in"

# ── 3. Both bats suites ──────────────────────────────────────────────────────
ac_log "AC 3: bats tests/hire-an-agent-harness.bats"
ac_run_bats_suite "$REPO_ROOT/tests/hire-an-agent-harness.bats"
ac_assert_eq "$bats_rc" "0" \
  "bats tests/hire-an-agent-harness.bats must pass (rc=$bats_rc): $bats_out"
ac_log "AC 3a OK: hire-an-agent-harness.bats passed"

ac_log "AC 3: bats tests/hire-an-agent-nomad.bats"
ac_run_bats_suite "$REPO_ROOT/tests/hire-an-agent-nomad.bats"
ac_assert_eq "$bats_rc" "0" \
  "bats tests/hire-an-agent-nomad.bats must pass (rc=$bats_rc): $bats_out"
ac_log "AC 3b OK: hire-an-agent-nomad.bats passed"

ac_pass
