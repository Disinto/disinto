#!/usr/bin/env bash
# =============================================================================
# tests/acceptance/issue-1535.sh
#
# Issue #1535: fix(edge): jev sends a typed question map
#
# verbs/jev.sh accepted a pack whose `questions` was an *array of strings*
# and posted that array. The TypeSafe API (POST /v1/systemone) requires
# `questions` to be a *map* of typed objects (`type` + `instructions`) — a
# string list is not a Noul. This change makes jev reject a string-array pack
# ("unknown pack", pre-socket, no debit) and post the pack's `questions` map
# through verbatim.
#
# Contract under test (#1535):
#   * a pack whose `questions` is a string array -> "unknown pack", the TypeSafe
#     socket is never opened, and the account is not debited (credits unchanged);
#   * the `scope` pack posts `.questions` equal to the pack's `questions` object
#     (the three Nouls, one yes/no each), and `.state` round-trips stdin exactly;
#   * no network.
#
# Hermetic: no network. The TypeSafe call is intercepted by a fake `curl`
# dropped at the front of PATH (same pattern as issue-1471). The string-array
# case is exercised by dropping a throwaway pack into packs/ and removing it
# before exit (the EXIT trap removes the pack too, so the repo tree is left
# clean even on a failed assertion).
#
# Acceptance: `bash tests/acceptance/issue-1535.sh` exits 0 and calls ac_pass.
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=../../tests/lib/acceptance-helpers.sh
source "$REPO_ROOT/tests/lib/acceptance-helpers.sh"

ac_require_cmd bash jq mktemp grep cat printf tr env chmod date

JEV="$REPO_ROOT/tools/edge-control/verbs/jev.sh"
PACKS_DIR="$REPO_ROOT/tools/edge-control/packs"
SCOPE_PACK="$REPO_ROOT/tools/edge-control/packs/scope.json"

ac_assert_file "$JEV" "verbs/jev.sh is missing"
ac_assert_file "$SCOPE_PACK" "packs/scope.json is missing"

# ── Fixtures: throwaway ledger ───────────────────────────────────────────────
TMP_DIR="$(mktemp -d /tmp/acceptance-1535.XXXXXX)"
# A scratch string-array pack is written into the real packs/ tree (the only
# resolvable location); it is cleaned by this trap on every exit path.
BAD_PACK=""
cleanup() {
  rm -rf "$TMP_DIR" 2>/dev/null || true
  if [[ -n "$BAD_PACK" ]]; then
    rm -f "$BAD_PACK" 2>/dev/null || true
  fi
}
trap cleanup EXIT
ACCOUNTS_FILE="$TMP_DIR/accounts.json"
printf '{"version":1,"accounts":{}}\n' > "$ACCOUNTS_FILE"

# jev requires status == "approved" and >= 1 credit, but seed_row emits pending
# rows — flip the row the ACs exercise to "approved" below.
seed_row "$FP_A" "acme" "false" 1
jq --arg fp "$FP_A" '.accounts[$fp].status = "approved"' "$ACCOUNTS_FILE" \
  > "${ACCOUNTS_FILE}.tmp" || ac_fail "cannot flip $FP_A to approved"
mv "${ACCOUNTS_FILE}.tmp" "$ACCOUNTS_FILE"

# ── TypeSafe stub: sourced from tests/lib/fake-typesafe.sh (shared) ──────────
# TMP_DIR, ACCOUNTS_FILE, and JEV are defined above. Provides STUB_DIR,
# TYPESAFE_API_URL, API_KEY, the STUB_* capture files, run_jev(), and
# balance_of().
# shellcheck source=../lib/fake-typesafe.sh
source "$REPO_ROOT/tests/lib/fake-typesafe.sh"

STATE="one concept: one repo: one observable behavior"

# ── AC1. a string-array pack is "unknown pack", pre-socket, credits unchanged ─
rm -f "$STUB_INVOKED" "$STUB_BODY_FILE"
# Drop the scratch string-array pack into the real packs/ tree.
BAD_PACK="$PACKS_DIR/stringpack.json"
printf '{"questions":["What is the one concept?", "What is the one behavior?"]}' \
  > "$BAD_PACK" \
  || { BAD_PACK=""; ac_fail "cannot create scratch pack at $PACKS_DIR/stringpack.json"; }

run_jev "$FP_A" "stringpack" "$STATE" "$API_KEY"
if [ "$RC" -ne 1 ]; then
  ac_fail "AC1: string-array pack should fail (rc=$RC, out=$OUT)"
fi
if [[ "$OUT" != '{"error":"unknown pack"}' ]]; then
  ac_fail "AC1: expected {\"error\":\"unknown pack\"}, got: $OUT"
fi
if [ -f "$STUB_INVOKED" ]; then
  ac_fail "AC1: stub invoked on a rejected string-array pack — no socket should open"
fi
if [[ "$(balance_of "$FP_A")" != 1 ]]; then
  ac_fail "AC1: rejected string-array pack debited FP_A (now $(balance_of "$FP_A"))"
fi
rm -f "$BAD_PACK"
BAD_PACK=""
ac_log "AC1: string-array pack -> unknown pack, not debited, no socket"

# ── AC2. scope posts its questions object and round-trips stdin state ────────
rm -f "$STUB_INVOKED" "$STUB_BODY_FILE" "$STUB_AUTH_FILE" "$STUB_URL_FILE"
run_jev "$FP_A" "scope" "$STATE" "$API_KEY" "200"
if [ "$RC" -ne 0 ]; then
  ac_fail "AC2: scope 200 jev should succeed (rc=$RC, out=$OUT)"
fi
if [ ! -f "$STUB_INVOKED" ]; then
  ac_fail "AC2: stub never invoked on the scope path"
fi
# .questions must equal the pack's questions object verbatim (the map of Nouls).
if ! [[ "$(jq -c '.questions' "$STUB_BODY_FILE")" \
      == "$(jq -c '.questions' "$SCOPE_PACK")" ]]; then
  ac_fail "AC2: POST .questions differ from the pack file (got $(jq -c '.questions' "$STUB_BODY_FILE"), want $(jq -c '.questions' "$SCOPE_PACK"))"
fi
# .state must round-trip stdin exactly (cap stays 32768; not raised).
if ! jq -e --arg s "$STATE" '.state == $s' "$STUB_BODY_FILE" >/dev/null 2>&1; then
  ac_fail "AC2: POST .state wrong: $(cat "$STUB_BODY_FILE")"
fi
ac_log "AC2: scope posts questions object verbatim + round-trips stdin state"

ac_pass