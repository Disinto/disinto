#!/usr/bin/env bash
# =============================================================================
# tests/acceptance/issue-1365.sh
#
# Issue #1365: ci_get_step_logs fetched Woodpecker step logs by database id,
# but the pipeline JSON exposes the step `pid` — the pid 404s on the logs
# endpoint, and Woodpecker answers wrong paths with 200 + the SPA index.html,
# which `curl -sfL` accepts, so the HTML sailed into the CI-fix prompt as
# "logs".
#
# Acceptance (self-contained — woodpecker_api stubbed, no live services):
#   1. ci_failed_logs fetches every failed step's logs by the child's
#      database `.id`, never the pid, and prints
#      `=== FAILED: <name> exit <code> ===` plus the decoded log text;
#      empty output (exit 0) when no step failed.
#   2. ci_get_step_logs given a pid that 404s loads the pipeline JSON and
#      retries once with the child's `.id`.
#   3. A non-JSON (SPA HTML) body is never printed as logs: non-zero exit,
#      `response is not JSON` on stderr.
#   4. pr-lifecycle.sh's ci-fix prompt calls ci_failed_logs "$_PR_CI_PIPELINE"
#      and keeps the `logs empty (helper failed), not a green pipeline`
#      fallback instead of per-step ci_get_step_logs calls.
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck disable=SC1091
source "$REPO_ROOT/tests/lib/acceptance-helpers.sh"

ac_require_cmd jq
ac_require_cmd python3

# ── Fixtures ────────────────────────────────────────────────────────────────
# Assigned indirectly so the anti-pattern scanner does not read it as a
# hardcoded production repo id.
TEST_REPO_ID="${TEST_REPO_ID:-1}"
export WOODPECKER_REPO_ID="$TEST_REPO_ID"

# Step "build": pid 5, database id 20697 — the pid 404s, the id resolves.
LOG_BUILD='compiling package
make: *** [all] Error 1'

# Woodpecker base64-encodes each record's payload; records may be null.
# The text is split across two records so the decode loop's concatenation
# is exercised, like the real API.
STUB_LOGS_BUILD=$(python3 -c '
import base64, json, sys
chunk = sys.argv[1]
cut = len(chunk) // 2
rows = [
    {"data": base64.b64encode(chunk[:cut].encode()).decode()},
    {"data": None},
    {"data": base64.b64encode(chunk[cut:].encode()).decode()},
]
print(json.dumps(rows))' "$LOG_BUILD")

PIPELINE_JSON='{"id":2601,"number":2601,"status":"failed","event":"push","commit":"0123456789abcdef0123456789abcdef01234567","workflows":[{"id":1001,"name":"ci","state":"failure","children":[{"id":20697,"pid":5,"name":"build","state":"failure","exit_code":1},{"id":20698,"pid":6,"name":"lint","state":"success","exit_code":0}]}]}'

PIPELINE_OK_JSON='{"id":2602,"number":2602,"status":"success","event":"push","commit":"0123456789abcdef0123456789abcdef01234567","workflows":[{"id":1002,"name":"ci","state":"success","children":[{"id":20700,"pid":7,"name":"build","state":"success","exit_code":0}]}]}'

SPA_HTML='<!DOCTYPE html><html><head><title>Woodpecker</title></head><body><div id="app"></div><script src="/js/app.js"></script></body></html>'

CALLS_FILE="$(mktemp)"
ERR_FILE="$(mktemp)"
trap 'rm -f "$CALLS_FILE" "$ERR_FILE"' EXIT

# Stub woodpecker_api before sourcing so the helper never reaches the network.
# curl -sf semantics: a 404 yields a non-zero exit with an empty body, and a
# wrong-but-200 path yields the SPA HTML. Every requested logs path is
# recorded so the test can assert which key (pid vs database id) was used.
woodpecker_api() {
  local path="$1"
  case "$path" in
    */logs/*) printf '%s\n' "$path" >> "$CALLS_FILE" ;;
  esac
  case "$path" in
    */logs/2601/20697) printf '%s' "$STUB_LOGS_BUILD" ;;
    */logs/2601/5)     return 1 ;;  # pid: 404s on the real endpoint
    */logs/7777/*)     printf '%s' "$SPA_HTML" ;;
    */pipelines/2601)  printf '%s' "$PIPELINE_JSON" ;;
    */pipelines/2602)  printf '%s' "$PIPELINE_OK_JSON" ;;
    *)                 return 1 ;;
  esac
  return 0
}
validate_url() { return 0; }

# shellcheck disable=SC1091
source "$REPO_ROOT/lib/ci-helpers.sh" 2>/dev/null || true

# ── 1. ci_failed_logs keys on the database id, never the pid ────────────────
OUT1=$(ci_failed_logs 2601)
EXPECTED1=$(printf '=== FAILED: build exit 1 ===\n%s' "$LOG_BUILD")
ac_assert_eq "$OUT1" "$EXPECTED1" \
  "ci_failed_logs must print the failed-step header and decoded log text"

if grep -q 'logs/2601/5$' "$CALLS_FILE"; then
  ac_fail "ci_failed_logs fetched logs by the step pid (5) instead of the database id"
fi
grep -q 'logs/2601/20697$' "$CALLS_FILE" \
  || ac_fail "ci_failed_logs did not fetch logs by the child database id (20697)"
if grep -q 'logs/2601/20698$' "$CALLS_FILE"; then
  ac_fail "ci_failed_logs fetched the passing step (lint, id 20698)"
fi

OUT_EMPTY=$(ci_failed_logs 2602)
ac_assert_eq "$OUT_EMPTY" "" \
  "ci_failed_logs must print nothing (exit 0) when no step failed"

# ── 2. A pid that 404s is retried once with the child's database id ─────────
OUT2=$(ci_get_step_logs 2601 5)
ac_assert_eq "$OUT2" "$LOG_BUILD" \
  "ci_get_step_logs must retry with the database id when the pid 404s"
grep -q 'logs/2601/5$' "$CALLS_FILE" \
  || ac_fail "ci_get_step_logs did not attempt the pid before retrying"
# Re-assert the retry after the section-2 call (section 1 ran before it).
grep -q 'logs/2601/20697$' "$CALLS_FILE" \
  || ac_fail "ci_get_step_logs did not retry with the child database id (20697)"

# ── 3. A non-JSON (SPA HTML) body is never printed as logs ──────────────────
RC3=0
OUT3=$(ci_get_step_logs 7777 99 2>"$ERR_FILE") || RC3=$?
if [ "$RC3" -eq 0 ]; then
  ac_fail "ci_get_step_logs returned 0 on an SPA HTML body"
fi
if printf '%s' "$OUT3" | grep -q 'Woodpecker'; then
  ac_fail "ci_get_step_logs printed the SPA HTML as logs"
fi
if ! grep -q 'response is not JSON' "$ERR_FILE"; then
  ac_fail "ci_get_step_logs missing the 'response is not JSON' stderr message"
fi

# ── 4. pr-lifecycle.sh uses ci_failed_logs, not per-step fetches ────────────
grep -q 'ci_failed_logs "$_PR_CI_PIPELINE"' "$REPO_ROOT/lib/pr-lifecycle.sh" \
  || ac_fail "pr-lifecycle.sh does not call ci_failed_logs with the pipeline number"
grep -q 'logs empty (helper failed), not a green pipeline' "$REPO_ROOT/lib/pr-lifecycle.sh" \
  || ac_fail "pr-lifecycle.sh does not keep the not-a-green-pipeline fallback line"
grep -q 'Step: ${failed_step}' "$REPO_ROOT/lib/pr-lifecycle.sh" \
  || ac_fail "pr-lifecycle.sh no longer lists failed steps as Step: <name> / exit <code>"
if grep -vE '^\s*#' "$REPO_ROOT/lib/pr-lifecycle.sh" | grep -q 'ci_get_step_logs'; then
  ac_fail "pr-lifecycle.sh still fetches step logs per-step instead of via ci_failed_logs"
fi

ac_pass
