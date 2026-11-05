#!/usr/bin/env bash
# =============================================================================
# tests/acceptance/issue-2118.sh — every agent but the canary follows live
#
# Issue #2118 (sprint self-update, step 13): dev, gardener and supervisor pin
# FACTORY_REF = "live" in the task's env block, directly after their
# AGENT_ROLES line, so a merge reaches them only after it held on the canary
# (docs/design/notes/self-update.md). The dev and gardener jobs share the
# /srv/disinto/project-repos/_factory checkout through the project-repos host
# volume, so they must pin the same ref — hence the three together. No
# FACTORY_CHECKOUT is added: dev and gardener keep the shared checkout, and
# the supervisor's checkout is already its own (it mounts no project-repos).
#
# Acceptance:
#   AC1: each of the three specs pins FACTORY_REF = "live" exactly once.
#   AC2: the line sits inside the task's env { ... } block, directly after
#        the AGENT_ROLES line, and AGENT_ROLES is unchanged.
#   AC3: none of the three specs sets FACTORY_CHECKOUT.
#   AC4: when the nomad CLI is on PATH, `nomad job validate` exits 0 for each
#        spec — mirroring .woodpecker/nomad-validate.yml; skipped otherwise.
#   AC5: the canary spec, agents-review-qwen.hcl, still pins "canary".
#
# Read-only: parses the jobspecs from the checkout; submits no job.
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/../.." && pwd)"

# shellcheck disable=SC1091
source "$REPO_ROOT/tests/lib/acceptance-helpers.sh"

ac_require_cmd awk grep sed

LIVE_LINE='FACTORY_REF        = "live"'

specs=(
  "nomad/jobs/agents-dev-qwen.hcl:dev"
  "nomad/jobs/agents-gardener-qwen.hcl:gardener"
  "nomad/jobs/agents-supervisor-opus.hcl:supervisor"
)

for entry in "${specs[@]}"; do
  rel="${entry%:*}"
  role="${entry#*:}"
  spec="$REPO_ROOT/$rel"
  ac_assert_file "$spec" "jobspec $rel must exist"

  # ── AC1: the live ref pinned exactly once ──────────────────────────────────
  ac_log "AC1: $rel pins FACTORY_REF = \"live\" exactly once"
  count="$(grep -cF "$LIVE_LINE" "$spec" || true)"
  ac_assert_eq "$count" "1" "$rel must set FACTORY_REF to \"live\" exactly once (got $count)"

  # ── AC2: inside the task env block, right after AGENT_ROLES ─────────────────
  ac_log "AC2: $rel keeps its live ref inside the task env block"
  env="$(ac_jobspec_env_block "$spec")"
  [ -n "$env" ] || ac_fail "could not extract the task's env { ... } block from $rel"

  if ! printf '%s\n' "$env" | grep -qF "$LIVE_LINE"; then
    ac_fail "FACTORY_REF = \"live\" must sit inside the task env block of $rel"
  fi

  ref_line="$(printf '%s\n' "$env" | grep -nF "$LIVE_LINE" | head -n1 | cut -d: -f1)"
  role_line="$(printf '%s\n' "$env" | grep -nE '^[[:space:]]*AGENT_ROLES[[:space:]]*=' \
    | head -n1 | cut -d: -f1)"
  [ "$ref_line" -gt "$role_line" ] \
    || ac_fail "the FACTORY_REF line in $rel must sit after its AGENT_ROLES line (roles l.$role_line, ref l.$ref_line)"
  between="$(printf '%s\n' "$env" | sed -n "$((role_line + 1)),$((ref_line - 1))p")"
  if [ -n "$between" ] \
     && printf '%s\n' "$between" | grep -qvE '^[[:space:]]*(#|[[:space:]]*$)'; then
    ac_fail "in $rel only comment lines may sit between AGENT_ROLES and FACTORY_REF"
  fi

  pinned_role="$(ac_env_value "$env" AGENT_ROLES)"
  ac_assert_eq "$pinned_role" "$role" \
    "AGENT_ROLES must still pin the single role \"$role\" in $rel (got '$pinned_role')"

  # ── AC3: no private factory checkout ────────────────────────────────────────
  ac_log "AC3: $rel names no FACTORY_CHECKOUT"
  if grep -q 'FACTORY_CHECKOUT' "$spec"; then
    ac_fail "$rel must not set FACTORY_CHECKOUT: these jobs keep the shared factory checkout"
  fi

  # ── AC4: the jobspec still validates (skipped when nomad is absent) ─────────
  if command -v nomad >/dev/null 2>&1; then
    ac_log "AC4: nomad job validate $rel"
    nomad job validate "$spec" || ac_fail "nomad job validate rejected $rel"
  else
    ac_warn "AC4: nomad not on PATH — skipping job validate (CI's nomad-job-validate runs it)"
  fi
done

# ── AC5: the canary still follows canary ──────────────────────────────────────
canary="$REPO_ROOT/nomad/jobs/agents-review-qwen.hcl"
ac_assert_file "$canary" "jobspec nomad/jobs/agents-review-qwen.hcl must exist"
ac_log "AC5: the review job still pins FACTORY_REF = \"canary\""
canary_count="$(grep -cF 'FACTORY_REF        = "canary"' "$canary" || true)"
ac_assert_eq "$canary_count" "1" \
  "agents-review-qwen.hcl must keep FACTORY_REF = \"canary\" exactly once (got $canary_count)"

ac_pass "issue #2118: dev, gardener and supervisor follow live; the review agent stays the canary"
