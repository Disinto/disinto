#!/usr/bin/env bash
# =============================================================================
# tests/acceptance/issue-1467.sh
#
# Issue #1467: feat(edge): ticket verb appends a support ticket
#
# Exercises verbs/ticket.sh and verbs/tickets.sh against a throwaway
# TICKETS_FILE and ACCOUNTS_FILE in a mktemp dir — no live services, no sshd,
# and never /var/lib/disinto or /etc/ssh. The verbs are run directly with
# DISPATCH_FP exported, per the dispatcher contract (see issue-1465.sh for the
# pattern).
#
#   AC1  ticket SUBJ (body from stdin) appends exactly one JSONL line to
#        $TICKETS_FILE carrying ts (UTC RFC3339), the caller fp, the row's
#        name (null when unset, else the bound name), the subject, and the
#        body — and a *pending* key is accepted.
#   AC2  the ledger is read-only: the accounts file is byte-identical before
#        and after a ticket (status/credits/name/admin untouched).
#   AC3  an empty subject writes nothing and exits non-zero.
#   AC4  a body over 8192 bytes is rejected (non-zero, nothing appended).
#   AC5  a body containing a NUL byte is rejected (non-zero, nothing appended).
#   AC6  tickets with a non-admin caller -> {"error":"not admin"} and rc!=0.
#   AC7  tickets with an admin caller -> the JSONL parsed as a JSON array
#        (rc 0) containing every line appended in AC1.
#
# Run via: tools/run-acceptance.sh 1467
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../lib/acceptance-helpers.sh
source "$REPO_ROOT/tests/lib/acceptance-helpers.sh"

ac_require_cmd bash jq mktemp grep cat head tr date

TICKET_SCRIPT="$REPO_ROOT/tools/edge-control/verbs/ticket.sh"
TICKETS_SCRIPT="$REPO_ROOT/tools/edge-control/verbs/tickets.sh"
ACCOUNTS_LIB="$REPO_ROOT/tools/edge-control/lib/accounts.sh"

ac_assert_file "$TICKET_SCRIPT"  "verbs/ticket.sh is missing"
ac_assert_file "$TICKETS_SCRIPT"  "verbs/tickets.sh is missing"
ac_assert_file "$ACCOUNTS_LIB"    "lib/accounts.sh is missing"

# ── Fixtures: throwaway ledger + ticket file, fingerprints ───────────────────
TMP_DIR="$(mktemp -d)"
ACCOUNTS_FILE="$TMP_DIR/accounts.json"
TICKETS_FILE="$TMP_DIR/tickets.jsonl"
trap 'rm -rf "$TMP_DIR"' EXIT
printf '{"version":1,"accounts":{}}\n' > "$ACCOUNTS_FILE"
: > "$TICKETS_FILE"

# (seed_row + FP_A/FP_B/FP_ADMIN come from tests/lib/acceptance-helpers.sh)

# Two pending non-admin callers (one with no name, one bound), plus a *pending*
# admin so the admin gate is provably independent of status.
seed_row "$FP_A"      ""       "false"
seed_row "$FP_B"      "supporter" "false"
seed_row "$FP_ADMIN"  "admin"  "true"

# ── Run the verbs exactly as the dispatcher would ─────────────────────────────
# TICKET_BODY is the stdin the ticket verb receives (a bash string: no NULs).
TICKET_BODY=""
run_ticket() {
  local fp="$1" subject="$2"
  RC=0
  OUT="$(printf '%s' "$TICKET_BODY" |
    ACCOUNTS_FILE="$ACCOUNTS_FILE" TICKETS_FILE="$TICKETS_FILE" \
    DISPATCH_FP="$fp" bash "$TICKET_SCRIPT" "$subject")" || RC=$?
}
run_list() {
  local fp="$1"
  RC=0
  OUT="$(ACCOUNTS_FILE="$ACCOUNTS_FILE" TICKETS_FILE="$TICKETS_FILE" \
    DISPATCH_FP="$fp" bash "$TICKETS_SCRIPT")" || RC=$?
}

# JSONL -> JSON array ("" -> []), as the tickets verb does.
tickets_array() {
  if [[ -f "$TICKETS_FILE" ]]; then
    jq -s '.' "$TICKETS_FILE"
  else
    printf '[]\n'
  fi
}
# RFC3339 UTC timestamp regex, e.g. 2026-09-23T00:00:00Z
TS_RE='^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$'

# ── AC1. a pending key appends one line with every field ─────────────────────
TICKET_BODY="hello world"
run_ticket "$FP_A" "first ticket"
if [ "$RC" -ne 0 ]; then
  ac_fail "AC1: pending key ticket should succeed (rc=$RC, out=$OUT)"
fi
last_out="$(printf '%s\n' "$OUT" | tail -n 1)"
jq -e --arg subj "first ticket" \
  --arg tsre "$TS_RE" \
  --arg fp "$FP_A" \
  '.fp == $fp and .subject == $subj and .body == "hello world"
   and .name == null and (.ts | type == "string") and (.ts | test($tsre))' \
  <<<"$last_out" >/dev/null 2>&1 \
  || ac_fail "AC1: appended record is wrong: $last_out"

# Second pending key (with a bound name) appends a second line.
TICKET_BODY="second body"
run_ticket "$FP_B" "second ticket"
if [ "$RC" -ne 0 ]; then
  ac_fail "AC1: second pending key ticket should succeed (rc=$RC, out=$OUT)"
fi
last_out="$(printf '%s\n' "$OUT" | tail -n 1)"
jq -e --arg subj "second ticket" \
  --arg tsre "$TS_RE" --arg fp "$FP_B" \
  '.fp == $fp and .subject == $subj and .body == "second body"
   and .name == "supporter" and (.ts | test($tsre))' \
  <<<"$last_out" >/dev/null 2>&1 \
  || ac_fail "AC1: second record name/fields are wrong: $last_out"
ac_log "AC1: pending keys append one line each with ts/fp/name/subject/body"

# ── AC2. the ledger is read-only (byte-identical accounts file) ──────────────
acct_before="$(cat "$ACCOUNTS_FILE")"
TICKET_BODY="ledger should not change"
run_ticket "$FP_A" "ledger check" 2>/dev/null
acct_after="$(cat "$ACCOUNTS_FILE")"
if [ "$acct_before" != "$acct_after" ]; then
  ac_fail "AC2: the ticket verb mutated the ledger (before/after differ)"
fi
# (the ticket also wrote a 3rd line — confirm the append, not a rewrite)
n=$(jq -s '.' "$TICKETS_FILE" | jq 'length')
if [ "$n" -ne 3 ]; then
  ac_fail "AC2: expected 3 ticket lines after AC1 + this ticket, got $n"
fi
ac_log "AC2: ledger byte-identical across a ticket (status/credits/name/admin)"

# ── AC3. empty subject -> nothing written, non-zero ──────────────────────────
run_ticket "$FP_A" ""
if [ "$RC" -eq 0 ]; then
  ac_fail "AC3: empty subject should be denied (rc=0, out=$OUT)"
fi
jq -e '.error == "empty subject"' <<<"$OUT" >/dev/null 2>&1 \
  || ac_fail "AC3: expected {\"error\":\"empty subject\"}, got: $OUT"
n=$(jq -s '.' "$TICKETS_FILE" | jq 'length')
if [ "$n" -ne 3 ]; then
  ac_fail "AC3: empty subject appended a line (now $n)"
fi
ac_log "AC3: empty subject -> no write, non-zero"

# ── AC4. body over 8192 bytes -> rejected, nothing written ───────────────────
TICKET_BODY="$(head -c 8193 /dev/zero | tr '\0' 'a')"
if [ "${#TICKET_BODY}" -ne 8193 ]; then
  ac_fail "AC4: fixture body is not 8193 bytes (got ${#TICKET_BODY})"
fi
run_ticket "$FP_A" "too big"
if [ "$RC" -eq 0 ]; then
  ac_fail "AC4: 8193-byte body should be rejected (rc=0, out=$OUT)"
fi
jq -e '.error == "body exceeds 8192 bytes"' <<<"$OUT" >/dev/null 2>&1 \
  || ac_fail "AC4: expected {\"error\":\"body exceeds 8192 bytes\"}, got: $OUT"
n=$(jq -s '.' "$TICKETS_FILE" | jq 'length')
if [ "$n" -ne 3 ]; then
  ac_fail "AC4: oversized body appended a line (now $n)"
fi
ac_log "AC4: body over 8192 bytes -> rejected, nothing written"

# ── AC5. body containing a NUL byte -> rejected, nothing written ─────────────
RC=0
OUT="$(printf 'a\000b' |
  ACCOUNTS_FILE="$ACCOUNTS_FILE" TICKETS_FILE="$TICKETS_FILE" \
  DISPATCH_FP="$FP_A" bash "$TICKET_SCRIPT" "nul ticket")" || RC=$?
if [ "$RC" -eq 0 ]; then
  ac_fail "AC5: NUL body should be rejected (rc=0)"
fi
jq -e '.error == "body contains NUL"' <<<"$OUT" >/dev/null 2>&1 \
  || ac_fail "AC5: expected {\"error\":\"body contains NUL\"}, got: $OUT"
n=$(jq -s '.' "$TICKETS_FILE" | jq 'length')
if [ "$n" -ne 3 ]; then
  ac_fail "AC5: NUL body appended a line (now $n)"
fi
ac_log "AC5: NUL in body -> rejected, nothing written"

# ── AC6. non-admin listing is denied ─────────────────────────────────────────
run_list "$FP_A"
if [ "$RC" -eq 0 ]; then
  ac_fail "AC6: non-admin tickets listing should be denied (rc=0, out=$OUT)"
fi
jq -e '.error == "not admin"' <<<"$OUT" >/dev/null 2>&1 \
  || ac_fail "AC6: expected {\"error\":\"not admin\"}, got: $OUT"
ac_log "AC6: non-admin tickets -> not admin, non-zero"

# ── AC7. admin listing returns the JSONL as a JSON array ─────────────────────
run_list "$FP_ADMIN"
if [ "$RC" -ne 0 ]; then
  ac_fail "AC7: admin tickets listing should succeed (rc=$RC, out=$OUT)"
fi
arr="$(tickets_array)"
jq -e --arg fp_a "$FP_A" --arg fp_b "$FP_B" \
  --arg subj_a "first ticket" --arg subj_b "second ticket" \
  'type == "array"
   and length >= 3
   and (map(select(.fp == $fp_a and .subject == $subj_a)) | length == 1)
   and (map(select(.fp == $fp_b and .subject == $subj_b)) | length == 1)' \
  <<<"$arr" >/dev/null 2>&1 \
  || ac_fail "AC7: admin list is not the JSON array of the appended tickets: $OUT"
ac_log "AC7: admin tickets -> JSON array of appended tickets"
ac_pass
