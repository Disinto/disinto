#!/usr/bin/env bash
# =============================================================================
# tests/acceptance/issue-2117.sh — the review agent follows canary in its own
# checkout
#
# Issue #2117 (sprint self-update, step 12): the canary of the update-self
# rollout is the review agent. nomad/jobs/agents-review-qwen.hcl now sets, in
# the task's env block right after AGENT_ROLES:
#   FACTORY_REF      = "canary"
#   FACTORY_CHECKOUT = "/home/agent/data/_factory"
# so it follows the canary branch in a checkout on this job's own data volume
# while the shared /home/agent/repos/_factory keeps following live. Nothing
# else changes: no volume, no image, no resources.
#
# Acceptance:
#   AC1: both lines appear verbatim, exactly once, in the jobspec.
#   AC2: both sit inside the task's env { ... } block (extracted with awk),
#        and AGENT_ROLES is still "review".
#   AC3: when the nomad CLI is on PATH, `nomad job validate` exits 0 —
#        mirroring .woodpecker/nomad-validate.yml; the step is skipped when
#        the CLI is absent.
#
# Read-only: parses the jobspec HCL from the checkout; submits no job.
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/../.." && pwd)"

# shellcheck disable=SC1091
source "$REPO_ROOT/tests/lib/acceptance-helpers.sh"

ac_require_cmd awk grep sed

SPEC="$REPO_ROOT/nomad/jobs/agents-review-qwen.hcl"
ac_assert_file "$SPEC" "jobspec nomad/jobs/agents-review-qwen.hcl must exist"

# ── AC1: each line exactly once, verbatim ────────────────────────────────────
ac_log "AC1: FACTORY_REF/FACTORY_CHECKOUT pinned exactly once each"
ref_count="$(grep -cF 'FACTORY_REF        = "canary"' "$SPEC" || true)"
ac_assert_eq "$ref_count" "1" \
  "FACTORY_REF must be set to \"canary\" exactly once (got $ref_count)"

checkout_count="$(grep -cF 'FACTORY_CHECKOUT   = "/home/agent/data/_factory"' "$SPEC" || true)"
ac_assert_eq "$checkout_count" "1" \
  "FACTORY_CHECKOUT must be set to the job's own factory checkout exactly once (got $checkout_count)"

# ── AC2: inside the task env block, role unchanged ───────────────────────────
ac_log "AC2: both lines sit inside the task's env { ... } block"
env="$(ac_jobspec_env_block "$SPEC")"
[ -n "$env" ] || ac_fail "could not extract the task's env { ... } block"

if ! printf '%s\n' "$env" | grep -qF 'FACTORY_REF        = "canary"'; then
  ac_fail 'FACTORY_REF = "canary" must sit inside the task env block'
fi
if ! printf '%s\n' "$env" | grep -qF 'FACTORY_CHECKOUT   = "/home/agent/data/_factory"'; then
  ac_fail 'FACTORY_CHECKOUT = "/home/agent/data/_factory" must sit inside the task env block'
fi

role="$(ac_env_value "$env" AGENT_ROLES)"
ac_assert_eq "$role" "review" \
  "AGENT_ROLES must still pin the single role \"review\" (got '$role')"

# ── AC3: jobspec still validates (skipped when nomad CLI is absent) ──────────
if command -v nomad >/dev/null 2>&1; then
  ac_log "AC3: nomad job validate nomad/jobs/agents-review-qwen.hcl"
  nomad job validate "$SPEC" \
    || ac_fail "nomad job validate rejected agents-review-qwen.hcl"
else
  ac_warn "AC3: nomad not on PATH — skipping job validate (CI's nomad-job-validate runs it)"
fi

ac_pass "issue #2117: the review agent follows canary in its own checkout"
