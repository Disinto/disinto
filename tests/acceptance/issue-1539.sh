#!/usr/bin/env bash
# =============================================================================
# tests/acceptance/issue-1539.sh
#
# Issue #1539: feat(edge): porter-admin grants admin on the local ledger
#
# Exercises tools/edge-control/porter-admin.sh against a throwaway
# PORTER_LEDGER in a mktemp dir (AC2-AC4) and, in AC1, against the real
# default path /var/lib/disinto/accounts.json (the file the door reads).
# AC1 branches on the caller's euid: non-root -> the euid gate refuses the
# default-path grant (nothing is written); root -> the default-path grant
# writes the door-readable ledger. The post-merge pipeline (alpine:3, no
# user: directive) runs this test as root, so the test must be correct in
# both modes.
#
#   AC1  default path (PORTER_LEDGER unset), branched on the caller's euid:
#        non-root -> {"error":"not root"}, rc 1, default ledger untouched;
#        root     -> rc 0, admin row written to /var/lib/disinto/accounts.json.
#   AC2  valid fingerprint on an empty ledger -> one row: admin true, credits
#        0, status pending, name null; stdout is the compact row.
#   AC3  running it again leaves one row and does not change credits; an
#        existing row with non-default credits/status/name is not clobbered
#        (only admin flips).
#   AC4  SHA256:nope -> {"error":"invalid fingerprint"}, rc 1, ledger
#        untouched.
#
# Run via: tools/run-acceptance.sh 1539
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../lib/acceptance-helpers.sh
source "$REPO_ROOT/tests/lib/acceptance-helpers.sh"

ac_require_cmd bash jq mktemp env

ADMINSH="$REPO_ROOT/tools/edge-control/porter-admin.sh"
ac_assert_file "$ADMINSH" "tools/edge-control/porter-admin.sh is missing"

# AC1 branches on the caller's euid (see header): non-root exercises the euid
# gate; root exercises the real default-path grant. Both are valid execution
# modes, so nothing here is a hard fail.

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT
LEDGER="$TMP_DIR/accounts.json"

# ── Run helpers: execute porter-admin.sh the way the operator would ─────────
# Through the PORTER_LEDGER seam — all writes land in $TMP_DIR.
run_admin() {
  local sub="$1" fp="${2:-}"
  RC=0
  OUT="$(PORTER_LEDGER="$LEDGER" bash "$ADMINSH" "$sub" "$fp")" || RC=$?
}
# Through the default path: PORTER_LEDGER is dropped from the env entirely.
run_admin_default() {
  local sub="$1" fp="${2:-}"
  RC=0
  OUT="$(env -u PORTER_LEDGER bash "$ADMINSH" "$sub" "$fp")" || RC=$?
}

n_rows() {
  jq '(.accounts // {}) | length' "$LEDGER"
}

# ── AC1: default path (PORTER_LEDGER unset), branched on the caller's euid ───
printf '{"version":1,"accounts":{}}\n' > "$LEDGER"
if [[ $EUID -ne 0 ]]; then
  # Non-root: the euid gate must refuse the default-path grant. Capture the
  # default-path ledger state before and after so the "untouched" claim holds
  # whether or not the file pre-existed.
  default_before=""
  if [ -f "/var/lib/disinto/accounts.json" ]; then
    default_before="$(cat "/var/lib/disinto/accounts.json")"
  fi
  run_admin_default "add-admin" "$FP_A"
  if [[ "$RC" -ne 1 ]]; then
    ac_fail "AC1: default path as non-root should be refused (rc=$RC, out=$OUT)"
  fi
  if [[ "$OUT" != '{"error":"not root"}' ]]; then
    ac_fail "AC1: expected {\"error\":\"not root\"}, got: $OUT"
  fi
  default_after=""
  if [ -f "/var/lib/disinto/accounts.json" ]; then
    default_after="$(cat "/var/lib/disinto/accounts.json")"
  fi
  if [[ "$default_after" != "$default_before" ]]; then
    ac_fail "AC1: the not-root refusal changed the default-path ledger (was: $default_before; now: $default_after)"
  fi
  ac_log "AC1: default path + non-root euid -> {\"error\":\"not root\"}, default ledger untouched"
else
  # Root: the euid gate does not fire, so the default-path grant must write
  # the file the door reads. Verify that contract: rc 0, an admin row present
  # in /var/lib/disinto/accounts.json, and stdout is the compact row.
  run_admin_default "add-admin" "$FP_A"
  if [[ "$RC" -ne 0 ]]; then
    ac_fail "AC1: default path as root should grant (rc=$RC, out=$OUT)"
  fi
  if ! jq -e --arg fp "$FP_A" '
    (.accounts // {})
    | (
        has($fp)
        and .[$fp].admin == true
        and .[$fp].credits == 0
        and .[$fp].status == "pending"
        and .[$fp].fingerprint == $fp
      )
  ' /var/lib/disinto/accounts.json >/dev/null 2>&1; then
    ac_fail "AC1: root default-path grant did not write an admin row to /var/lib/disinto/accounts.json: $(cat /var/lib/disinto/accounts.json 2>/dev/null)"
  fi
  if ! jq -e --arg fp "$FP_A" '
    .fingerprint == $fp
    and .admin == true
    and .credits == 0
    and .status == "pending"
    and .name == null
  ' <<<"$OUT" >/dev/null 2>&1; then
    ac_fail "AC1: stdout for the root default-path grant is not the compact row (out=$OUT)"
  fi
  ac_log "AC1: default path + root -> admin row written to /var/lib/disinto/accounts.json"
fi

# ── AC2: valid fp on an empty ledger -> one row, admin true, credits 0 ──────
run_admin "add-admin" "$FP_A"
if [[ "$RC" -ne 0 ]]; then
  ac_fail "AC2: admin grant on an empty ledger should succeed (rc=$RC, out=$OUT)"
fi
if ! jq -e --arg fp "$FP_A" '
  (.accounts // {})
  | (
      length == 1
      and .[$fp].admin == true
      and .[$fp].credits == 0
      and .[$fp].status == "pending"
      and .[$fp].name == null
      and .[$fp].fingerprint == $fp
    )
' "$LEDGER" >/dev/null 2>&1; then
  ac_fail "AC2: row is not admin/credits=0/pending: $(cat "$LEDGER")"
fi
if ! jq -e --arg fp "$FP_A" '
  .fingerprint == $fp
  and .admin == true
  and .credits == 0
  and .status == "pending"
  and .name == null
' <<<"$OUT" >/dev/null 2>&1; then
  ac_fail "AC2: stdout is not the compact row (out=$OUT)"
fi
ac_log "AC2: empty ledger + valid fp -> one row (admin true, credits 0, status pending)"

# ── AC3: re-run leaves one row, credits unchanged; no clobbering ─────────────
run_admin "add-admin" "$FP_A"
if [[ "$RC" -ne 0 ]]; then
  ac_fail "AC3: second grant on the same ledger should succeed (rc=$RC, out=$OUT)"
fi
if [[ "$(n_rows)" != "1" ]]; then
  ac_fail "AC3: expected one row after the second run, got $(n_rows)"
fi
if ! jq -e --arg fp "$FP_A" '
  (.accounts | length == 1)
  and .accounts[$fp].credits == 0
  and .accounts[$fp].admin == true
  and .accounts[$fp].status == "pending"
' "$LEDGER" >/dev/null 2>&1; then
  ac_fail "AC3: second run changed credits or the row count: $(cat "$LEDGER")"
fi

# Give the row a non-default state (what credits-grant/approve would produce)
# and confirm the grant flips only admin.
if jq --arg fp "$FP_A" '
  .accounts[$fp].credits = 250
  | .accounts[$fp].status = "registered"
  | .accounts[$fp].name = "bound"
' "$LEDGER" > "${LEDGER}.ac3tmp"; then
  mv "${LEDGER}.ac3tmp" "$LEDGER" \
    || { rm -f "${LEDGER}.ac3tmp"; ac_fail "AC3: cannot write mutated row"; }
else
  rm -f "${LEDGER}.ac3tmp" 2>/dev/null
  ac_fail "AC3: cannot pre-mutate the row"
fi
run_admin "add-admin" "$FP_A"
if [[ "$RC" -ne 0 ]]; then
  ac_fail "AC3: grant on a non-default row should succeed (rc=$RC, out=$OUT)"
fi
if ! jq -e --arg fp "$FP_A" '
  (.accounts | length == 1)
  and .accounts[$fp].credits == 250
  and .accounts[$fp].status == "registered"
  and .accounts[$fp].name == "bound"
  and .accounts[$fp].admin == true
' "$LEDGER" >/dev/null 2>&1; then
  ac_fail "AC3: existing credits/status/name were clobbered: $(cat "$LEDGER")"
fi
ac_log "AC3: re-run leaves one row with credits unchanged; non-default state is not clobbered"

# ── AC4: bad fingerprint -> invalid fingerprint error, ledger untouched ──────
before="$(cat "$LEDGER")"
run_admin "add-admin" "SHA256:nope"
if [[ "$RC" -eq 0 ]]; then
  ac_fail "AC4: SHA256:nope should be refused (rc=0, out=$OUT)"
fi
if [[ "$OUT" != '{"error":"invalid fingerprint"}' ]]; then
  ac_fail "AC4: expected {\"error\":\"invalid fingerprint\"}, got: $OUT"
fi
if [[ "$(cat "$LEDGER")" != "$before" ]]; then
  ac_fail "AC4: ledger changed on an invalid fingerprint"
fi
ac_log "AC4: SHA256:nope -> {\"error\":\"invalid fingerprint\"}, nothing written"

ac_pass
