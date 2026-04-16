#!/usr/bin/env bats
# tests/vault-import.bats — Tests for tools/vault-import.sh
#
# Runs against a dev-mode Vault server (single binary, no LXC needed).
# CI launches vault server -dev inline before running these tests.

VAULT_BIN="${VAULT_BIN:-vault}"
IMPORT_SCRIPT="${BATS_TEST_DIRNAME}/../tools/vault-import.sh"
FIXTURES_DIR="${BATS_TEST_DIRNAME}/fixtures"

setup_file() {
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
  # Source the module under test for hvault functions
  source "${BATS_TEST_DIRNAME}/../lib/hvault.sh"
  export VAULT_ADDR VAULT_TOKEN
}

# --- Security checks ---

@test "refuses to run if VAULT_ADDR is not localhost" {
  export VAULT_ADDR="http://prod-vault.example.com:8200"
  run "$IMPORT_SCRIPT" \
    --env "$FIXTURES_DIR/dot-env-complete" \
    --sops "$FIXTURES_DIR/.env.vault.enc" \
    --age-key "$FIXTURES_DIR/age-keys.txt"
  [ "$status" -ne 0 ]
  echo "$output" | grep -q "Security check failed"
}

@test "refuses if age key file permissions are not 0400" {
  # Create a temp file with wrong permissions
  local bad_key="${BATS_TEST_TMPDIR}/bad-ages.txt"
  echo "AGE-SECRET-KEY-1TEST" > "$bad_key"
  chmod 644 "$bad_key"

  run "$IMPORT_SCRIPT" \
    --env "$FIXTURES_DIR/dot-env-complete" \
    --sops "$FIXTURES_DIR/.env.vault.enc" \
    --age-key "$bad_key"
  [ "$status" -ne 0 ]
  echo "$output" | grep -q "permissions"
}

# --- Dry-run mode ─────────────────────────────────────────────────────────────

@test "--dry-run prints plan without writing to Vault" {
  run "$IMPORT_SCRIPT" \
    --env "$FIXTURES_DIR/dot-env-complete" \
    --sops "$FIXTURES_DIR/.env.vault.enc" \
    --age-key "$FIXTURES_DIR/age-keys.txt" \
    --dry-run
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "DRY-RUN"
  echo "$output" | grep -q "Import plan"
  echo "$output" | grep -q "Planned operations"

  # Verify nothing was written to Vault
  run curl -sf -H "X-Vault-Token: ${VAULT_TOKEN}" \
    "${VAULT_ADDR}/v1/secret/data/disinto/bots/review"
  [ "$status" -ne 0 ]
}

# --- Complete fixture import ─────────────────────────────────────────────────

@test "imports all keys from complete fixture" {
  run "$IMPORT_SCRIPT" \
    --env "$FIXTURES_DIR/dot-env-complete" \
    --sops "$FIXTURES_DIR/.env.vault.enc" \
    --age-key "$FIXTURES_DIR/age-keys.txt"
  [ "$status" -eq 0 ]

  # Check bots/review
  run curl -sf -H "X-Vault-Token: ${VAULT_TOKEN}" \
    "${VAULT_ADDR}/v1/secret/data/disinto/bots/review"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "review-token"
  echo "$output" | grep -q "review-pass"

  # Check bots/dev-qwen
  run curl -sf -H "X-Vault-Token: ${VAULT_TOKEN}" \
    "${VAULT_ADDR}/v1/secret/data/disinto/bots/dev-qwen"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "llama-token"
  echo "$output" | grep -q "llama-pass"

  # Check forge
  run curl -sf -H "X-Vault-Token: ${VAULT_TOKEN}" \
    "${VAULT_ADDR}/v1/secret/data/disinto/shared/forge"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "generic-forge-token"
  echo "$output" | grep -q "generic-forge-pass"
  echo "$output" | grep -q "generic-admin-token"

  # Check woodpecker
  run curl -sf -H "X-Vault-Token: ${VAULT_TOKEN}" \
    "${VAULT_ADDR}/v1/secret/data/disinto/shared/woodpecker"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "wp-agent-secret"
  echo "$output" | grep -q "wp-forgejo-client"
  echo "$output" | grep -q "wp-forgejo-secret"
  echo "$output" | grep -q "wp-token"

  # Check chat
  run curl -sf -H "X-Vault-Token: ${VAULT_TOKEN}" \
    "${VAULT_ADDR}/v1/secret/data/disinto/shared/chat"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "forward-auth-secret"
  echo "$output" | grep -q "chat-client-id"
  echo "$output" | grep -q "chat-client-secret"

  # Check runner tokens from sops
  run curl -sf -H "X-Vault-Token: ${VAULT_TOKEN}" \
    "${VAULT_ADDR}/v1/secret/data/disinto/runner/GITHUB_TOKEN"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.data.data.value == "github-test-token-abc123"'
}

# --- Idempotency ──────────────────────────────────────────────────────────────

@test "re-run with unchanged fixtures reports all unchanged" {
  # First run
  run "$IMPORT_SCRIPT" \
    --env "$FIXTURES_DIR/dot-env-complete" \
    --sops "$FIXTURES_DIR/.env.vault.enc" \
    --age-key "$FIXTURES_DIR/age-keys.txt"
  [ "$status" -eq 0 ]

  # Second run - should report unchanged
  run "$IMPORT_SCRIPT" \
    --env "$FIXTURES_DIR/dot-env-complete" \
    --sops "$FIXTURES_DIR/.env.vault.enc" \
    --age-key "$FIXTURES_DIR/age-keys.txt"
  [ "$status" -eq 0 ]

  # Check that all keys report unchanged
  echo "$output" | grep -q "unchanged"
  # Count unchanged occurrences (should be many)
  local unchanged_count
  unchanged_count=$(echo "$output" | grep -c "unchanged" || true)
  [ "$unchanged_count" -gt 10 ]
}

@test "re-run with modified value reports only that key as updated" {
  # Create a modified fixture
  local modified_env="${BATS_TEST_TMPDIR}/dot-env-modified"
  cp "$FIXTURES_DIR/dot-env-complete" "$modified_env"

  # Modify one value
  sed -i 's/llama-token/MODIFIED-LLAMA-TOKEN/' "$modified_env"

  # Run with modified fixture
  run "$IMPORT_SCRIPT" \
    --env "$modified_env" \
    --sops "$FIXTURES_DIR/.env.vault.enc" \
    --age-key "$FIXTURES_DIR/age-keys.txt"
  [ "$status" -eq 0 ]

  # Check that dev-qwen token was updated
  echo "$output" | grep -q "dev-qwen.*updated"

  # Verify the new value was written (path is disinto/bots/dev-qwen, key is token)
  run curl -sf -H "X-Vault-Token: ${VAULT_TOKEN}" \
    "${VAULT_ADDR}/v1/secret/data/disinto/bots/dev-qwen"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.data.data.token == "MODIFIED-LLAMA-TOKEN"'
}

# --- Incomplete fixture ───────────────────────────────────────────────────────

@test "handles incomplete fixture gracefully" {
  # The incomplete fixture is missing some keys, but that should be OK
  # - it should only import what exists
  # - it should warn about missing pairs
  run "$IMPORT_SCRIPT" \
    --env "$FIXTURES_DIR/dot-env-incomplete" \
    --sops "$FIXTURES_DIR/.env.vault.enc" \
    --age-key "$FIXTURES_DIR/age-keys.txt"
  [ "$status" -eq 0 ]

  # Should have imported what was available
  echo "$output" | grep -q "review"

  # Should complete successfully even with incomplete fixture
  # The script handles missing pairs gracefully with warnings to stderr
  [ "$status" -eq 0 ]
}

# --- Security: no secrets in output ───────────────────────────────────────────

@test "never logs secret values in stdout" {
  # Run the import
  run "$IMPORT_SCRIPT" \
    --env "$FIXTURES_DIR/dot-env-complete" \
    --sops "$FIXTURES_DIR/.env.vault.enc" \
    --age-key "$FIXTURES_DIR/age-keys.txt"
  [ "$status" -eq 0 ]

  # Check that no actual secret values appear in output
  # (only key names and status messages)
  local secret_patterns=(
    "generic-forge-token"
    "generic-forge-pass"
    "generic-admin-token"
    "review-token"
    "review-pass"
    "llama-token"
    "llama-pass"
    "wp-agent-secret"
    "forward-auth-secret"
    "github-test-token"
    "codeberg-test-token"
    "clawhub-test-token"
    "deploy-key-test"
    "npm-test-token"
    "dockerhub-test-token"
  )

  for pattern in "${secret_patterns[@]}"; do
    if echo "$output" | grep -q "$pattern"; then
      echo "FAIL: Found secret pattern '$pattern' in output" >&2
      echo "Output was:" >&2
      echo "$output" >&2
      return 1
    fi
  done
}

# --- Error handling ───────────────────────────────────────────────────────────

@test "fails with missing --env argument" {
  run "$IMPORT_SCRIPT" \
    --sops "$FIXTURES_DIR/.env.vault.enc" \
    --age-key "$FIXTURES_DIR/age-keys.txt"
  [ "$status" -ne 0 ]
  echo "$output" | grep -q "Missing required argument"
}

@test "fails with missing --sops argument" {
  run "$IMPORT_SCRIPT" \
    --env "$FIXTURES_DIR/dot-env-complete" \
    --age-key "$FIXTURES_DIR/age-keys.txt"
  [ "$status" -ne 0 ]
  echo "$output" | grep -q "Missing required argument"
}

@test "fails with missing --age-key argument" {
  run "$IMPORT_SCRIPT" \
    --env "$FIXTURES_DIR/dot-env-complete" \
    --sops "$FIXTURES_DIR/.env.vault.enc"
  [ "$status" -ne 0 ]
  echo "$output" | grep -q "Missing required argument"
}

@test "fails with non-existent env file" {
  run "$IMPORT_SCRIPT" \
    --env "/nonexistent/.env" \
    --sops "$FIXTURES_DIR/.env.vault.enc" \
    --age-key "$FIXTURES_DIR/age-keys.txt"
  [ "$status" -ne 0 ]
  echo "$output" | grep -q "not found"
}

@test "fails with non-existent sops file" {
  run "$IMPORT_SCRIPT" \
    --env "$FIXTURES_DIR/dot-env-complete" \
    --sops "/nonexistent/.env.vault.enc" \
    --age-key "$FIXTURES_DIR/age-keys.txt"
  [ "$status" -ne 0 ]
  echo "$output" | grep -q "not found"
}

@test "fails with non-existent age key file" {
  run "$IMPORT_SCRIPT" \
    --env "$FIXTURES_DIR/dot-env-complete" \
    --sops "$FIXTURES_DIR/.env.vault.enc" \
    --age-key "/nonexistent/age-keys.txt"
  [ "$status" -ne 0 ]
  echo "$output" | grep -q "not found"
}
