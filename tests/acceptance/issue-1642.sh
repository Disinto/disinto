#!/usr/bin/env bash
# =============================================================================
# tests/acceptance/issue-1642.sh
#
# Issue #1642: run claim checks; one miss contradicts the claim.
#
# tools/claim-checks.sh runs each id that has ${TAPE_DIR}/claims/<id>.current
# and passes claim_valid. A probe value that meets expect is one completed run
# and no outcome; a miss is one run plus an outcome with bits
# {contradicted: 1, held: 0}. A challenged claim appends nothing on the next
# run. A probe that exits 1 is one failed run and no outcome. A second run
# inside CLAIM_CHECK_INTERVAL_S appends nothing.
#
# gardener/gardener-run.sh calls the tool right after tools/claim-proposals.sh.
# A non-zero exit only logs a warning.
#
# Hermetic: no network, no forge, no agent. Fixture probes live in a temp
# OPS_REPO_ROOT; the tape and claim files live in temp TAPE_DIR and CLAIMS_DIR.
# The tool is executed, not sourced.
#
# Acceptance: `bash tests/acceptance/issue-1642.sh` exits 0 and calls ac_pass.
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=../../tests/lib/acceptance-helpers.sh
source "$REPO_ROOT/tests/lib/acceptance-helpers.sh"

ac_require_cmd bash jq flock python3 timeout date
ac_assert_file "$REPO_ROOT/tools/claim-checks.sh" "tools/claim-checks.sh is missing"
ac_assert_file "$REPO_ROOT/lib/probe.sh" "lib/probe.sh is missing"
ac_assert_file "$REPO_ROOT/lib/claims.sh" "lib/claims.sh is missing"
ac_assert_file "$REPO_ROOT/gardener/gardener-run.sh" "gardener/gardener-run.sh is missing"
ac_assert_file "$REPO_ROOT/gardener/AGENTS.md" "gardener/AGENTS.md is missing"

# The review (formula 3b) requires this sentence after the claim-proposals
# sentence. Wrapping is allowed; the words must appear in this order.
DOC_FLAT="$(tr '\n' ' ' < "$REPO_ROOT/gardener/AGENTS.md" | tr -s ' ')"
DOC_NEED='Then `tools/claim-checks.sh` (#1642) runs each proposed claim'"'"'s check at most once per `CLAIM_CHECK_INTERVAL_S` (default 86400); the first miss writes a `contradicted` outcome. A failure only logs a warning.'
printf '%s\n' "$DOC_FLAT" | grep -qF "$DOC_NEED" \
  || ac_fail "gardener/AGENTS.md must describe claim-checks.sh (#1642) after claim-proposals"
PROP_DOC=$(grep -n 'tools/claim-proposals.sh` (#1641)' "$REPO_ROOT/gardener/AGENTS.md" | head -n1 | cut -d: -f1)
CHECK_DOC=$(grep -n 'tools/claim-checks.sh` (#1642)' "$REPO_ROOT/gardener/AGENTS.md" | head -n1 | cut -d: -f1)
[ -n "$PROP_DOC" ] || ac_fail "gardener/AGENTS.md must still name tools/claim-proposals.sh (#1641)"
[ -n "$CHECK_DOC" ] || ac_fail "gardener/AGENTS.md must name tools/claim-checks.sh (#1642)"
[ "$PROP_DOC" -lt "$CHECK_DOC" ] \
  || ac_fail "claim-checks sentence (line $CHECK_DOC) must follow the claim-proposals sentence (line $PROP_DOC)"

# Wiring: the call sits after claim-proposals.sh and before detect_pr_number,
# and a non-zero exit is a warning, not a fatal under set -e.
GARDENER="$REPO_ROOT/gardener/gardener-run.sh"
PROP_LINE=$(grep -n 'tools/claim-proposals.sh' "$GARDENER" | grep '||' | head -n1 | cut -d: -f1)
CHECK_LINE=$(grep -n 'tools/claim-checks.sh' "$GARDENER" | grep '||' | head -n1 | cut -d: -f1)
DETECT_LINE=$(grep -n 'detect_pr_number "chore/gardener-"' "$GARDENER" | head -n1 | cut -d: -f1)
[ -n "$PROP_LINE" ] || ac_fail "gardener-run.sh must call tools/claim-proposals.sh"
[ -n "$CHECK_LINE" ] || ac_fail "gardener-run.sh must call tools/claim-checks.sh"
[ -n "$DETECT_LINE" ] || ac_fail "gardener-run.sh must call detect_pr_number"
[ "$PROP_LINE" -lt "$CHECK_LINE" ] \
  || ac_fail "claim-checks.sh (line $CHECK_LINE) must follow claim-proposals.sh (line $PROP_LINE)"
[ "$CHECK_LINE" -lt "$DETECT_LINE" ] \
  || ac_fail "claim-checks.sh (line $CHECK_LINE) must precede detect_pr_number (line $DETECT_LINE)"
grep -F 'tools/claim-checks.sh' "$GARDENER" | grep -q '||' \
  || ac_fail "claim-checks.sh must be guarded so a non-zero exit does not abort"
grep -qF 'claim-checks.sh failed' "$GARDENER" \
  || ac_fail "a non-zero claim-checks.sh must log a warning"
ac_log "wiring OK: claim-checks.sh follows claim-proposals.sh and a failure only warns"

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

OPS_REPO_ROOT="$TMP_DIR/ops"
CLAIMS_DIR="$TMP_DIR/claims"
TAPE_DIR="$TMP_DIR/tape"
PAYLOAD_DIR="$TMP_DIR/payloads"
mkdir -p "$OPS_REPO_ROOT/probes" "$CLAIMS_DIR" "$TAPE_DIR/claims" "$PAYLOAD_DIR"
export OPS_REPO_ROOT CLAIMS_DIR TAPE_DIR PAYLOAD_DIR

# write_claim ID CHECK — a valid claim whose expect is "<= 0.2".
write_claim() {
  local id="$1" check="$2"
  cat >"$CLAIMS_DIR/${id}.toml" <<EOF
statement = "the rate stays under the bound"
class     = "internal"
check     = "${check}"
expect    = "<= 0.2"
window    = "7d"
rests_on  = []
EOF
}

# write_probe REL BODY — a non-executable probe under the temp ops repo.
write_probe() {
  local rel="$1" body="$2" dest
  dest="$OPS_REPO_ROOT/$rel"
  mkdir -p "$(dirname "$dest")"
  printf '%s\n' '#!/usr/bin/env bash' "$body" >"$dest"
  chmod a-x "$dest"
}

# write_current ID PID — the proposal this claim's checks pair with.
write_current() {
  local id="$1" pid="$2"
  printf '%s\n' "$pid" >"$TAPE_DIR/claims/${id}.current"
}

# run_tool — execute the tool against the fixture dirs.
# stdout -> $OUT, stderr -> $ERR, exit status -> $RC.
run_tool() {
  RC=0
  OUT=""
  ERR=""
  (
    export OPS_REPO_ROOT CLAIMS_DIR TAPE_DIR PAYLOAD_DIR
    # The runner may have exported a real ops clone. The fixture is the only
    # probe source this test is allowed to run.
    bash "$REPO_ROOT/tools/claim-checks.sh"
  ) >"$TMP_DIR/out" 2>"$TMP_DIR/err" || RC=$?
  OUT="$(cat "$TMP_DIR/out" 2>/dev/null || true)"
  ERR="$(cat "$TMP_DIR/err" 2>/dev/null || true)"
}

tape_lines() {
  if [ -f "$TAPE_DIR/tape.jsonl" ]; then
    wc -l < "$TAPE_DIR/tape.jsonl" | tr -d '[:space:]'
  else
    printf '0\n'
  fi
}

# count_type PID TYPE — number of tape records of TYPE under PID.
count_type() {
  local pid="$1" type="$2"
  if [ ! -f "$TAPE_DIR/tape.jsonl" ]; then
    printf '0\n'
    return 0
  fi
  jq -s --arg pid "$pid" --arg type "$type" \
    '[.[] | select(.type == $type and .proposal_id == $pid)] | length' \
    "$TAPE_DIR/tape.jsonl"
}

# one_record PID TYPE — the single record, or empty.
one_record() {
  local pid="$1" type="$2"
  jq -sc --arg pid "$pid" --arg type "$type" \
    '[.[] | select(.type == $type and .proposal_id == $pid)] | .[0] // empty' \
    "$TAPE_DIR/tape.jsonl"
}

# ── AC1: probe prints 0.1, expect <= 0.2 — completed run, no outcome ────────
ac_log "AC1: probe 0.1 meets <= 0.2 — one completed run, no outcome, .last starts with 0.1"
write_claim rate-ok probes/ok.sh
write_probe probes/ok.sh 'echo 0.1'
write_current rate-ok pid-ok
# A valid claim with no proposal id must not be probed.
write_claim rate-unproposed probes/unproposed.sh
write_probe probes/unproposed.sh "echo ran > '$TMP_DIR/unproposed-ran'; echo 0.1"
run_tool
ac_assert_eq "$RC" "0" "met check must return 0 (got $RC): $OUT | $ERR"
[ -z "$ERR" ] || ac_fail "met check must not print stderr (got: $ERR)"
[ -z "$OUT" ] || ac_fail "met check must not print stdout (got: $OUT)"
ac_assert_eq "$(count_type pid-ok run)" "1" "met check must append exactly one run"
ac_assert_eq "$(count_type pid-ok outcome)" "0" "met check must append no outcome"
ac_assert_jq \
  '.organ == "gardener" and .agent == "bash" and .status == "completed" and .attempts == 1 and (.ended | type == "string") and (.started | type == "string") and (.cost.duration_s | type == "number") and .cost.duration_s >= 0' \
  "$(one_record pid-ok run)" \
  "met run must be a closed gardener/bash completed run under pid-ok"
LAST_OK="$TAPE_DIR/claims/rate-ok.last"
ac_assert_file "$LAST_OK" "<id>.last must be written when a value came back"
LAST_OK_TEXT="$(head -n 1 "$LAST_OK")"
case "$LAST_OK_TEXT" in
  "0.1 "*) ;;
  *) ac_fail "<id>.last must start with 0.1 (got '$LAST_OK_TEXT')" ;;
esac
printf '%s\n' "$LAST_OK_TEXT" | grep -qE '^0\.1 [0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$' \
  || ac_fail "<id>.last must be '<value> <iso time>' (got '$LAST_OK_TEXT')"
ac_assert_file "$TAPE_DIR/claims/rate-ok.checked" "<id>.checked must hold the epoch after a check"
[ ! -f "$TMP_DIR/unproposed-ran" ] \
  || ac_fail "a claim with no .current must not be probed"
ac_log "AC1 OK: one completed run, no outcome, .last starts with 0.1"

# ── AC5 (also after a met check): a second run inside the interval ───────────
ac_log "AC5: a second run inside the interval appends nothing"
write_probe probes/ok.sh "echo ran > '$TMP_DIR/interval-ran'; echo 9"
LINES_BEFORE="$(tape_lines)"
run_tool
ac_assert_eq "$RC" "0" "interval skip must return 0 (got $RC): $OUT | $ERR"
ac_assert_eq "$(tape_lines)" "$LINES_BEFORE" \
  "a second run inside the interval must append nothing (was $LINES_BEFORE, now $(tape_lines))"
ac_assert_eq "$(count_type pid-ok run)" "1" "interval skip must leave the one completed run"
[ ! -f "$TMP_DIR/interval-ran" ] || ac_fail "interval skip must not re-run the probe"
case "$(head -n 1 "$LAST_OK")" in
  "0.1 "*) ;;
  *) ac_fail "interval skip must not rewrite .last (got '$(head -n 1 "$LAST_OK")')" ;;
esac
ac_log "AC5 OK: second run inside the interval appended nothing"

# ── AC2: probe prints 0.5 — one run and one contradicted outcome ─────────────
ac_log "AC2: probe 0.5 misses <= 0.2 — one run and one contradicted outcome"
write_claim rate-miss probes/miss.sh
write_probe probes/miss.sh 'echo 0.5'
write_current rate-miss pid-miss
run_tool
ac_assert_eq "$RC" "0" "miss check must return 0 (got $RC): $OUT | $ERR"
[ -z "$ERR" ] || ac_fail "miss check must not print stderr (got: $ERR)"
ac_assert_eq "$(count_type pid-miss run)" "1" "miss must append exactly one run"
ac_assert_eq "$(count_type pid-miss outcome)" "1" "miss must append exactly one outcome"
ac_assert_eq "$(count_type pid-ok run)" "1" "the met claim's run must stay one"
ac_assert_jq \
  '.status == "completed" and .organ == "gardener" and .agent == "bash" and .proposal_id == "pid-miss"' \
  "$(one_record pid-miss run)" \
  "miss run must be completed under pid-miss"
ac_assert_jq \
  '.bits == {"contradicted": 1, "held": 0} and .numbers.value == 0.5 and .children == {} and .payloads == []' \
  "$(one_record pid-miss outcome)" \
  "miss outcome must be bits {contradicted: 1, held: 0} and numbers.value 0.5"
ac_log "AC2 OK: one run and one contradicted outcome with value 0.5"

# ── AC3: a run after the contradiction appends nothing ───────────────────────
ac_log "AC3: a run after the contradiction appends nothing"
# Drop the interval mark and point the probe at a value that would meet
# expect, so only the contradicted outcome can explain an empty append.
rm -f "$TAPE_DIR/claims/rate-miss.checked"
write_probe probes/miss.sh "echo ran > '$TMP_DIR/challenged-ran'; echo 0.1"
LINES_BEFORE="$(tape_lines)"
run_tool
ac_assert_eq "$RC" "0" "challenged skip must return 0 (got $RC): $OUT | $ERR"
ac_assert_eq "$(tape_lines)" "$LINES_BEFORE" \
  "a run after contradicted must append nothing (was $LINES_BEFORE, now $(tape_lines))"
ac_assert_eq "$(count_type pid-miss run)" "1" "challenged claim must keep its one run"
ac_assert_eq "$(count_type pid-miss outcome)" "1" "challenged claim must keep its one outcome"
[ ! -f "$TMP_DIR/challenged-ran" ] || ac_fail "a challenged claim must not re-run the probe"
ac_log "AC3 OK: a run after contradicted appended nothing"

# ── AC4: a probe exiting 1 — one failed run, no outcome ──────────────────────
ac_log "AC4: a probe exiting 1 — one failed run, no outcome"
write_claim rate-fail probes/fail.sh
write_probe probes/fail.sh 'echo noisy >&2; exit 1'
write_current rate-fail pid-fail
run_tool
ac_assert_eq "$RC" "0" "failed probe must not fail the tool (got $RC): $OUT | $ERR"
[ -z "$ERR" ] || ac_fail "failed probe must not print tool stderr (got: $ERR)"
ac_assert_eq "$(count_type pid-fail run)" "1" "failed probe must append exactly one run"
ac_assert_eq "$(count_type pid-fail outcome)" "0" "failed probe must append no outcome"
ac_assert_jq \
  '.status == "failed" and .organ == "gardener" and .agent == "bash" and .proposal_id == "pid-fail" and .attempts == 1' \
  "$(one_record pid-fail run)" \
  "probe exit 1 must be a failed closed run under pid-fail"
[ ! -f "$TAPE_DIR/claims/rate-fail.last" ] \
  || ac_fail "a probe that returns no value must not write <id>.last"
ac_assert_file "$TAPE_DIR/claims/rate-fail.checked" \
  "a failed probe still records <id>.checked so the interval applies"
ac_log "AC4 OK: one failed run, no outcome"

# ── AC5: a second run of the failed probe inside the interval ────────────────
ac_log "AC5b: a second run of the failed probe inside the interval appends nothing"
LINES_BEFORE="$(tape_lines)"
run_tool
ac_assert_eq "$RC" "0" "failed-probe interval skip must return 0 (got $RC): $OUT | $ERR"
ac_assert_eq "$(tape_lines)" "$LINES_BEFORE" \
  "a second failed-probe run inside the interval must append nothing"
ac_assert_eq "$(count_type pid-fail run)" "1" "failed probe must still have exactly one run"
ac_assert_eq "$(count_type pid-fail outcome)" "0" "failed probe must still have no outcome"
ac_log "AC5b OK: second failed-probe run inside the interval appended nothing"

ac_pass
