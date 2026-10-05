#!/usr/bin/env bash
# =============================================================================
# tests/acceptance/issue-1802.sh — disinto init stops creating the chat OAuth
# app and stops writing EDGE_TUNNEL_FQDN_CHAT
#
# Issue #1802: bin/disinto and lib/ci-setup.sh stop creating the Forgejo chat
# OAuth app (disinto-chat) and stop writing EDGE_TUNNEL_FQDN_CHAT. The chat
# OAuth impl, its wrapper, the dry-run entry, the post-deploy chat-init env
# block, and the edge-register chat FQDN lines are gone; the Woodpecker OAuth
# setup keeps a single --preserve-env=FORGE_TOKEN,VAULT_ADDR sudo path and the
# docs drop every chat reference.
#
# Read-only: grep, test, and bash -n. No live box.
#
# Acceptance: `bash tests/acceptance/issue-1802.sh` exits 0 and prints PASS.
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck disable=SC1091
source "$REPO_ROOT/tests/lib/acceptance-helpers.sh"

ac_require_cmd grep test bash

CLI="$REPO_ROOT/bin/disinto"
CI_SETUP="$REPO_ROOT/lib/ci-setup.sh"
TOML_EXAMPLE="$REPO_ROOT/projects/disinto.toml.example"
AGENTS="$REPO_ROOT/lib/AGENTS.md"

ac_assert_file "$CLI" "bin/disinto must exist"
ac_assert_file "$CI_SETUP" "lib/ci-setup.sh must exist"
ac_assert_file "$TOML_EXAMPLE" "projects/disinto.toml.example must exist"
ac_assert_file "$AGENTS" "lib/AGENTS.md must exist"

ac_log "checking bin/disinto no longer references the chat OAuth app or EDGE_TUNNEL_FQDN_CHAT"
if grep -nE 'FQDN_CHAT|create_chat_oauth|chat_redirect_uri|Chat OAuth|Chat:' "$CLI"; then
  ac_fail "chat OAuth / EDGE_TUNNEL_FQDN_CHAT remains in bin/disinto"
fi

ac_log "checking lib/ci-setup.sh and projects/disinto.toml.example have no chat references"
if grep -ni chat "$CI_SETUP" "$TOML_EXAMPLE"; then
  ac_fail "chat remains in lib/ci-setup.sh or projects/disinto.toml.example"
fi

ac_log "checking exactly one --preserve-env=FORGE_TOKEN,VAULT_ADDR sudo call in bin/disinto"
preserve_count="$(grep -c 'preserve-env=FORGE_TOKEN,VAULT_ADDR' "$CLI" || true)"
if [ "$preserve_count" != "1" ]; then
  ac_fail "preserve-env=FORGE_TOKEN,VAULT_ADDR count in bin/disinto is ${preserve_count}, expected 1"
fi

ac_log "checking lib/AGENTS.md ci-setup.sh row no longer mentions chat"
chat_rows="$(grep -F '_create_forgejo_oauth_app()' "$AGENTS" | grep -ci chat || true)"
if [ "$chat_rows" != "0" ]; then
  ac_fail "lib/AGENTS.md ci-setup.sh row mentions chat (${chat_rows} match)"
fi

ac_log "checking both scripts parse (bash -n)"
bash -n "$CLI" || ac_fail "bash -n bin/disinto failed"
bash -n "$CI_SETUP" || ac_fail "bash -n lib/ci-setup.sh failed"

echo PASS
