#!/usr/bin/env bash
# =============================================================================
# dispatch.sh — restricted forced-command dispatcher (any-key identity)
#
# The "store door" of the edge control plane. Any SSH key may log in (see
# key-command.sh, which emits the restrict,command line via sshd's
# AuthorizedKeysCommand) and is identified purely by its key fingerprint.
# dispatch.sh is the single thing the caller can execute — never a shell.
#
# Flow:
#   1. Require exactly `--fp <fingerprint>` on the CLI and validate it (the
#      account-ledger fingerprint regex).
#   2. account_ensure <fp>: make sure this fingerprint's account row exists in
#      the ledger (creates a fresh row with status=pending, credits=0 if needed).
#   3. Read SSH_ORIGINAL_COMMAND. If it is empty: {"error":"no command"}.
#   4. First whitespace-delimited token is the verb; it must match
#      ^[a-z][a-z0-9-]*$. Otherwise: {"error":"unknown command"}.
#   5. Export DISPATCH_FP and exec verbs/<verb>.sh (relative to this script)
#      with the remaining arguments.
#
# Security guarantees:
#   • The command string is never eval'ed. It is split on the first whitespace
#     into (verb, rest); only the verb token is used to choose a file, and the
#     verb is a single validated lowercase token — so the only thing that can
#     ever be executed is the file verbs/<verb>.sh, which by construction lives
#     inside verbs/ (no '/', no '..', no absolute path, no shell metacharacters).
#   • SSH_ORIGINAL_COMMAND itself is only read; it is never shell input.
#
# Exit: the verb's exit status on success. 1 on missing/invalid --fp, empty
# command, or unknown/non-executable verb.
#
# NOTE: enabling sshd's AuthorizedKeysCommand is operator work on the edge
#       host; no file in this tree performs it.
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT_DIR="${SCRIPT_DIR%/}"

# Ledger + fingerprint contract (shared with key-command.sh and the verbs).
# shellcheck source=lib/accounts.sh
source "${SCRIPT_DIR}/lib/accounts.sh"

VERBS_DIR="${SCRIPT_DIR}/verbs"

# --- CLI: require exactly `--fp <fingerprint>` --------------------------------
# (The verb and its args arrive via SSH_ORIGINAL_COMMAND, never here.)
[[ $# -eq 2 ]] \
  || { echo '{"error":"bad arguments (expected: --fp FINGERPRINT)"}'; exit 1; }
[[ "$1" == "--fp" ]] \
  || { echo '{"error":"expected --fp first"}'; exit 1; }
fp="$2"
[[ -n "$fp" ]] \
  || { echo '{"error":"empty fingerprint"}'; exit 1; }

# Validate against the account-ledger fingerprint regex.
[[ "$fp" =~ $FINGERPRINT_RE ]] \
  || { echo '{"error":"invalid fingerprint"}'; exit 1; }

# Ensure the account row exists for this fingerprint.
account_ensure "$fp"

# --- forced command -----------------------------------------------------------
command="${SSH_ORIGINAL_COMMAND:-}"
if [[ -z "$command" ]]; then
  echo '{"error":"no command"}'
  exit 1
fi

# First whitespace-delimited token is the verb; the rest (verbatim, including
# spaces) are the verb's arguments.
verb=""
rest=""
read -r verb rest <<< "$command"
[[ -n "$verb" ]] \
  || { echo '{"error":"no command"}'; exit 1; }
# The verb must be a single safe token. Anything else is "unknown command".
if [[ ! "$verb" =~ ^[a-z][a-z0-9-]*$ ]]; then
  echo '{"error":"unknown command"}'
  exit 1
fi

# The only thing that can be executed is verbs/<verb>.sh, resolved by the
# (already-validated) token. By construction this path is always inside verbs/.
verb_path="${VERBS_DIR}/${verb}.sh"
if [[ ! -f "$verb_path" ]] || [[ ! -x "$verb_path" ]]; then
  echo '{"error":"unknown command"}'
  exit 1
fi

# Export the caller's fingerprint for the verb and hand off. exec replaces
# this process, so no further state is needed here.
export DISPATCH_FP="$fp"
if [[ -n "$rest" ]]; then
  read -ra rest_args <<< "$rest"
  exec "$verb_path" "${rest_args[@]}"
else
  exec "$verb_path"
fi
