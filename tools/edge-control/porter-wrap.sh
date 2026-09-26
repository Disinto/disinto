#!/usr/bin/env bash
# =============================================================================
# porter-wrap.sh — the forced command (sshd AuthorizedKeysCommand -> this file)
#
# key-command.sh emits a single restricted authorized_keys line whose command
# forces THIS file (not dispatch.sh directly). When sshd runs us:
#
#   1. We load the edge env from $PORTER_ENV (default /etc/porter/porter.env).
#      We read the file LITERALLY — never `source`, never `eval`. A line is
#      KEY=value. Only the allowlisted keys are exported; every other key
#      (PATH, LD_PRELOAD, BASH_ENV, ACCOUNTS_FILE, EVIL, …) is ignored. The
#      value is always literal — a line like KEY=$(cmd) assigns the string
#      "$(cmd)" to the variable, it does not run cmd.
#   2. We exec the sibling dispatch.sh with the same arguments, so the caller
#      still reaches the dispatcher — but through this wrapper that has loaded
#      the env the dispatcher needs (sshd strips the caller's environment).
#
# Contract:
#   • Prints nothing. Never logs or echoes a value.
#   • A missing env file is not an error — a no-op.
#   • Exit status is dispatch.sh's.
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Read $PORTER_ENV (default /etc/porter/porter.env) and export the allowlisted
# keys, literally. No source, no eval. Blank lines and `#` comments are skipped;
# any line that is not KEY=value is ignored; keys outside the allowlist
# (PATH, LD_PRELOAD, BASH_ENV, ACCOUNTS_FILE, EVIL, …) are ignored; the value
# is always literal (no command substitution, no eval). A missing file returns
# early and prints nothing.
load_porter_env() {
  local env_file="${PORTER_ENV:-/etc/porter/porter.env}"
  [[ -f "$env_file" ]] || return 0
  local line key value
  while IFS= read -r line || [[ -n "$line" ]]; do
    # Tolerate CRLF without ever altering a value.
    line="${line%$'\r'}"
    [[ -z "$line" ]] && continue
    [[ "$line" == \#* ]] && continue
    [[ "$line" == *=* ]] || continue
    key="${line%%=*}"   # name: everything before the first '='
    value="${line#*=}"  # value: everything after the first '=', literal
    # GANDI_API_KEY is deliberately NOT in the allowlist: the door must
    # never see a registrar token. DNS work happens in the root script
    # porter-dns.sh, which reads the token file directly (mode 600) and
    # never exports the key.
    case "$key" in
      TYPESAFE_API_KEY|TYPESAFE_API_URL|JEV_MODEL|STRIPE_SECRET_KEY|\
        STRIPE_WEBHOOK_SECRET|STRIPE_PRICE_ID|STRIPE_API_BASE|\
        STRIPE_SUCCESS_URL|STRIPE_CANCEL_URL|STRIPE_CREDITS_PER_PURCHASE|\
        DOMAIN_SUFFIX|EDGE_APPLY)
        # One quoted argument: bash splits it on the first '=' into name=value
        # and assigns the literal value — no re-expansion, no command run.
        export "$key=$value"
        ;;
    esac
  done < "$env_file"
}
load_porter_env

# Hand off to the dispatcher, verbatim, with the same arguments.
exec "${SCRIPT_DIR}/dispatch.sh" "$@"
