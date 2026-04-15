#!/usr/bin/env bash
# tests/smoke-load-secret.sh — Unit tests for load_secret() precedence chain
#
# Covers the 4 precedence cases:
#   1. /secrets/<NAME>.env  (Nomad template)
#   2. Current environment
#   3. secrets/<NAME>.enc   (age-encrypted per-key file)
#   4. Default / empty fallback
#
# Required tools: bash, age (for case 3)

set -euo pipefail

FACTORY_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

fail() { printf 'FAIL: %s\n' "$*" >&2; FAILED=1; }
pass() { printf 'PASS: %s\n' "$*"; }
FAILED=0

# Set up a temp workspace and fake HOME so age key paths work
test_dir=$(mktemp -d)
fake_home=$(mktemp -d)
trap 'rm -rf "$test_dir" "$fake_home"' EXIT

# Minimal env for sourcing env.sh's load_secret function without the full boot
# We source the function definition directly to isolate the unit under test.
# shellcheck disable=SC2034
export USER="${USER:-test}"
export HOME="$fake_home"

# Source env.sh to get load_secret (and FACTORY_ROOT)
source "${FACTORY_ROOT}/lib/env.sh"

# ── Case 4: Default / empty fallback ────────────────────────────────────────
echo "=== 1/5 Case 4: default fallback ==="

unset TEST_SECRET_FALLBACK 2>/dev/null || true
val=$(load_secret TEST_SECRET_FALLBACK "my-default")
if [ "$val" = "my-default" ]; then
  pass "load_secret returns default when nothing is set"
else
  fail "Expected 'my-default', got '${val}'"
fi

val=$(load_secret TEST_SECRET_FALLBACK)
if [ -z "$val" ]; then
  pass "load_secret returns empty when no default and nothing set"
else
  fail "Expected empty, got '${val}'"
fi

# ── Case 2: Environment variable already set ────────────────────────────────
echo "=== 2/5 Case 2: environment variable ==="

export TEST_SECRET_ENV="from-environment"
val=$(load_secret TEST_SECRET_ENV "ignored-default")
if [ "$val" = "from-environment" ]; then
  pass "load_secret returns env value over default"
else
  fail "Expected 'from-environment', got '${val}'"
fi
unset TEST_SECRET_ENV

# ── Case 3: Age-encrypted per-key file ──────────────────────────────────────
echo "=== 3/5 Case 3: age-encrypted secret ==="

if command -v age &>/dev/null && command -v age-keygen &>/dev/null; then
  # Generate a test age key
  age_key_dir="${fake_home}/.config/sops/age"
  mkdir -p "$age_key_dir"
  age-keygen -o "${age_key_dir}/keys.txt" 2>/dev/null
  pub_key=$(age-keygen -y "${age_key_dir}/keys.txt")

  # Create encrypted secret
  secrets_dir="${FACTORY_ROOT}/secrets"
  mkdir -p "$secrets_dir"
  printf 'age-test-value' | age -r "$pub_key" -o "${secrets_dir}/TEST_SECRET_AGE.enc"

  unset TEST_SECRET_AGE 2>/dev/null || true
  val=$(load_secret TEST_SECRET_AGE "fallback")
  if [ "$val" = "age-test-value" ]; then
    pass "load_secret decrypts age-encrypted secret"
  else
    fail "Expected 'age-test-value', got '${val}'"
  fi

  # Verify caching: call load_secret directly (not in subshell) so export propagates
  unset TEST_SECRET_AGE 2>/dev/null || true
  load_secret TEST_SECRET_AGE >/dev/null
  if [ "${TEST_SECRET_AGE:-}" = "age-test-value" ]; then
    pass "load_secret caches decrypted value in environment (direct call)"
  else
    fail "Decrypted value not cached in environment"
  fi

  # Clean up test secret
  rm -f "${secrets_dir}/TEST_SECRET_AGE.enc"
  rmdir "$secrets_dir" 2>/dev/null || true
  unset TEST_SECRET_AGE
else
  echo "SKIP: age/age-keygen not found — skipping age decryption test"
fi

# ── Case 1: Nomad template path ────────────────────────────────────────────
echo "=== 4/5 Case 1: Nomad template (/secrets/<NAME>.env) ==="

nomad_dir="/secrets"
if [ -w "$(dirname "$nomad_dir")" ] 2>/dev/null || [ -w "$nomad_dir" ] 2>/dev/null; then
  mkdir -p "$nomad_dir"
  printf 'TEST_SECRET_NOMAD=from-nomad-template\n' > "${nomad_dir}/TEST_SECRET_NOMAD.env"

  # Even with env set, Nomad path takes precedence
  export TEST_SECRET_NOMAD="from-env-should-lose"
  val=$(load_secret TEST_SECRET_NOMAD "default")
  if [ "$val" = "from-nomad-template" ]; then
    pass "load_secret prefers Nomad template over env"
  else
    fail "Expected 'from-nomad-template', got '${val}'"
  fi

  rm -f "${nomad_dir}/TEST_SECRET_NOMAD.env"
  rmdir "$nomad_dir" 2>/dev/null || true
  unset TEST_SECRET_NOMAD
else
  echo "SKIP: /secrets not writable — skipping Nomad template test (needs root or container)"
fi

# ── Precedence: env beats age ────────────────────────────────────────────
echo "=== 5/5 Precedence: env beats age-encrypted ==="

if command -v age &>/dev/null && command -v age-keygen &>/dev/null; then
  age_key_dir="${fake_home}/.config/sops/age"
  mkdir -p "$age_key_dir"
  [ -f "${age_key_dir}/keys.txt" ] || age-keygen -o "${age_key_dir}/keys.txt" 2>/dev/null
  pub_key=$(age-keygen -y "${age_key_dir}/keys.txt")

  secrets_dir="${FACTORY_ROOT}/secrets"
  mkdir -p "$secrets_dir"
  printf 'age-value-should-lose' | age -r "$pub_key" -o "${secrets_dir}/TEST_SECRET_PREC.enc"

  export TEST_SECRET_PREC="env-value-wins"
  val=$(load_secret TEST_SECRET_PREC "default")
  if [ "$val" = "env-value-wins" ]; then
    pass "load_secret prefers env over age-encrypted file"
  else
    fail "Expected 'env-value-wins', got '${val}'"
  fi

  rm -f "${secrets_dir}/TEST_SECRET_PREC.enc"
  rmdir "$secrets_dir" 2>/dev/null || true
  unset TEST_SECRET_PREC
else
  echo "SKIP: age not found — skipping precedence test"
fi

# ── Summary ───────────────────────────────────────────────────────────────
echo ""
if [ "$FAILED" -ne 0 ]; then
  echo "=== SMOKE-LOAD-SECRET TEST FAILED ==="
  exit 1
fi
echo "=== SMOKE-LOAD-SECRET TEST PASSED ==="
