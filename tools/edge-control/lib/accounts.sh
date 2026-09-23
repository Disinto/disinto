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
#         "admin": false,               # admin-privileged caller (set by admin-grant)
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
#     status=pending, credits=0, admin=false. Returns 0 on success, 1 on a bad
#     fingerprint.
#
#   account_row <fp>
#     Print the compact JSON row for <fp> on stdout. Exits non-zero (empty
#     output) if the row is absent.
#
#   account_set_name <fp> <name>
#     Set the row's `name` field to <name>, leaving all other fields
#     (status, credits, created_at) untouched — atomic read-modify-write over
#     a tmp path + rename (like account_ensure). If the row is absent, a fresh
#     pending row is created with the name already bound. The caller validates
#     <name> and decides whether the claim is allowed (collision checks live in
#     the calling verb); this function itself never refuses an overwrite.
#     Returns 0 on success, 1 on a bad fingerprint or failed update.
#
#   print_account_row
#     Report the caller's account row (used by the report verbs, whoami and
#     status). dispatch.sh always exports DISPATCH_FP before exec'ing a verb,
#     so its absence here is an internal miswire: a visible failure (a
#     {"error":"missing fingerprint"} on stderr) and exit 1, not a silent miss.
#     On success, prints the compact row for DISPATCH_FP and exits the calling
#     verb 0.
#
# Sourcing contract: FINGERPRINT_RE, ACCOUNTS_FILE, account_ensure(),
# account_row(), account_set_name(), and print_account_row() become available
# to the caller.
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
        {fingerprint: $fp, status: "pending", credits: 0, name: null, admin: false, created_at: $now})' \
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

# Set the name field for <fp> (see header). Caller validates <name>; this is
# the atomic write the verbs use.
account_set_name() {
  local fp="$1" name="$2"
  local now tmp

  if [[ ! "$fp" =~ $FINGERPRINT_RE ]]; then
    echo "account_set_name: invalid fingerprint" >&2
    return 1
  fi

  accounts_init

  # Same atomic read-modify-write as account_ensure: a missing row is created
  # fresh (status=pending, credits=0), an existing row is only touched on the
  # name field, so status/credits/created_at survive untouched.
  now="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
  tmp="$(mktemp)" || { echo "account_set_name: mktemp failed" >&2; return 1; }

  if jq --arg fp "$fp" --arg name "$name" --arg now "$now" \
        '.accounts = (.accounts // {})
         | .accounts[$fp] = (.accounts[$fp] //
            {fingerprint: $fp, status: "pending", credits: 0, name: null, admin: false, created_at: $now})
         | .accounts[$fp].name = $name' \
        "$ACCOUNTS_FILE" > "$tmp" 2>/dev/null; then
    mv "$tmp" "$ACCOUNTS_FILE"
  else
    rm -f "$tmp"
    echo "account_set_name: failed to update $ACCOUNTS_FILE" >&2
    return 1
  fi

  return 0
}

# Report the caller's account row (see file header). dispatch.sh exports
# DISPATCH_FP before exec'ing any verb; this guard makes an internal miswire a
# loud, visible failure rather than a silent empty row.
print_account_row() {
  if [[ -z "${DISPATCH_FP:-}" ]]; then
    echo '{"error":"missing fingerprint"}' >&2
    exit 1
  fi
  account_row "${DISPATCH_FP}"
  exit 0
}
