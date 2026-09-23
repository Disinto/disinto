#!/usr/bin/env bash
# =============================================================================
# accounts.sh — edge control plane account ledger
#
# The "account row" is the single source of truth for who is connected to the
# edge control plane. The SSH key fingerprint is the account: there is no
# username and no password — a fingerprint identifies a caller across every
# verb (whoami, status, register-request, approve, credits-buy, ...).
#
# This is the shared library the dispatcher (dispatch.sh) and every verb in
# verbs/ source. It is NOT an executable entry point.
#
# File format (ACCOUNTS_FILE, default /var/lib/disinto/accounts.json):
#
#   {
#     "version": 1,
#     "accounts": {
#       "SHA256:<43 base64url chars>": {
#         "fingerprint": "SHA256:...",
#         "status": "pending",          # pending -> registered -> active; revoked
#         "credits": 0,                 # integer, debited/credited by verbs
#         "name": null,                 # bound name (set by the admin-approve verb)
#         "created_at": "2026-09-23T00:00:00Z"
#       }
#     }
#   }
#
# Functions:
#   account_ensure <fp>
#     Create the accounts file (with an empty accounts map) if it is missing,
#     and make sure a row exists for <fp>. Idempotent: an existing row is left
#     untouched so that later verbs (which credit/debit, bind a name, change
#     status) are not clobbered. A fresh row is created with
#     status=pending, credits=0. Returns 0 on success, 1 on a bad fingerprint.
#
#   account_row <fp>
#     Print the compact JSON row for <fp> on stdout. Exits non-zero (empty
#     output) if the row is absent.
#
# Sourcing contract: FINGERPRINT_RE, ACCOUNTS_FILE, account_ensure(), and
# account_row() become available to the caller.
# =============================================================================

set -euo pipefail

# SHA256 fingerprint: the ssh-keygen "SHA256:" prefix + exactly 43 base64url
# characters (A-Z, a-z, 0-9, '-', '_'). This is the one canonical regex for
# the whole edge-control plane; dispatch.sh and key-command.sh validate with it.
FINGERPRINT_RE='^SHA256:[A-Za-z0-9_-]{43}$'

# Where the ledger lives. Operators (and tests) override via ACCOUNTS_FILE.
ACCOUNTS_FILE="${ACCOUNTS_FILE:-/var/lib/disinto/accounts.json}"

# Make sure the ledger file and its directory exist, seeded with an empty
# accounts map. Non-interactive and idempotent.
accounts_init() {
  local dir
  dir="$(dirname "$ACCOUNTS_FILE")"
  mkdir -p "$dir"
  if [ ! -f "$ACCOUNTS_FILE" ]; then
    printf '{"version":1,"accounts":{}}\n' > "$ACCOUNTS_FILE"
  fi
}

# Ensure a row exists for <fp>. See the file header for the contract.
account_ensure() {
  local fp="$1"

  if [[ ! "$fp" =~ $FINGERPRINT_RE ]]; then
    echo "account_ensure: invalid fingerprint" >&2
    return 1
  fi

  accounts_init

  # Atomically update the ledger: read the current file, add the row if the
  # fingerprint is absent (leave an existing row alone), and write to a tmp
  # path we then rename over the original.
  local now tmp
  now="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
  tmp="$(mktemp)" || { echo "account_ensure: mktemp failed" >&2; return 1; }

  if jq --arg fp "$fp" --arg now "$now" \
    '.accounts = (.accounts // {})
     | .accounts[$fp] = (.accounts[$fp] //
        {fingerprint: $fp, status: "pending", credits: 0, name: null, created_at: $now})' \
    "$ACCOUNTS_FILE" > "$tmp" 2>/dev/null; then
    mv "$tmp" "$ACCOUNTS_FILE"
  else
    rm -f "$tmp"
    echo "account_ensure: failed to update $ACCOUNTS_FILE" >&2
    return 1
  fi
}

# Print the compact JSON row for <fp>. No output and a non-zero exit if the
# row is missing — dispatch.sh always account_ensure()'d it first, so a miss
# here is an internal invariant breach worth surfacing.
account_row() {
  local fp="$1"
  jq -c --arg fp "$fp" '.accounts // {} | .[$fp] // empty' "$ACCOUNTS_FILE"
}
