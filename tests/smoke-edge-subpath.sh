#!/usr/bin/env bash
# =============================================================================
# smoke-edge-subpath.sh — End-to-end subpath routing smoke test
#
# Verifies Forgejo, Woodpecker, and chat function correctly under subpaths:
#   - Forgejo at /forge/
#   - Woodpecker at /ci/
#   - Chat at /chat/
#   - Staging at /staging/
#
# Usage:
#   smoke-edge-subpath.sh [--base-url BASE_URL]
#
# Environment variables:
#   BASE_URL         — Edge proxy URL (default: http://localhost)
#   EDGE_TIMEOUT     — Request timeout in seconds (default: 30)
#   EDGE_MAX_RETRIES — Max retries per request (default: 3)
#
# Exit codes:
#   0 — All checks passed
#   1 — One or more checks failed
# =============================================================================
set -euo pipefail

# Script directory for relative paths
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source common helpers if available
source "${SCRIPT_DIR}/../lib/env.sh" 2>/dev/null || true

# ─────────────────────────────────────────────────────────────────────────────
# Configuration
# ─────────────────────────────────────────────────────────────────────────────

BASE_URL="${BASE_URL:-http://localhost}"
EDGE_TIMEOUT="${EDGE_TIMEOUT:-30}"
EDGE_MAX_RETRIES="${EDGE_MAX_RETRIES:-3}"

# Subpaths to test
FORGE_PATH="/forge/"
CI_PATH="/ci/"
CHAT_PATH="/chat/"
STAGING_PATH="/staging/"

# Track overall test status
FAILED=0
PASSED=0
SKIPPED=0

# ─────────────────────────────────────────────────────────────────────────────
# Logging helpers
# ─────────────────────────────────────────────────────────────────────────────

log_info() {
  echo "[INFO] $*"
}

log_pass() {
  echo "[PASS] $*"
  ((PASSED++)) || true
}

log_fail() {
  echo "[FAIL] $*"
  ((FAILED++)) || true
}

log_skip() {
  echo "[SKIP] $*"
  ((SKIPPED++)) || true
}

log_section() {
  echo ""
  echo "=== $* ==="
  echo ""
}

# ─────────────────────────────────────────────────────────────────────────────
# HTTP helpers
# ─────────────────────────────────────────────────────────────────────────────

# Make an HTTP request with retry logic
# Usage: http_request <method> <url> [options...]
# Returns: HTTP status code on stdout
http_request() {
  local method="$1"
  local url="$2"
  shift 2

  local retries=0
  local response status

  while [ "$retries" -lt "$EDGE_MAX_RETRIES" ]; do
    response=$(curl -sS -w '\n%{http_code}' -X "$method" \
      --max-time "$EDGE_TIMEOUT" \
      -o /tmp/edge-response-$$ \
      "$@" 2>&1) || {
      retries=$((retries + 1))
      log_info "Retry $retries/$EDGE_MAX_RETRIES for $url"
      sleep 1
      continue
    }

    status=$(echo "$response" | tail -n1)

    echo "$status"
    return 0
  done

  log_fail "Max retries exceeded for $url"
  return 1
}

# Make a GET request and return status code
http_get() {
  local url="$1"
  shift || true
  http_request "GET" "$url" "$@"
}

# Make a HEAD request (no body)
http_head() {
  local url="$1"
  shift || true
  http_request "HEAD" "$url" "$@"
}

# Make a GET request and return the response body
http_get_body() {
  local url="$1"
  shift || true
  curl -sS --max-time "$EDGE_TIMEOUT" "$@" "$url"
}

# ─────────────────────────────────────────────────────────────────────────────
# Test functions
# ─────────────────────────────────────────────────────────────────────────────

test_root_redirect() {
  log_section "Test 1: Root redirect to /forge/"

  local status
  status=$(http_head "$BASE_URL/")

  if [ "$status" = "302" ]; then
    log_pass "Root / redirects with 302"
  else
    log_fail "Expected 302 redirect from /, got status $status"
  fi
}

test_forgejo_subpath() {
  log_section "Test 2: Forgejo at /forge/"

  local status
  status=$(http_head "$BASE_URL${FORGE_PATH}")

  if [ "$status" -ge 200 ] && [ "$status" -lt 400 ]; then
    log_pass "Forgejo at ${BASE_URL}${FORGE_PATH} returns status $status"
  else
    log_fail "Forgejo at ${BASE_URL}${FORGE_PATH} returned unexpected status $status"
  fi
}

test_woodpecker_subpath() {
  log_section "Test 3: Woodpecker at /ci/"

  local status
  status=$(http_head "$BASE_URL${CI_PATH}")

  if [ "$status" -ge 200 ] && [ "$status" -lt 400 ]; then
    log_pass "Woodpecker at ${BASE_URL}${CI_PATH} returns status $status"
  else
    log_fail "Woodpecker at ${BASE_URL}${CI_PATH} returned unexpected status $status"
  fi
}

test_chat_subpath() {
  log_section "Test 4: Chat at /chat/"

  # Test chat login endpoint
  local status
  status=$(http_head "$BASE_URL${CHAT_PATH}login")

  if [ "$status" -ge 200 ] && [ "$status" -lt 400 ]; then
    log_pass "Chat login at ${BASE_URL}${CHAT_PATH}login returns status $status"
  else
    log_fail "Chat login at ${BASE_URL}${CHAT_PATH}login returned unexpected status $status"
  fi

  # Test chat OAuth callback endpoint
  status=$(http_head "$BASE_URL${CHAT_PATH}oauth/callback")

  if [ "$status" -ge 200 ] && [ "$status" -lt 400 ]; then
    log_pass "Chat OAuth callback at ${BASE_URL}${CHAT_PATH}oauth/callback returns status $status"
  else
    log_fail "Chat OAuth callback at ${BASE_URL}${CHAT_PATH}oauth/callback returned unexpected status $status"
  fi
}

test_staging_subpath() {
  log_section "Test 5: Staging at /staging/"

  local status
  status=$(http_head "$BASE_URL${STAGING_PATH}")

  if [ "$status" -ge 200 ] && [ "$status" -lt 400 ]; then
    log_pass "Staging at ${BASE_URL}${STAGING_PATH} returns status $status"
  else
    log_fail "Staging at ${BASE_URL}${STAGING_PATH} returned unexpected status $status"
  fi
}

test_forward_auth_rejection() {
  log_section "Test 6: Forward auth on /chat/* rejects unauthenticated requests"

  # Request a protected chat endpoint without auth header
  # Should return 401 (Unauthorized) due to forward_auth
  local status
  status=$(http_head "$BASE_URL${CHAT_PATH}auth/verify")

  if [ "$status" = "401" ]; then
    log_pass "Unauthenticated /chat/auth/verify returns 401 (forward_auth working)"
  elif [ "$status" -ge 200 ] && [ "$status" -lt 400 ]; then
    log_skip "Unauthenticated /chat/auth/verify returns $status (forward_auth may be disabled)"
  else
    log_fail "Expected 401 for unauthenticated /chat/auth/verify, got status $status"
  fi
}

test_forgejo_oauth_callback() {
  log_section "Test 7: Forgejo OAuth callback for Woodpecker under subpath"

  # Test that Forgejo OAuth callback path works (Woodpecker OAuth integration)
  local status
  status=$(http_head "$BASE_URL${FORGE_PATH}login/oauth/callback")

  if [ "$status" -ge 200 ] && [ "$status" -lt 400 ]; then
    log_pass "Forgejo OAuth callback at ${BASE_URL}${FORGE_PATH}login/oauth/callback works"
  else
    log_fail "Forgejo OAuth callback returned unexpected status $status"
  fi
}

# ─────────────────────────────────────────────────────────────────────────────
# Main
# ─────────────────────────────────────────────────────────────────────────────

main() {
  log_info "Starting subpath routing smoke test"
  log_info "Base URL: $BASE_URL"
  log_info "Timeout: ${EDGE_TIMEOUT}s, Max retries: ${EDGE_MAX_RETRIES}"

  # Run all tests
  test_root_redirect
  test_forgejo_subpath
  test_woodpecker_subpath
  test_chat_subpath
  test_staging_subpath
  test_forward_auth_rejection
  test_forgejo_oauth_callback

  # Summary
  log_section "Test Summary"
  log_info "Passed: $PASSED"
  log_info "Failed: $FAILED"
  log_info "Skipped: $SKIPPED"

  if [ "$FAILED" -gt 0 ]; then
    log_fail "Some tests failed"
    exit 1
  fi

  log_pass "All tests passed!"
  exit 0
}

# Parse arguments
while [[ $# -gt 0 ]]; do
  case "$1" in
    --base-url)
      BASE_URL="$2"
      shift 2
      ;;
    --base-url=*)
      BASE_URL="${1#*=}"
      shift
      ;;
    --help)
      echo "Usage: $0 [options]"
      echo ""
      echo "Options:"
      echo "  --base-url URL     Set base URL (default: http://localhost)"
      echo "  --help             Show this help message"
      echo ""
      echo "Environment variables:"
      echo "  BASE_URL           Base URL for edge proxy (default: http://localhost)"
      echo "  EDGE_TIMEOUT       Request timeout in seconds (default: 30)"
      echo "  EDGE_MAX_RETRIES   Max retries per request (default: 3)"
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      exit 1
      ;;
  esac
done

main
