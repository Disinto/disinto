#!/usr/bin/env bash
# =============================================================================
# stripe-webhook.sh — Stripe webhook receiver: credit the SSH fingerprint
#
# Single-shot receiver, NOT a daemon, binds no port. The operator invokes it
# once per Stripe webhook POST (Caddy route, see examples/stripe-webhook.caddy);
# it reads the raw event body from stdin, verifies the `Stripe-Signature`
# header, and writes the ledger.
#
# Contract
#   stdin                — raw event JSON body, verbatim (trailing newlines
#                          preserved; the HMAC is computed over exactly these
#                          bytes).
#   STRIPE_SIGNATURE     — the `Stripe-Signature` header: t=<ts>,v1=<hex>.
#   STRIPE_WEBHOOK_SECRET — the Stripe webhook signing secret (env only,
#                          AD-005). Unset → exit 1, write nothing.
#   STRIPE_CREDITS_PER_PURCHASE — credits per paid checkout (default 100).
#   STRIPE_EVENTS_FILE — replay ledger, one event id per line
#                         (default /var/lib/disinto/stripe-events).
#
# Flow
#   1. Read the raw body from stdin.
#   2. STRIPE_WEBHOOK_SECRET unset → exit 1, write nothing.
#   3. Parse t= / v1=; compute HMAC-SHA256 of `t + "." + body` with the secret
#      and compare in constant time; reject timestamps older than 300 s (and
#      any future timestamp). Any failure → exit 1, write nothing.
#   4. Parse the event with jq; require an `id` and a `type`.
#   5. `checkout.session.completed` with `payment_status == "paid"`:
#        a. Dedup: event id already in $STRIPE_EVENTS_FILE → exit 0, no credit.
#        b. account_ensure(client_reference_id).
#        c. account_add_credits(client_reference_id, credits).
#        d. Record the event id in $STRIPE_EVENTS_FILE.
#        e. exit 0.
#      Other event types (and completed sessions with non-paid status): exit 0,
#      no credits, no ledger entry.
#   All failures fail closed: exit 1, no ledger write, no output. The full
#   Stripe body is never written to a log, stdout, or stderr.
# =============================================================================
set -euo pipefail

# shellcheck disable=SC1090
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1090
source "${SCRIPT_DIR}/lib/accounts.sh"

# ── Configuration (env override; defaults per the issue) ─────────────────────
STRIPE_WEBHOOK_SECRET="${STRIPE_WEBHOOK_SECRET:-}"
CREDITS_PER_PURCHASE="${STRIPE_CREDITS_PER_PURCHASE:-100}"
STRIPE_EVENTS_FILE="${STRIPE_EVENTS_FILE:-/var/lib/disinto/stripe-events}"
SIG_MAX_AGE_S=300

# Positive integer credit amount (max 7 digits, per credits-grant.sh) — fail
# closed otherwise.
if [[ ! "$CREDITS_PER_PURCHASE" =~ ^[1-9][0-9]{0,5}$ ]]; then
  exit 1
fi

# ── Read the raw body verbatim (preserves trailing newlines) ───────────────
body=""
IFS= read -r -d '' body || true

# Unset secret: cannot verify, fail closed with zero output.
[[ -n "$STRIPE_WEBHOOK_SECRET" ]] || exit 1

# ── Parse the signature header: t=<unix-ts>,v1=<hex-hmac> ───────────────────
sig="${STRIPE_SIGNATURE:-}"
[[ -n "$sig" ]] || exit 1

ts=""
v1=""
IFS=',' read -r -a sig_parts <<< "$sig"
for part in "${sig_parts[@]}"; do
  key="${part%%=*}"
  val="${part#*=}"
  case "$key" in
    t)  ts="$val" ;;
    v1) v1="$val" ;;
  esac
done
[[ -n "$ts" && -n "$v1" ]] || exit 1
[[ "$ts" =~ ^[0-9]+$ ]] || exit 1
[[ "$v1" =~ ^[0-9a-f]{64}$ ]] || exit 1

# ── HMAC-SHA256 verification, constant-time compare ──────────────────────────
hmac_raw="$(printf '%s' "${ts}.${body}" | openssl dgst -sha256 -hmac "$STRIPE_WEBHOOK_SECRET" -r 2>/dev/null)" || exit 1
expected="${hmac_raw%% *}"
[[ "$expected" =~ ^[0-9a-f]{64}$ ]] || exit 1

# Walk every byte; never short-circuit (no timing channel).
cmp_hmac() {
  local a="$1" b="$2"
  if [[ "${#a}" -ne "${#b}" ]]; then
    return 1
  fi
  local i=0 diff=0 c
  for (( i = 0; i < ${#a}; i++ )); do
    c="${a:i:1}"
    if [[ "$c" != "${b:i:1}" ]]; then
      diff=1
    fi
  done
  return "$diff"
}
cmp_hmac "$expected" "$v1" || exit 1

# ── Timestamp window: reject stale or future timestamps ──────────────────────
now="$(date -u +%s)"
age=$(( now - ts ))
if (( age > SIG_MAX_AGE_S )) || (( age < 0 )); then
  exit 1
fi

# ── Event parsing (jq) ───────────────────────────────────────────────────────
event_id="$(jq -r '.id // empty' <<<"$body" 2>/dev/null)" || exit 1
event_type="$(jq -r '.type // empty' <<<"$body" 2>/dev/null)" || exit 1
[[ -n "$event_id" && -n "$event_type" ]] || exit 1

# Only `checkout.session.completed` with `payment_status == "paid"` ever
# changes the ledger; every other event type is a plain success (exit 0,
# no credits).
if [[ "$event_type" != "checkout.session.completed" ]]; then
  exit 0
fi
payment_status="$(jq -r '.data.object.payment_status // empty' <<<"$body" 2>/dev/null)" || exit 1
[[ "$payment_status" == "paid" ]] || exit 0

target="$(jq -r '.data.object.client_reference_id // empty' <<<"$body" 2>/dev/null)" || exit 1
[[ "$target" =~ $FINGERPRINT_RE ]] || exit 1

# ── Replay guard + credit, atomic under flock ────────────────────────────────
# The check/credit/record triple is serialized on a lock so two concurrent
# identical POSTs (Stripe retries) can never double-credit.
events_dir="$(dirname "$STRIPE_EVENTS_FILE")"
if ! mkdir -p -- "$events_dir"; then
  exit 1
fi
lock_file="${STRIPE_EVENTS_FILE}.lock"

rc=0
(
  # fd 20 = lock file; lock is released automatically on subshell exit.
  if ! exec 20>>"$lock_file"; then
    exit 1
  fi
  flock -x 20 || exit 1

  # Already processed this event id → success, no second credit.
  if [[ -f "$STRIPE_EVENTS_FILE" ]] && grep -Fxq -- "$event_id" "$STRIPE_EVENTS_FILE"; then
    exit 0
  fi

  # Ensure the row (atomic read-modify-write), then credit it.
  if ! account_ensure "$target"; then
    exit 1
  fi
  if ! account_add_credits "$target" "$CREDITS_PER_PURCHASE"; then
    exit 1
  fi

  # Record the event id (one per line), only after the credits landed.
  if ! printf '%s\n' "$event_id" >> "$STRIPE_EVENTS_FILE"; then
    exit 1
  fi
)
rc=$?
exit "$rc"
