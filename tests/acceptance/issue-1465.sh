#!/usr/bin/env bash
# =============================================================================
# tests/acceptance/issue-1465.sh
#
# Issue #1465: feat(edge): register-request claims a pending name
#
# Exercises verbs/register-request.sh against a throwaway ACCOUNTS_FILE in a
# mktemp dir — no live services, no sshd, never /var/lib/disinto or
# /etc/ssh. The verb is run directly with DISPATCH_FP exported, per the
# dispatcher contract (see issue-1464.sh for the pattern).
#
#   AC1  a valid name is stored in the caller's row, status stays pending,
#         credits stay 0, and the last stdout line is the claimed row.
#   AC2  a second fingerprint requesting that name gets {"error":"name taken"}
#         (non-zero exit) and its own row stays name=null (no overwrite).
#   AC3  reserved names are rejected with {"error":"name reserved"} and
#         malformed names with {"error":"invalid project name"}; both write
#         nothing.
#   AC4  idempotence: the same fingerprint re-requesting its current name
#         prints the row and writes nothing. A fingerprint holding a *different*
#         name gets {"error":"already named"} and writes nothing.
#   AC5  the verb never references (and behaviorally never invokes)
#         allocate_port / free_port / add_route / remove_route /
#         rebuild_authorized_keys; the registry.json and authorized_keys
#         sentinels survive successful claims byte-for-byte untouched.
#
# Run via: tools/run-acceptance.sh 1465
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../tests/lib/acceptance-helpers.sh
source "$REPO_ROOT/tests/lib/acceptance-helpers.sh"

ac_require_cmd bash jq mktemp grep cat tail

VERBS_DIR="$REPO_ROOT/tools/edge-control/verbs"
REGISTER_REQUEST="$VERBS_DIR/register-request.sh"

ac_assert_file "$REGISTER_REQUEST" "verbs/register-request.sh is missing"
ac_assert_file "$REPO_ROOT/tools/edge-control/lib/accounts.sh" "lib/accounts.sh is missing"

# ── Fixtures: throwaway ledger, fingerprints, no-op sentinels ─────────────────
TMP_DIR="$(mktemp -d)"
ACCOUNTS_FILE="$TMP_DIR/accounts.json"
trap 'rm -rf "$TMP_DIR"' EXIT

# Make a ledger row for <fp> (status=pending, name=null, credits=0), the same
# shape dispatch.sh + account_ensure produce.
seed_row() {
  local fp="$1"
  local tmp
  tmp="$ACCOUNTS_FILE.tmp"
  jq --arg fp "$fp" --arg now "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" \
     '.accounts[$fp] = {fingerprint: $fp, status: "pending", credits: 0, name: null, created_at: $now}' \
     "$ACCOUNTS_FILE" > "$tmp" \
    || ac_fail "seed_row: cannot seed row for $fp"
  mv "$tmp" "$ACCOUNTS_FILE"
}

printf '{"version":1,"accounts":{}}\n' > "$ACCOUNTS_FILE"

# Valid SHA256 fingerprints: "SHA256:" + exactly 43 base64url chars.
FP_A="SHA256:$(printf 'A%.0s' {1..43})"
FP_B="SHA256:$(printf 'B%.0s' {1..43})"
FP_C="SHA256:$(printf 'C%.0s' {1..43})"
[[ "$FP_A" =~ ^SHA256:[A-Za-z0-9_-]{43}$ ]] \
  || ac_fail "test fixture fingerprint is malformed: $FP_A"

for fp in "$FP_A" "$FP_B" "$FP_C"; do
  seed_row "$fp"
done

# The claim is name-only. These sentinels stand in for the port registry and
# the tunnel authorized_keys ledger; a correct verb leaves them byte-for-byte
# untouched (and never sources lib/ports.sh, lib/caddy.sh, or
# lib/authorized_keys.sh at all).
REGISTRY_SENTINEL="$TMP_DIR/registry.json"
printf '{"version":1,"projects":{"sentinel-project":{"port":20001}}}\n' > "$REGISTRY_SENTINEL"
AUTH_KEYS_SENTINEL="$TMP_DIR/authorized_keys"
printf 'restrict,command="/bin/false" ssh-ed25519 AAAABSENTKEY sentinel\n' > "$AUTH_KEYS_SENTINEL"
REG_BEFORE="$(cat "$REGISTRY_SENTINEL")"
AUTH_BEFORE="$(cat "$AUTH_KEYS_SENTINEL")"

# Run the verb as the dispatcher would: ACCOUNTS_FILE + DISPATCH_FP exported,
# verb path + name arg. OUT = stdout, RC = exit code.
run_verb() {
  local fp="$1"
  shift
  RC=0
  OUT="$(ACCOUNTS_FILE="$ACCOUNTS_FILE" DISPATCH_FP="$fp" \
    bash "$REGISTER_REQUEST" "$@")" || RC=$?
}

# ── AC1. valid name is stored and status stays pending ──────────────────────────
run_verb "$FP_A" acme
if [ "$RC" -ne 0 ]; then
  ac_fail "AC1: register-request acme should succeed (rc=$RC, out=$OUT)"
fi
jq -e --arg fp "$FP_A" \
  '.accounts[$fp] | .name == "acme" and .status == "pending" and .credits == 0' \
  "$ACCOUNTS_FILE" >/dev/null 2>&1 \
  || ac_fail "AC1: ledger row for $FP_A is not acme/pending/credits-0: $ACCOUNTS_FILE"
last_out="$(printf '%s\n' "$OUT" | tail -n 1)"
jq -e --arg fp "$FP_A" --arg n "acme" \
  '.fingerprint == $fp and .name == $n and .status == "pending"' <<<"$last_out" >/dev/null 2>&1 \
  || ac_fail "AC1: last stdout line is not the claimed row: $last_out"
ac_log "AC1: register-request acme -> name stored, status pending"

# ── AC2. second fingerprint on the same name → name taken, no overwrite ────────
run_verb "$FP_B" acme
if [ "$RC" -eq 0 ]; then
  ac_fail "AC2: $FP_B claiming acme should be denied (rc=0, out=$OUT)"
fi
jq -e '.error == "name taken"' <<<"$OUT" >/dev/null 2>&1 \
  || ac_fail "AC2: expected {\"error\":\"name taken\"}, got: $OUT"
jq -e --arg fp "$FP_B" '.accounts[$fp].name == null' "$ACCOUNTS_FILE" >/dev/null 2>&1 \
  || ac_fail "AC2: denied request wrote into $FP_B's row"
ac_log "AC2: second fingerprint -> name taken, no overwrite"

# ── AC3. reserved and malformed names rejected, nothing written ─────────────────
# (a) a fingerprint holding a name must still be refused for a reserved name
run_verb "$FP_A" www
if [ "$RC" -eq 0 ]; then
  ac_fail "AC3a: reserved name www should be denied (rc=0, out=$OUT)"
fi
jq -e '.error == "name reserved"' <<<"$OUT" >/dev/null 2>&1 \
  || ac_fail "AC3a: expected {\"error\":\"name reserved\"}, got: $OUT"
jq -e --arg fp "$FP_A" '.accounts[$fp].name == "acme"' "$ACCOUNTS_FILE" >/dev/null 2>&1 \
  || ac_fail "AC3a: reserved-name denial clobbered $FP_A's claim"

# (b) fresh fingerprint, reserved name
run_verb "$FP_C" caddy
if [ "$RC" -eq 0 ]; then
  ac_fail "AC3b: reserved name caddy should be denied (rc=0, out=$OUT)"
fi
jq -e '.error == "name reserved"' <<<"$OUT" >/dev/null 2>&1 \
  || ac_fail "AC3b: expected {\"error\":\"name reserved\"}, got: $OUT"

# (c) malformed names: uppercase, too short
run_verb "$FP_C" Acme
if [ "$RC" -eq 0 ]; then
  ac_fail "AC3c: uppercase name should be denied (rc=0, out=$OUT)"
fi
jq -e '.error == "invalid project name"' <<<"$OUT" >/dev/null 2>&1 \
  || ac_fail "AC3c: expected {\"error\":\"invalid project name\"}, got: $OUT"

run_verb "$FP_C" a
if [ "$RC" -eq 0 ]; then
  ac_fail "AC3d: too-short name should be denied (rc=0, out=$OUT)"
fi
jq -e '.error == "invalid project name"' <<<"$OUT" >/dev/null 2>&1 \
  || ac_fail "AC3d: expected {\"error\":\"invalid project name\"}, got: $OUT"

# (e) no claim writes landed on any of these rows
jq -e --arg fp "$FP_C" '.accounts[$fp].name == null' "$ACCOUNTS_FILE" >/dev/null 2>&1 \
  || ac_fail "AC3e: rejection wrote into $FP_C's row"
ac_log "AC3: reserved and malformed names rejected, nothing written"

# ── AC4. idempotence + already named ───────────────────────────────────────────
# (a) same fingerprint re-requesting its current name: prints the row, no change
run_verb "$FP_A" acme
if [ "$RC" -ne 0 ]; then
  ac_fail "AC4a: re-request of own name should be idempotent (rc=$RC, out=$OUT)"
fi
last_out="$(printf '%s\n' "$OUT" | tail -n 1)"
jq -e --arg fp "$FP_A" --arg n "acme" \
  '.fingerprint == $fp and .name == $n and .status == "pending"' <<<"$last_out" >/dev/null 2>&1 \
  || ac_fail "AC4a: idempotent re-request did not print the row: $last_out"
jq -e --arg fp "$FP_A" \
  '.accounts[$fp] | .name == "acme" and .status == "pending" and .credits == 0' \
  "$ACCOUNTS_FILE" >/dev/null 2>&1 \
  || ac_fail "AC4a: idempotent re-request mutated $FP_A's row"

# (b) a fingerprint bound to a *different* name requesting another name
run_verb "$FP_B" other
if [ "$RC" -ne 0 ]; then
  ac_fail "AC4b-1: $FP_B should claim the unbound name other (rc=$RC, out=$OUT)"
fi
run_verb "$FP_B" acme
if [ "$RC" -eq 0 ]; then
  ac_fail "AC4b-2: $FP_B holding 'other' requesting acme should be denied (rc=0, out=$OUT)"
fi
jq -e '.error == "already named"' <<<"$OUT" >/dev/null 2>&1 \
  || ac_fail "AC4b-2: expected {\"error\":\"already named\"}, got: $OUT"
jq -e --arg fp "$FP_B" '.accounts[$fp].name == "other"' "$ACCOUNTS_FILE" >/dev/null 2>&1 \
  || ac_fail "AC4b-2: already-named denial overwrote $FP_B's name"
ac_log "AC4: idempotent re-request prints the row; different name -> already named"

# ── AC5. no port/route/keys machinery: static + behavioral ─────────────────────
# (a) static: the verb must not reference the allocation/route/keys functions.
if grep -qE 'allocate_port|free_port|add_route|remove_route|rebuild_authorized_keys' \
    "$REGISTER_REQUEST"; then
  ac_fail "AC5a: register-request.sh references port/route/keys machinery"
fi
if grep -qE 'source .*(ports|caddy|authorized_keys)' "$REGISTER_REQUEST"; then
  ac_fail "AC5b: register-request.sh sources the port/caddy/authorized_keys libs"
fi

# (b) behavioral: the sentinels survive all the successful claims (AC1, AC4a,
#     AC4b-1) byte-for-byte — nothing registry or authorized_keys related
#     happened during the name claim.
if [ "$REG_BEFORE" != "$(cat "$REGISTRY_SENTINEL")" ]; then
  ac_fail "AC5c: registry sentinel mutated by a name claim"
fi
if [ "$AUTH_BEFORE" != "$(cat "$AUTH_KEYS_SENTINEL")" ]; then
  ac_fail "AC5d: authorized_keys sentinel mutated by a name claim"
fi
ac_log "AC5: claim is name-only — no route/port/keys machinery touched"
ac_pass
