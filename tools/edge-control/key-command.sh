#!/usr/bin/env bash
# =============================================================================
# key-command.sh — sshd AuthorizedKeysCommand handler (any-key identity)
#
# sshd invokes this (via `AuthorizedKeysCommand /opt/disinto-edge/key-command.sh
# %f %t %k`) for *every* incoming public key, before it will let a session start.
# Its job is to turn an arbitrary SSH key into the edge-control account identified
# by that key's fingerprint, and to emit a single restricted authorized_keys line:
#
#     pty,restrict,command="<SCRIPT_DIR>/porter-wrap.sh --fp FINGERPRINT" TYPE KEY
#
# porter-wrap.sh is the wrapper the dispatcher hands the caller to: it loads
# the allowlisted edge env (PORTER_ENV) that sshd otherwise strips, then execs
# the sibling dispatch.sh with the same arguments.
#
# That line:
#   • grants a pty so interactive (menu) sessions have a TTY for the dispatcher
#     to list verbs and read one line from stdin — the pty does NOT grant a
#     shell; the forced command still runs;
#   • forces the dispatcher as the only command the caller can run (never a shell);
#   • carries the caller's fingerprint so dispatch.sh can attribute the session;
#   • is a *restrict* line — no permitlisten, no permitopen, no
#     agent-forwarding. The caller can only run dispatcher verbs.
#
# Output contract:
#   success -> exactly one line on stdout (the restrict line), nothing else.
#   bad args (wrong arity, empty field, bad fingerprint, unsupported key type)
#             -> empty stdout, exit 1 (diagnostics go to stderr only).
#
# NOTE: turning this on (`AuthorizedKeysCommand ...`) is operator work on the
# edge host; no file in this tree performs it.
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Fingerprint contract (one canonical regex for the whole edge-control plane,
# defined alongside the account row in lib/accounts.sh).
# shellcheck source=lib/accounts.sh
source "${SCRIPT_DIR}/lib/accounts.sh"

# The forced command the restrict line hands the caller to: the sibling
# porter-wrap.sh (resolved relative to this file, so it tracks the install
# directory — /opt/disinto-edge/ in production). porter-wrap.sh loads the
# allowlisted edge env and execs the sibling dispatch.sh. The operator enables
# AuthorizedKeysCommand to point at this file.
DISPATCH_CMD="${SCRIPT_DIR}/porter-wrap.sh"

# Only these public-key types are acceptable (the account ledger's allowlist).
ALLOWED_KEY_TYPES='^(ssh-ed25519|ssh-rsa|ecdsa-sha2-nistp256|ecdsa-sha2-nistp384|ecdsa-sha2-nistp521)$'

# Bad argument -> empty stdout (stderr is free), exit 1.
fail() {
  printf 'key-command.sh: %s\n' "$*" >&2
  exit 1
}

[[ $# -eq 3 ]] || fail "expected 3 args (fingerprint key-type key-data), got $#"
fingerprint="$1"
key_type="$2"
key_data="$3"

[[ -n "$fingerprint" ]] || fail "fingerprint is empty"
[[ -n "$key_type" ]]    || fail "key type is empty"
[[ -n "$key_data" ]]    || fail "key data is empty"

[[ "$fingerprint" =~ $FINGERPRINT_RE ]] || fail "invalid fingerprint"
[[ "$key_type" =~ $ALLOWED_KEY_TYPES ]] || fail "unsupported key type: $key_type"

# Persist the caller's public key on that fingerprint's ledger row before
# emitting the restrict line. The stored field is `pubkey` =
# "KEY_TYPE KEY_DATA" (one space, no options, no comments) — the value the
# tunnel side (lib/apply-name.sh) drops into disinto-tunnel's
# authorized_keys. A fresh row is created if absent (status=pending,
# credits=0, admin=false); an existing row is touched on its `pubkey` field
# only. A failed write refuses the connection (empty stdout, exit 1) rather
# than opening a session whose row does not carry the key; the key material
# itself is never written to stderr.
if ! account_set_pubkey "$fingerprint" "$key_type" "$key_data"; then
  fail "failed to store public key for $fingerprint"
fi

# One line, and nothing else, on stdout.
printf 'pty,restrict,command="%s --fp %s" %s %s\n' \
  "$DISPATCH_CMD" "$fingerprint" "$key_type" "$key_data"
