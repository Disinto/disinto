#!/usr/bin/env bash
# =============================================================================
# tests/acceptance/issue-2055.sh
#
# Issue #2055: a suspended remedy drafts its can-fix claim.
#
#   1. repair_claim_pr boom "supervisor/actions/marker.sh" suspended "10 12"
#      against a stub forge: returns 0 and prints 42; the calls include
#      POST /branches, PUT /contents/claims/can-fix-boom.toml,
#      PUT /contents/probes/can-fix-boom.sh and POST /pulls whose title
#      contains "claims: can-fix-boom (suspended". The PUT payloads carry
#      no author/committer.
#   2. The drafted claim passes lib/claims.sh claim_valid; its first line
#      names the state and the counts ("suspended", "10 of the last 12").
#   3. When main already has probes/can-fix-boom.sh, the probe PUT is skipped.
#   4. When a PR titled "claims: can-fix-boom ..." is already open, the
#      function prints its number (41) and files nothing.
#   5. The lifted revision: title carries "(lifted", the claim's first line
#      says "lifted".
#   6. A bad CONDITION (Bad_Name) returns 1 before any call.
#   7. With the forge unreachable, repair_claim_pr returns 1 with exactly
#      one stderr line.
#   8. A failed POST /branches is accepted when GET /branches/<branch>
#      shows the branch (the draft still opens).
#   9. The drafted probe prints cleared/acted over the repair tape:
#      0.25 for 4 acted outcomes, one cleared; with no acted outcome in
#      the window it prints nothing, one stderr line, exit 1.
#   10. supervisor-run.sh sources lib/repair-claim.sh after lib/notice.sh,
#      calls repair_claim_pr "$name" exactly twice, and both files parse.
#      The two AGENTS.md rows are present.
#
# Hermetic: no network, no live services. A stub curl on PATH records every
# call to $CALLS_FILE and answers from canned JSON.
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../lib/acceptance-helpers.sh
source "$REPO_ROOT/tests/lib/acceptance-helpers.sh"

ac_require_cmd bash jq grep sed date mktemp base64

LIB="$REPO_ROOT/lib/repair-claim.sh"
TARGET="$REPO_ROOT/supervisor/supervisor-run.sh"
ac_assert_file "$LIB" "lib/repair-claim.sh must exist"
ac_assert_file "$TARGET" "supervisor/supervisor-run.sh must exist"

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

# ── the stub forge ───────────────────────────────────────────────────────────
STUB_DIR="$TMP_DIR/stub"
mkdir -p "$STUB_DIR"
cat > "$STUB_DIR/curl" <<'STUB_EOF'
#!/usr/bin/env bash
# Fake ops-repo forge API for #2055. Every call is recorded as one JSON line
# {method,url,payload} into $CALLS_FILE. AC_STUB_FAIL=1 makes every call fail
# (exit 22, like an unreachable API). STUB_OPEN=1 lists an open draft PR;
# STUB_PROBE_EXISTS=1 says main already holds the probe; STUB_BRANCH_FAIL=1
# makes POST /branches fail while GET /branches/<name> still shows it.
method=GET url="" payload=""
while [ $# -gt 0 ]; do
  case "$1" in
    -X) method="${2:-GET}"; shift 2 ;;
    -d) payload="${2:-}"; shift 2 ;;
    http*) url="$1"; shift ;;
    *) shift ;;
  esac
done
if [ -n "${CALLS_FILE:-}" ]; then
  jq -n --arg m "$method" --arg u "$url" --arg p "$payload" \
    '{method: $m, url: $u, payload: $p}' >> "$CALLS_FILE"
fi
if [ "${AC_STUB_FAIL:-0}" = "1" ]; then
  exit 22
fi
case "$url" in
  */pulls\?state=open*)
    if [ "${STUB_OPEN:-0}" = "1" ]; then
      printf '[{"number":41,"title":"claims: can-fix-boom (suspended 2026-01-01T00:00:00Z)"}]\n'
    else
      printf '[]\n'
    fi
    ;;
  */pulls)
    if [ "$method" = POST ]; then
      printf '{"number":42}\n'
    else
      exit 22
    fi
    ;;
  */branches)
    if [ "$method" = POST ]; then
      if [ "${STUB_BRANCH_FAIL:-0}" = "1" ]; then exit 22; fi
      printf '{"name":"created"}\n'
    else
      exit 22
    fi
    ;;
  */branches/*)
    if [ "$method" = GET ]; then
      name="${url#*/branches/}"
      printf '{"name":"%s"}\n' "${name%%\?*}"
    else
      exit 22
    fi
    ;;
  */contents/probes/*)
    if [ "$method" = GET ]; then
      if [ "${STUB_PROBE_EXISTS:-0}" = "1" ]; then
        printf '{"sha":"deadbeef"}\n'
      else
        exit 22
      fi
    else
      printf '{"commit":{"sha":"c0ffee"}}\n'
    fi
    ;;
  *)
    if [ "$method" = PUT ]; then
      printf '{"commit":{"sha":"c0ffee"}}\n'
    else
      exit 22
    fi
    ;;
esac
STUB_EOF
chmod +x "$STUB_DIR/curl"

export PATH="$STUB_DIR:$PATH"
export FORGE_TOKEN="stub-token"
export FORGE_API_BASE="http://forge.example/api/v1"
export FORGE_OPS_REPO="o/ops"
export PRIMARY_BRANCH="main"
CALLS_FILE="$TMP_DIR/calls.jsonl"
export CALLS_FILE

# run_claim CONDITION SCRIPT STATE COUNTS — one repair_claim_pr call against
# the stub; sets the globals RC/OUT/ERR and truncates the call log first.
run_claim() {
  : > "$CALLS_FILE"
  ac_run_block "$LIB" repair_claim_pr "$1" "$2" "$3" "$4"
}

# call_count METHOD URL_SUBSTR — number of recorded stub calls.
call_count() {
  jq -s --arg m "$1" --arg s "$2" \
    'map(select(.method == $m and (.url | contains($s)))) | length' "$CALLS_FILE"
}

# call_payload METHOD URL_SUBSTR — payload of the first matching call, empty
# when there is none.
call_payload() {
  jq -sr --arg m "$1" --arg s "$2" \
    'map(select(.method == $m and (.url | contains($s)))) | first | .payload // empty' "$CALLS_FILE"
}

# ── AC 1: a suspended remedy drafts the claim PR ─────────────────────────────
ac_log "AC 1: repair_claim_pr boom ... suspended '10 12' opens the draft and prints 42"
run_claim boom "supervisor/actions/marker.sh" suspended "10 12"
ac_assert_eq "$RC" "0" "the draft call must return 0 (got $RC): $ERR"
ac_assert_eq "$OUT" "42" "the function must print the PR number 42 (got '$OUT')"
ac_assert_eq "$(call_count POST /branches)" "1" "the draft must create its branch via POST /branches"
ac_assert_eq "$(call_count PUT /contents/claims/can-fix-boom.toml)" "1" "the draft must PUT the claim file"
ac_assert_eq "$(call_count PUT /contents/probes/can-fix-boom.sh)" "1" "the draft must PUT the probe file when main lacks it"
ac_assert_eq "$(call_count POST /pulls)" "1" "the draft must POST exactly one PR"

claim_payload="$(call_payload PUT /contents/claims/can-fix-boom.toml)"
branch="$(printf '%s' "$claim_payload" | jq -r '.branch // empty')"
[[ "$branch" =~ ^claims/can-fix-boom-[0-9]{12}$ ]] \
  || ac_fail "the branch must be claims/can-fix-boom-<YYYYmmddHHMM>, got: '$branch'"
ac_assert_eq "$(printf '%s' "$claim_payload" | jq -r '.message // empty')" \
  "claims: can-fix-boom suspended" "the commit message must be 'claims: <id> <STATE>'"
ac_assert_jq '(has("author") or has("committer")) | not' "$claim_payload" \
  "the PUT payload must carry no author or committer"

mkdir -p "$TMP_DIR/claims"
printf '%s' "$claim_payload" | jq -r '.content // empty' | base64 -d > "$TMP_DIR/claims/can-fix-boom.toml"
first_line="$(head -n 1 "$TMP_DIR/claims/can-fix-boom.toml")"
for needle in 'Drafted by the supervisor: suspended' '10 of the last 12' 'proposal-loop.md §5'; do
  case "$first_line" in
    *"$needle"*) ;;
    *) ac_fail "the claim's first line must contain '$needle', got: $first_line" ;;
  esac
done
grep -qF 'statement = "the boom remedy (supervisor/actions/marker.sh) clears the condition it acts on"' \
  "$TMP_DIR/claims/can-fix-boom.toml" || ac_fail "the claim must state what the remedy does"
grep -qF 'class = "internal"' "$TMP_DIR/claims/can-fix-boom.toml" || ac_fail "the claim class must be internal"
grep -qF 'check = "probes/can-fix-boom.sh"' "$TMP_DIR/claims/can-fix-boom.toml" || ac_fail "the claim check must point at the drafted probe"
grep -qF 'expect = ">= 0.5"' "$TMP_DIR/claims/can-fix-boom.toml" || ac_fail "the claim expect must be '>= 0.5'"
grep -qF 'window = "7d"' "$TMP_DIR/claims/can-fix-boom.toml" || ac_fail "the claim window must be '7d'"
grep -qF 'rests_on = []' "$TMP_DIR/claims/can-fix-boom.toml" || ac_fail "the claim must rest on nothing"

ac_log "AC 1b: the drafted claim passes claim_valid"
CLAIMS_DIR="$TMP_DIR/claims" ac_run_block "$REPO_ROOT/lib/claims.sh" claim_valid can-fix-boom
ac_assert_eq "$RC" "0" "the drafted claim must be a valid claim (claim_valid failed: $ERR)"

pull_payload="$(call_payload POST /pulls)"
title="$(printf '%s' "$pull_payload" | jq -r '.title // empty')"
case "$title" in
  "claims: can-fix-boom (suspended "*) ;;
  *) ac_fail "the PR title must be 'claims: <id> (suspended <ISO date>)', got: '$title'" ;;
esac
ac_assert_eq "$(printf '%s' "$pull_payload" | jq -r '.base // empty')" "main" "the PR base must be the primary branch"
ac_assert_eq "$(printf '%s' "$pull_payload" | jq -r '.head // empty')" "$branch" "the PR head must be the drafted branch"
body="$(printf '%s' "$pull_payload" | jq -r '.body // empty')"
for needle in \
  'the boom remedy (supervisor/actions/marker.sh) clears the condition it acts on' \
  '10 of the last 12 tries failed' \
  'Drafted by the supervisor (proposal-loop.md §5)' \
  'The gate merges it' \
  'tools/claim-proposals.sh' \
  'checked afresh'; do
  case "$body" in
    *"$needle"*) ;;
    *) ac_fail "the PR body must contain '$needle', got: $body" ;;
  esac
done

# Keep the drafted probe for AC 9.
printf '%s' "$(call_payload PUT /contents/probes/can-fix-boom.sh)" \
  | jq -r '.content // empty' | base64 -d > "$TMP_DIR/draft-probe.sh"
chmod +x "$TMP_DIR/draft-probe.sh"
# shellcheck disable=SC2016  # literal source text of the drafted probe
grep -qF 'tape="${TAPE_DIR:-/srv/disinto/tape}/tape.jsonl"' "$TMP_DIR/draft-probe.sh" \
  || ac_fail "the probe must read the repair tape at the documented default path"
# shellcheck disable=SC2016  # literal source text of the drafted probe
grep -qF 'window="${PROBE_WINDOW_DAYS:-7}"' "$TMP_DIR/draft-probe.sh" \
  || ac_fail "the probe must honour PROBE_WINDOW_DAYS with default 7"

# ── AC 2: main already has the probe -> no probe PUT ─────────────────────────
ac_log "AC 2: when main holds probes/can-fix-boom.sh the draft skips the probe PUT"
STUB_PROBE_EXISTS=1 run_claim boom "supervisor/actions/marker.sh" suspended "10 12"
ac_assert_eq "$RC" "0" "the draft must still succeed (got $RC): $ERR"
ac_assert_eq "$OUT" "42" "the draft must print 42 (got '$OUT')"
ac_assert_eq "$(call_count PUT /contents/probes/can-fix-boom.sh)" "0" "an existing probe must not be rewritten"
ac_assert_eq "$(call_count PUT /contents/claims/can-fix-boom.toml)" "1" "the claim file must still be PUT"

# ── AC 3: one open draft per claim ────────────────────────────────────────────
ac_log "AC 3: an open 'claims: can-fix-boom' PR short-circuits the draft"
STUB_OPEN=1 run_claim boom "supervisor/actions/marker.sh" suspended "10 12"
ac_assert_eq "$RC" "0" "the open-draft path must return 0 (got $RC)"
ac_assert_eq "$OUT" "41" "the function must print the existing PR number (got '$OUT')"
ac_assert_eq "$(call_count POST /pulls)" "0" "no second PR may be opened"
ac_assert_eq "$(call_count PUT /contents/)" "0" "no content may be written when a draft is open"

# ── AC 4: the lift drafts the revision ────────────────────────────────────────
ac_log "AC 4: state lifted — the PR title and the claim's first line say lifted"
run_claim boom "supervisor/actions/marker.sh" lifted "3 4"
ac_assert_eq "$RC" "0" "the lifted draft must return 0 (got $RC): $ERR"
ac_assert_eq "$OUT" "42" "the lifted draft must print 42 (got '$OUT')"
title="$(call_payload POST /pulls | jq -r '.title // empty')"
case "$title" in
  "claims: can-fix-boom (lifted "*) ;;
  *) ac_fail "the lifted PR title must be 'claims: <id> (lifted <ISO date>)', got: '$title'" ;;
esac
first_line="$(printf '%s' "$(call_payload PUT /contents/claims/can-fix-boom.toml)" \
  | jq -r '.content // empty' | base64 -d | head -n 1)"
case "$first_line" in
  *"lifted"*"3 of the last 4"*) ;;
  *) ac_fail "the lifted claim's first line must record the state and counts, got: $first_line" ;;
esac

# ── AC 5: an unsafe condition is refused before any call ──────────────────────
ac_log "AC 5a: CONDITION 'Bad_Name' returns 1 with no forge call"
run_claim Bad_Name "supervisor/actions/marker.sh" suspended "1 2"
ac_assert_eq "$RC" "1" "a CONDITION with an uppercase letter must be refused (got $RC)"
ac_assert_eq "$(call_count GET /)" "0" "the refusal must happen before any forge call"

ac_log "AC 5b: an unknown STATE returns 1 with no forge call"
run_claim boom "supervisor/actions/marker.sh" unknown "1 2"
ac_assert_eq "$RC" "1" "STATE must be suspended or lifted (got $RC)"
ac_assert_eq "$(call_count GET /)" "0" "the refusal must happen before any forge call"

# ── AC 6: a failed forge call fails with exactly one stderr line ──────────────
ac_log "AC 6: AC_STUB_FAIL=1 — repair_claim_pr returns 1 with one stderr line"
AC_STUB_FAIL=1 run_claim boom "supervisor/actions/marker.sh" suspended "10 12"
ac_assert_eq "$RC" "1" "an unreachable forge must return 1 (got $RC)"
err_lines="$(printf '%s\n' "$ERR" | grep -c 'repair-claim:' || true)"
ac_assert_eq "$err_lines" "1" "the failure must print exactly one stderr line (got: $ERR)"

# ── AC 7: a failed branch create is accepted when the branch shows up ─────────
ac_log "AC 7: POST /branches failing is accepted when GET /branches shows the branch"
STUB_BRANCH_FAIL=1 run_claim boom "supervisor/actions/marker.sh" suspended "10 12"
ac_assert_eq "$RC" "0" "the existing-branch fallback must let the draft succeed (got $RC): $ERR"
ac_assert_eq "$OUT" "42" "the fallback path must still print the PR number (got '$OUT')"
ac_assert_eq "$(call_count GET /branches/)" "1" "the fallback must verify the branch with GET /branches/<branch>"

# ── AC 9: the drafted probe reads the tape ────────────────────────────────────
ac_log "AC 9a: the probe prints cleared/acted = 0.25 over the repair tape"
TAPE="$TMP_DIR/tape"
mkdir -p "$TAPE"
now_iso="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
cat > "$TAPE/tape.jsonl" <<EOF
{"type":"proposal","t":"$now_iso","id":"p1","loop":"repair","class":"boom"}
{"type":"proposal","t":"$now_iso","id":"p2","loop":"repair","class":"other"}
{"type":"outcome","proposal_id":"p1","bits":{"acted":1,"cleared":0}}
{"type":"outcome","proposal_id":"p1","bits":{"acted":1,"cleared":0}}
{"type":"outcome","proposal_id":"p1","bits":{"acted":1,"cleared":1}}
{"type":"outcome","proposal_id":"p1","bits":{}}
{"type":"outcome","proposal_id":"p1","bits":{"acted":0,"cleared":1}}
{"type":"outcome","proposal_id":"p2","bits":{"acted":1,"cleared":1}}
torn-line-not-json
EOF
rc=0
out="$(TAPE_DIR="$TAPE" bash "$TMP_DIR/draft-probe.sh")" || rc=$?
ac_assert_eq "$rc" "0" "the probe must succeed when acted outcomes exist (got $rc)"
ac_assert_eq "$out" "0.25" "the probe must print cleared/acted = 1 of 4 acted (got '$out')"

ac_log "AC 9b: no acted outcome in the window — nothing on stdout, one stderr line, exit 1"
TAPE2="$TMP_DIR/tape-empty"
mkdir -p "$TAPE2"
cat > "$TAPE2/tape.jsonl" <<'EOF'
{"type":"proposal","t":"2020-01-01T00:00:00Z","id":"p1","loop":"repair","class":"boom"}
{"type":"outcome","proposal_id":"p1","bits":{"acted":1,"cleared":1}}
EOF
rc=0
out="$(TAPE_DIR="$TAPE2" bash "$TMP_DIR/draft-probe.sh" 2>"$TMP_DIR/probe-err")" || rc=$?
ac_assert_eq "$rc" "1" "the probe must exit 1 when the window holds no acted outcome (got $rc)"
ac_assert_eq "$out" "" "the probe must print nothing on stdout in that case (got '$out')"
err_lines="$(grep -c '.' "$TMP_DIR/probe-err" || true)"
ac_assert_eq "$err_lines" "1" "the probe must print exactly one stderr line (got: $(cat "$TMP_DIR/probe-err"))"

# ── AC 10: the wiring in supervisor-run.sh and the docs ───────────────────────
ac_log "AC 10: supervisor-run.sh sources the lib after notice.sh and calls it twice"
bash -n "$LIB" || ac_fail "bash -n failed on lib/repair-claim.sh"
bash -n "$TARGET" || ac_fail "bash -n failed on supervisor/supervisor-run.sh"
notice_line="$(grep -n '^source .*lib/notice\.sh' "$TARGET" | head -n 1 | cut -d: -f1)"
claim_line="$(grep -n '^source .*lib/repair-claim\.sh' "$TARGET" | head -n 1 | cut -d: -f1)"
[ -n "$claim_line" ] || ac_fail "supervisor/supervisor-run.sh must source lib/repair-claim.sh"
if [ -z "$notice_line" ] || [ "$claim_line" -le "$notice_line" ]; then
  ac_fail "lib/repair-claim.sh must be sourced after lib/notice.sh"
fi
# shellcheck disable=SC2016  # literal call sites in the script source
calls="$(grep -c 'repair_claim_pr "\$name"' "$TARGET" || true)"
ac_assert_eq "$calls" "2" "supervisor-run.sh must call repair_claim_pr in both the mark and the lift arms (got $calls)"
# shellcheck disable=SC2016  # literal call sites in the script source
grep -qF 'repair_claim_pr "$name" "$script" suspended "$counts"' "$TARGET" \
  || ac_fail "the suspension arm must draft the claim with the suspension counts"
# shellcheck disable=SC2016  # literal call sites in the script source
grep -qF 'repair_claim_pr "$name" "$script" lifted "$counts"' "$TARGET" \
  || ac_fail "the lift arm must draft the claim revision"

ac_log "AC 10b: the AGENTS.md rows name lib/repair-claim.sh"
# shellcheck disable=SC2016  # markdown backticks, not shell expansion
grep -qF '`lib/repair-claim.sh`' "$REPO_ROOT/lib/AGENTS.md" \
  || ac_fail "lib/AGENTS.md must carry a row for lib/repair-claim.sh"
grep -qF 'claims/can-fix-<recipe>.toml' "$REPO_ROOT/supervisor/AGENTS.md" \
  || ac_fail "supervisor/AGENTS.md must document the claim draft (#2055)"

ac_pass