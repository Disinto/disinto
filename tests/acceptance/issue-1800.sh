#!/usr/bin/env bash
# =============================================================================
# tests/acceptance/issue-1800.sh — `disinto doctor` and the other chat Nomad
# job leftovers are gone
#
# Issue #1800: chat has no Nomad job any more, so the doctor command (its only
# check), the chat ready-timeout, and the docs that still describe them are
# removed. The chat-ops ACL row stays; #1801 removes it.
#
# Read-only: grep, test, and bash -n. No live box.
#
# Acceptance: `bash tests/acceptance/issue-1800.sh` exits 0 and prints PASS.
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
cd "$REPO_ROOT"

# shellcheck disable=SC1091
source "$REPO_ROOT/tests/lib/acceptance-helpers.sh"

ac_require_cmd grep test bash

ac_log "checking doctor symbols and JOB_READY_TIMEOUT_CHAT are gone from bin and lib"
if grep -rn -e disinto_doctor -e doctor_check_chat -e JOB_READY_TIMEOUT_CHAT bin lib; then
  ac_fail "disinto_doctor, doctor_check_chat, or JOB_READY_TIMEOUT_CHAT remains under bin or lib"
fi

ac_log "checking tests/disinto-doctor.bats is gone"
if [ -e tests/disinto-doctor.bats ]; then
  ac_fail "tests/disinto-doctor.bats still exists"
fi

ac_log "checking the doctor case arm is gone"
if grep -nE '^ +doctor\)' bin/disinto; then
  ac_fail "doctor case arm remains in bin/disinto"
fi

ac_log "checking nomad/AGENTS.md no longer documents doctor or the chat job"
if grep -n doctor nomad/AGENTS.md; then
  ac_fail "doctor remains in nomad/AGENTS.md"
fi
if grep -n chat nomad/AGENTS.md | grep -v chat-ops; then
  ac_fail "chat other than chat-ops remains in nomad/AGENTS.md"
fi

ac_log "checking the deploy-order and item_snoozed rows no longer name chat or inbox-ack"
count="$(grep -e 'deploy order now covers' -e item_snoozed lib/AGENTS.md | grep -ciE 'chat|inbox-ack' || true)"
if [ "$count" != "0" ]; then
  ac_fail "deploy order or item_snoozed row still mentions chat or inbox-ack (count=$count)"
fi

ac_log "checking bin/disinto and deploy.sh parse"
bash -n bin/disinto || ac_fail "bash -n bin/disinto failed"
bash -n lib/init/nomad/deploy.sh || ac_fail "bash -n lib/init/nomad/deploy.sh failed"

echo PASS
