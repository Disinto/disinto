#!/usr/bin/env bash
# =============================================================================
# test-caddyfile-routing.sh — Caddyfile routing block unit test
#
# Extracts the Caddyfile template from nomad/jobs/edge.hcl and validates its
# structure without requiring a running Caddy instance.
#
# Checks:
#   - Forgejo subpath (/forge/* -> :3000)
#   - Woodpecker subpath (/ci/* -> :8000)
#   - Staging subpath (/staging/* -> nomadService discovery)
#   - Root redirect to /forge/
#
# Usage:
#   test-caddyfile-routing.sh
#
# Exit codes:
#   0 — All checks passed
#   1 — One or more checks failed
# =============================================================================
set -euo pipefail

# Script directory for relative paths
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

EDGE_TEMPLATE="${REPO_ROOT}/nomad/jobs/edge.hcl"

# Track test status
FAILED=0
PASSED=0

# ─────────────────────────────────────────────────────────────────────────────
# Logging helpers
# ─────────────────────────────────────────────────────────────────────────────

tr_info() {
  echo "[INFO] $*"
}

tr_pass() {
  echo "[PASS] $*"
  ((PASSED++)) || true
}

tr_fail() {
  echo "[FAIL] $*"
  ((FAILED++)) || true
}

tr_section() {
  echo ""
  echo "=== $* ==="
  echo ""
}

# ─────────────────────────────────────────────────────────────────────────────
# Caddyfile extraction
# ─────────────────────────────────────────────────────────────────────────────

extract_caddyfile() {
  local template_file="$1"

  # Extract the Caddyfile template (content between <<EOT and EOT markers
  # within the template stanza)
  local caddyfile
  caddyfile=$(sed -n '/data[[:space:]]*=[[:space:]]*<<[Ee][Oo][Tt]/,/^EOT$/p' "$template_file" | sed '1s/.*/# Caddyfile extracted from Nomad template/; $d')

  if [ -z "$caddyfile" ]; then
    echo "ERROR: Could not extract Caddyfile template from $template_file" >&2
    return 1
  fi

  echo "$caddyfile"
}

# ─────────────────────────────────────────────────────────────────────────────
# Validation functions
# ─────────────────────────────────────────────────────────────────────────────

check_forgejo_routing() {
  tr_section "Validating Forgejo routing"

  # Check handle block for /forge/*
  if echo "$CADDYFILE" | grep -q "handle /forge/\*"; then
    tr_pass "Forgejo handle block (handle /forge/*)"
  else
    tr_fail "Missing Forgejo handle block (handle /forge/*)"
  fi

  # Check uri strip_prefix /forge (required for Forgejo routing)
  if echo "$CADDYFILE" | grep -q "uri strip_prefix /forge"; then
    tr_pass "Forgejo strip_prefix configured (/forge)"
  else
    tr_fail "Missing Forgejo strip_prefix (/forge)"
  fi

  # Check reverse_proxy to Forgejo via Nomad service discovery
  if echo "$CADDYFILE" | grep -q 'nomadService "forgejo"'; then
    tr_pass "Forgejo reverse_proxy uses Nomad service discovery"
  else
    tr_fail "Missing Forgejo Nomad service discovery"
  fi
}

check_woodpecker_routing() {
  tr_section "Validating Woodpecker routing"

  # Check handle block for /ci/*
  if echo "$CADDYFILE" | grep -q "handle /ci/\*"; then
    tr_pass "Woodpecker handle block (handle /ci/*)"
  else
    tr_fail "Missing Woodpecker handle block (handle /ci/*)"
  fi

  # Check reverse_proxy to Woodpecker via Nomad service discovery
  if echo "$CADDYFILE" | grep -q 'nomadService "woodpecker"'; then
    tr_pass "Woodpecker reverse_proxy uses Nomad service discovery"
  else
    tr_fail "Missing Woodpecker Nomad service discovery"
  fi
}

check_staging_routing() {
  tr_section "Validating Staging routing"

  # Check handle block for /staging/*
  if echo "$CADDYFILE" | grep -q "handle /staging/\*"; then
    tr_pass "Staging handle block (handle /staging/*)"
  else
    tr_fail "Missing Staging handle block (handle /staging/*)"
  fi

  # Check for uri strip_prefix /staging directive
  if echo "$CADDYFILE" | grep -q "uri strip_prefix /staging"; then
    tr_pass "Staging uri strip_prefix configured (/staging)"
  else
    tr_fail "Missing uri strip_prefix /staging for staging"
  fi

  # Check for nomadService discovery (dynamic port)
  if echo "$CADDYFILE" | grep -q "nomadService"; then
    tr_pass "Staging uses Nomad service discovery"
  else
    tr_fail "Missing Nomad service discovery for staging"
  fi
}

check_root_redirect() {
  tr_section "Validating root redirect"

  # Check root redirect to /forge/
  if echo "$CADDYFILE" | grep -q "redir /forge/ 302"; then
    tr_pass "Root redirect to /forge/ configured (302)"
  else
    tr_fail "Missing root redirect to /forge/"
  fi
}

# ─────────────────────────────────────────────────────────────────────────────
# Main
# ─────────────────────────────────────────────────────────────────────────────

main() {
  tr_info "Extracting Caddyfile template from $EDGE_TEMPLATE"

  # Extract Caddyfile
  CADDYFILE=$(extract_caddyfile "$EDGE_TEMPLATE")

  if [ -z "$CADDYFILE" ]; then
    tr_fail "Could not extract Caddyfile template"
    exit 1
  fi

  tr_pass "Caddyfile template extracted successfully"

  # Run all validation checks
  check_forgejo_routing
  check_woodpecker_routing
  check_staging_routing
  check_root_redirect

  # Summary
  tr_section "Test Summary"
  tr_info "Passed: $PASSED"
  tr_info "Failed: $FAILED"

  if [ "$FAILED" -gt 0 ]; then
    tr_fail "Some checks failed"
    exit 1
  fi

  tr_pass "All routing blocks validated!"
  exit 0
}

main
