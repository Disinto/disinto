#!/usr/bin/env bash
# =============================================================================
# tests/acceptance/issue-1757.sh
#
# Issue #1757: fix(edge): porter-install writes the --admin-key row before the
# DNS step
#
# porter-install.sh now runs porter-caddy.sh / porter-dns.sh (#1578, #1581).
# With no Gandi token, porter-dns.sh exits non-zero — a refusal, by design,
# "after the door files are in place". But the --admin-key block sat AFTER the
# Caddy + DNS calls, so `--admin-key <pubkey>` never wrote the admin row:
# the door installed but its admin could not get in. #1537's contract (the door
# installs without a token) broke — its run stopped at the DNS refusal, before
# the --admin-key block.
#
# Fix: the --admin-key block now runs before the Caddy + DNS block (after the
# sshd gate), so the admin row is in place even when the DNS step refuses last.
#
#   AC1  In porter-install.sh the --admin-key block (its header line) comes
#         before the `bash "${SRC_DIR}/porter-dns.sh"` call, asserted by line
#         number.
#   AC2  tests/acceptance/issue-1537.sh (door without a token, --admin-key)
#         exits 0.
#   AC3  tests/acceptance/issue-1581.sh (door with a token) exits 0.
#
# No network of its own; delegates to issue-1537.sh and issue-1581.sh, which
# are hermetic (PORTER_ROOT + stubs, no /etc writes).
#
# Run with: tools/run-acceptance.sh 1757
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../lib/acceptance-helpers.sh
source "$REPO_ROOT/tests/lib/acceptance-helpers.sh"

ac_require_cmd bash grep cut head

PORTER_INSTALL="$REPO_ROOT/tools/edge-control/porter-install.sh"
ac_assert_file "${PORTER_INSTALL}" "tools/edge-control/porter-install.sh is missing"

# ── AC1: the --admin-key block precedes the porter-dns.sh call (by line) ─────
# Anchor the block by its ASCII-stable header text (the `# ── --admin-key:`
# line, whose box-drawing chars flank the ASCII text) and the DNS call.
admin_key_line="$(grep -nF -- '--admin-key: ensure the row' "${PORTER_INSTALL}" \
  | head -n1 | cut -d: -f1)"
[[ -n "${admin_key_line}" ]] \
  || ac_fail "AC1: cannot find the --admin-key block header in ${PORTER_INSTALL}"
dns_line="$(grep -nF -- '/porter-dns.sh"' "${PORTER_INSTALL}" \
  | head -n1 | cut -d: -f1)"
[[ -n "${dns_line}" ]] \
  || ac_fail "AC1: cannot find the porter-dns.sh call in ${PORTER_INSTALL}"
if (( admin_key_line >= dns_line )); then
  ac_fail "AC1: the --admin-key block (line ${admin_key_line}) is not before the porter-dns.sh call (line ${dns_line})"
fi
ac_log "AC1: --admin-key block (line ${admin_key_line}) precedes porter-dns.sh call (line ${dns_line})"

# ── AC2: door without a token installs, admin row written before the DNS
#         refusal ──────────────────────────────────────────────────────────────
if bash "$REPO_ROOT/tests/acceptance/issue-1537.sh"; then
  ac_log "AC2: tests/acceptance/issue-1537.sh exited 0"
else
  ac_fail "AC2: tests/acceptance/issue-1537.sh did not exit 0"
fi

# ── AC3: door with a token (token fixture) still exits 0 ─────────────────────
if bash "$REPO_ROOT/tests/acceptance/issue-1581.sh"; then
  ac_log "AC3: tests/acceptance/issue-1581.sh exited 0"
else
  ac_fail "AC3: tests/acceptance/issue-1581.sh did not exit 0"
fi

ac_pass
