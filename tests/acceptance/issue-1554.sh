#!/usr/bin/env bash
# =============================================================================
# tests/acceptance/issue-1554.sh
#
# Issue #1554: feat(edge): store the SSH public key on the account row
#
# key-command.sh saw the caller's public key and threw it away; the ledger
# row had no pubkey field, so apply_approve fell back to the fingerprint
# string in disinto-tunnel's authorized_keys — which is not a key — so an
# approved name still could not tunnel. This change makes key-command.sh
# persist `pubkey` = "KEY_TYPE KEY_DATA" (one space, no options, no comments)
# onto that fingerprint's ledger row: creating the row if absent
# (status=pending, credits=0, admin=false) and touching only the `pubkey`
# field on an existing row. The restrict line is unchanged in shape, and the
# key material is never written to stderr.
#
# Contract under test (#1554):
#   * a valid ed25519 key creates a row whose `pubkey` is "ssh-ed25519"
#     plus the key data, and whose `status` is "pending";
#   * an existing row keeps its `status`, `credits`, `name`, and `admin` when
#     the key is stored (a second connection with the same key writes the same
#     value and changes nothing else);
#   * a rejected key type leaves the ledger unchanged and prints no stdout;
#   * no network.
#
# Hermetic: no network. The ledger is a throwaway $ACCOUNTS_FILE in an mktemp
# dir (never /var/lib/disinto).
#
# Run via: tools/run-acceptance.sh 1554
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=../lib/acceptance-helpers.sh
source "$REPO_ROOT/tests/lib/acceptance-helpers.sh"

ac_require_cmd bash jq grep cmp mktemp rm cat date

KEY_COMMAND="$REPO_ROOT/tools/edge-control/key-command.sh"
ac_assert_file "$KEY_COMMAND" "tools/edge-control/key-command.sh is missing"

# ── Fixtures: throwaway ledger ───────────────────────────────────────────────
TMP_DIR="$(mktemp -d /tmp/acceptance-1554.XXXXXX)"
ACCOUNTS_FILE="$TMP_DIR/accounts.json"
printf '{"version":1,"accounts":{}}\n' > "$ACCOUNTS_FILE"
cleanup() {
  rm -rf "$TMP_DIR" 2>/dev/null || true
}
trap cleanup EXIT

KEY_TYPE="ssh-ed25519"
KEY_DATA="AAAAC3NzaC1lZDI1NTE5AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAB"
EXPECTED_PUBKEY="${KEY_TYPE} ${KEY_DATA}"

# Run key-command.sh against the throwaway ledger; rc/out/err are globals.
run_key() {
  local stderr_file="${TMP_DIR}/key_err.txt"
  rc=0
  out=""
  err=""
  out="$(ACCOUNTS_FILE="$ACCOUNTS_FILE" bash "$KEY_COMMAND" "$@" 2>"$stderr_file")" || rc=$?
  err="$(cat "$stderr_file")"
}

# ── AC1. valid ed25519 key creates a row (pubkey + pending, credits 0,
#     admin false) and emits the usual restrict line ────────────────────────
run_key "$FP_A" "$KEY_TYPE" "$KEY_DATA"
if [ "$rc" -ne 0 ]; then
  ac_fail "AC1: valid key should exit 0 (rc=$rc, err=$err)"
fi
if [[ -n "$err" ]]; then
  ac_fail "AC1: stderr must be empty on success (got: $err)"
fi
expected_line="pty,restrict,command=\"${REPO_ROOT}/tools/edge-control/porter-wrap.sh --fp ${FP_A}\" ${KEY_TYPE} ${KEY_DATA}"
if [[ "$out" != "$expected_line" ]]; then
  ac_fail "AC1: restrict line changed (got: $out)"
fi
jq -e --arg fp "$FP_A" --arg pk "$EXPECTED_PUBKEY" \
    '(.accounts // {})[$fp].pubkey == $pk' "$ACCOUNTS_FILE" \
  >/dev/null 2>&1 || ac_fail "AC1: pubkey not stored on row $FP_A"
jq -e --arg fp "$FP_A" '(.accounts // {})[$fp].status == "pending"' "$ACCOUNTS_FILE" \
  >/dev/null 2>&1 || ac_fail "AC1: created row status not pending"
jq -e --arg fp "$FP_A" '(.accounts // {})[$fp].credits == 0' "$ACCOUNTS_FILE" \
  >/dev/null 2>&1 || ac_fail "AC1: created row credits not 0"
jq -e --arg fp "$FP_A" '(.accounts // {})[$fp].admin == false' "$ACCOUNTS_FILE" \
  >/dev/null 2>&1 || ac_fail "AC1: created row admin not false"
ac_log "AC1: valid ed25519 key -> row with pubkey, status=pending, restrict line intact"

# ── AC2. existing row keeps status/credits/name/admin; second connection
#     with the same key changes nothing else ────────────────────────────────
seed_row "$FP_B" "bob" "true" 3
tmpfile="$ACCOUNTS_FILE.tmp"
jq --arg fp "$FP_B" '.accounts[$fp].status = "registered"' "$ACCOUNTS_FILE" \
    > "$tmpfile" || ac_fail "AC2: cannot flip $FP_B to registered"
mv "$tmpfile" "$ACCOUNTS_FILE"
jq --arg fp "$FP_B" '.accounts[$fp].created_at = "2026-01-01T00:00:00Z"' "$ACCOUNTS_FILE" \
    > "$tmpfile" || ac_fail "AC2: cannot pin created_at on $FP_B"
mv "$tmpfile" "$ACCOUNTS_FILE"

run_key "$FP_B" "$KEY_TYPE" "$KEY_DATA"
if [ "$rc" -ne 0 ]; then
  ac_fail "AC2: key storage on an existing row should exit 0 (rc=$rc, err=$err)"
fi
if [[ -n "$err" ]]; then
  ac_fail "AC2: stderr must be empty on success (got: $err)"
fi
if ! jq -e --arg fp "$FP_B" --arg pk "$EXPECTED_PUBKEY" \
     '(.accounts // {})[$fp]
      | (.pubkey == $pk and .status == "registered" and .name == "bob" and .admin == true and .credits == 3)' \
     "$ACCOUNTS_FILE" >/dev/null 2>&1; then
  ac_fail "AC2: existing row lost a field after storing the key"
fi
if ! jq -e --arg fp "$FP_B" \
     '(.accounts // {})[$fp].created_at == "2026-01-01T00:00:00Z"' "$ACCOUNTS_FILE" \
     >/dev/null 2>&1; then
  ac_fail "AC2: created_at changed when storing the key"
fi
# Idempotency: same key again -> row byte-for-byte identical.
row_before="$(jq -c --arg fp "$FP_B" '.accounts // {} | .[$fp]' "$ACCOUNTS_FILE")"
run_key "$FP_B" "$KEY_TYPE" "$KEY_DATA"
if [ "$rc" -ne 0 ]; then
  ac_fail "AC2: second connection with the same key should exit 0 (rc=$rc, err=$err)"
fi
row_after="$(jq -c --arg fp "$FP_B" '.accounts // {} | .[$fp]' "$ACCOUNTS_FILE")"
if [[ "$row_before" != "$row_after" ]]; then
  ac_fail "AC2: second connection with the same key changed the row (before: $row_before, after: $row_after)"
fi
ac_log "AC2: existing row keeps status/credits/name/admin (and created_at); same key twice is idempotent"

# ── AC3. rejected key type leaves the ledger unchanged, prints no stdout,
#     and never logs the key material ───────────────────────────────────────
snapshot="$TMP_DIR/accounts.snap"
cp "$ACCOUNTS_FILE" "$snapshot" || ac_fail "AC3: cannot snapshot ledger"
run_key "$FP_B" "ssh-dsa" "$KEY_DATA"
if [ "$rc" -ne 1 ]; then
  ac_fail "AC3: rejected key type should exit 1 (rc=$rc)"
fi
if [[ -n "$out" ]]; then
  ac_fail "AC3: rejected key type printed stdout (got: $out)"
fi
if ! cmp -s "$ACCOUNTS_FILE" "$snapshot"; then
  ac_fail "AC3: rejected key type changed the ledger"
fi
if [[ "$err" == *"$KEY_DATA"* ]]; then
  ac_fail "AC3: key material appeared in stderr (got: $err)"
fi
ac_log "AC3: rejected key type -> no ledger change, no stdout, key never logged"

ac_pass
