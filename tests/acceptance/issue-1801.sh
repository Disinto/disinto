#!/usr/bin/env bash
# =============================================================================
# tests/acceptance/issue-1801.sh — kv/disinto/chat seeders keep only
# forge_pat and nomad_token
#
# Issue #1801: chat-init.sh and vault-seed-chat.sh no longer create the
# disinto-chat OAuth app or write oauth / forward_auth keys. They still
# merge-write forge_pat and nomad_token, and chat-init.sh still applies
# chat-ops.hcl and mints nomad_token when Nomad ACLs are on.
#
# Read-only: grep, test, and bash -n. No live box.
#
# Acceptance: `bash tests/acceptance/issue-1801.sh` exits 0 and prints PASS.
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck disable=SC1091
source "$REPO_ROOT/tests/lib/acceptance-helpers.sh"

ac_require_cmd grep test bash

CHAT_INIT="$REPO_ROOT/lib/init/nomad/chat-init.sh"
SEED="$REPO_ROOT/tools/vault-seed-chat.sh"
POLICY="$REPO_ROOT/nomad/acl-policies/chat-ops.hcl"
CLI="$REPO_ROOT/bin/disinto"

ac_assert_file "$CHAT_INIT" "lib/init/nomad/chat-init.sh must exist"
ac_assert_file "$SEED" "tools/vault-seed-chat.sh must exist"
ac_assert_file "$POLICY" "nomad/acl-policies/chat-ops.hcl must exist"
ac_assert_file "$CLI" "bin/disinto must exist"

ac_log "checking seeders no longer mention oauth, forward_auth, or EDGE_"
if grep -niE 'oauth|forward_auth|EDGE_' "$CHAT_INIT" "$SEED"; then
  ac_fail "oauth, forward_auth, or EDGE_ remains in a kv/disinto/chat seeder"
fi

ac_log "checking each seeder assigns forge_pat once"
for f in "$CHAT_INIT" "$SEED"; do
  count="$(grep -cF '.forge_pat = $v' "$f" || true)"
  if [ "$count" != "1" ]; then
    ac_fail "$(basename "$f") .forge_pat = \$v count is ${count}, expected 1"
  fi
done

ac_log "checking nomad_token payload assignment"
# vault-seed-chat.sh writes nomad_token only in the shared payload block.
seed_nomad="$(grep -cF '.nomad_token = $v' "$SEED" || true)"
if [ "$seed_nomad" != "1" ]; then
  ac_fail "vault-seed-chat.sh .nomad_token = \$v count is ${seed_nomad}, expected 1"
fi
# chat-init.sh keeps that same payload block and the ACL mint (former
# Step 3/3), which also assigns .nomad_token = $v. Both lines are required.
init_nomad="$(grep -cF '.nomad_token = $v' "$CHAT_INIT" || true)"
if [ "$init_nomad" != "2" ]; then
  ac_fail "chat-init.sh .nomad_token = \$v count is ${init_nomad}, expected 2 (payload + ACL mint)"
fi

ac_log "checking chat-ops policy apply remains in chat-init.sh"
ops_count="$(grep -c chat-ops "$CHAT_INIT" || true)"
if [ "$ops_count" -lt 1 ]; then
  ac_fail "chat-ops is missing from chat-init.sh"
fi

ac_log "checking disinto vault help no longer names OAuth secrets or forward_auth"
vault_fn="$(sed -n '/^disinto_vault()/,/^}/p' "$CLI")"
if printf '%s\n' "$vault_fn" | grep -niE 'OAuth \+ secrets|OAuth credentials|forward_auth'; then
  ac_fail "disinto_vault still describes OAuth secrets or forward_auth"
fi

ac_log "checking both seeders parse (bash -n)"
bash -n "$CHAT_INIT" || ac_fail "bash -n lib/init/nomad/chat-init.sh failed"
bash -n "$SEED" || ac_fail "bash -n tools/vault-seed-chat.sh failed"

echo PASS
