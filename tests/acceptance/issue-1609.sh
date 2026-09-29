#!/usr/bin/env bash
# =============================================================================
# tests/acceptance/issue-1609.sh
#
# Issue #1609: dev-poll's outcome emitter (dev/dev-poll.sh, emit_tape_outcome)
# gains an optional 5th arg REASON. When set, it sources lib/signature.sh (a
# loop-agnostic reason -> signature resolver, signature_for, from #1607) and
# passes a non-empty result to tape_outcome as the 6th arg (the record's
# "signature" field). When the reason is absent/unknown (empty resolution) the
# record keeps its pre-#1607 shape — no "signature" key.
#
# Wired into dev-poll:
#   - the CI-exhaustion block (handle_ci_exhaustion, exhausted_first_time)
#     emits merged:0 / ci_green:0 with reason ci_exhausted_poll BEFORE it
#     issue_block()s;
#   - both stale-branch abandonment paths (in-progress + backlog scans)
#     emit closed PRs with reason stale_branch;
#   - the three direct-merge paths and the pick step emit with no reason
#     (4 args, unchanged) — no signature;
#   - unknown reasons resolve to empty -> no signature.
#
# Acceptance (read-only — no live services, no agents started, no state
# mutation; hand-written tmp TAPE_DIRs + a hermetic RUBRICS_DIR fixture, the
# same extract-and-stub approach as issue-1399/issue-1398):
#   1. stubbed CI-exhausted outcome (reason ci_exhausted_poll) -> exactly one
#      record, merged:0, signature == "ci-exhausted" (fixture mapping)
#   2. stubbed stale-branch abandonment (reason stale_branch) -> one record,
#      merged:0, signature == "stale-branch" (fixture mapping)
#   3. stubbed direct merge (no reason) -> one record, merged:1, NO "signature"
#      field
#   4. unknown reason (not in the rubric) -> one record, NO "signature" field
#   5. wiring — the source emits with each reason at its site, the CI-exhausted
#      emit precedes issue_block, and the three merge sites carry no 5th arg
#
# Contract: executable bash, set -euo pipefail, exit 0, last stdout line PASS
# (or FAIL: <reason>). The rubric's (loop/sig) names live ONLY in a throwaway
# fixture under $TMP_DIR (never committed), so lib/ genericity is exercised
# against real (loop/sig) content without naming it in source.
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../tests/lib/acceptance-helpers.sh
source "$REPO_ROOT/tests/lib/acceptance-helpers.sh"

ac_require_cmd bash jq python3 awk grep

TARGET="$REPO_ROOT/dev/dev-poll.sh"
ac_assert_file "$TARGET" "dev/dev-poll.sh must exist"

# ── Hermetic fixture: reason->signature map (loop/sig names ONLY here) ───────

TMP_DIR="$(mktemp -d)"
RUBRICS_DIR="$TMP_DIR/rubrics"
mkdir -p "$RUBRICS_DIR"
cat > "$RUBRICS_DIR/dev.toml" <<'EOF'
[map]
ci_exhausted_poll = "ci-exhausted"
stale_branch = "stale-branch"
EOF
export RUBRICS_DIR

PROJECT_NAME="acceptance-1609"   # sentinel — can never clobber a live id file
trap 'rm -rf "$TMP_DIR" \
  /tmp/dev-proposal-id-acceptance-1609-1609 \
  /tmp/dev-proposal-id-acceptance-1609-16091 \
  /tmp/dev-proposal-id-acceptance-1609-16092 \
  /tmp/dev-proposal-id-acceptance-1609-16093' EXIT

# ── Stub curl: hermetic forge stand-in (no network, no live services) ─────────
STUB_BIN="$TMP_DIR/bin"
mkdir -p "$STUB_BIN"
ac_write_curl_stub "$STUB_BIN"
# The extracted emitters log through log(); the subshells inherit this
# stand-in so their lines land in the runner's captured output.
log() { echo "poll: $*"; }

# ── Extract the emitter (and the CI-exhaustion handler for the wiring AC) ────
FN_OUT="$(ac_extract_fn emit_tape_outcome "$TARGET")"
[ -n "$FN_OUT" ] || ac_fail "could not extract emit_tape_outcome() from dev-poll.sh"

# ── Helpers ───────────────────────────────────────────────────────────────────

# id_for <issue> <uuid> — write the proposal id file the outcome keys off of.
id_for() {
  printf '%s\n' "$2" > "/tmp/dev-proposal-id-${PROJECT_NAME:-default}-${1}"
}

# run_emit <TAPE_DIR> <issue> <pr> <merged> <ci_green> [reason] — run the
# extracted emit_tape_outcome in an isolated subshell: stub curl first on
# PATH, the ac_stub_env sentinels (PROJECT_NAME, TAPE_DIR), the real lib/tape.sh
# PLUS lib/signature.sh (the new signature resolver), and the caller's
# RUBRICS_DIR. The reason is the optional 5th arg to emit_tape_outcome.
# Capture the subshell's combined output; the exit status is the function's.
run_emit() {
  local tape_dir="$1" issue="$2" pr="$3" merged="$4" ci_green="$5" reason="${6:-}"
  (
    ac_stub_env "$STUB_BIN" "$tape_dir"
    export RUBRICS_DIR
    # shellcheck disable=SC1091  # path only known at runtime
    source "$REPO_ROOT/lib/tape.sh"
    # shellcheck disable=SC1091  # path only known at runtime
    source "$REPO_ROOT/lib/signature.sh"
    eval "$FN_OUT"
    if [ -n "$reason" ]; then
      emit_tape_outcome "$issue" "$pr" "$merged" "$ci_green" "$reason"
    else
      emit_tape_outcome "$issue" "$pr" "$merged" "$ci_green"
    fi
  ) 2>&1
}

# last_json <TAPE_DIR> — print the final line of $1/tape.jsonl (or nothing if
# absent).
last_json() {
  tail -n 1 "$1/tape.jsonl" 2>/dev/null
}

# line_count <TAPE_DIR> — number of records in $1/tape.jsonl (0 if absent).
line_count() {
  if [ -f "$1/tape.jsonl" ]; then wc -l < "$1/tape.jsonl"; else printf 0; fi
}

# ── AC 1: CI-exhausted outcome carries the ci-exhausted_poll signature ──────

ac_log "AC 1: CI-exhausted (reason ci_exhausted_poll) -> merged:0, signature 'ci-exhausted'"
id1609="1609-outcome-uuid"
id_for 1609 "$id1609"
TAPE1="$TMP_DIR/tape-ci-exhausted"
rc=0
out="$(run_emit "$TAPE1" 1609 42 0 0 ci_exhausted_poll)" || rc=$?
ac_assert_eq "$rc" "0" "emit_tape_outcome must succeed (rc=$rc): $out"
ac_assert_eq "$(line_count "$TAPE1")" "1" "exactly one outcome record (got $(line_count "$TAPE1"))"
last_json "$TAPE1" | jq -e \
  --arg pid "$id1609" \
  '.type == "outcome" and .proposal_id == $pid and .bits.merged == 0 and .signature == "ci-exhausted"' \
  > /dev/null \
  || ac_fail "CI-exhausted outcome must be {type:outcome, proposal_id:$id1609, merged:0, signature:'ci-exhausted'}, got: $(last_json "$TAPE1")"
ac_log "AC 1 OK"

# ── AC 2: stale-branch abandonment carries the stale_branch signature ────────

ac_log "AC 2: stale-branch abandonment (reason stale_branch) -> merged:0, signature 'stale-branch'"
id16091="16091-outcome-uuid"
id_for 16091 "$id16091"
TAPE2="$TMP_DIR/tape-stale"
rc=0
out="$(run_emit "$TAPE2" 16091 43 0 0 stale_branch)" || rc=$?
ac_assert_eq "$rc" "0" "emit_tape_outcome must succeed (rc=$rc): $out"
ac_assert_eq "$(line_count "$TAPE2")" "1" "exactly one outcome record (got $(line_count "$TAPE2"))"
last_json "$TAPE2" | jq -e \
  --arg pid "$id16091" \
  '.type == "outcome" and .proposal_id == $pid and .bits.merged == 0 and .signature == "stale-branch"' \
  > /dev/null \
  || ac_fail "stale-branch outcome must be {type:outcome, proposal_id:$id16091, merged:0, signature:'stale-branch'}, got: $(last_json "$TAPE2")"
ac_log "AC 2 OK"

# ── AC 3: direct merge (no reason) -> NO signature field ──────────────────────

ac_log "AC 3: direct merge (no reason) -> merged:1, NO signature field"
id16092="16092-outcome-uuid"
id_for 16092 "$id16092"
TAPE3="$TMP_DIR/tape-merge"
rc=0
out="$(run_emit "$TAPE3" 16092 44 1 1)" || rc=$?
ac_assert_eq "$rc" "0" "emit_tape_outcome must succeed (rc=$rc): $out"
ac_assert_eq "$(line_count "$TAPE3")" "1" "exactly one outcome record (got $(line_count "$TAPE3"))"
last_json "$TAPE3" | jq -e \
  --arg pid "$id16092" \
  '.type == "outcome" and .proposal_id == $pid and .bits.merged == 1 and .signature == null and (has("signature") | not)' \
  > /dev/null \
  || ac_fail "direct-merge outcome must have NO signature field (merged:1), got: $(last_json "$TAPE3")"
ac_log "AC 3 OK"

# ── AC 4: unknown reason -> no signature (pre-#1607 shape) ───────────────────

ac_log "AC 4: unknown reason (not in rubric) -> NO signature field"
id16093="16093-outcome-uuid"
id_for 16093 "$id16093"
TAPE4="$TMP_DIR/tape-unknown"
rc=0
out="$(run_emit "$TAPE4" 16093 45 0 0 "not_a_real_reason")" || rc=$?
ac_assert_eq "$rc" "0" "emit_tape_outcome must succeed (rc=$rc): $out"
ac_assert_eq "$(line_count "$TAPE4")" "1" "exactly one outcome record (got $(line_count "$TAPE4"))"
last_json "$TAPE4" | jq -e \
  --arg pid "$id16093" \
  '.type == "outcome" and .proposal_id == $pid and .bits.merged == 0 and .signature == null and (has("signature") | not)' \
  > /dev/null \
  || ac_fail "unknown-reason outcome must have NO signature field, got: $(last_json "$TAPE4")"
ac_log "AC 4 OK"

# ── AC 5: source wiring (reason at each site; merge sites have no 5th arg) ────

ac_log "AC 5: source wiring — reasons at each site, merge sites have no 5th arg"

# dev-poll sources lib/signature.sh so signature_for is available in-process.
grep -qF 'lib/signature.sh' "$TARGET" \
  || ac_fail "dev-poll.sh must source lib/signature.sh"

# AC 5a: handle_ci_exhaustion emits with reason ci_exhausted_poll, before it
# issue_block()s the exhausted issue (extracted, so ordering is verifiable).
FN_CIEX="$(ac_extract_fn handle_ci_exhaustion "$TARGET")"
[ -n "$FN_CIEX" ] \
  || ac_fail "could not extract handle_ci_exhaustion() from dev-poll.sh"
# The extracted source is a multi-line string, not a file — pipe it to grep.
printf '%s\n' "$FN_CIEX" | grep -qF 'emit_tape_outcome "$issue_num" "$pr_num" 0 0 ci_exhausted_poll' \
  || ac_fail "handle_ci_exhaustion must emit an outcome with reason ci_exhausted_poll (merged:0, ci_green:0)"
printf '%s\n' "$FN_CIEX" | grep -qF 'issue_block "$issue_num" "ci_exhausted_poll' \
  || ac_fail "handle_ci_exhaustion must block the issue (ci_exhausted_poll)"
ci_line="$(printf '%s\n' "$FN_CIEX" | grep -nF 'emit_tape_outcome "$issue_num" "$pr_num" 0 0 ci_exhausted_poll' | head -n 1 | cut -d: -f1)"
blk_line="$(printf '%s\n' "$FN_CIEX" | grep -nF 'issue_block "$issue_num" "ci_exhausted_poll' | head -n 1 | cut -d: -f1)"
if [ -z "$ci_line" ] || [ -z "$blk_line" ]; then
  ac_fail "could not locate the ci_exhausted_poll emit/issue_block in handle_ci_exhaustion"
fi
if ! [ "$ci_line" -lt "$blk_line" ]; then
  ac_fail "the ci_exhausted_poll emit (line $ci_line) must precede issue_block (line $blk_line) in handle_ci_exhaustion"
fi
ac_log "AC 5a OK (ci_exhausted_poll emit precedes issue_block)"

# AC 5b: both stale-branch abandonment sites pass reason stale_branch.
grep -qF 'emit_tape_outcome "$ISSUE_NUM" "$HAS_PR" 0 0 stale_branch' "$TARGET" \
  || ac_fail "in-progress scan must emit an outcome for closed PRs with reason stale_branch"
grep -qF 'emit_tape_outcome "$ISSUE_NUM" "$EXISTING_PR" 0 0 stale_branch' "$TARGET" \
  || ac_fail "backlog scan must emit an outcome for closed PRs with reason stale_branch"
ac_log "AC 5b OK (both stale-branch sites pass stale_branch)"

# AC 5c: the three direct-merge sites pass NO reason (exact 4-arg form, 1 1
# with nothing after — a trailing 5th arg would break the anchor).
grep -qE 'emit_tape_outcome "\$PL_ISSUE" "\$PL_PR_NUM" 1 1[[:space:]]*$' "$TARGET" \
  || ac_fail "pre-lock merge site must emit with no 5th arg (4-arg form)"
grep -qE 'emit_tape_outcome "\$ISSUE_NUM" "\$HAS_PR" 1 1[[:space:]]*$' "$TARGET" \
  || ac_fail "in-progress merge site must emit with no 5th arg (4-arg form)"
grep -qE 'emit_tape_outcome "\$ISSUE_NUM" "\$EXISTING_PR" 1 1[[:space:]]*$' "$TARGET" \
  || ac_fail "backlog merge site must emit with no 5th arg (4-arg form)"
ac_log "AC 5c OK (merge sites pass no reason)"

ac_pass
