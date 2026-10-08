#!/usr/bin/env bash
# =============================================================================
# tests/acceptance/issue-1954.sh — the healer job renders the Telegram secret
#
# Issue #1954: nomad/jobs/healer.hcl must render TELEGRAM_BOT_TOKEN and
# TELEGRAM_CHAT_ID from kv/data/disinto/notify/telegram via role
# service-healer. error_on_missing_key = false lets the healer run, unable
# to notify, before the secret is seeded.
#
# Read-only: greps the jobspec and nomad/AGENTS.md. No job submit, no socket.
#
# Acceptance: `bash tests/acceptance/issue-1954.sh` exits 0 and prints PASS.
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck disable=SC1091
source "$REPO_ROOT/tests/lib/acceptance-helpers.sh"

ac_require_cmd grep

SPEC="$REPO_ROOT/nomad/jobs/healer.hcl"
DOC="$REPO_ROOT/nomad/AGENTS.md"
ac_assert_file "$SPEC" "nomad/jobs/healer.hcl must exist"
ac_assert_file "$DOC" "nomad/AGENTS.md must exist"

ac_log "checking vault role service-healer"
grep -q 'role        = "service-healer"' "$SPEC" \
  || ac_fail "healer task must set vault role = \"service-healer\""
grep -q 'vault {' "$SPEC" \
  || ac_fail "healer task must have a vault block"

ac_log "checking the notify.env template"
grep -q 'destination          = "secrets/notify.env"' "$SPEC" \
  || ac_fail "template must write secrets/notify.env"
grep -q 'env                  = true' "$SPEC" \
  || ac_fail "template must set env = true"
grep -q 'error_on_missing_key = false' "$SPEC" \
  || ac_fail "template must set error_on_missing_key = false"
grep -q 'kv/data/disinto/notify/telegram' "$SPEC" \
  || ac_fail "template must read kv/data/disinto/notify/telegram"
grep -q 'TELEGRAM_BOT_TOKEN={{ .Data.data.bot_token }}' "$SPEC" \
  || ac_fail "template must render TELEGRAM_BOT_TOKEN from bot_token"
grep -q 'TELEGRAM_CHAT_ID={{ .Data.data.chat_id }}' "$SPEC" \
  || ac_fail "template must render TELEGRAM_CHAT_ID from chat_id"

ac_log "checking the jobs table row"
row="Telegram secret from \`kv/disinto/notify/telegram\` (role \`service-healer\`)"
grep -qF -- "$row" "$DOC" \
  || ac_fail "nomad/AGENTS.md healer row must name the Telegram secret and role service-healer"

echo PASS
