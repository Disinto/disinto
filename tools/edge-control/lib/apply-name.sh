#!/usr/bin/env bash
# =============================================================================
# lib/apply-name.sh — network side effects for name approve/revoke
#
# The single place that talks to the port registry (lib/ports.sh), Caddy
# (lib/caddy.sh), and the tunnel authorized_keys (lib/authorized_keys.sh).
# The name verbs (verbs/approve.sh, verbs/revoke.sh) call into this lib AFTER
# their ledger checks and BEFORE their status mutation, so a failed apply never
# leaves a half-changed row: the ledger status is only set once the apply
# returns 0 ("set status only after apply returns 0").
#
# Modes (env var EDGE_APPLY, default 0):
#   1     — real side effects. Source lib/ports.sh, lib/caddy.sh, and
#           lib/authorized_keys.sh, and invoke the appropriate functions:
#             approve: allocate_port, add_route, rebuild_authorized_keys.
#             revoke:  remove_route, free_port, rebuild_authorized_keys.
#           A non-zero from any one of them fails the apply (rc 1), so the
#           calling verb leaves the status untouched.
#   stub  — no network libs are sourced. Append `approve NAME` or `revoke
#           NAME` to $EDGE_APPLY_LOG. Stub counts as success: the apply is a
#           no-op on the ledger and on the network, so a failed (best-effort)
#           log write must not turn a successful apply into a failure.
#   0     — no side effects at all. This is the default, so a factory box's
#           test box can never touch a real Caddy / registry / authorized_keys.
#
# Sourcing contract: sourcing this lib makes apply_approve() / apply_revoke()
# available. accounts.sh is always sourced (it provides row_fp_by_name() and
# ACCOUNTS_FILE); the port/caddy/authorized_keys libs are sourced only when
# EDGE_APPLY=1.
#
# NOTE: this lib is never run as a standalone entry point — it is sourced by
# the name verbs. It is executable for convenience and carries no main().
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Always needed: the row lookup (name -> holder fingerprint, holder pubkey).
# shellcheck source=accounts.sh
source "${SCRIPT_DIR}/accounts.sh"

# Real side effects only when the operator (or a test) opted in.
if [[ "${EDGE_APPLY:-0}" == "1" ]]; then
  # shellcheck disable=SC1090,SC1091
  source "${SCRIPT_DIR}/ports.sh"
  source "${SCRIPT_DIR}/caddy.sh"
  source "${SCRIPT_DIR}/authorized_keys.sh"
fi

# Best-effort audit line for stub mode. The stub apply is a no-op on the
# ledger and on the network, so a failed log write must not turn a successful
# apply into a failure ("stub ... counts as success").
_apply_log() {
  printf '%s %s\n' "$1" "$2" >> "${EDGE_APPLY_LOG:-/dev/null}" 2>/dev/null \
    || true
}

# approve <name> <admin_fp>
#   EDGE_APPLY=1    : allocate the name's port, add its Caddy route, rebuild
#                     the tunnel authorized_keys (the admin's fp is recorded
#                     as registered_by).
#   EDGE_APPLY=stub : log "approve <name>" to $EDGE_APPLY_LOG.
#   EDGE_APPLY=0    : no-op.
#   Returns 0 on success, 1 if any side effect fails (mode 1 only).
apply_approve() {
  local name="$1" admin_fp="$2"
  case "${EDGE_APPLY:-0}" in
    1)
      local holder pubkey fqdn port
      holder="$(row_fp_by_name "$name")"
      if [[ -z "$holder" ]]; then
        return 1
      fi
      # The registry entry needs the tunnel's pubkey. The row may carry it
      # (captured at key registration); the fallback to the fingerprint keeps
      # the entry well-formed when it is absent.
      pubkey="$(jq -r --arg fp "$holder" \
        '(.accounts // {})[$fp].pubkey // empty' "$ACCOUNTS_FILE")"
      [[ -n "$pubkey" ]] || pubkey="$holder"
      fqdn="${name}.${DOMAIN_SUFFIX}"
      if ! port="$(allocate_port "$name" "$pubkey" "$fqdn" "$admin_fp")"; then
        return 1
      fi
      if ! add_route "$name" "$port"; then
        return 1
      fi
      if ! rebuild_authorized_keys; then
        return 1
      fi
      ;;
    stub)
      _apply_log "approve" "$name"
      ;;
    *)
      :
      ;;
  esac
  return 0
}

# revoke <name> <admin_fp>
#   EDGE_APPLY=1    : drop the name's Caddy route, free its port, rebuild the
#                     tunnel authorized_keys.
#   EDGE_APPLY=stub : log "revoke <name>" to $EDGE_APPLY_LOG.
#   EDGE_APPLY=0    : no-op.
#   Returns 0 on success, 1 if any side effect fails (mode 1 only).
#
#   Idempotent in mode 1: remove_route() already returns 0 when the route is
#   absent, and free_port() returns 1 on a missing registry project, so we
#   gate free_port() on get_port(). A name that was never applied (or already
#   revoked) is therefore revoked without failing.
apply_revoke() {
  local name="$1"
  case "${EDGE_APPLY:-0}" in
    1)
      if ! remove_route "$name"; then
        return 1
      fi
      if [[ "$(get_port "$name")" != "" ]]; then
        if ! free_port "$name" >/dev/null; then
          return 1
        fi
      fi
      if ! rebuild_authorized_keys; then
        return 1
      fi
      ;;
    stub)
      _apply_log "revoke" "$name"
      ;;
    *)
      :
      ;;
  esac
  return 0
}
