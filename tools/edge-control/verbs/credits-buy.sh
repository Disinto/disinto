#!/usr/bin/env bash
# =============================================================================
# credits-buy.sh — open a Stripe Checkout session for this caller.
#
#     credits-buy
#
#     No arguments. stdin is ignored. This verb only *opens* a Stripe Checkout
#     session and returns its URL — it never touches the account ledger, never
#     debits or credits, and accepts no card, PAN, or CVC (neither on argv nor
#     on stdin). Crediting the account is a separate concern (Stripe webhook,
#     a later issue); the URL alone must not change the balance.
#
#   Config (environment, no secrets ever written to disk by this verb):
#     STRIPE_SECRET_KEY   required  — Stripe secret key (basic-auth user)
#     STRIPE_PRICE_ID     required  — the Price ID to sell
#     STRIPE_API_BASE     optional  — API base, default https://api.stripe.com
#     STRIPE_SUCCESS_URL  optional  — sent as success_url when set
#     STRIPE_CANCEL_URL   optional  — sent as cancel_url when set
#
#   Flow:
#     1. Require STRIPE_SECRET_KEY + STRIPE_PRICE_ID. If either is unset:
#            {"error":"payments not configured"} and exit 1 — *before* any
#            socket is opened, so no request is sent when payments are not
#            configured.
#     2. Require DISPATCH_FP (the caller's fingerprint, exported by
#            dispatch.sh before exec'ing the verb).
#     3. POST ${STRIPE_API_BASE}/v1/checkout/sessions with basic auth (secret
#            key), mode=payment, line_items [{price: STRIPE_PRICE_ID}],
#            client_reference_id = DISPATCH_FP, plus success_url/cancel_url
#            when set.
#     4. On a 2xx response that carries a `url` field: print {"url":"<...>"}.
#     5. On anything else (non-2xx, missing url, or a transport failure):
#            print {"error":"checkout failed"} and exit 1. Never echo the
#            Stripe body.
#
#   Output contract (one-line JSON on stdout unless noted):
#     rc 0  -> {"url":"<session url>"}
#     rc 1  -> {"error":"payments not configured"}
#             {"error":"checkout failed"}
#             {"error":"missing fingerprint"} to stderr (miswire; rc 1)
# =============================================================================
set -euo pipefail

# Ignore stdin: this verb reads no payment data from it (no card/PAN/CVC is
# ever accepted, whether piped in or not). Redirecting fd 0 to /dev/null
# makes that guarantee explicit — anything on stdin is discarded.
exec 0</dev/null

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1090,SC1091
source "${SCRIPT_DIR}/../lib/accounts.sh"

fail_checkout() {
  jq -cn '{error:"checkout failed"}'
  exit 1
}

# ── config gate (no socket may be opened before this check) ──────────────────
if [[ -z "${STRIPE_SECRET_KEY:-}" || -z "${STRIPE_PRICE_ID:-}" ]]; then
  jq -cn '{error:"payments not configured"}'
  exit 1
fi

# ── caller fingerprint (exported by dispatch.sh before exec) ─────────────────
fp="$(require_dispatch_fp)" || exit 1

# ── build the checkout payload (jq -n: never reads stdin) ─────────────────────
payload="$(jq -cn \
  --arg fp "$fp" \
  --arg price "$STRIPE_PRICE_ID" \
  --arg success "${STRIPE_SUCCESS_URL:-}" \
  --arg cancel "${STRIPE_CANCEL_URL:-}" \
  '{mode:"payment",
    client_reference_id: $fp,
    line_items: [{ price: $price }]
  }
  | (if $success != "" then . + {success_url: $success} else . end)
  | (if $cancel  != "" then . + {cancel_url:  $cancel}  else . end)')"

# ── POST to the Stripe Checkout API ───────────────────────────────────────────
# STRIPE_API_BASE defaults to the live api.stripe.com; tests point it at a
# local stub (or drop a fake `curl` on PATH) so the request never reaches a
# live host. -w $'\n%{http_code}' appends the HTTP status to the body so the
# verb can classify non-2xx responses.
response="$(curl -s -w $'\n%{http_code}' \
  --request POST \
  --header "Content-Type: application/json" \
  --user "${STRIPE_SECRET_KEY}:" \
  --data "$payload" \
  "${STRIPE_API_BASE:-https://api.stripe.com}/v1/checkout/sessions" \
  2>/dev/null)" || fail_checkout

# Strip the trailing newline+code that -w appended to isolate the code.
http_code="${response##*$'\n'}"
body="${response%$'\n'*}"

# 2xx *and* a `url` field in the body => success; anything else fails closed.
if [[ "$http_code" =~ ^2[0-9]{2}$ ]]; then
  session_url="$(jq -r '.url // empty' <<<"$body")" || session_url=""
  if [[ -n "$session_url" ]]; then
    jq -cn --arg u "$session_url" '{url:$u}'
    exit 0
  fi
fi
fail_checkout
