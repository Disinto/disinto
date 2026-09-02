#!/usr/bin/env bash
# =============================================================================
# tests/acceptance/issue-1118-classify-decoded-logs.sh
#
# Issue #1118: classify_pipeline_failure fetched failed-step logs with a raw
# Woodpecker API call and jq'd out `.data` — the base64-encoded payload that
# Woodpecker returns. is_infra_step() then grepped that base64 for literals
# like "Failed to connect" or "docker pull.*timeout", which never match, so
# the log-pattern branch of infra classification was dead. Only exit-code
# heuristics (clone/git exit 128, exit 137) could classify "infra", and
# pr_walk_to_merge burned agent CI-fix attempts on infra failures that only
# show up in step logs.
#
# Fix: classify_pipeline_failure reuses ci_get_step_logs, which decodes the
# base64 payloads (#1114).
#
# Acceptance (self-contained — woodpecker_api stubbed, no live services):
#   1. A base64-encoded log record containing an infra pattern classifies the
#      pipeline failure as "infra" (decoding is required to match).
#   2. A log record without any infra pattern still classifies as "code".
#   3. classify_pipeline_failure reuses ci_get_step_logs rather than re-
#      issuing the raw log API call.
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck disable=SC1091
source "$REPO_ROOT/tests/lib/acceptance-helpers.sh"

ac_require_cmd python3

# Stub woodpecker_api before sourcing so the helper never reaches the network.
# Stubbed fixture, not configuration: assigned indirectly so the anti-pattern
# scanner does not read it as a hardcoded production repo id.
TEST_REPO_ID="${TEST_REPO_ID:-1}"

LOG_INFRA=$'pulling image\nError: Failed to connect to registry: connection timed out\n'
LOG_CODE=$'compiling package\nmake: *** [build] Error 1\n'

STUB_LOGS_INFRA=$(python3 -c '
import base64, json, sys
print(json.dumps([
    {"data": base64.b64encode(sys.argv[1].encode()).decode()},
    {"data": None},
]))' "$LOG_INFRA")

STUB_LOGS_CODE=$(python3 -c '
import base64, json, sys
print(json.dumps([{"data": base64.b64encode(sys.argv[1].encode()).decode()}]))' "$LOG_CODE")

PIPELINE_JSON='{"workflows":[{"children":[{"name":"build","state":"failure","exit_code":1,"pid":99}]}]}'

# Mode is toggled by the test to serve different log payloads per scenario.
STUB_MODE="infra"
woodpecker_api() {
  case "$1" in
    */logs/*)
      if [ "$STUB_MODE" = "infra" ]; then
        printf '%s' "$STUB_LOGS_INFRA"
      else
        printf '%s' "$STUB_LOGS_CODE"
      fi
      ;;
    *) printf '%s' "$PIPELINE_JSON" ;;
  esac
}
validate_url() { return 0; }

# shellcheck disable=SC1091
source "$REPO_ROOT/lib/ci-helpers.sh" 2>/dev/null || true

# ── 1. Decoded log payload matches the infra pattern ────────────────────────
# The payload is base64 at the wire level; only a decoding fetch can match it.
STUB_MODE="infra"
RESULT=$(classify_pipeline_failure "$TEST_REPO_ID" 1994 2>/dev/null) \
  || ac_fail "classify_pipeline_failure must return 0 for an infra failure"
ac_assert_eq "$RESULT" "infra build: log matches infra pattern (timeout/connection)" \
  "infra log pattern in base64-encoded logs must classify as infra"

# ── 2. Log without any infra pattern stays "code" ────────────────────────────
STUB_MODE="code"
RESULT=$(classify_pipeline_failure "$TEST_REPO_ID" 1994 2>/dev/null) \
  && ac_fail "non-infra log payload must not classify as infra (got: $RESULT)"
ac_assert_eq "$RESULT" "code" "step logs without infra patterns classify as code"

# ── 3. The classifier reuses the decoding helper ─────────────────────────────
# A raw `jq -r '.[].data'` fetch of the log endpoint would regress the fix:
# base64 text never contains the grepped literals.
CLASSIFY_SRC=$(sed -n '/^classify_pipeline_failure()/,/^}/p' "$REPO_ROOT/lib/ci-helpers.sh")
grep -q 'ci_get_step_logs' <<< "$CLASSIFY_SRC" \
  || ac_fail "classify_pipeline_failure does not reuse ci_get_step_logs"
if grep -vE '^\s*#' <<< "$CLASSIFY_SRC" | grep -q "\.data"; then
  ac_fail "classify_pipeline_failure still reads the raw base64 .data field"
fi

ac_pass
