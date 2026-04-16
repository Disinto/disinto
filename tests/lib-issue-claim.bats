#!/usr/bin/env bats
# =============================================================================
# tests/lib-issue-claim.bats — Regression guard for the issue_claim TOCTOU
# fix landed in #830.
#
# Before the fix, two dev agents polling concurrently could both observe
# `.assignee == null`, both PATCH the assignee, and Forgejo's last-write-wins
# semantics would leave the loser believing it had claimed successfully.
# Two agents would then implement the same issue and collide at the PR/branch
# stage.
#
# The fix re-reads the assignee after the PATCH and aborts when it doesn't
# match self, with label writes moved AFTER the verification so a losing
# claim leaves no stray `in-progress` label.
#
# These tests stub `curl` with a bash function so each call tree can be
# driven through a specific response sequence (pre-check, PATCH, re-read)
# without a live Forgejo. The stub records every HTTP call to
# `$CALLS_LOG` for assertions.
# =============================================================================

setup() {
  ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
  export FACTORY_ROOT="$ROOT"
  export FORGE_TOKEN="dummy-token"
  export FORGE_URL="https://forge.example.test"
  export FORGE_API="${FORGE_URL}/api/v1"

  export CALLS_LOG="${BATS_TEST_TMPDIR}/curl-calls.log"
  : > "$CALLS_LOG"
  export ISSUE_GET_COUNT_FILE="${BATS_TEST_TMPDIR}/issue-get-count"
  echo 0 > "$ISSUE_GET_COUNT_FILE"

  # Scenario knobs — overridden per @test.
  export MOCK_ME="bot"
  export MOCK_INITIAL_ASSIGNEE=""
  export MOCK_RECHECK_ASSIGNEE="bot"

  # Stand-in for lib/env.sh's forge_api (we don't source env.sh — too
  # much unrelated setup). Shape mirrors the real helper closely enough
  # that _ilc_ensure_label_id() works.
  forge_api() {
    local method="$1" path="$2"
    shift 2
    curl -sf -X "$method" \
      -H "Authorization: token ${FORGE_TOKEN}" \
      -H "Content-Type: application/json" \
      "${FORGE_API}${path}" "$@"
  }

  # curl shim — parses method + URL out of the argv and dispatches
  # canned responses per endpoint. Every call gets logged as
  # `METHOD URL` (one line) to $CALLS_LOG for later grep-based asserts.
  curl() {
    local method="GET" url="" arg
    while [ $# -gt 0 ]; do
      arg="$1"
      case "$arg" in
        -X) method="$2"; shift 2 ;;
        -H|-d|--data-binary|-o) shift 2 ;;
        -sf|-s|-f|--silent|--fail) shift ;;
        *) url="$arg"; shift ;;
      esac
    done
    printf '%s %s\n' "$method" "$url" >> "$CALLS_LOG"

    case "$method $url" in
      "GET ${FORGE_URL}/api/v1/user")
        printf '{"login":"%s"}' "$MOCK_ME"
        ;;
      "GET ${FORGE_API}/issues/"*)
        # Distinguish pre-check (first GET) from re-read (subsequent GETs)
        # via a counter file that persists across curl invocations in the
        # same test.
        local n
        n=$(cat "$ISSUE_GET_COUNT_FILE")
        n=$((n + 1))
        echo "$n" > "$ISSUE_GET_COUNT_FILE"
        local who
        if [ "$n" -eq 1 ]; then
          who="$MOCK_INITIAL_ASSIGNEE"
        else
          who="$MOCK_RECHECK_ASSIGNEE"
        fi
        if [ -z "$who" ]; then
          printf '{"assignee":null}'
        else
          printf '{"assignee":{"login":"%s"}}' "$who"
        fi
        ;;
      "PATCH ${FORGE_API}/issues/"*)
        : # accept any PATCH; body is ignored by the mock
        ;;
      "GET ${FORGE_API}/labels")
        printf '[]'
        ;;
      "POST ${FORGE_API}/labels")
        printf '{"id":99}'
        ;;
      "POST ${FORGE_API}/issues/"*"/labels")
        :
        ;;
      "DELETE ${FORGE_API}/issues/"*"/labels/"*)
        :
        ;;
      *)
        return 1
        ;;
    esac
    return 0
  }

  # shellcheck source=../lib/issue-lifecycle.sh
  source "${ROOT}/lib/issue-lifecycle.sh"
}

# ── helpers ──────────────────────────────────────────────────────────────────

# count_calls METHOD URL — count matching lines in $CALLS_LOG.
count_calls() {
  local method="$1" url="$2"
  grep -cF "${method} ${url}" "$CALLS_LOG" 2>/dev/null || echo 0
}

# ── happy path ───────────────────────────────────────────────────────────────

@test "issue_claim returns 0 when re-read confirms self (no regression, single agent)" {
  export MOCK_ME="bot"
  export MOCK_INITIAL_ASSIGNEE=""
  export MOCK_RECHECK_ASSIGNEE="bot"

  run issue_claim 42
  [ "$status" -eq 0 ]

  # Exactly two GETs to /issues/42 — pre-check and post-PATCH re-read.
  [ "$(count_calls GET "${FORGE_API}/issues/42")" -eq 2 ]

  # Assignee PATCH fired.
  [ "$(count_calls PATCH "${FORGE_API}/issues/42")" -eq 1 ]

  # in-progress label added (POST /issues/42/labels).
  [ "$(count_calls POST "${FORGE_API}/issues/42/labels")" -eq 1 ]
}

# ── lost race ────────────────────────────────────────────────────────────────

@test "issue_claim returns 1 and leaves no stray in-progress when re-read shows another agent" {
  export MOCK_ME="bot"
  export MOCK_INITIAL_ASSIGNEE=""
  export MOCK_RECHECK_ASSIGNEE="rival"

  run issue_claim 42
  [ "$status" -eq 1 ]
  [[ "$output" == *"claim lost to rival"* ]]

  # Re-read happened (two GETs) — this is the new verification step.
  [ "$(count_calls GET "${FORGE_API}/issues/42")" -eq 2 ]

  # PATCH happened (losers still PATCH before verifying).
  [ "$(count_calls PATCH "${FORGE_API}/issues/42")" -eq 1 ]

  # CRITICAL: no in-progress label operations on a lost claim.
  # (No need to roll back what was never written.)
  [ "$(count_calls POST "${FORGE_API}/issues/42/labels")" -eq 0 ]
  [ "$(count_calls GET "${FORGE_API}/labels")" -eq 0 ]
}

# ── pre-check skip ──────────────────────────────────────────────────────────

@test "issue_claim skips early (no PATCH) when pre-check shows another assignee" {
  export MOCK_ME="bot"
  export MOCK_INITIAL_ASSIGNEE="rival"
  export MOCK_RECHECK_ASSIGNEE="rival"

  run issue_claim 42
  [ "$status" -eq 1 ]
  [[ "$output" == *"already assigned to rival"* ]]

  # Only the pre-check GET — no PATCH, no re-read, no labels.
  [ "$(count_calls GET "${FORGE_API}/issues/42")" -eq 1 ]
  [ "$(count_calls PATCH "${FORGE_API}/issues/42")" -eq 0 ]
  [ "$(count_calls POST "${FORGE_API}/issues/42/labels")" -eq 0 ]
}
