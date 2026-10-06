#!/usr/bin/env bash
# =============================================================================
# tests/acceptance/issue-1841.sh
#
# Issue #1841: the edge dispatcher gives the reproduce/triage/verify sidecars
# DSH_BASE_URL (the local-model/think-budget proxy), not the Claude CLI or
# the OAuth session. Since #1838 the sidecar runs dsh against the local model
# (docker/reproduce/sidecar-agent.sh); DSH_BASE_URL is its only model
# setting. This test only reads files.
#
# Acceptance:
#   1. _dispatch_sidecar_docker mentions no claude/anthropic config.
#   2. _dispatch_sidecar_docker passes DSH_BASE_URL when it is set.
#   3. _dispatch_sidecar_docker still mounts ~/.ssh read-only.
#   4. bash -n docker/edge/dispatcher.sh succeeds.
#
# Run via: tools/run-acceptance.sh 1841
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../lib/acceptance-helpers.sh
source "$REPO_ROOT/tests/lib/acceptance-helpers.sh"

ac_require_cmd bash grep sed

DISPATCHER="$REPO_ROOT/docker/edge/dispatcher.sh"
ac_assert_file "$DISPATCHER" "docker/edge/dispatcher.sh must exist"

# Extract the sidecar launcher body (read-only) with the issue's exact range.
FN_SIDECAR="$(sed -n '/^_dispatch_sidecar_docker()/,/^}/p' "$DISPATCHER")"
[ -n "$FN_SIDECAR" ] \
  || ac_fail "could not extract _dispatch_sidecar_docker from docker/edge/dispatcher.sh"

ac_log "AC 1: sidecar launcher mentions no claude or anthropic thing"
claude_hits="$(grep -nEi 'claude|anthropic' <<<"$FN_SIDECAR" || true)"
[ -z "$claude_hits" ] \
  || ac_fail "_dispatch_sidecar_docker must mention no claude/anthropic thing (got: ${claude_hits})"

ac_log "AC 2: sidecar launcher passes DSH_BASE_URL"
# shellcheck disable=SC2016  # literal ${DSH_BASE_URL}, matching the issue's grep -cF
dsu_count="$(grep -cF 'DSH_BASE_URL=${DSH_BASE_URL}' <<<"$FN_SIDECAR" || true)"
ac_assert_eq "$dsu_count" "1" \
  "_dispatch_sidecar_docker must pass DSH_BASE_URL once (got $dsu_count)"

ac_log "AC 3: sidecar launcher keeps the read-only ~/.ssh mount"
ssh_count="$(grep -cF '/home/agent/.ssh:ro' <<<"$FN_SIDECAR" || true)"
ac_assert_eq "$ssh_count" "1" \
  "_dispatch_sidecar_docker must mount /home/agent/.ssh:ro once (got $ssh_count)"

ac_log "AC 4: dispatcher parses"
bash -n "$DISPATCHER" \
  || ac_fail "bash -n docker/edge/dispatcher.sh failed"

ac_pass
