#!/usr/bin/env bash
# =============================================================================
# lib/name-verbs.sh — shared preamble + helpers for the admin name verbs
#
# Sourced (never executed) by verbs/approve.sh and verbs/revoke.sh so that the
# two verbs share NO duplicated lines. It provides:
#   - strict mode (set -euo pipefail) and the libs' SCRIPT_DIR
#   - the ledger (lib/accounts.sh) + the side-effect lib (lib/apply-name.sh)
#   - fail_error()          JSON error on stdout, exit 1 (shared contract)
#   - name_verb_preamble()  exactly-one-name arg check, dispatcher-fingerprint
#                           gate, admin gate, and name -> holder lookup. On
#                           success it sets the globals NAME, HOLDER, ADMIN_FP.
#
# register-request.sh keeps its own preamble; this lib only serves the two
# admin name verbs.
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Ledger lookup + mutation helpers (row_fp_by_name, account_set_status) and the
# dispatch-fingerprint / admin gates (require_dispatch_fp, require_admin).
source "${SCRIPT_DIR}/accounts.sh"

# apply_approve / apply_revoke (the sole owner of the port/caddy/authorized_keys
# side effects; sources those libs only when EDGE_APPLY=1).
source "${SCRIPT_DIR}/apply-name.sh"

# Shared JSON-error helper: one-line JSON on stdout, non-zero exit.
fail_error() {
  printf '{"error":"%s"}\n' "$1"
  exit 1
}
# name_verb_preamble <name> — the common gate shared by approve.sh and
# revoke.sh. Fails (fail_error + exit 1) on: not exactly one argument, no
# DISPATCH_FP, non-admin caller, or a name no row holds. On success it sets the
# globals NAME (the claimed name), HOLDER (that row's fingerprint), and
# ADMIN_FP (the admin caller's fingerprint) for the verb body to consume.
name_verb_preamble() {
  if [[ $# -ne 1 ]]; then
    fail_error "bad arguments"
  fi
  local name="$1" fp holder
  fp="$(require_dispatch_fp)" || exit 1
  require_admin "$fp"
  holder="$(row_fp_by_name "$name")"
  if [[ -z "$holder" ]]; then
    fail_error "unknown name"
  fi
  # Consume these globals in the verb that sourced this lib (set -u is on).
  # shellcheck disable=SC2034  # NAME consumed by the calling verb
  NAME="$name"
  # shellcheck disable=SC2034  # HOLDER consumed by the calling verb
  HOLDER="$holder"
  # shellcheck disable=SC2034  # ADMIN_FP consumed by the calling verb
  ADMIN_FP="$fp"
}
