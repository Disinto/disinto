#!/usr/bin/env bash
# =============================================================================
# tests/acceptance/issue-1795.sh — kv/disinto/voice seeding is gone
#
# Issue #1795: nothing reads kv/disinto/voice any more. The reseed-voice
# command, tools/vault-seed-voice.sh, and the voice path in the edge-chat
# policy are removed. The historical service-edge-chat role keeps only the
# disinto/chat paths.
#
# Read-only: test, grep, and bash -n. Does not talk to Vault or Nomad.
#
# Acceptance: `bash tests/acceptance/issue-1795.sh` exits 0 and prints PASS.
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck disable=SC1091
source "$REPO_ROOT/tests/lib/acceptance-helpers.sh"

ac_require_cmd test grep bash

POLICY="$REPO_ROOT/vault/policies/service-edge-chat.hcl"
ROLES="$REPO_ROOT/vault/roles.yaml"
CLI="$REPO_ROOT/bin/disinto"

ac_assert_file "$POLICY" "vault/policies/service-edge-chat.hcl must exist"
ac_assert_file "$ROLES" "vault/roles.yaml must exist"
ac_assert_file "$CLI" "bin/disinto must exist"

ac_log "checking tools/vault-seed-voice.sh is gone"
if [ -e "$REPO_ROOT/tools/vault-seed-voice.sh" ]; then
  ac_fail "tools/vault-seed-voice.sh still exists"
fi

ac_log "checking reseed-voice, vault-seed-voice, and disinto/voice are gone"
if grep -rn -e reseed-voice -e vault-seed-voice -e disinto/voice \
  "$REPO_ROOT/bin" "$REPO_ROOT/tools" "$REPO_ROOT/vault" "$REPO_ROOT/.woodpecker"; then
  ac_fail "voice seeding names remain under bin, tools, vault, or .woodpecker"
fi

ac_log "checking service-edge-chat.hcl keeps only the two disinto/chat paths"
paths="$(grep -n 'path "kv/' "$POLICY" || true)"
expected='path "kv/data/disinto/chat" {
path "kv/metadata/disinto/chat" {'
got="$(printf '%s\n' "$paths" | sed 's/^[0-9]*://')"
if [ "$got" != "$expected" ]; then
  printf '%s\n' "$paths"
  ac_fail "service-edge-chat.hcl kv paths are not exactly the two disinto/chat paths"
fi

ac_log "checking chat subprocess is gone from the role comment and policy"
if grep -n 'chat subprocess' "$ROLES" "$POLICY"; then
  ac_fail "chat subprocess remains in vault/roles.yaml or service-edge-chat.hcl"
fi

ac_log "checking bin/disinto parses (bash -n)"
bash -n "$CLI" || ac_fail "bash -n bin/disinto failed"

echo PASS
