#!/usr/bin/env bats
# =============================================================================
# tests/lib-ci-required-contexts.bats — Unit tests for ci_required_contexts()
# and the required-context reducer in ci_commit_status().
#
# Verifies that when branch protection declares required status check contexts,
# ci_commit_status() reduces over just those — optional workflows that are
# stuck/failed do not block decisions (#1136).
#
# Uses a curl shim to return canned forge API responses.
# =============================================================================

setup() {
  ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
  export FACTORY_ROOT="$ROOT"
  export FORGE_TOKEN="dummy-token"
  export FORGE_URL="https://forge.example.test"
  export FORGE_API="${FORGE_URL}/api/v1/repos/owner/repo"
  export PRIMARY_BRANCH="main"
  export WOODPECKER_REPO_ID="0"  # disable Woodpecker path

  # Reset cache between tests
  unset _CI_REQUIRED_CONTEXTS

  export CALLS_LOG="${BATS_TEST_TMPDIR}/curl-calls.log"
  : > "$CALLS_LOG"

  # Mock forge_api — mirrors lib/env.sh shape
  forge_api() {
    local method="$1" path="$2"
    shift 2
    curl -sf -X "$method" \
      -H "Authorization: token ${FORGE_TOKEN}" \
      -H "Content-Type: application/json" \
      "${FORGE_API}${path}" "$@"
  }

  # Mock forge_api_all (used by some ci-helpers functions)
  forge_api_all() {
    forge_api GET "$1"
  }

  # Mock woodpecker_api (not used when WOODPECKER_REPO_ID=0, but needed for source)
  woodpecker_api() { return 1; }

  # Default mock responses — overridden per test
  # Branch protection: status checks enabled, "ci" is required
  export MOCK_BP_ENABLED="true"
  export MOCK_BP_CONTEXTS='["ci"]'

  # Commit statuses: "ci" success, "edge-subpath" pending
  export MOCK_STATUSES='[
    {"id":1,"context":"ci","status":"success","created_at":"2026-01-01T00:00:00Z"},
    {"id":2,"context":"edge-subpath","status":"pending","created_at":"2026-01-01T00:00:01Z"}
  ]'

  curl() {
    local method="GET" url="" arg
    while [ $# -gt 0 ]; do
      arg="$1"
      case "$arg" in
        -X) method="$2"; shift 2 ;;
        -H|-d|--data-binary|-o) shift 2 ;;
        -w) shift 2 ;;
        -sf|-s|-f|--silent|--fail) shift ;;
        *) url="$arg"; shift ;;
      esac
    done
    printf '%s %s\n' "$method" "$url" >> "$CALLS_LOG"

    case "$url" in
      *"/branch_protections/"*)
        printf '{"enable_status_check":%s,"status_check_contexts":%s}' \
          "$MOCK_BP_ENABLED" "$MOCK_BP_CONTEXTS"
        ;;
      *"/commits/"*"/status")
        printf '{"state":"pending","statuses":%s}' "$MOCK_STATUSES"
        ;;
      *)
        return 1
        ;;
    esac
    return 0
  }

  source "${ROOT}/lib/ci-helpers.sh"
}

# ── ci_required_contexts tests ───────────────────────────────────────────────

@test "ci_required_contexts returns context list when status checks enabled" {
  run ci_required_contexts
  [ "$status" -eq 0 ]
  [[ "$output" == "ci" ]]
}

@test "ci_required_contexts returns empty when status checks disabled" {
  export MOCK_BP_ENABLED="false"
  unset _CI_REQUIRED_CONTEXTS
  run ci_required_contexts
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "ci_required_contexts returns empty when branch protection not found" {
  curl() {
    return 1
  }
  unset _CI_REQUIRED_CONTEXTS
  run ci_required_contexts
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "ci_required_contexts caches result across calls" {
  ci_required_contexts >/dev/null
  ci_required_contexts >/dev/null
  # Only one API call despite two invocations
  local call_count
  call_count=$(grep -c "branch_protections" "$CALLS_LOG" 2>/dev/null || echo 0)
  [ "$call_count" -eq 1 ]
}

@test "ci_required_contexts returns multiple contexts" {
  export MOCK_BP_CONTEXTS='["ci","lint"]'
  unset _CI_REQUIRED_CONTEXTS
  run ci_required_contexts
  [ "$status" -eq 0 ]
  [[ "$output" == *"ci"* ]]
  [[ "$output" == *"lint"* ]]
}

# ── ci_commit_status with required contexts ──────────────────────────────────

@test "ci_commit_status returns success when required context passes (optional pending)" {
  # "ci" is success, "edge-subpath" is pending — should report success
  run ci_commit_status "abc123"
  [ "$status" -eq 0 ]
  [[ "$output" == "success" ]]
}

@test "ci_commit_status returns failure when required context fails (optional success)" {
  export MOCK_STATUSES='[
    {"id":1,"context":"ci","status":"failure","created_at":"2026-01-01T00:00:00Z"},
    {"id":2,"context":"edge-subpath","status":"success","created_at":"2026-01-01T00:00:01Z"}
  ]'
  unset _CI_REQUIRED_CONTEXTS
  run ci_commit_status "abc123"
  [ "$status" -eq 0 ]
  [[ "$output" == "failure" ]]
}

@test "ci_commit_status returns pending when required context has no status yet" {
  export MOCK_STATUSES='[
    {"id":1,"context":"edge-subpath","status":"success","created_at":"2026-01-01T00:00:00Z"}
  ]'
  unset _CI_REQUIRED_CONTEXTS
  run ci_commit_status "abc123"
  [ "$status" -eq 0 ]
  [[ "$output" == "pending" ]]
}

@test "ci_commit_status returns success when all required contexts pass" {
  export MOCK_BP_CONTEXTS='["ci","lint"]'
  export MOCK_STATUSES='[
    {"id":1,"context":"ci","status":"success","created_at":"2026-01-01T00:00:00Z"},
    {"id":2,"context":"lint","status":"success","created_at":"2026-01-01T00:00:01Z"},
    {"id":3,"context":"edge-subpath","status":"failure","created_at":"2026-01-01T00:00:02Z"}
  ]'
  unset _CI_REQUIRED_CONTEXTS
  run ci_commit_status "abc123"
  [ "$status" -eq 0 ]
  [[ "$output" == "success" ]]
}

@test "ci_commit_status returns failure when any required context fails" {
  export MOCK_BP_CONTEXTS='["ci","lint"]'
  export MOCK_STATUSES='[
    {"id":1,"context":"ci","status":"success","created_at":"2026-01-01T00:00:00Z"},
    {"id":2,"context":"lint","status":"error","created_at":"2026-01-01T00:00:01Z"},
    {"id":3,"context":"edge-subpath","status":"success","created_at":"2026-01-01T00:00:02Z"}
  ]'
  unset _CI_REQUIRED_CONTEXTS
  run ci_commit_status "abc123"
  [ "$status" -eq 0 ]
  [[ "$output" == "failure" ]]
}

@test "ci_commit_status uses latest status per context (re-run overwrites)" {
  export MOCK_STATUSES='[
    {"id":1,"context":"ci","status":"failure","created_at":"2026-01-01T00:00:00Z"},
    {"id":3,"context":"ci","status":"success","created_at":"2026-01-01T00:01:00Z"}
  ]'
  unset _CI_REQUIRED_CONTEXTS
  run ci_commit_status "abc123"
  [ "$status" -eq 0 ]
  [[ "$output" == "success" ]]
}

# ── incident reproduction shape ──────────────────────────────────────────────

@test "incident shape: required ci passes, optional edge-subpath stuck pending — returns success" {
  # This is the exact scenario from the 2026-04-21 incident:
  # - "ci" workflow: success
  # - "edge-subpath" (optional): stuck pending
  # - Combined state would be "pending" (worst of all)
  # - With fix: only "ci" matters → success
  export MOCK_BP_CONTEXTS='["ci"]'
  export MOCK_STATUSES='[
    {"id":1,"context":"ci","status":"success","created_at":"2026-01-01T00:00:00Z"},
    {"id":2,"context":"edge-subpath","status":"pending","created_at":"2026-01-01T00:00:01Z"},
    {"id":3,"context":"caddy-validate","status":"failure","created_at":"2026-01-01T00:00:02Z"}
  ]'
  unset _CI_REQUIRED_CONTEXTS
  run ci_commit_status "abc123"
  [ "$status" -eq 0 ]
  [[ "$output" == "success" ]]
}

# ── fallback: no required contexts → original behavior ───────────────────────

@test "ci_commit_status falls back to combined state when no required contexts" {
  export MOCK_BP_ENABLED="false"
  export WOODPECKER_REPO_ID="0"
  unset _CI_REQUIRED_CONTEXTS

  # Combined state is "pending" (from MOCK_STATUSES default)
  # Without required contexts, falls through to forge combined .state
  run ci_commit_status "abc123"
  [ "$status" -eq 0 ]
  # Falls back to .state from combined endpoint → "pending"
  [[ "$output" == "pending" ]]
}
