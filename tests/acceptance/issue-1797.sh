#!/usr/bin/env bash
# =============================================================================
# tests/acceptance/issue-1797.sh — vault-import no longer maps chat secrets
#
# Issue #1797: tools/vault-import.sh no longer maps
# FORWARD_AUTH_SECRET, CHAT_OAUTH_CLIENT_ID, CHAT_OAUTH_CLIENT_SECRET to
# kv/disinto/shared/chat. The chat loop, the chat case arm, the shared/chat
# mapping lines (header + usage), and the "(4 fields for forge/woodpecker/chat)"
# comment are gone from vault-import.sh; the bats test and its fixtures drop the
# chat keys; and the _hvault_seed_key comment and the service-forgejo.hcl scope
# comment no longer name the chat OAuth client.
#
# Read-only: test, grep, and bash -n. Does not talk to Vault or Nomad.
#
# Acceptance: `bash tests/acceptance/issue-1797.sh` exits 0 and prints PASS.
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck disable=SC1091
source "$REPO_ROOT/tests/lib/acceptance-helpers.sh"

ac_require_cmd test grep bash

VIMPORT="$REPO_ROOT/tools/vault-import.sh"
HVAULT="$REPO_ROOT/lib/hvault.sh"
BATS="$REPO_ROOT/tests/vault-import.bats"
FIXTURES="$REPO_ROOT/tests/fixtures"
POLICY="$REPO_ROOT/vault/policies/service-forgejo.hcl"

ac_assert_file "$VIMPORT" "tools/vault-import.sh must exist"
ac_assert_file "$HVAULT" "lib/hvault.sh must exist"
ac_assert_file "$BATS" "tests/vault-import.bats must exist"
ac_assert_file "$POLICY" "vault/policies/service-forgejo.hcl must exist"

ac_log "AC1: no shared/chat, CHAT_OAUTH, FORWARD_AUTH, or forward-auth in"
ac_log "vault-import.sh, hvault.sh, the bats test, fixtures, or vault/"
if grep -rn -e shared/chat -e CHAT_OAUTH -e FORWARD_AUTH -e forward-auth \
  "$VIMPORT" "$HVAULT" "$BATS" "$FIXTURES" "$REPO_ROOT/vault"; then
  ac_fail "chat-secret names remain in vault-import.sh, hvault.sh, the bats test, fixtures, or vault"
fi

ac_log "AC2: no 'chat' in service-forgejo.hcl or hvault.sh"
if grep -n chat "$POLICY" "$HVAULT"; then
  ac_fail "chat remains in service-forgejo.hcl or hvault.sh"
fi

ac_log "AC3: tools/vault-import.sh parses (bash -n)"
bash -n "$VIMPORT" || ac_fail "bash -n tools/vault-import.sh failed"

ac_pass
