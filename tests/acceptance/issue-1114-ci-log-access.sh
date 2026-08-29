#!/usr/bin/env bash
# =============================================================================
# tests/acceptance/issue-1114-ci-log-access.sh
#
# Issue #1114: the dev agent was asked to fix CI failures it could not see.
# WOODPECKER_TOKEN was never delivered to the agent container, so
# lib/ci-debug.sh aborted on an unbound variable, _PR_CI_ERROR_LOG stayed
# empty, and the CI-fix prompt fell back to "No logs available." — which reads
# as "the pipeline produced no output" rather than "the credential is missing".
#
# A second fault sat underneath it: ci_get_step_logs emitted the API's raw
# `.data` field, which Woodpecker base64-encodes, so even a credentialed call
# returned unreadable text.
#
# Acceptance (self-contained — woodpecker_api stubbed, no live services):
#   1. ci_get_step_logs base64-decodes the log payload and skips null records.
#   2. The jobspecs deliver WOODPECKER_TOKEN via a Vault template stanza and
#      never as a literal.
#   3. lib/ci-debug.sh fetches over the REST API — no woodpecker-cli, which is
#      absent from the agent image.
#   4. pr_poll_ci records WHY retrieval failed instead of leaving the variable
#      empty, and the prompt's fallback no longer claims there were no logs.
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck disable=SC1091
source "$REPO_ROOT/tests/lib/acceptance-helpers.sh"

ac_require_cmd jq
ac_require_cmd python3

# ── 1. ci_get_step_logs decodes base64 and tolerates null records ───────────
# Stub woodpecker_api before sourcing so the helper never reaches the network.
WOODPECKER_REPO_ID=1
export WOODPECKER_REPO_ID

PLAIN='+ shellcheck lib/foo.sh
lib/foo.sh:12:1: warning: unused variable [SC2034]'

STUB_JSON=$(python3 - "$PLAIN" <<'PY'
import base64, json, sys
text = sys.argv[1]
half = len(text) // 2
print(json.dumps([
    {"data": base64.b64encode(text[:half].encode()).decode()},
    {"data": None},
    {"data": base64.b64encode(text[half:].encode()).decode()},
]))
PY
)

woodpecker_api() { printf '%s' "$STUB_JSON"; }
validate_url() { return 0; }

# ci-helpers.sh is sourced for ci_get_step_logs only; the stubs above shadow
# the network path.
# shellcheck disable=SC1091
source "$REPO_ROOT/lib/ci-helpers.sh" 2>/dev/null || true

DECODED=$(ci_get_step_logs 1994 13701)
ac_assert_eq "$DECODED" "$PLAIN" \
  "ci_get_step_logs must base64-decode the log payload and skip null records"

if printf '%s' "$DECODED" | grep -q 'jq -r'; then
  ac_fail "ci_get_step_logs still returns raw .data"
fi

# ── 2. Token arrives from Vault, never as a literal ─────────────────────────
for job in agents-dev-qwen agents-review-qwen; do
  spec="$REPO_ROOT/nomad/jobs/${job}.hcl"
  ac_assert_file "$spec" "jobspec ${job}.hcl must exist"

  grep -q 'WOODPECKER_TOKEN={{ .Data.data.woodpecker_token }}' "$spec" \
    || ac_fail "${job}.hcl does not render WOODPECKER_TOKEN from Vault"
  grep -q 'kv/data/disinto/shared/ci' "$spec" \
    || ac_fail "${job}.hcl does not read the shared/ci Vault path"
  grep -q 'WOODPECKER_SERVER' "$spec" \
    || ac_fail "${job}.hcl does not set WOODPECKER_SERVER"
  grep -q 'WOODPECKER_REPO_ID' "$spec" \
    || ac_fail "${job}.hcl does not set WOODPECKER_REPO_ID"

  # A literal would be an assignment to something other than a template
  # expression or the seed-me placeholder.
  if grep -E 'WOODPECKER_TOKEN\s*=' "$spec" \
     | grep -vq -e '{{' -e 'seed-me'; then
    ac_fail "${job}.hcl appears to carry a literal WOODPECKER_TOKEN"
  fi
done

# ── 3. ci-debug.sh uses the API, not the absent CLI ─────────────────────────
# Match an invocation, not the comment that explains why there isn't one.
if grep -vE '^\s*#' "$REPO_ROOT/lib/ci-debug.sh" | grep -q 'woodpecker-cli'; then
  ac_fail "lib/ci-debug.sh still shells out to woodpecker-cli, absent from the agent image"
fi
grep -q 'ci_get_step_logs' "$REPO_ROOT/lib/ci-debug.sh" \
  || ac_fail "lib/ci-debug.sh does not reuse ci_get_step_logs"

# ── 4. Retrieval failures are named, not silently empty ────────────────────
if grep -q 'No logs available\.' "$REPO_ROOT/lib/pr-lifecycle.sh"; then
  ac_fail "lib/pr-lifecycle.sh still falls back to \"No logs available.\""
fi
grep -q 'CI log retrieval failed' "$REPO_ROOT/lib/pr-lifecycle.sh" \
  || ac_fail "lib/pr-lifecycle.sh does not report why CI log retrieval failed"
grep -q 'WOODPECKER_TOKEN is not set' "$REPO_ROOT/lib/pr-lifecycle.sh" \
  || ac_fail "lib/pr-lifecycle.sh does not distinguish a missing credential"

ac_pass
