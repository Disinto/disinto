#!/usr/bin/env bash
# =============================================================================
# porter-admin.sh — grant admin on the local ledger (local only, never a verb)
#
#     porter-admin.sh add-admin FINGERPRINT
#
# The door has no admin-granting verb: credits-grant and approve both refuse
# a caller whose row is not admin, and any remote verb that could flip
# admin: true would let every key that reaches the door take full control of
# the ledger (privilege escalation). So the first admin is bootstrapped
# from the edge box itself, by the operator, with this local-only tool.
#
# Deliberately kept out of the door: not under verbs/ and not in the
# porter-install.sh copy list (#1537) — nothing ships it to the door runtime.
#
# Ledger path: ${PORTER_LEDGER:-/var/lib/disinto/accounts.json}. When the
# path is the default and the effective uid is not 0, refuse with
# {"error":"not root"} and exit 1 — nothing is written (the check precedes
# any file access). Setting PORTER_LEDGER is the test seam: no euid check,
# the tool works against any writable path.
#
# Flow:
#   1. Validate the subcommand: exactly `add-admin FINGERPRINT`. Otherwise
#      {"error":"bad arguments (expected: add-admin FINGERPRINT)"} /
#      {"error":"unknown command"}; rc 1.
#   2. Default path + non-zero euid -> {"error":"not root"}, rc 1, nothing
#      written.
#   3. Fingerprint must match the ledger regex ^SHA256:[A-Za-z0-9_-]{43}$
#      (FINGERPRINT_RE from lib/accounts.sh). Otherwise {"error":"invalid
#      fingerprint"}, rc 1, nothing written.
#   4. Reuse the shared account_ensure (lib/accounts.sh) to create the ledger
#      file/directory and the default-shaped row (status=pending, credits=0,
#      admin=false), then a single local-only jq pass over a tmp + rename
#      flips admin=true. The admin-grant deliberately stays out of the door's
#      shared lib (lib/ ships to the door runtime; admin must be grantable
#      only by this local tool). Existing rows keep status, credits, name and
#      created_at untouched — only admin moves.
#   5. Print the compact row. rc 0.
#
# Output contract (JSON on stdout unless noted):
#   rc 0 -> the compact account row of FINGERPRINT
#   rc 1 -> {"error":"..."} with one of:
#       "bad arguments (expected: add-admin FINGERPRINT)"
#       "unknown command"
#       "not root"                  — default path, euid != 0
#       "invalid fingerprint"
#       "failed to update ledger"
#   Every failure path returns before the ledger is written.
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

DEFAULT_LEDGER="/var/lib/disinto/accounts.json"
LEDGER="${PORTER_LEDGER:-$DEFAULT_LEDGER}"
# lib/accounts.sh honors a pre-set ACCOUNTS_FILE (the verbs are driven this
# way in the acceptance tests); it otherwise defaults to /var/lib/disinto.
# shellcheck disable=SC2034
ACCOUNTS_FILE="$LEDGER"

# shellcheck source=lib/accounts.sh
source "${SCRIPT_DIR}/lib/accounts.sh"

# ── subcommand + argument count ───────────────────────────────────────────────
if [[ $# -ne 2 ]]; then
  fail_error "bad arguments (expected: add-admin FINGERPRINT)"
fi
if [[ "$1" != "add-admin" ]]; then
  fail_error "unknown command"
fi
target="$2"

# ── default path: /var/lib/disinto requires root; PORTER_LEDGER is the seam ───
if [[ "$LEDGER" == "$DEFAULT_LEDGER" && $EUID -ne 0 ]]; then
  fail_error "not root"
fi

# ── fingerprint: the account-ledger regex; fail before any write ─────────────
if [[ ! "$target" =~ $FINGERPRINT_RE ]]; then
  fail_error "invalid fingerprint"
fi

# ── ensure the row via the shared lib (lib/accounts.sh). It creates the ledger
# file + directory (seeded only when the file is absent) and a default-shaped
# row (status=pending, credits=0, admin=false), atomically — a neutral, shared
# operation the door itself needs. Reusing it avoids re-implementing ensure.
if ! account_ensure "$target"; then
  fail_error "failed to update ledger"
fi

# ── flip admin=true: a single local-only pass over a tmp path + rename. Only
# the admin field moves; status/credits/name/created_at are left untouched.
# This block lives only in this local operator tool — it is never shipped to
# the door runtime (see file header), so the edge has no admin-grant primitive.
tmp="${LEDGER}.admin-tmp"
if jq --arg fp "$target" '.accounts[$fp].admin = true' "$LEDGER" > "$tmp"; then
  mv "$tmp" "$LEDGER"
else
  rm -f "$tmp"
  fail_error "failed to update ledger"
fi

account_row "$target"
exit 0
