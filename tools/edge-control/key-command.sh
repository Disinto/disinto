#!/usr/bin/env bash
# =============================================================================
# key-command.sh — sshd AuthorizedKeysCommand handler (any-key identity)
#
# sshd invokes this (via `AuthorizedKeysCommand /opt/disinto-edge/key-command.sh
# %f %t %k`) for *every* incoming public key, before it will let a session start.
# Its job is to turn an arbitrary SSH key into the edge-control account identified
# by that key's fingerprint, and to emit a single restricted authorized_keys line:
#
#     restrict,command="/opt/disinto-edge/dispatch.sh --fp FINGERPRINT" TYPE KEY
#
# That line:
#   • forces the dispatcher as the only command the caller can run (never a shell);
#   • carries the caller's fingerprint so dispatch.sh can attribute the session;
#   • is a *restrict* line — no permitlisten, no permitopen, no pty, no
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

# The dispatcher the restrict line hands the caller to. Matches install.sh
# INSTALL_DIR; the operator enables AuthorizedKeysCommand to point at this file.
DISPATCH_CMD='/opt/disinto-edge/dispatch.sh'

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

# One line, and nothing else, on stdout.
printf 'restrict,command="%s --fp %s" %s %s\n' \
  "$DISPATCH_CMD" "$fingerprint" "$key_type" "$key_data"
