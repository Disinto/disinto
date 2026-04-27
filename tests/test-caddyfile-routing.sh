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
#   - Chat subpath (/chat/* with forward_auth and OAuth routes)
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

check_chat_routing() {
  tr_section "Validating Chat routing"

  # Check login endpoint
  if echo "$CADDYFILE" | grep -q "handle /chat/login"; then
    tr_pass "Chat login handle block (handle /chat/login)"
  else
    tr_fail "Missing Chat login handle block (handle /chat/login)"
  fi

  # Check OAuth callback endpoint
  if echo "$CADDYFILE" | grep -q "handle /chat/oauth/callback"; then
    tr_pass "Chat OAuth callback handle block (handle /chat/oauth/callback)"
  else
    tr_fail "Missing Chat OAuth callback handle block (handle /chat/oauth/callback)"
  fi

  # Check catch-all for /chat/*
  if echo "$CADDYFILE" | grep -q "handle /chat/\*"; then
    tr_pass "Chat catch-all handle block (handle /chat/*)"
  else
    tr_fail "Missing Chat catch-all handle block (handle /chat/*)"
  fi

  # Check reverse_proxy to Chat on port 8080 (subprocess via env var)
  if echo "$CADDYFILE" | grep -q 'reverse_proxy 127\.0\.0\.1:{{ or (env "CHAT_PORT") "8080" }}'; then
    tr_pass "Chat reverse_proxy configured (127.0.0.1:CHAT_PORT)"
  else
    tr_fail "Missing Chat reverse_proxy (expected 127.0.0.1:{{ or (env \"CHAT_PORT\") \"8080\" }})"
  fi

  # Check forward_auth block for /chat/*
  if echo "$CADDYFILE" | grep -A10 "handle /chat/\*" | grep -q "forward_auth"; then
    tr_pass "forward_auth block configured for /chat/*"
  else
    tr_fail "Missing forward_auth block for /chat/*"
  fi

  # Check forward_auth URI
  if echo "$CADDYFILE" | grep -q "uri /chat/auth/verify"; then
    tr_pass "forward_auth URI configured (/chat/auth/verify)"
  else
    tr_fail "Missing forward_auth URI (/chat/auth/verify)"
  fi
}

check_voice_routing() {
  tr_section "Validating voice bridge routing (#662)"

  # Check /voice/ws handle exists
  if echo "$CADDYFILE" | grep -q "handle /voice/ws"; then
    tr_pass "Voice WebSocket handle block (handle /voice/ws)"
  else
    tr_fail "Missing Voice WebSocket handle block (handle /voice/ws)"
  fi

  # Check reverse_proxy points at loopback VOICE_PORT
  if echo "$CADDYFILE" | grep -q 'reverse_proxy 127\.0\.0\.1:{{ or (env "VOICE_PORT") "8090" }}'; then
    tr_pass "Voice reverse_proxy configured (127.0.0.1:VOICE_PORT)"
  else
    tr_fail "Missing Voice reverse_proxy (expected 127.0.0.1:{{ or (env \"VOICE_PORT\") \"8090\" }})"
  fi

  # Check forward_auth shared with /chat/* for OAuth gating
  if echo "$CADDYFILE" | awk '/handle \/voice\/ws/,/^    }$/' | grep -q "forward_auth"; then
    tr_pass "Voice forward_auth block configured"
  else
    tr_fail "Missing forward_auth inside /voice/ws handle"
  fi

  # Check WebSocket Upgrade headers forwarded
  if echo "$CADDYFILE" | awk '/handle \/voice\/ws/,/^    }$/' | grep -q "header_up Upgrade"; then
    tr_pass "Voice WebSocket Upgrade header forwarded"
  else
    tr_fail "Missing Upgrade header_up inside /voice/ws handle"
  fi
}

check_voice_ui_routing() {
  tr_section "Validating voice UI routing (#663)"

  # /voice/static/* — static asset file_server with forward_auth
  if echo "$CADDYFILE" | grep -q "handle /voice/static/\*"; then
    tr_pass "Voice static handle block (handle /voice/static/*)"
  else
    tr_fail "Missing Voice static handle block (handle /voice/static/*)"
  fi
  if echo "$CADDYFILE" | awk '/handle \/voice\/static\/\*/,/^    }$/' | grep -q "file_server"; then
    tr_pass "Voice static handler uses file_server"
  else
    tr_fail "Missing file_server inside /voice/static/* handle"
  fi
  if echo "$CADDYFILE" | awk '/handle \/voice\/static\/\*/,/^    }$/' | grep -q "forward_auth"; then
    tr_pass "Voice static handler shares forward_auth gate"
  else
    tr_fail "Missing forward_auth inside /voice/static/* handle"
  fi

  # /voice/ — index.html via file_server + try_files
  if echo "$CADDYFILE" | grep -q "handle /voice/ {"; then
    tr_pass "Voice index handle block (handle /voice/)"
  else
    tr_fail "Missing Voice index handle block (handle /voice/)"
  fi
  if echo "$CADDYFILE" | awk '/handle \/voice\/ \{/,/^    }$/' | grep -q "try_files"; then
    tr_pass "Voice index handler uses try_files for SPA fallback"
  else
    tr_fail "Missing try_files inside /voice/ handle"
  fi
  if echo "$CADDYFILE" | awk '/handle \/voice\/ \{/,/^    }$/' | grep -q "forward_auth"; then
    tr_pass "Voice index handler shares forward_auth gate"
  else
    tr_fail "Missing forward_auth inside /voice/ handle"
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
  check_chat_routing
  check_voice_routing
  check_voice_ui_routing
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
