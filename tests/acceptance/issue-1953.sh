#!/usr/bin/env bash
# =============================================================================
# tests/acceptance/issue-1953.sh — a role for the healer to read the Telegram
# secret
#
# Issue #1953: the healer job (#1951) needs read access to the Telegram bot
# token and chat id to message the owner when its own fix did not work
# (#1955). The secrets live at kv/disinto/notify/telegram (keys bot_token,
# chat_id), seeded by hand — not this change. This lands
# vault/policies/service-healer.hcl (read on
# kv/data/disinto/notify/telegram) plus the matching service-healer role in
# vault/roles.yaml bound to job_id healer.
#
# Read-only: parses the policy HCL and vault/roles.yaml from the checkout;
# no forge, no nomad, no repo mutation.
#
# Verifies (per the issue acceptance criteria):
#   1. service-healer.hcl grants ONLY `read` on
#      kv/data/disinto/notify/telegram (nothing else).
#   2. vault/roles.yaml has a service-healer role bound to job_id healer
#      (whose policy is service-healer).
#
# Run via: tools/run-acceptance.sh 1953
#
# Last stdout line is PASS or FAIL: <reason>.
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck disable=SC1091
source "$REPO_ROOT/tests/lib/acceptance-helpers.sh"

ac_require_cmd grep test

POLICY="$REPO_ROOT/vault/policies/service-healer.hcl"
ROLES="$REPO_ROOT/vault/roles.yaml"

ac_assert_file "$POLICY" "vault/policies/service-healer.hcl must exist"
ac_assert_file "$ROLES" "vault/roles.yaml must exist"

# ── 1. the policy grants only read on the notify/telegram path ──────────────
ac_log "AC1: service-healer.hcl grants only read on kv/data/disinto/notify/telegram"

# The non-comment body must be exactly the single read grant on that path.
# `$(...)` strips the trailing newline; a mismatch means an extra path, an
# extra capability, or a capability other than read.
body="$(grep -vE '^[[:space:]]*#' "$POLICY" | grep -vE '^[[:space:]]*$')"
expected='path "kv/data/disinto/notify/telegram" {
  capabilities = ["read"]
}'
if [ "$body" != "$expected" ]; then
  printf '%s\n' "$body"
  ac_fail "service-healer.hcl must grant exactly read on kv/data/disinto/notify/telegram"
fi

ac_log "AC1: policy is exactly a read grant on the notify/telegram path"

# ── 2. vault/roles.yaml binds job_id healer to the service-healer role ──────
ac_log "AC2: vault/roles.yaml binds job_id healer to the service-healer role"

block="$(grep -A3 'name: *service-healer$' "$ROLES" || true)"
[ -n "$block" ] || ac_fail "vault/roles.yaml does not contain a service-healer role"

printf '%s\n' "$block" | grep -qF 'job_id:    healer' \
  || ac_fail "service-healer role must bind job_id healer, got: $block"
printf '%s\n' "$block" | grep -qF 'policy:    service-healer' \
  || ac_fail "service-healer role must keep policy service-healer"

ac_log "service-healer: policy grants only read on notify/telegram; roles.yaml binds healer"
ac_pass
