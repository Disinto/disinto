#!/usr/bin/env bash
# =============================================================================
# tests/acceptance/issue-1084.sh — branch protection gate is version-controlled
#
# A force-pushed head gets no ci/woodpecker/push/* pipeline, so a push-event
# status check context would make any rebased PR unmergeable. The fix pins the
# required context to the PR pipeline: the project-repo protection payload in
# lib/branch-protection.sh must declare status_check_contexts =
# ["ci/woodpecker/pr/ci"] with the status-check gate enabled.
#
# Read-only: renders the payload from the lib function and asserts on it with
# jq. No pushes, no issue filing, no state mutation, no network calls.
# =============================================================================
set -euo pipefail

# shellcheck disable=SC1091
source "$(dirname "$0")/../lib/acceptance-helpers.sh"

ac_require_cmd jq

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
ac_assert_file "${ROOT}/lib/branch-protection.sh" \
  "lib/branch-protection.sh not found in repo checkout"

# shellcheck disable=SC1091
source "${ROOT}/lib/branch-protection.sh"

ac_log "rendering project branch-protection payload"
payload="$(project_branch_protection_payload)"

ac_log "asserting payload declares ci/woodpecker/pr/ci as the required status check"
ac_assert_jq '.status_check_contexts == ["ci/woodpecker/pr/ci"]' "$payload" \
  "project branch-protection payload does not declare status_check_contexts [\"ci/woodpecker/pr/ci\"]"
ac_assert_jq '.required_status_checks == true' "$payload" \
  "project branch-protection payload does not enable the status-check gate (required_status_checks)"

ac_pass
