#!/usr/bin/env bash
# =============================================================================
# verbs/jev.sh — run a named Jev pack and debit one credit
#
#     jev <pack-id>
#
# The shared-key Jev call (Jev is a rented reader). An *approved* account may
# run a *named* pack (a noul — a small instruction document stored under
# packs/) against the TypeSafe systemone endpoint. The caller's stdin is the
# *state* (max 32768 bytes); the *questions* come only from the pack file —
# never from stdin, never hardcoded (the shared TypeSafe key is env-only,
# AD-005, and the pack is the sole question source). Exactly one credit is
# debited — and only when the final HTTP status is 200 and the response body
# is JSON with an `answers` object — and only then is the body echoed
# verbatim; on every other outcome nothing is debited. A 429/529 is retried
# twice (three attempts total) with 1s then 2s backoff; no other status is
# retried, and each call is bounded by `curl --max-time 20` so a hung request
# cannot hold the SSH session.
#
# Config (environment; secrets are never written to disk or to a log):
#   TYPESAFE_API_KEY   required  — the shared TypeSafe key (never logged)
#   TYPESAFE_API_URL   optional  — default https://api.typesafe.ai
#   JEV_MODEL          optional  — default jev-1.13.0
#
# Pack path contract: packs/ sits beside verbs/ (the edge-control root, the
#   parent of this file's dir). <pack-id> must match ^[a-z][a-z0-9-]*$ so the
#   only resolvable path is packs/<id>.json — no "..", no "/", no absolute
#   path, no escape. Any other id, or a file that is missing / not a valid
#   questions noul, is "unknown pack".
#
# Output contract (stdout unless noted):
#   rc 0  -> the response body. On stderr exactly one line:
#             "jev fp=<fp> pack=<pack-id> model=<model> status=<http-code>"
#             — only fp/pack/model/status, never the state or the key. The
#             model is the body's `.model` when that is a non-empty string,
#             else the request model.
#   rc 1  -> one-line JSON {"error":"..."} with one of:
#             "bad arguments"         — not exactly one argument
#             "unknown pack"          — id fails the regex, or the pack file
#                                       is missing / not a questions noul
#             "state exceeds 32768 bytes"  — stdin is larger than 32768 bytes
#             "state contains NUL"      — stdin carries a NUL byte
#             "jev not configured"      — TYPESAFE_API_KEY is unset
#             "not approved"            — the account status is not "approved"
#             "no credits"              — the account has fewer than 1 credit
#             "jev failed"              — the final outcome was not a 200 with
#                                        a JSON body carrying an `answers`
#                                        object
#           {"error":"missing fingerprint"} to stderr + rc 1 (miswire)
#   Every failure path returns before the debit.
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT_DIR="${SCRIPT_DIR%/}"

# Ledger + fingerprint contract (shared with dispatch.sh and the sibling verbs).
# shellcheck disable=SC1090,SC1091
source "${SCRIPT_DIR}/../lib/accounts.sh"

# packs/ is beside verbs/ (the edge-control root = the parent of this dir).
PACKS_DIR="$(cd "${SCRIPT_DIR}/../packs" && pwd)"
MAX_STATE_BYTES=32768

# ── argument: exactly one pack id ─────────────────────────────────────────────
if [[ $# -ne 1 ]]; then
  fail_error "bad arguments"
fi
pack_id="$1"

# The pack id is the only filesystem component here. The regex admits a single
# lowercase/digit/hyphen token — no ".", no "/", no leading digit — so "..",
# "foo/..", absolute paths and symlink escapes are all rejected before any
# file is opened.
if [[ ! "$pack_id" =~ ^[a-z][a-z0-9-]*$ ]]; then
  fail_error "unknown pack"
fi

# ── config gate: no socket, no ledger write before this (box-level gate) ─────
if [[ -z "${TYPESAFE_API_KEY:-}" ]]; then
  fail_error "jev not configured"
fi

# ── caller (exported by dispatch.sh before exec) ─────────────────────────────
fp="$(require_dispatch_fp)" || exit 1

# ── account gate: approved AND >= 1 credit (fail closed, no debit) ───────────
status="$(jq -r --arg fp "$fp" '(.accounts // {})[($fp)].status // empty' \
      "$ACCOUNTS_FILE" 2>/dev/null)" || status=""
if [[ "$status" != "approved" ]]; then
  fail_error "not approved"
fi
credits="$(jq -r --arg fp "$fp" '(.accounts // {})[($fp)].credits // 0' \
        "$ACCOUNTS_FILE" 2>/dev/null)" || credits=0
if [[ ! "$credits" =~ ^[0-9]+$ ]] || (( credits < 1 )); then
  fail_error "no credits"
fi

# ── pack: a noul; questions is a *map* of typed questions (the ONLY source
#     of questions) ─────────────────────────────────────────────────────────────
pack_file="${PACKS_DIR}/${pack_id}.json"
if [[ ! -f "$pack_file" ]]; then
  fail_error "unknown pack"
fi
# (The expression's stdout — just a boolean — is discarded; only its exit code
#  matters, and the key/state must never leak to a log or the response.)
# A pack is valid only when `questions` is a non-empty object and every value
# is a typed question: `type` is `noul`/`choice`/`score` and `instructions`
# is a non-empty string (a TypeSafe "Noul" is one yes/no — not a string list).
# A string array, an empty object, or any other shape is "unknown pack"
# (rejected pre-socket, no debit).
if ! jq -e '.questions
            | (type == "object")
              and (length > 0)
              and (to_entries
                   | all(
                       (   (.value.type == "noul"
                            or .value.type == "choice"
                            or .value.type == "score")
                            and ((.value.instructions | type) == "string")
                            and ((.value.instructions | length) > 0)
                       )
                   )
                 )' "$pack_file" >/dev/null 2>&1; then
  fail_error "unknown pack"
fi

# ── state: stdin, capped at 32768 bytes, no NUL ──────────────────────────────
state_file="$(mktemp)" || { printf '{"error":"mktemp failed"}\n' >&2; exit 1; }
trap 'rm -f "$state_file"' EXIT
cat > "$state_file"
state_bytes="$(wc -c < "$state_file" | tr -d ' ')"
if (( state_bytes > MAX_STATE_BYTES )); then
  fail_error "state exceeds 32768 bytes"
fi
# A NUL byte is present iff stripping every NUL changes the byte count.
no_nul_bytes="$(tr -d '\0' < "$state_file" | wc -c | tr -d ' ')"
if (( state_bytes != no_nul_bytes )); then
  fail_error "state contains NUL"
fi

# ── request payload: model + state + the pack's questions. The state is sent
#     as-is (never re-parsed into questions); the pack file is the sole source
#     of the questions. ───────────────────────────────────────────────────────
request_model="${JEV_MODEL:-jev-1.13.0}"
questions="$(jq -c '.questions' "$pack_file" 2>/dev/null)" || { fail_error "unknown pack"; }
payload="$(jq -cn \
   --arg model "$request_model" \
   --rawfile state "$state_file" \
   --argjson questions "$questions" \
   '{ model: $model, state: $state, questions: $questions }')" \
  || { printf '{"error":"failed to build request"}\n' >&2; exit 1; }

# ── POST to the TypeSafe systemone endpoint ───────────────────────────────────
# TYPESAFE_API_URL defaults to the live host; tests point it at a local stub
# so no request reaches api.typesafe.ai. The key rides along as a header and
# is never echoed. `curl --max-time 20` bounds a hung call (so the SSH session
# is not held) and its own stderr is discarded. -w $'\n%{http_code}' appends
# the code as a trailing line (command substitution strips the trailing \n).
# A 429/529 is retried twice (three attempts total) with 1s then 2s backoff;
# no other status is retried.
url="${TYPESAFE_API_URL:-https://api.typesafe.ai}/v1/systemone"
response=""
http_code=""
body=""
attempt=1
while :; do
  if ! response="$(curl -s --max-time 20 -w $'\n%{http_code}' \
      --request POST \
      --header "Content-Type: application/json" \
      --header "Authorization: Bearer ${TYPESAFE_API_KEY}" \
      --data "$payload" \
      "$url" \
      2>/dev/null)"; then
    # Transfer failure (refused/timeout): no HTTP code, no body.
    http_code="0"
    body=""
  else
    # With the trailing \n stripped, the code follows the last \n and the body
    # precedes the first.
    http_code="${response##*$'\n'}"
    body="${response%$'\n'*}"
  fi
  case "$http_code" in
    429|529)
      # Retry with backoff while a retry remains (1s after the 1st, 2s after
      # the 2nd); the 3rd attempt is always final.
      if (( attempt == 1 )); then
        sleep 1
        attempt=2
        continue
      elif (( attempt == 2 )); then
        sleep 2
        attempt=3
        continue
      fi
      ;;
  esac
  break
done

# model for the log: the body's .model when that is a non-empty string, else the
# request model. Never the body itself, the state, or the key.
model_log="$request_model"
body_model="$(jq -r 'if (.model | type) == "string" and ((.model | length) > 0) then .model else empty end' <<<"$body" 2>/dev/null)" || body_model=""
if [[ -n "$body_model" ]]; then
  model_log="$body_model"
fi

# One-line stderr log: only fp / pack / model / status. Never the state,
# never the key.
printf 'jev fp=%s pack=%s model=%s status=%s\n' \
     "$fp" "$pack_id" "$model_log" "$http_code" >&2

# Debit only when the final outcome is a 200 whose body is JSON with an
# `answers` object; any other outcome (including 200 without `answers`) is a
# "jev failed" — no debit, no body echo.
if [[ "$http_code" == "200" ]]; then
  body_ok="$(jq -r 'if (type == "object") and ((.answers | type) == "object") then "ok" else "no" end' <<<"$body" 2>/dev/null)" || body_ok="no"
  if [[ "$body_ok" == "ok" ]]; then
    if ! account_add_credits "$fp" -1; then
      printf '{"error":"failed to debit credit"}\n' >&2
      exit 1
    fi
    printf '%s\n' "$body"
    exit 0
  fi
fi
fail_error "jev failed"
