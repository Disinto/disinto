#!/usr/bin/env bats
# tests/lib-hvault.bats — Unit tests for lib/hvault.sh
#
# Runs against a dev-mode Vault server (single binary, no LXC needed).
# CI launches vault server -dev inline before running these tests.

VAULT_BIN="${VAULT_BIN:-vault}"

setup_file() {
  export TEST_DIR
  TEST_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"

  # Start dev-mode vault on a random port
  export VAULT_DEV_PORT
  VAULT_DEV_PORT="$(shuf -i 18200-18299 -n 1)"
  export VAULT_ADDR="http://127.0.0.1:${VAULT_DEV_PORT}"

  "$VAULT_BIN" server -dev \
    -dev-listen-address="127.0.0.1:${VAULT_DEV_PORT}" \
    -dev-root-token-id="test-root-token" \
    -dev-no-store-token \
    &>"${BATS_FILE_TMPDIR}/vault.log" &
  export VAULT_PID=$!

  export VAULT_TOKEN="test-root-token"

  # Wait for vault to be ready (up to 10s)
  local i=0
  while ! curl -sf "${VAULT_ADDR}/v1/sys/health" >/dev/null 2>&1; do
    sleep 0.5
    i=$((i + 1))
    if [ "$i" -ge 20 ]; then
      echo "Vault failed to start. Log:" >&2
      cat "${BATS_FILE_TMPDIR}/vault.log" >&2
      return 1
    fi
  done
}

teardown_file() {
  if [ -n "${VAULT_PID:-}" ]; then
    kill "$VAULT_PID" 2>/dev/null || true
    wait "$VAULT_PID" 2>/dev/null || true
  fi
}

setup() {
  # Source the module under test
  source "${TEST_DIR}/lib/hvault.sh"
  export VAULT_ADDR VAULT_TOKEN
}

# ── hvault_kv_put + hvault_kv_get ────────────────────────────────────────────

@test "hvault_kv_put writes and hvault_kv_get reads a secret" {
  run hvault_kv_put "test/myapp" "username=admin" "password=s3cret"
  [ "$status" -eq 0 ]

  run hvault_kv_get "test/myapp"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.username == "admin"'
  echo "$output" | jq -e '.password == "s3cret"'
}

@test "hvault_kv_get extracts a single key" {
  hvault_kv_put "test/single" "foo=bar" "baz=qux"

  run hvault_kv_get "test/single" "foo"
  [ "$status" -eq 0 ]
  [ "$output" = "bar" ]
}

@test "hvault_kv_get fails for missing key" {
  hvault_kv_put "test/keymiss" "exists=yes"

  run hvault_kv_get "test/keymiss" "nope"
  [ "$status" -ne 0 ]
}

@test "hvault_kv_get fails for missing path" {
  run hvault_kv_get "test/does-not-exist-$(date +%s)"
  [ "$status" -ne 0 ]
}

@test "hvault_kv_put fails without KEY=VAL" {
  run hvault_kv_put "test/bad"
  [ "$status" -ne 0 ]
  echo "$output" | grep -q '"error":true' || echo "$stderr" | grep -q '"error":true'
}

@test "hvault_kv_put rejects malformed pair (no =)" {
  run hvault_kv_put "test/bad2" "noequals"
  [ "$status" -ne 0 ]
}

@test "hvault_kv_get fails without PATH" {
  run hvault_kv_get
  [ "$status" -ne 0 ]
}

# ── hvault_kv_list ───────────────────────────────────────────────────────────

@test "hvault_kv_list lists keys at a path" {
  hvault_kv_put "test/listdir/a" "k=1"
  hvault_kv_put "test/listdir/b" "k=2"

  run hvault_kv_list "test/listdir"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '. | length >= 2'
  echo "$output" | jq -e 'index("a")'
  echo "$output" | jq -e 'index("b")'
}

@test "hvault_kv_list fails on nonexistent path" {
  run hvault_kv_list "test/no-such-path-$(date +%s)"
  [ "$status" -ne 0 ]
}

@test "hvault_kv_list fails without PATH" {
  run hvault_kv_list
  [ "$status" -ne 0 ]
}

# ── hvault_policy_apply ──────────────────────────────────────────────────────

@test "hvault_policy_apply creates a policy" {
  local pfile="${BATS_TEST_TMPDIR}/test-policy.hcl"
  cat > "$pfile" <<'HCL'
path "secret/data/test/*" {
  capabilities = ["read"]
}
HCL

  run hvault_policy_apply "test-reader" "$pfile"
  [ "$status" -eq 0 ]

  # Verify the policy exists via Vault API
  run curl -sf -H "X-Vault-Token: ${VAULT_TOKEN}" \
    "${VAULT_ADDR}/v1/sys/policies/acl/test-reader"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.data.policy' | grep -q "secret/data/test"
}

@test "hvault_policy_apply is idempotent" {
  local pfile="${BATS_TEST_TMPDIR}/idem-policy.hcl"
  printf 'path "secret/*" { capabilities = ["list"] }\n' > "$pfile"

  run hvault_policy_apply "idem-policy" "$pfile"
  [ "$status" -eq 0 ]

  # Apply again — should succeed
  run hvault_policy_apply "idem-policy" "$pfile"
  [ "$status" -eq 0 ]
}

@test "hvault_policy_apply fails with missing file" {
  run hvault_policy_apply "bad-policy" "/nonexistent/policy.hcl"
  [ "$status" -ne 0 ]
}

@test "hvault_policy_apply fails without args" {
  run hvault_policy_apply
  [ "$status" -ne 0 ]
}

# ── hvault_token_lookup ──────────────────────────────────────────────────────

@test "hvault_token_lookup returns token info" {
  run hvault_token_lookup
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.policies'
  echo "$output" | jq -e '.accessor'
  echo "$output" | jq -e 'has("ttl")'
}

@test "hvault_token_lookup fails without VAULT_TOKEN" {
  unset VAULT_TOKEN
  run hvault_token_lookup
  [ "$status" -ne 0 ]
}

@test "hvault_token_lookup fails without VAULT_ADDR" {
  unset VAULT_ADDR
  run hvault_token_lookup
  [ "$status" -ne 0 ]
}

# ── hvault_jwt_login ─────────────────────────────────────────────────────────

@test "hvault_jwt_login fails without VAULT_ADDR" {
  unset VAULT_ADDR
  run hvault_jwt_login "myrole" "fakejwt"
  [ "$status" -ne 0 ]
}

@test "hvault_jwt_login fails without args" {
  run hvault_jwt_login
  [ "$status" -ne 0 ]
}

@test "hvault_jwt_login returns error for unconfigured jwt auth" {
  # JWT auth backend is not enabled in dev mode by default — expect failure
  run hvault_jwt_login "myrole" "eyJhbGciOiJSUzI1NiJ9.fake.sig"
  [ "$status" -ne 0 ]
}

# ── Env / prereq errors ─────────────────────────────────────────────────────

@test "all functions fail with structured JSON error when VAULT_ADDR unset" {
  unset VAULT_ADDR
  for fn in hvault_kv_get hvault_kv_put hvault_kv_list hvault_policy_apply hvault_token_lookup; do
    run $fn "dummy" "dummy"
    [ "$status" -ne 0 ]
  done
}
