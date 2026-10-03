#!/usr/bin/env bash
# =============================================================================
# tests/acceptance/issue-1641.sh
#
# Issue #1641: a merged claim becomes a claim-loop proposal.
#
# tools/claim-proposals.sh turns each id from claim_ids into a claim-loop
# proposal. A revision already on the tape (marker ${TAPE_DIR}/claims/<id>.<sha>)
# is skipped. An invalid claim logs one line and appends nothing. A deleted
# claim file gets nothing — retiring a claim is its merge.
#
# gardener/gardener-run.sh calls the tool right after refresh_ops_calibration,
# before any sprint tool. A non-zero exit only logs a warning.
#
# Hermetic: no network, no forge, no agent — a temp TAPE_DIR, CLAIMS_DIR, and
# PAYLOAD_DIR. The tool is executed, not sourced.
#
# Acceptance: `bash tests/acceptance/issue-1641.sh` exits 0 and calls ac_pass.
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=../../tests/lib/acceptance-helpers.sh
source "$REPO_ROOT/tests/lib/acceptance-helpers.sh"

ac_require_cmd bash jq sha256sum flock python3
ac_assert_file "$REPO_ROOT/tools/claim-proposals.sh" "tools/claim-proposals.sh is missing"
ac_assert_file "$REPO_ROOT/lib/claims.sh" "lib/claims.sh is missing"
ac_assert_file "$REPO_ROOT/gardener/gardener-run.sh" "gardener/gardener-run.sh is missing"
ac_assert_file "$REPO_ROOT/gardener/AGENTS.md" "gardener/AGENTS.md is missing"

# The review (formula 3b) requires this sentence in the same change.
grep -qF 'tools/claim-proposals.sh` (#1641)' "$REPO_ROOT/gardener/AGENTS.md" \
  || ac_fail "gardener/AGENTS.md must name tools/claim-proposals.sh (#1641)"
grep -qF 'turns each new or' "$REPO_ROOT/gardener/AGENTS.md" \
  || ac_fail "gardener/AGENTS.md must describe claim-proposals.sh"
grep -qF 'revised claim file in `${OPS_REPO_ROOT}/claims/`' "$REPO_ROOT/gardener/AGENTS.md" \
  || ac_fail "gardener/AGENTS.md must name the claims dir the tool reads"
grep -qF 'A failure only logs a warning.' "$REPO_ROOT/gardener/AGENTS.md" \
  || ac_fail "gardener/AGENTS.md must say a claim-proposals failure only logs a warning"

# Wiring: the call sits after refresh_ops_calibration and before detect_pr
# (no sprint tool exists yet; the call must still precede the next step), and
# a non-zero exit is a warning, not a fatal under set -e.
GARDENER="$REPO_ROOT/gardener/gardener-run.sh"
CAL_LINE=$(grep -n '^refresh_ops_calibration$' "$GARDENER" | head -n1 | cut -d: -f1)
CLAIM_LINE=$(grep -n 'tools/claim-proposals.sh' "$GARDENER" | head -n1 | cut -d: -f1)
DETECT_LINE=$(grep -n 'detect_pr_number "chore/gardener-"' "$GARDENER" | head -n1 | cut -d: -f1)
[ -n "$CAL_LINE" ] || ac_fail "gardener-run.sh must call refresh_ops_calibration"
[ -n "$CLAIM_LINE" ] || ac_fail "gardener-run.sh must call tools/claim-proposals.sh"
[ -n "$DETECT_LINE" ] || ac_fail "gardener-run.sh must call detect_pr_number"
[ "$CAL_LINE" -lt "$CLAIM_LINE" ] \
  || ac_fail "claim-proposals.sh (line $CLAIM_LINE) must follow refresh_ops_calibration (line $CAL_LINE)"
[ "$CLAIM_LINE" -lt "$DETECT_LINE" ] \
  || ac_fail "claim-proposals.sh (line $CLAIM_LINE) must precede detect_pr_number (line $DETECT_LINE)"
grep -F 'tools/claim-proposals.sh' "$GARDENER" | grep -q '||' \
  || ac_fail "claim-proposals.sh must be guarded so a non-zero exit does not abort"
grep -qF 'claim-proposals.sh failed' "$GARDENER" \
  || ac_fail "a non-zero claim-proposals.sh must log a warning"
ac_log "wiring OK: claim-proposals.sh follows refresh_ops_calibration and a failure only warns"

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

CLAIMS_DIR="$TMP_DIR/claims"
TAPE_DIR="$TMP_DIR/tape"
PAYLOAD_DIR="$TMP_DIR/payloads"
mkdir -p "$CLAIMS_DIR" "$TAPE_DIR" "$PAYLOAD_DIR"

# The example from #1640, as claims/dev-comes-back.toml.
write_claim() {
  local expect="${1:-<= 0.2}"
  cat >"$CLAIMS_DIR/dev-comes-back.toml" <<EOF
statement = "a dev proposal comes back, merged or rejected, within 48 hours"
class     = "internal"
check     = "probes/dev-unreturned.sh"
expect    = "${expect}"
window    = "7d"
rests_on  = []
EOF
}

write_claim "<= 0.2"

# run_tool — execute the tool against the fixture dirs.
# stdout -> $OUT, stderr -> $ERR, exit status -> $RC.
run_tool() {
  RC=0
  OUT=""
  ERR=""
  (
    export TAPE_DIR CLAIMS_DIR PAYLOAD_DIR
    # The runner may have exported OPS_REPO_ROOT / PROJECT_TOML. The fixture
    # dir is the only claim source this test is allowed to read.
    unset OPS_REPO_ROOT PROJECT_TOML || true
    bash "$REPO_ROOT/tools/claim-proposals.sh"
  ) >"$TMP_DIR/out" 2>"$TMP_DIR/err" || RC=$?
  OUT="$(cat "$TMP_DIR/out" 2>/dev/null || true)"
  ERR="$(cat "$TMP_DIR/err" 2>/dev/null || true)"
}

tape_lines() {
  if [ -f "$TAPE_DIR/tape.jsonl" ]; then
    wc -l < "$TAPE_DIR/tape.jsonl" | tr -d ' '
  else
    printf '0\n'
  fi
}

current_id() {
  tr -d '[:space:]' < "$TAPE_DIR/claims/dev-comes-back.current"
}

# ── AC1: one claim proposal, payload holds the claim text, .current names it ─
ac_log "AC1: dev-comes-back becomes one claim proposal"
run_tool
ac_assert_eq "$RC" "0" "first run must return 0 (got $RC): $OUT | $ERR"
[ -z "$ERR" ] || ac_fail "first run must not print stderr (got: $ERR)"
[ -z "$OUT" ] || ac_fail "first run must not print stdout (got: $OUT)"
ac_assert_eq "$(tape_lines)" "1" \
  "first run must append exactly one proposal (got $(tape_lines))"

LINE="$(head -n1 "$TAPE_DIR/tape.jsonl")"
ac_assert_jq '.type == "proposal" and .loop == "claim" and .class == "internal"
    and .decision == "approved" and .ref == "claims/dev-comes-back.toml"
    and .context == {} and (.parent | not) and (.caused_by | not)
    and (.forecast | not) and (.payloads | type == "array" and length == 1)' \
  "$LINE" "record must be an approved claim proposal with one payload"

PROP_ID="$(jq -r '.id' <<<"$LINE")"
[ -n "$PROP_ID" ] || ac_fail "proposal must have an id"
ac_assert_file "$TAPE_DIR/claims/dev-comes-back.current" \
  "<id>.current was not written"
ac_assert_eq "$(current_id)" "$PROP_ID" \
  "<id>.current must hold the proposal id (got '$(current_id)')"

PAYLOAD_HASH="$(jq -r '.payloads[0]' <<<"$LINE")"
ac_assert_file "$PAYLOAD_DIR/$PAYLOAD_HASH" \
  "payloads entry must name a file under PAYLOAD_DIR (got $PAYLOAD_HASH)"
cmp -s "$CLAIMS_DIR/dev-comes-back.toml" "$PAYLOAD_DIR/$PAYLOAD_HASH" \
  || ac_fail "payload file must hold the claim text"

SHA="$(sha256sum "$CLAIMS_DIR/dev-comes-back.toml" | cut -d' ' -f1)"
ac_assert_file "$TAPE_DIR/claims/dev-comes-back.$SHA" \
  "revision marker <id>.<sha> was not written"
ac_assert_eq "$(tr -d '[:space:]' < "$TAPE_DIR/claims/dev-comes-back.$SHA")" "$PROP_ID" \
  "revision marker must hold the proposal id"
ac_log "AC1 OK: one claim proposal, payload holds the claim text, .current names it"

# ── AC2: a second run appends nothing ────────────────────────────────────────
ac_log "AC2: second run appends nothing"
run_tool
ac_assert_eq "$RC" "0" "second run must return 0 (got $RC): $OUT | $ERR"
ac_assert_eq "$(tape_lines)" "1" \
  "second run must append nothing (got $(tape_lines) lines)"
ac_assert_eq "$(current_id)" "$PROP_ID" \
  "second run must leave <id>.current unchanged"
ac_log "AC2 OK: second run appended nothing"

# ── AC3: a revised expect is a second proposal; .current names it ────────────
ac_log "AC3: revised expect appends a second proposal"
write_claim "<= 0.1"
run_tool
ac_assert_eq "$RC" "0" "revised run must return 0 (got $RC): $OUT | $ERR"
ac_assert_eq "$(tape_lines)" "2" \
  "revised expect must append a second proposal (got $(tape_lines) lines)"

LINE2="$(tail -n1 "$TAPE_DIR/tape.jsonl")"
ac_assert_jq '.type == "proposal" and .loop == "claim" and .class == "internal"
    and .decision == "approved" and .ref == "claims/dev-comes-back.toml"
    and (.payloads | type == "array" and length == 1)' \
  "$LINE2" "second record must be a claim proposal for the revised file"
PROP_ID2="$(jq -r '.id' <<<"$LINE2")"
[ "$PROP_ID2" != "$PROP_ID" ] \
  || ac_fail "revised proposal must be a fresh id (got $PROP_ID2)"
ac_assert_eq "$(current_id)" "$PROP_ID2" \
  "<id>.current must name the revised proposal (got '$(current_id)')"
HASH2="$(jq -r '.payloads[0]' <<<"$LINE2")"
cmp -s "$CLAIMS_DIR/dev-comes-back.toml" "$PAYLOAD_DIR/$HASH2" \
  || ac_fail "revised payload must hold the revised claim text"
# The first revision's marker is still there; the new sha has its own.
[ -f "$TAPE_DIR/claims/dev-comes-back.$SHA" ] \
  || ac_fail "the first revision marker must remain"
SHA2="$(sha256sum "$CLAIMS_DIR/dev-comes-back.toml" | cut -d' ' -f1)"
[ "$SHA2" != "$SHA" ] || ac_fail "revised claim must have a different sha"
ac_assert_file "$TAPE_DIR/claims/dev-comes-back.$SHA2" \
  "revised revision marker was not written"
ac_log "AC3 OK: second proposal appended and <id>.current names it"

# A deleted claim file gets nothing: retiring a claim is its merge.
ac_log "deleted claim appends nothing"
rm -f "$CLAIMS_DIR/dev-comes-back.toml"
run_tool
ac_assert_eq "$RC" "0" "deleted-claim run must return 0 (got $RC): $OUT | $ERR"
ac_assert_eq "$(tape_lines)" "2" \
  "a deleted claim must append nothing (got $(tape_lines) lines)"
ac_log "deleted claim OK: tape unchanged"

# ── AC4: an invalid claim appends nothing ────────────────────────────────────
ac_log "AC4: invalid claim appends nothing"
rm -rf "$TAPE_DIR" "$CLAIMS_DIR" "$PAYLOAD_DIR"
mkdir -p "$TAPE_DIR" "$CLAIMS_DIR" "$PAYLOAD_DIR"
cat >"$CLAIMS_DIR/dev-comes-back.toml" <<'EOF'
statement = "a dev proposal comes back, merged or rejected, within 48 hours"
class     = "internal"
check     = "probes/dev-unreturned.sh"
expect    = "<= 0.2"
window    = "soon"
rests_on  = []
EOF
run_tool
ac_assert_eq "$RC" "0" "invalid claim must not fail the tool (got $RC): $OUT | $ERR"
ac_assert_eq "$(tape_lines)" "0" "invalid claim must append nothing"
[ ! -e "$TAPE_DIR/claims/dev-comes-back.current" ] \
  || ac_fail "invalid claim must not write <id>.current"
# One log line, naming the claim. claim_valid's own stderr is not a second line.
ac_assert_eq "$(printf '%s\n' "$OUT" | grep -c . || true)" "1" \
  "invalid claim must log exactly one line (got: $OUT)"
case "$OUT" in
  *dev-comes-back*) ;;
  *) ac_fail "the log line must name the invalid claim (got: $OUT)" ;;
esac
[ -z "$ERR" ] || ac_fail "invalid claim must not also print stderr (got: $ERR)"
ac_log "AC4 OK: invalid claim appended nothing"

# ── AC5: an unwritable payload store omits payloads ──────────────────────────
# tape_payload echoes the hash and returns 0 when mkdir/cp fail (set -e is
# inactive inside the command substitution). The proposal must not keep that
# dangling hash. A regular file (not a mode-555 directory) is unwritable even
# for root, which is what CI runs as.
ac_log "AC5: unwritable PAYLOAD_DIR omits the payloads field"
rm -rf "$TAPE_DIR" "$CLAIMS_DIR" "$PAYLOAD_DIR"
mkdir -p "$TAPE_DIR" "$CLAIMS_DIR"
PAYLOAD_DIR="$TMP_DIR/payloads-unwritable"
: > "$PAYLOAD_DIR"
write_claim "<= 0.2"
run_tool
ac_assert_eq "$RC" "0" \
  "unwritable payload store must not fail the tool (got $RC): $OUT | $ERR"
ac_assert_eq "$(tape_lines)" "1" \
  "unwritable payload store must still append one proposal (got $(tape_lines))"
LINE="$(head -n1 "$TAPE_DIR/tape.jsonl")"
ac_assert_jq '.type == "proposal" and .loop == "claim" and .class == "internal"
    and .decision == "approved" and .ref == "claims/dev-comes-back.toml"
    and (has("payloads") | not)' "$LINE" \
  "a failed payload store must append with no payloads field"
SHA="$(sha256sum "$CLAIMS_DIR/dev-comes-back.toml" | cut -d' ' -f1)"
[ ! -e "${PAYLOAD_DIR}/${SHA}" ] \
  || ac_fail "payload file must not exist when the store is unwritable"
ac_assert_file "$TAPE_DIR/claims/dev-comes-back.current" \
  "the proposal must still be recorded in <id>.current"
ac_log "AC5 OK: unwritable payload store appended a proposal with no payloads field"

ac_pass "issue #1641: a merged claim becomes a claim-loop proposal"
