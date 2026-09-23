#!/usr/bin/env bash
# =============================================================================
# ticket.sh — append a support ticket from this caller
#
#     ticket <subject>
#
# The body is read from stdin, at most 8192 bytes. A ticket is a *record*, not
# a privilege: it appends one JSONL line to $TICKETS_FILE and never touches the
# account row — status, credits, name and admin stay exactly as they were.
# Pending keys may file tickets; only the admin-gated `tickets` verb reads
# them back.
#
# Output contract (stdout unless noted):
#   rc 0  -> the appended record, compact JSON on one line
#   rc 1  -> {"error":"..."} on validation failure:
#              "bad arguments"  | "empty subject" | "body exceeds 8192 bytes"
#              | "body contains NUL"
#           {"error":"missing fingerprint"} to stderr and rc 1 when the
#           dispatcher miswired (DISPATCH_FP unset — internal, not a caller
#           mistake).
#
# Fields of the appended record:
#   ts      — UTC RFC3339, at append time (same format as the ledger)
#   fp      — the caller's SSH-key fingerprint (DISPATCH_FP)
#   name    — the caller's bound name, or null if unset
#   subject — the <subject> argument
#   body    — the bytes read from stdin
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1090,SC1091
source "${SCRIPT_DIR}/../lib/accounts.sh"

TICKETS_FILE="${TICKETS_FILE:-/var/lib/disinto/tickets.jsonl}"
MAX_BODY_BYTES=8192

fail_error() {
  printf '{"error":"%s"}\n' "$1"
  exit 1
}

# ── arguments ────────────────────────────────────────────────────────────────
if [[ $# -ne 1 ]]; then
  fail_error "bad arguments"
fi
subject="$1"
if [[ -z "$subject" ]]; then
  fail_error "empty subject"
fi

# ── fingerprint (set by dispatch.sh; validated via require_dispatch_fp) ──────
fp="$(require_dispatch_fp)" || exit 1

# ── body: read stdin, enforce <=8192 bytes and no NUL, into a scratch file ──
body_file="$(mktemp)" || { printf '{"error":"mktemp failed"}\n' >&2; exit 1; }
trap 'rm -f "$body_file"' EXIT
cat > "$body_file"
body_bytes="$(wc -c < "$body_file" | tr -d ' ')"

if (( body_bytes > MAX_BODY_BYTES )); then
  fail_error "body exceeds 8192 bytes"
fi

# A NUL byte is present iff stripping every NUL changes the byte count.
no_nul_bytes="$(tr -d '\0' < "$body_file" | wc -c | tr -d ' ')"
if (( body_bytes != no_nul_bytes )); then
  fail_error "body contains NUL"
fi

# ── caller metadata: name (null if unset) straight from the ledger row ──────
name="$(jq -r --arg fp "$fp" '(.accounts // {})[($fp)].name // empty' \
    "$ACCOUNTS_FILE" 2>/dev/null)" || name=""

# ── append the record under a single exclusive flock (lib/tape.sh pattern) ───
ts="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
lock_file="$(dirname "$TICKETS_FILE")/.tickets.lock"
mkdir -p "$(dirname "$TICKETS_FILE")"
record=$(jq -cn --arg ts "$ts" --arg fp "$fp" --arg subject "$subject" \
             --arg name "$name" --rawfile body "$body_file" '{ ts: $ts, fp: $fp, name: (if $name == "" then null else $name end), subject: $subject, body: $body }') \
  || { printf '{"error":"failed to build ticket record"}\n' >&2; exit 1; }

(
  flock -x 9
  printf '%s\n' "$record" >> "$TICKETS_FILE"
) 9>"$lock_file"

printf '%s\n' "$record"
exit 0
