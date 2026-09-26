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
#   account_add_credits <fp> <n>
#     Add <n> to the row's `credits` field, leaving every other field
#     (status, name, admin, created_at) untouched — atomic read-modify-write
#     over a tmp path + rename (like account_set_name). The caller validates
#     <n> and runs account_ensure <fp> first; the row is never created here —
#     a missing row is a caller bug. Returns 0 on success, 1 on a bad
#     fingerprint, a missing row, or a failed update.
#
#   account_set_pubkey <fp> <key-type> <key-data>
#     Store the public key on the <fp> row in the `pubkey` field as
#     "<key-type> <key-data>" — a single space, no options, no comments.
#     Atomic read-modify-write over a tmp path + rename (like
#     account_set_name): the row is created if absent (status=pending,
#     credits=0, name=null, admin=false), and an existing row is touched on
#     its `pubkey` field only — status, credits, name, admin, and
#     created_at all survive. Idempotent: a second connection with the same
#     key writes the same value and changes nothing else. The key material
#     is never echoed (failure messages name only the ledger path). Returns
#     0 on success, 1 on a bad fingerprint, an empty field, or a failed
#     update.
#
#   print_account_row
#     Report the caller's account row (used by the report verbs, whoami and
#     status). dispatch.sh always exports DISPATCH_FP before exec'ing a verb,
#     so its absence here is an internal miswire: a visible failure (a
#     {"error":"missing fingerprint"} on stderr) and exit 1, not a silent miss.
#     On success, prints the compact row for DISPATCH_FP and exits the calling
#     verb 0.
#
#   fail_error <message>
#     Print the canonical JSON error object ({"error":"<message>"}) on stdout
#     and exit 1. Shared by every verb so the failure shape is uniform.
#
# Sourcing contract: FINGERPRINT_RE, ACCOUNTS_FILE, fail_error(), account_ensure(),
# account_row(), account_set_name(), account_set_pubkey(),
# account_add_credits(), is_admin(), require_admin(), require_dispatch_fp(),
# and print_account_row() become available to the caller.
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

# Print the canonical JSON error object to stdout and exit non-zero. Shared by
# every verb so the failure shape is uniform: {"error":"<message>"}. The
# <message> must never contain state, a fingerprint, or a secret.
fail_error() {
  printf '{"error":"%s"}\n' "$1"
  exit 1
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

# Store the public key for <fp> (see header). The caller validates the key
# type against the allowlist (key-command.sh); this function is the atomic
# write that persists it, and it never echoes the key material.
account_set_pubkey() {
  local fp="$1" key_type="$2" key_data="$3"
  local now tmp

  if [[ ! "$fp" =~ $FINGERPRINT_RE ]]; then
    echo "account_set_pubkey: invalid fingerprint" >&2
    return 1
  fi
  if [[ -z "$key_type" ]] || [[ -z "$key_data" ]]; then
    echo "account_set_pubkey: key type and key data must be non-empty" >&2
    return 1
  fi

  # Atomic read-modify-write: a missing row is created fresh (status=pending,
  # credits=0, name=null, admin=false, created_at=now), an existing row is
  # touched on the pubkey field only, so status/credits/name/admin/created_at
  # survive untouched.
  accounts_init
  now="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
  tmp="$(mktemp)" || { echo "account_set_pubkey: mktemp failed" >&2; return 1; }

  if jq --arg fp "$fp" --arg key_type "$key_type" --arg key_data "$key_data" \
        --arg now "$now" \
        '.accounts = (.accounts // {})
         | .accounts[$fp] = (.accounts[$fp] //
            {fingerprint: $fp, status: "pending", credits: 0, name: null, admin: false, created_at: $now})
         | .accounts[$fp].pubkey = ($key_type + " " + $key_data)' \
        "$ACCOUNTS_FILE" > "$tmp" 2>/dev/null; then
    mv "$tmp" "$ACCOUNTS_FILE"
    return 0
  else
    rm -f "$tmp"
    echo "account_set_pubkey: failed to update $ACCOUNTS_FILE" >&2
    return 1
  fi
}

# Add <n> to the `credits` field of <fp>'s row (see header). The caller
# validates <n> and runs account_ensure <fp> first; this function is the
# atomic write the verbs use and it never creates a row itself.
account_add_credits() {
  local fp="$1" n="$2"
  local tmp

  if [[ ! "$fp" =~ $FINGERPRINT_RE ]]; then
    echo "account_add_credits: invalid fingerprint" >&2
    return 1
  fi

  # The row must exist (the caller runs account_ensure first). Without this
  # guard, assigning on an absent key would rewrite the whole entry as the
  # scalar <n> instead of a row object.
  if ! jq -e --arg fp "$fp" '(.accounts // {}) | has($fp)' "$ACCOUNTS_FILE" \
       >/dev/null 2>&1; then
    echo "account_add_credits: no row for $fp" >&2
    return 1
  fi

  tmp="$(mktemp)" || { echo "account_add_credits: mktemp failed" >&2; return 1; }

  if jq --arg fp "$fp" --argjson n "$n" \
        '.accounts[$fp].credits = (.accounts[$fp].credits + $n)' \
        "$ACCOUNTS_FILE" > "$tmp" 2>/dev/null; then
    mv "$tmp" "$ACCOUNTS_FILE"
    return 0
  else
    rm -f "$tmp"
    echo "account_add_credits: failed to update $ACCOUNTS_FILE" >&2
    return 1
  fi
}

# is_admin <fp> — return 0 if $ACCOUNTS_FILE[$fp] carries exactly
# "admin": true; fail closed (return 1) on a missing row, a missing field, or
# anything not the boolean true (jq -e exits 1 on no/empty output). The
# caller validates <fp> against FINGERPRINT_RE first.
is_admin() {
  local fp="$1"
  jq -e --arg fp "$fp" '(.accounts // {})[$fp].admin == true' "$ACCOUNTS_FILE" \
    >/dev/null 2>&1
}

# require_admin <fp> — process gate for admin verbs (tickets.sh,
# credits-grant.sh): exit the verb process with {"error":"not admin"} (rc 1)
# when the caller is not admin, or continue otherwise. Call it after
# require_dispatch_fp() so <fp> is the caller, not a target.
require_admin() {
  is_admin "$1" \
    || { printf '{"error":"not admin"}\n'; exit 1; }
}

# Require the dispatcher fingerprint (exported by dispatch.sh before exec'ing
# the verb). On a miswire (empty/absent), fail closed: emit the standard error
# JSON to stderr and return 1. On success, print the fingerprint on stdout and
# return 0. Verbs capture it as:  fp="$(require_dispatch_fp)" || exit 1
require_dispatch_fp() {
  local fp="${DISPATCH_FP:-}"
  if [[ -z "$fp" ]]; then
    printf '{"error":"missing fingerprint"}\n' >&2
    return 1
  fi
  printf '%s\n' "$fp"
  return 0
}

# Report the caller's account row (see file header). dispatch.sh exports
# DISPATCH_FP before exec'ing any verb; require_dispatch_fp() makes an internal
# miswire a loud, visible failure rather than a silent empty row.
print_account_row() {
  local fp
  fp="$(require_dispatch_fp)" || exit 1
  account_row "$fp"
  exit 0
}

# row_fp_by_name <name> — fingerprint of the row whose `name` field equals
# <name>, or empty when no row holds that name. This is the reverse lookup the
# name-keyed verbs (verbs/approve.sh, verbs/revoke.sh) and lib/apply-name.sh
# use to turn a claimed subdomain back into the account row it belongs to.
row_fp_by_name() {
  local name="$1"
  jq -r --arg n "$name" \
      '[ (.accounts // {}) | to_entries[]
         | select((.value.name // empty) == $n)
         | .key ]
       | .[0] // empty' "$ACCOUNTS_FILE"
}

# account_set_status <fp> <status> — set the row's `status` field, leaving every
# other field (name, credits, admin, created_at) untouched — an atomic
# read-modify-write over a tmp path + rename (like account_set_name). The
# caller validates <status> (a verb decides which values are legal and when);
# this function itself never refuses an overwrite. The row must exist — this is
# a mutation, not an upsert (a missing row is a caller bug: the verb ran
# row_fp_by_name() first and only proceeds when it found the row). Returns 0
# on success, 1 on a bad fingerprint, a missing row, or a failed update.
account_set_status() {
  local fp="$1" status="$2"
  local tmp

  if [[ ! "$fp" =~ $FINGERPRINT_RE ]]; then
    echo "account_set_status: invalid fingerprint" >&2
    return 1
  fi

  if ! jq -e --arg fp "$fp" '(.accounts // {}) | has($fp)' \
       "$ACCOUNTS_FILE" >/dev/null 2>&1; then
    echo "account_set_status: no row for $fp" >&2
    return 1
  fi

  tmp="$(mktemp)" || { echo "account_set_status: mktemp failed" >&2; return 1; }

  if jq --arg fp "$fp" --arg status "$status" \
        '.accounts[$fp].status = $status' \
        "$ACCOUNTS_FILE" > "$tmp" 2>/dev/null; then
    mv "$tmp" "$ACCOUNTS_FILE"
    return 0
  else
    rm -f "$tmp"
    echo "account_set_status: failed to update $ACCOUNTS_FILE" >&2
    return 1
  fi
}
