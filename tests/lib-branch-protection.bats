#!/usr/bin/env bats
# lib-branch-protection.bats — tests for the empty-repo deferral added in #1249.
#
# setup_project_branch_protection() must:
#   - return 2 (DEFERRED, never a silent skip) when the repo is CONFIRMED empty
#     (no commits → no branch to protect yet), with an explicit re-run notice;
#   - fall through to the normal ~70s wait path when emptiness is UNKNOWN
#     (API unreachable / missing field), so protection is never silently skipped;
#   - return 1 on a real failure (branch never appears, protection PUT fails).
#
# The Forge API is exercised three ways:
#   - a `curl()` shim (tests 1-8) keyed on URL slug — no network needed;
#   - one real mock-forgejo over HTTP (test 9) end-to-end.
#
# NOTE: bats 1.8.2 `run` executes in a SUBSHELL, so variable side-effects from
# stub functions do NOT propagate back to the test body. Stubs therefore signal
# via mktemp marker FILES (shared across the subshell boundary) instead.

setup() {
  ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
  export FORGE_TOKEN="dummy-token"
  export FORGE_URL="https://forge.example.test"
  export FORGE_OPS_REPO="disinto-admin/disinto-ops"

  # curl() shim — canned repo objects resolved AT CALL TIME, keyed on the URL
  # slug. Only _bp_repo_empty() reaches the shim in tests 1-8 (the wait/apply
  # helpers are stubbed out in those tests). Unknown URL → non-zero (API fail).
  curl() {
    local url="" arg
    while [ "$#" -gt 0 ]; do
      case "$1" in
        -H|-d|-o|-w|--max-time|-X) shift 2 ;;
        -sf|-s|-f|--silent|--fail) shift ;;
        -*) shift ;;
        *) url="$1"; shift ;;
      esac
    done
    case "$url" in
      *"/repos/acme/empty-repo"*)    printf '%s' '{"id":1,"full_name":"acme/empty-repo","empty":true}'; return 0 ;;
      *"/repos/acme/full-repo"*)     printf '%s' '{"id":2,"full_name":"acme/full-repo","empty":false}'; return 0 ;;
      *"/repos/acme/no-field-repo"*) printf '%s' '{"id":3,"full_name":"acme/no-field-repo"}'; return 0 ;;
      *) return 1 ;;
    esac
  }

  source "${ROOT}/lib/branch-protection.sh"
}

# ---------------------------------------------------------------------------
# _bp_repo_empty()
# ---------------------------------------------------------------------------

@test "_bp_repo_empty: confirmed-empty repo reports true" {
  run _bp_repo_empty acme/empty-repo
  [ "$status" -eq 0 ]
  [ "$output" = "true" ]
}

@test "_bp_repo_empty: repo with commits reports false" {
  run _bp_repo_empty acme/full-repo
  [ "$status" -eq 0 ]
  [ "$output" = "false" ]
}

@test "_bp_repo_empty: unreachable API reports unknown (never false)" {
  run _bp_repo_empty acme/missing-repo
  [ "$status" -eq 0 ]
  [ "$output" = "unknown" ]
}

@test "_bp_repo_empty: response without an empty field reports unknown" {
  run _bp_repo_empty acme/no-field-repo
  [ "$status" -eq 0 ]
  [ "$output" = "unknown" ]
}

# ---------------------------------------------------------------------------
# setup_project_branch_protection()
# ---------------------------------------------------------------------------

@test "setup_project_branch_protection: CONFIRMED-empty repo defers (rc 2), never waits" {
  local marker; marker="$(mktemp)"
  _bp_wait_for_branch() { echo waited >> "$marker"; return 1; }
  run setup_project_branch_protection acme/empty-repo master
  [ "$status" -eq 2 ]
  [[ "$output" == *"DEFERRED"* ]]
  [[ "$output" == *"re-run"* ]]
  [[ "$output" == *"acme/empty-repo"* ]]
  [ ! -s "$marker" ]   # the ~70s wait was never attempted
  rm -f "$marker"
}

@test "setup_project_branch_protection: UNKNOWN emptiness falls through to the wait path (no silent skip)" {
  local marker; marker="$(mktemp)"
  _bp_wait_for_branch() { echo waited >> "$marker"; return 1; }
  run setup_project_branch_protection acme/no-field-repo master
  [ "$status" -eq 1 ]
  [ -s "$marker" ]              # the wait WAS attempted
  [[ "$output" != *"DEFERRED"* ]]   # and it was not misreported as a deferral
  rm -f "$marker"
}

@test "setup_project_branch_protection: non-empty repo applies the CI-gated payload (rc 0)" {
  local marker payload_file
  marker="$(mktemp)"; payload_file="$(mktemp)"
  _bp_wait_for_branch() { echo waited >> "$marker"; return 0; }
  _bp_apply_protection() { printf '%s' "$3" > "$payload_file"; return 0; }
  run setup_project_branch_protection acme/full-repo master
  [ "$status" -eq 0 ]
  [ -s "$marker" ]
  [ "$(jq -r '.required_status_checks' "$payload_file")" = "true" ]
  [ "$(jq -r '.status_check_contexts[0]' "$payload_file")" = "ci/woodpecker/pr/ci" ]
  [ "$(jq -r '.merge_whitelist_usernames[0]' "$payload_file")" = "dev-bot" ]
  rm -f "$marker" "$payload_file"
}

@test "setup_project_branch_protection: branch never appearing fails (rc 1), not deferred" {
  local marker; marker="$(mktemp)"
  _bp_wait_for_branch() { echo waited >> "$marker"; return 1; }
  run setup_project_branch_protection acme/full-repo master
  [ "$status" -eq 1 ]
  [ "$(cat "$marker")" = "waited" ]
  [[ "$output" != *"DEFERRED"* ]]
  rm -f "$marker"
}

# ---------------------------------------------------------------------------
# setup_vault_branch_protection() — ops-repo deferral (#1273)
# ---------------------------------------------------------------------------

@test "setup_vault_branch_protection: CONFIRMED-empty ops repo defers (rc 2), never waits" {
  local marker; marker="$(mktemp)"
  _bp_wait_for_branch() { echo waited >> "$marker"; return 1; }
  FORGE_OPS_REPO="acme/empty-repo"
  run setup_vault_branch_protection master
  [ "$status" -eq 2 ]
  [[ "$output" == *"DEFERRED"* ]]
  [[ "$output" == *"re-run"* ]]
  [[ "$output" == *"acme/empty-repo"* ]]
  [ ! -s "$marker" ]   # the ~70s wait was never attempted
  rm -f "$marker"
}

@test "setup_vault_branch_protection: UNKNOWN emptiness falls through to the wait path (no silent skip)" {
  local marker; marker="$(mktemp)"
  _bp_wait_for_branch() { echo waited >> "$marker"; return 1; }
  FORGE_OPS_REPO="acme/no-field-repo"
  run setup_vault_branch_protection master
  [ "$status" -eq 1 ]
  [ -s "$marker" ]              # the wait WAS attempted
  [[ "$output" != *"DEFERRED"* ]]   # and it was not misreported as a deferral
  rm -f "$marker"
}

@test "setup_vault_branch_protection: non-empty ops repo applies the vault payload (rc 0)" {
  local marker payload_file
  marker="$(mktemp)"; payload_file="$(mktemp)"
  _bp_wait_for_branch() { echo waited >> "$marker"; return 0; }
  _bp_apply_protection() { printf '%s' "$3" > "$payload_file"; return 0; }
  FORGE_OPS_REPO="acme/full-repo"
  run setup_vault_branch_protection master
  [ "$status" -eq 0 ]
  [ -s "$marker" ]
  [ "$(jq -r '.admin_enforced' "$payload_file")" = "true" ]
  [ "$(jq -r '.required_approvals' "$payload_file")" = "1" ]
  [ "$(jq -r '.enable_push' "$payload_file")" = "false" ]
  rm -f "$marker" "$payload_file"
}

@test "setup_vault_branch_protection: branch never appearing fails (rc 1), not deferred" {
  local marker; marker="$(mktemp)"
  _bp_wait_for_branch() { echo waited >> "$marker"; return 1; }
  FORGE_OPS_REPO="acme/full-repo"
  run setup_vault_branch_protection master
  [ "$status" -eq 1 ]
  [ "$(cat "$marker")" = "waited" ]
  [[ "$output" != *"DEFERRED"* ]]
  rm -f "$marker"
}

# ---------------------------------------------------------------------------
# Integration: a genuinely empty repo over real HTTP (mock-forgejo)
# ---------------------------------------------------------------------------

@test "integration: init against a fresh empty repo defers (rc 2) over real HTTP" {
  # Real curl against a real mock — no shim.
  unset -f curl
  local port; port=$(( 20000 + RANDOM % 20000 ))
  MOCK_FORGE_PORT="$port" python3 "${ROOT}/tests/mock-forgejo.py" > /tmp/bp-integ-mock.log 2>&1 &
  local mock_pid=$!
  local i
  for i in $(seq 1 150); do
    curl -sf --max-time 1 "http://localhost:${port}/api/v1/version" >/dev/null 2>&1 && break
    sleep 0.2
  done

  local owner="freshowner"
  local base="http://localhost:${port}/api/v1"

  # Create the owner, then a repo with no auto_init → the mock reports empty:true.
  curl -sf -X POST -H "Authorization: token ${FORGE_TOKEN}" -H "Content-Type: application/json" \
    -d "{\"username\":\"${owner}\",\"email\":\"${owner}@example.test\"}" \
    "${base}/admin/users" >/dev/null
  curl -sf -X POST -H "Authorization: token ${FORGE_TOKEN}" -H "Content-Type: application/json" \
    -d "{\"name\":\"fresh\",\"auto_init\":false}" \
    "${base}/users/${owner}/repos" >/dev/null

  # Sanity: the mock really reports this repo as empty.
  local empty_flag
  empty_flag="$(curl -sf -H "Authorization: token ${FORGE_TOKEN}" "${base}/repos/${owner}/fresh" | jq -r '.empty')"
  [ "$empty_flag" = "true" ]

  FORGE_URL="http://localhost:${port}"
  run setup_project_branch_protection "${owner}/fresh" master
  [ "$status" -eq 2 ]
  [[ "$output" == *"DEFERRED"* ]]
  [[ "$output" == *"re-run"* ]]

  kill "$mock_pid" 2>/dev/null || true
  wait "$mock_pid" 2>/dev/null || true
}
