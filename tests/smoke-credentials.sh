#!/usr/bin/env bash
# tests/smoke-credentials.sh — Verify no git remote URL contains embedded credentials
#
# Scans all shell scripts that construct git URLs and verifies:
#   1. No source file embeds credentials in remote URLs (static check)
#   2. The repair_baked_cred_urls function correctly strips credentials
#   3. configure_git_creds writes a working credential helper
#
# Required tools: bash, git, grep

set -euo pipefail

FACTORY_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
FAILED=0

fail() { printf 'FAIL: %s\n' "$*" >&2; FAILED=1; }
pass() { printf 'PASS: %s\n' "$*"; }

# ── 1. Static check: no credential embedding in URL construction ──────────
echo "=== 1/3 Static check: no credential embedding in URL construction ==="

# Patterns that embed credentials into git URLs:
#   sed "s|://|://user:pass@|"   — the classic injection pattern
#   ://.*:.*@                     — literal user:pass@ in a URL string
# Allowlist: git-creds.sh itself (it writes the credential helper, not URLs),
# and this test file.
cred_embed_pattern='s\|://\|://.*:.*\$\{.*\}@'

offending_files=()
while IFS= read -r f; do
  # Skip allowlisted files:
  #   git-creds.sh          — writes the credential helper, not URLs
  #   smoke-credentials.sh  — this test file
  #   hire-agent.sh         — one-shot setup: clones as newly-created user, clone dir deleted immediately
  case "$f" in
    */git-creds.sh|*/smoke-credentials.sh|*/hire-agent.sh) continue ;;
  esac
  if grep -qE "$cred_embed_pattern" "$f" 2>/dev/null; then
    offending_files+=("$f")
  fi
done < <(git -C "$FACTORY_ROOT" ls-files '*.sh')

if [ ${#offending_files[@]} -eq 0 ]; then
  pass "No shell scripts embed credentials in git remote URLs"
else
  for f in "${offending_files[@]}"; do
    fail "Credential embedding found in: $f"
    grep -nE "$cred_embed_pattern" "$FACTORY_ROOT/$f" 2>/dev/null | head -3
  done
fi

# ── 2. Unit test: repair_baked_cred_urls strips credentials ───────────────
echo "=== 2/3 Unit test: repair_baked_cred_urls ==="

# Source the shared lib
# shellcheck source=lib/git-creds.sh
source "${FACTORY_ROOT}/lib/git-creds.sh"

# Create a temporary git repo with a baked-credential URL
test_dir=$(mktemp -d)
trap 'rm -rf "$test_dir"' EXIT

mkdir -p "${test_dir}/repo"
git -C "${test_dir}/repo" init -q
git -C "${test_dir}/repo" config user.email "test@test"
git -C "${test_dir}/repo" config user.name "test"
git -C "${test_dir}/repo" commit --allow-empty -m "init" -q
git -C "${test_dir}/repo" remote add origin "http://dev-bot:secret-token@forgejo:3000/org/repo.git"

# Run repair
_GIT_CREDS_LOG_FN="echo" repair_baked_cred_urls "${test_dir}"

# Verify the URL was cleaned
repaired_url=$(git -C "${test_dir}/repo" config --get remote.origin.url)
if [ "$repaired_url" = "http://forgejo:3000/org/repo.git" ]; then
  pass "repair_baked_cred_urls correctly stripped credentials"
else
  fail "repair_baked_cred_urls result: '${repaired_url}' (expected 'http://forgejo:3000/org/repo.git')"
fi

# Also test that a clean URL is left untouched
git -C "${test_dir}/repo" remote set-url origin "http://forgejo:3000/org/repo.git"
_GIT_CREDS_LOG_FN="echo" repair_baked_cred_urls "${test_dir}"
clean_url=$(git -C "${test_dir}/repo" config --get remote.origin.url)
if [ "$clean_url" = "http://forgejo:3000/org/repo.git" ]; then
  pass "repair_baked_cred_urls leaves clean URLs untouched"
else
  fail "repair_baked_cred_urls modified a clean URL: '${clean_url}'"
fi

# ── 3. Unit test: configure_git_creds writes a credential helper ──────────
echo "=== 3/3 Unit test: configure_git_creds ==="

cred_home=$(mktemp -d)

# Export required globals
export FORGE_PASS="test-password-123"
export FORGE_URL="http://forgejo:3000"
export FORGE_TOKEN=""  # skip API call in test

configure_git_creds "$cred_home"

if [ -x "${cred_home}/.git-credentials-helper" ]; then
  pass "Credential helper script created and executable"
else
  fail "Credential helper script not found or not executable at ${cred_home}/.git-credentials-helper"
fi

# Verify the helper outputs correct credentials
helper_output=$(echo "" | "${cred_home}/.git-credentials-helper" get 2>/dev/null)
if printf '%s' "$helper_output" | grep -q "password=test-password-123"; then
  pass "Credential helper outputs correct password"
else
  fail "Credential helper output missing password: ${helper_output}"
fi

if printf '%s' "$helper_output" | grep -q "host=forgejo:3000"; then
  pass "Credential helper outputs correct host"
else
  fail "Credential helper output missing host: ${helper_output}"
fi

rm -rf "$cred_home"

# ── Summary ───────────────────────────────────────────────────────────────
echo ""
if [ "$FAILED" -ne 0 ]; then
  echo "=== SMOKE-CREDENTIALS TEST FAILED ==="
  exit 1
fi
echo "=== SMOKE-CREDENTIALS TEST PASSED ==="
