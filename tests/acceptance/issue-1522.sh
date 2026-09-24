#!/usr/bin/env bash
# =============================================================================
# tests/acceptance/issue-1522.sh
#
# Issue #1522: rebuild-and-deploy-agents dies on nomad job restart.
#
# Pipeline 2999 (merge of #1521) built disinto/agents:local, then exited 1
# before any alloc restarted:
#
#   Invalid -on-error value "ask": "ask" cannot be used when terminal is not
#   interactive
#
# The step runs the Nomad CLI via `docker run --rm` (no TTY). Nomad v1.9.5
# defaults `-on-error` to `ask`, which is illegal in that environment.
# `-yes` is not a fix: it ignores batch errors, and the following health
# poll cannot tell an in-place restart that never happened from a healthy
# already-running alloc.
#
# Two follow-ons would still fail or harm the box once restart returns 0:
#   - `nomad job status -json` is a one-element array. The old poll indexed
#     `.Allocations` on that array, so jq exits 5.
#   - the agents*.hcl glob includes agents.hcl, which is not the live
#     runtime. `nomad job run` would register a second polling loop.
#
# Read-only. Parses .woodpecker/ci.yml and runs the health-poll jq against
# fixtures. Does not call nomad, docker, or the forge.
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck disable=SC1091
source "$REPO_ROOT/tests/lib/acceptance-helpers.sh"

ac_require_cmd awk grep jq

CI_YML="$REPO_ROOT/.woodpecker/ci.yml"
ac_assert_file "$CI_YML" ".woodpecker/ci.yml must exist"

STEP_BLOCK="$(awk '
  /^  - name: rebuild-and-deploy-agents/ { in_step = 1 }
  in_step && /^  - name:/ && $0 !~ /rebuild-and-deploy-agents/ { in_step = 0 }
  in_step { print }
' "$CI_YML")"

if [ -z "$STEP_BLOCK" ]; then
  ac_fail "no step named rebuild-and-deploy-agents in .woodpecker/ci.yml"
fi

# ── Reproduction: the bare restart is what pipeline 2999 ran ────────────────
ac_log "reproduction: restart must not use the interactive -on-error default"
if printf '%s\n' "$STEP_BLOCK" | grep -q 'nomad_api job restart "\$job"'; then
  ac_fail "rebuild-and-deploy-agents still calls nomad job restart without -on-error=fail (pipeline 2999)"
fi

printf '%s\n' "$STEP_BLOCK" | grep -q 'nomad_api job restart -on-error=fail "\$job"' \
  || ac_fail "restart must be: nomad_api job restart -on-error=fail \"\$job\""

if printf '%s\n' "$STEP_BLOCK" | grep -q 'job restart -yes'; then
  ac_fail "restart must not use -yes (it ignores batch errors)"
fi

# ── Glob stays (#1173); the pre-cutover all-roles job is skipped ────────────
ac_log "checking the agents*.hcl glob is kept and basename agents is skipped"
printf '%s\n' "$STEP_BLOCK" | grep -q 'nomad/jobs/agents\*\.hcl' \
  || ac_fail "rebuild-and-deploy-agents must still discover jobspecs via nomad/jobs/agents*.hcl"

printf '%s\n' "$STEP_BLOCK" | grep -q '\[ "\$job" = "agents" \]' \
  || ac_fail "rebuild-and-deploy-agents must skip basename agents (not the live runtime)"

# ── Health poll unwraps the array form of nomad job status -json ────────────
ac_log "checking the health poll jq against array and object fixtures"
printf '%s\n' "$STEP_BLOCK" | grep -q 'if type == "array"' \
  || ac_fail "health poll must unwrap the array form of nomad job status -json"

# Same filter the step runs. A drift here fails the fixture below only if
# the yml also lost the array branch (asserted above).
jq_filter='
  (if type == "array" then (.[0] // {}) else . end) as $root
  | ($root.Allocations // []) as $a
  | if ($a | length) == 0 then 1
    else (($a | map(.JobVersion // 0) | max) // 0) as $v
      | $a | map(select((.JobVersion // 0) == $v and .ClientStatus != "running")) | length
    end'

running_array='[{"Allocations":[{"JobVersion":12,"ClientStatus":"running"}]}]'
unhealthy_array='[{"Allocations":[{"JobVersion":12,"ClientStatus":"pending"}]}]'
object_form='{"Allocations":[{"JobVersion":3,"ClientStatus":"running"}]}'
empty_array='[]'

got="$(printf '%s' "$running_array" | jq -r "$jq_filter")"
ac_assert_eq "$got" "0" "running alloc in array status must count as healthy"

got="$(printf '%s' "$object_form" | jq -r "$jq_filter")"
ac_assert_eq "$got" "0" "object-form status must still count as healthy"

got="$(printf '%s' "$unhealthy_array" | jq -r "$jq_filter")"
ac_assert_eq "$got" "1" "non-running alloc must count as unhealthy"

got="$(printf '%s' "$empty_array" | jq -r "$jq_filter")"
ac_assert_eq "$got" "1" "empty status array must count as unhealthy, not healthy"

ac_pass
