#!/usr/bin/env bash
# =============================================================================
# tests/acceptance/issue-1466.sh — admin approve and revoke bind a name
#
# Per-issue acceptance test for tools/edge-control/verbs/{approve.sh,revoke.sh}
# + tools/edge-control/lib/apply-name.sh. Runs the verbs in stub apply mode
# (EDGE_APPLY=stub) against a throwaway $ACCOUNTS_FILE in an mktemp dir and
# asserts the issue's five acceptance criteria:
#
#   1. non-admin approve doesn't change status
#   2. admin approve sets status to approved
#   3. EDGE_APPLY=stub records an apply line and does not invoke curl
#   4. admin revoke sets status to revoked and stub-records a revoke
#   5. unknown name returns an error and writes nothing
#
# Plus idempotency checks (re-approve an approved name; re-revoke an
# already-revoked name) and the "not approvable" guard (approve a revoked
# name). Every failure path returns before the ledger status is changed.
#
# Contract: last line of stdout is PASS on success, "FAIL: <reason>" otherwise.
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../" && pwd)"

# shellcheck disable=SC1090,SC1091
source "$REPO_ROOT/tests/lib/acceptance-helpers.sh"

ac_require_cmd bash jq mktemp grep cat date printf chmod

APPROVE="$REPO_ROOT/tools/edge-control/verbs/approve.sh"
REVOKE="$REPO_ROOT/tools/edge-control/verbs/revoke.sh"
APPLY="$REPO_ROOT/tools/edge-control/lib/apply-name.sh"

ac_assert_file "$APPROVE" "verbs/approve.sh is missing"
ac_assert_file "$REVOKE" "verbs/revoke.sh is missing"
ac_assert_file "$APPLY" "lib/apply-name.sh is missing"

# The stub apply must not reach any network lib: prove it with a fake curl on
# PATH that marks itself and fails (mirroring a downed Caddy). If the stub
# path ever sources caddy.sh and calls curl, this marker appears.
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

ACCOUNTS_FILE="$TMP_DIR/accounts.json"
APPLY_LOG="$TMP_DIR/apply.log"
CURL_MARKER="$TMP_DIR/.curl-invoked"
STUB_DIR="$TMP_DIR/stub-bin"
mkdir -p "$TMP_DIR" "$STUB_DIR"

printf '{"version":1,"accounts":{}}\n' > "$ACCOUNTS_FILE"
# A sentinel "registry" that the real (EDGE_APPLY=1) apply would mutate. In
# stub mode it must stay byte-identical — a second defense behind the fake-curl
# marker.
printf '{"version":1,"projects":{"sentinel-project":{"port":20001}}}\n' \
  > "$TMP_DIR/registry.json"

# Fake curl: if invoked, mark itself and exit 1 (like an unreachable Caddy).
cat > "$STUB_DIR/curl" <<'FAKE_CURL'
#!/usr/bin/env bash
: > "$FAKE_CURL_MARKER"
exit 1
FAKE_CURL
chmod +x "$STUB_DIR/curl"
export FAKE_CURL_MARKER="$CURL_MARKER"

# Fixture rows: a user who claimed "acme" (pending), an admin, a second user
# that also claims a name ("other"), so the name-lookup path is exercised by
# a non-holder too.
seed_row "$FP_A"     "acme"     "false" 0
seed_row "$FP_ADMIN" "admin-who" "true"  0
seed_row "$FP_B"     "other"    "false" 0

# Run a verb as the given fingerprint in stub apply mode.
#   $1=fingerprint  $2=verb path  $3=name-arg
#   stdout -> OUT, exit status -> RC (stderr discarded into a scratch file).
run_verb() {
  local fp="$1" verb_path="$2" name_arg="$3"
  RC=0
  OUT=""
  OUT="$(
    PATH="$STUB_DIR:$PATH" \
      ACCOUNTS_FILE="$ACCOUNTS_FILE" \
      DISPATCH_FP="$fp" \
      EDGE_APPLY=stub \
      EDGE_APPLY_LOG="$APPLY_LOG" \
      bash "$verb_path" "$name_arg" 2>"$TMP_DIR/stderr.txt"
  )" || RC=$?
}

# Snapshot the ledger for the "writes nothing" assertions.
snapshot_ledger() {
  cat "$ACCOUNTS_FILE"
}

# ── AC1: non-admin approve doesn't change status ─────────────────────────────
ac_log "AC1: non-admin approve leaves status untouched"
run_verb "$FP_A" "$APPROVE" "acme"
ac_assert_eq "$RC" "1" "non-admin (FP_A) approve must return 1 (got $RC)"
case "$OUT" in
  *'"error":"not admin"'*) ;;
  *) ac_fail "non-admin approve must emit {\"error\":\"not admin\"}, got: $OUT" ;;
esac
# The name holder's row (FP_A) must still be pending.
ac_assert_eq "$(jq -r --arg fp "$FP_A" '.accounts[$fp].status' "$ACCOUNTS_FILE")" \
  "pending" "non-admin approve must not change the holder's status (got $(jq -r --arg fp "$FP_A" '.accounts[$fp].status' "$ACCOUNTS_FILE"))"
# A non-admin who is not the holder also fails closed.
run_verb "$FP_B" "$APPROVE" "acme"
ac_assert_eq "$RC" "1" "non-admin (FP_B, non-holder) approve must return 1 (got $RC)"
case "$OUT" in
  *'"error":"not admin"'*) ;;
  *) ac_fail "non-admin non-holder approve must emit not-admin error, got: $OUT" ;;
esac
ac_assert_eq "$(jq -r --arg fp "$FP_A" '.accounts[$fp].status' "$ACCOUNTS_FILE")" \
  "pending" "second non-admin approve must still leave status pending"
# No stub line may have been written by the failed calls.
[[ -z "$(cat "$APPLY_LOG" 2>/dev/null)" ]] \
  || ac_fail "failed (denied) approve must not stub-record an apply line"

# ── AC2: admin approve sets status to approved (idempotent) ─────────────────
ac_log "AC2: admin approve sets status to approved"
run_verb "$FP_ADMIN" "$APPROVE" "acme"
ac_assert_eq "$RC" "0" "admin approve of a pending name must return 0 (got $RC): $OUT"
ac_assert_eq "$(jq -r --arg fp "$FP_A" '.accounts[$fp].status' "$ACCOUNTS_FILE")" \
  "approved" "admin approve must set the holder's status to approved (got $(jq -r --arg fp "$FP_A" '.accounts[$fp].status' "$ACCOUNTS_FILE"))"
# Re-approving an already-approved name is idempotent (still rc 0).
run_verb "$FP_ADMIN" "$APPROVE" "acme"
ac_assert_eq "$RC" "0" "re-approving an approved name must be idempotent (rc 0), got $RC: $OUT"
ac_assert_eq "$(jq -r --arg fp "$FP_A" '.accounts[$fp].status' "$ACCOUNTS_FILE")" \
  "approved" "re-approve must keep the status approved"

# ── AC3: stub records the apply line and does not invoke curl ───────────────
ac_log "AC3: EDGE_APPLY=stub records the apply line, invokes no curl"
ac_assert_file "$APPLY_LOG" "stub apply log file missing"
[[ "$(cat "$APPLY_LOG")" == *"approve acme"* ]] \
  || ac_fail "stub apply log must contain the approve line, got: $(cat "$APPLY_LOG")"
# No curl invocation anywhere (the fake-curl marker must be absent).
if [ -e "$CURL_MARKER" ]; then
  ac_fail "stub path invoked curl (marker present) — it must not source caddy.sh"
fi
# The registry sentinel is untouched.
if ! diff -q "$TMP_DIR/registry.json" \
  <(printf '{"version":1,"projects":{"sentinel-project":{"port":20001}}}\n') \
  >/dev/null 2>&1; then
  ac_fail "stub mode mutated the registry sentinel"
fi

# ── AC4: admin revoke sets status to revoked, stub-records a revoke ─────────
ac_log "AC4: admin revoke sets status to revoked, stub-records a revoke"
run_verb "$FP_ADMIN" "$REVOKE" "acme"
ac_assert_eq "$RC" "0" "admin revoke of an approved name must return 0 (got $RC): $OUT"
ac_assert_eq "$(jq -r --arg fp "$FP_A" '.accounts[$fp].status' "$ACCOUNTS_FILE")" \
  "revoked" "admin revoke must set the holder's status to revoked (got $(jq -r --arg fp "$FP_A" '.accounts[$fp].status' "$ACCOUNTS_FILE"))"
[[ "$(cat "$APPLY_LOG")" == *"revoke acme"* ]] \
  || ac_fail "stub apply log must contain the revoke line, got: $(cat "$APPLY_LOG")"
if [ -e "$CURL_MARKER" ]; then
  ac_fail "stub-mode revoke invoked curl — it must not source caddy.sh"
fi
if ! diff -q "$TMP_DIR/registry.json" \
    <(printf '{"version":1,"projects":{"sentinel-project":{"port":20001}}}\n') \
    >/dev/null 2>&1; then
  ac_fail "stub-mode revoke mutated the registry sentinel"
fi

# Re-revoke an already-revoked name: idempotent (rc 0, row still present).
run_verb "$FP_ADMIN" "$REVOKE" "acme"
ac_assert_eq "$RC" "0" "re-revoking an already-revoked name must be idempotent (rc 0), got $RC: $OUT"
ac_assert_eq "$(jq -r --arg fp "$FP_A" '.accounts[$fp].status' "$ACCOUNTS_FILE")" \
  "revoked" "re-revoke must keep the status revoked"
# The row must still exist (not deleted).
jq -e --arg fp "$FP_A" '.accounts[$fp] != null' "$ACCOUNTS_FILE" >/dev/null 2>&1 \
  || ac_fail "revoke must not delete the row"
# Approving the now-revoked name fails closed.
run_verb "$FP_ADMIN" "$APPROVE" "acme"
ac_assert_eq "$RC" "1" "approving a revoked name must return 1 (got $RC): $OUT"
case "$OUT" in
  *'"error":"not approvable"'*) ;;
  *) ac_fail "approving a revoked name must emit {\"error\":\"not approvable\"}, got: $OUT" ;;
esac
ac_assert_eq "$(jq -r --arg fp "$FP_A" '.accounts[$fp].status' "$ACCOUNTS_FILE")" \
  "revoked" "denied approve of a revoked name must not change its status"

# ── AC5: unknown name returns an error and writes nothing ───────────────────
ac_log "AC5: unknown name returns an error and writes nothing"
# Capture the ledger so the "writes nothing" assertion is byte-exact.
before="$(snapshot_ledger)"

# Approve an unknown name.
run_verb "$FP_ADMIN" "$APPROVE" "ghost"
ac_assert_eq "$RC" "1" "admin approve of an unknown name must return 1 (got $RC): $OUT"
case "$OUT" in
  *'"error":"unknown name"'*) ;;
  *) ac_fail "admin approve of unknown name must emit {\"error\":\"unknown name\"}, got: $OUT" ;;
esac
after="$(snapshot_ledger)"
ac_assert_eq "$after" "$before" "approve of unknown name must write nothing to the ledger"

# Revoke an unknown name.
before="$(snapshot_ledger)"
run_verb "$FP_ADMIN" "$REVOKE" "ghost"
ac_assert_eq "$RC" "1" "admin revoke of an unknown name must return 1 (got $RC): $OUT"
case "$OUT" in
  *'"error":"unknown name"'*) ;;
  *) ac_fail "admin revoke of unknown name must emit {\"error\":\"unknown name\"}, got: $OUT" ;;
esac
after="$(snapshot_ledger)"
ac_assert_eq "$after" "$before" "revoke of unknown name must write nothing to the ledger"

ac_pass
