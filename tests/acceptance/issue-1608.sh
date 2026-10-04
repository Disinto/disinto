#!/usr/bin/env bash
# =============================================================================
# tests/acceptance/issue-1608.sh — #1608: refusal and failure outcomes carry
# rejected and a signature
#
# #1608: close_dev_tape_outcome() (dev/dev-agent.sh) wrote {merged:0,
# ci_green:0} for every non-merged exit, so a refusal and a failed walk looked
# identical on the tape. This issue adds:
#   * _DEV_REFUSAL_STATUS — recorded by handle_refusal() for the four
#     disposition statuses (too_large, already_done, needs_ops,
#     design_conflict); unmet_dependency is excluded (it blocks the issue
#     instead of re-queueing it, not a disposition, #1672) and unknown
#     statuses are a no-op, so neither is recorded.
#   * close_dev_tape_outcome() classifies the exit:
#       - recorded disposition refusal -> {merged:0,ci_green:0,rejected:1},
#         reason = the status;
#       - failed walk (PR_WALK_RC != 0, no recorded refusal) -> {merged:0,
#         ci_green:0}, reason = _PR_WALK_EXIT_REASON (possibly empty);
#       - merged walk (PR_WALK_RC == 0) -> {merged:1,ci_green:1}, no reason;
#       - nothing recorded + walk not run (unmet_dependency, unknown) -> the
#         failed-walk shape, no rejected bit.
#     When a reason is present it is resolved via signature_for "$reason" dev
#     (lib/signature.sh, rubric loop "dev"); a non-empty resolution is passed
#     as the 6th arg to tape_outcome (the record's "signature" field). An
#     unresolved/empty reason leaves the record in its pre-#1608 shape (no
#     signature field). A lookup never changes the exit code or skips the write.
#
# The recording + classification are tested in two layers:
#   - handle_refusal() (unit): asserts _DEV_REFUSAL_STATUS is set for the four
#     dispositions and stays empty for unmet_dependency + an unknown status.
#   - close_dev_tape_outcome() (behavior): a stubbed refusal + a hermetic
#     rubric fixture yields the recorded bits/signature.
#
# Run via: tools/run-acceptance.sh 1608
#
# Acceptance (read-only; no live services, no agents, throwaway TAPE_DIRs +
# a hermetic RUBRICS_DIR fixture; the extract-and-stub approach of
# issue-1398/1399/1607/1609/1613):
#   1. needs_ops refusal + fixture rubric -> rejected:1, merged:0, signature
#      "needs-ops"
#   2. failed walk (reason agent_failed) -> merged:0, NO rejected, signature
#      "agent-loop"
#   3. merged walk -> NO rejected, NO signature
#   4. unmet_dependency refusal -> NO rejected
#   5. handle_refusal sets _DEV_REFUSAL_STATUS for too_large/already_done/
#      needs_ops/design_conflict; leaves it empty for unmet_dependency + unknown
#
# Contract: executable bash, set -euo pipefail, exit 0, last stdout line PASS
# (or FAIL: <reason>). The rubric (reason/sig) names live ONLY in a throwaway
# fixture under $TMP_DIR (never committed).
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../tests/lib/acceptance-helpers.sh
source "$REPO_ROOT/tests/lib/acceptance-helpers.sh"

ac_require_cmd bash jq awk grep

TARGET="$REPO_ROOT/dev/dev-agent.sh"
ac_assert_file "$TARGET" "dev/dev-agent.sh must exist"

# ── Env for the extracted code (mirrors the relevant dev-agent.sh globals) ─
PROJECT_NAME="acceptance-1608"   # sentinel — can never clobber a live id file
ISSUE=1608

# ── Hermetic fixture: reason -> signature (loop "dev" rubric) ────────────────
# Only the reason names exercised here. The fixture lives in a throwaway
# $TMP_DIR so lib/ genericity is exercised against real content without
# naming a signature in the repo source.
TMP_DIR="$(mktemp -d)"
RUBRICS_DIR="$TMP_DIR/rubrics"
mkdir -p "$RUBRICS_DIR"
cat > "$RUBRICS_DIR/dev.toml" <<'EOF'
[map]
needs_ops = "needs-ops"
agent_failed = "agent-loop"
EOF
export RUBRICS_DIR

# Per-AC proposal id files (keyed on PROJECT_NAME-issue); cleaned on exit.
id_files=()
id_for() {
  printf '%s\n' "$2" > "/tmp/dev-proposal-id-${PROJECT_NAME:-default}-${1}"
  id_files+=("/tmp/dev-proposal-id-${PROJECT_NAME}-$1")
}
trap 'rm -rf "$TMP_DIR"' EXIT

# ── Stub forge stand-in + log stand-in ───────────────────────────────────────
STUB_BIN="$TMP_DIR/bin"
mkdir -p "$STUB_BIN"
ac_write_curl_stub "$STUB_BIN"
log() { :; }   # silence extracted-code log() in subshells

# ── Extract the functions under test ─────────────────────────────────────────
for fn in close_dev_tape_outcome _dev_refusal_relabel handle_refusal dev_walk_reason_terminal; do
  fn_src="$(ac_extract_fn "$fn" "$TARGET")"
  [ -n "$fn_src" ] || ac_fail "could not locate ${fn}() in dev/dev-agent.sh"
  eval "$fn_src"
done

# ── Stubs: record mutating calls; keep the issue lifecycle hermetic ─────────
CALLS=()
REFUSALS=()
issue_post_refusal() {
  REFUSALS+=("$3")
  CALLS+=("issue_post_refusal $1 $3")
}
issue_release() { CALLS+=("issue_release $1"); }
issue_close()   { CALLS+=("issue_close $1"); }

# Fake label dir (a bare array, like a real `forge_api GET /labels`):
# rejected=100, backlog=200, in-progress=300, underspecified=400.
LABELS_JSON='[{"id":100,"name":"rejected"},{"id":200,"name":"backlog"},{"id":300,"name":"in-progress"},{"id":400,"name":"underspecified"}]'
forge_api() {
  local method="$1" path="$2"
  local extra=("$@") data="" i
  case "${method} ${path}" in
    "GET /labels")
      printf '%s\n' "$LABELS_JSON"
      ;;
    "POST /issues/$ISSUE/labels")
      for i in "${!extra[@]}"; do
        [ "${extra[i]}" = "-d" ] && data="${extra[i+1]}"
      done
      CALLS+=("forge POST /issues/$ISSUE/labels ${data}")
      printf 'null\n'
      ;;
    "DELETE /issues/$ISSUE/labels/"*)
      local lid="${path#*/labels/}"
      CALLS+=("forge DELETE /issues/$ISSUE/labels/${lid}")
      printf 'null\n'
      ;;
    *)
      printf 'null\n'
      ;;
  esac
}

# ── Helpers ───────────────────────────────────────────────────────────────────

# run_close <TAPE_DIR> <issue> <mode> <status> <pr_walk_rc> <walk_reason>
# — run the extracted code in an isolated subshell, then return the last record.
#   issue    the issue number (keys the proposal id file the outcome reads).
#   mode     "refusal" -> run handle_refusal <status> first (then the walk rc);
#           "walk"    -> skip the refusal, use <pr_walk_rc>/<walk_reason>
#   The subshell sets _DEV_REFUSAL_STATUS/_PR_WALK_EXIT_REASON/
#   _DEV_TAPE_OUTCOME_WRITTEN fresh, sources lib/tape.sh + lib/signature.sh,
#   and calls close_dev_tape_outcome. Returns 0 iff the function returned 0.
# Shell variables are local to the subshell; the parent keeps its own state.
run_close() {
  local tape_dir="$1" issue="$2" mode="$3" status="$4" pr_rc="$5" walk_reason="${6:-}"
  (
    ac_stub_env "$STUB_BIN" "$tape_dir"
    export RUBRICS_DIR PROJECT_NAME ISSUE
    # shellcheck disable=SC1091  # path only known at runtime
    source "$REPO_ROOT/lib/tape.sh"
    # shellcheck disable=SC1091  # path only known at runtime
    source "$REPO_ROOT/lib/signature.sh"
    ISSUE="$issue"
    # shellcheck disable=SC1091  # path only known at runtime
    source "$REPO_ROOT/lib/tape.sh"
    # shellcheck disable=SC1091  # path only known at runtime
    source "$REPO_ROOT/lib/tape-outcome-guard.sh"
    # shellcheck disable=SC1091  # path only known at runtime
    source "$REPO_ROOT/lib/signature.sh"
    _DEV_REFUSAL_STATUS=""
    _PR_WALK_EXIT_REASON=""
    _DEV_TAPE_OUTCOME_WRITTEN=0
    # shellcheck disable=SC2034  # consumed by the eval'd close_dev_tape_outcome
    PR_WALK_RC="$pr_rc"
    if [ "$mode" = refusal ]; then
      handle_refusal "$status" '{"status":"'"$status"'"}'
    else
      if [ -n "$walk_reason" ]; then
        _PR_WALK_EXIT_REASON="$walk_reason"
      fi
    fi
    close_dev_tape_outcome
  ) 2>&1
}

# last_json <TAPE_DIR>
last_json() {
  tail -n 1 "$1/tape.jsonl" 2>/dev/null
}

# line_count <TAPE_DIR>
line_count() {
  if [ -f "$1/tape.jsonl" ]; then
    wc -l < "$1/tape.jsonl" | tr -d ' '
  else
    printf 0
  fi
}

# ── AC 1: needs_ops refusal -> rejected:1 + needs-ops signature ─────────────
ac_log "AC 1: needs_ops refusal + rubric -> rejected:1, merged:0, signature 'needs-ops'"
id1608="1608-needs-ops"
id_for 1608 "$id1608"
TAPE1="$TMP_DIR/tape-needs-ops"
rc=0
out="$(run_close "$TAPE1" 1608 refusal needs_ops 1 "")" || rc=$?
ac_assert_eq "$rc" "0" "needs_ops outcome must succeed (rc=$rc): $out"
ac_assert_eq "$(line_count "$TAPE1")" "1" "exactly one outcome record (got $(line_count "$TAPE1"))"
last_json "$TAPE1" | jq -e \
  --arg pid "$id1608" \
  '.type == "outcome" and .proposal_id == $pid
   and .bits.merged == 0 and .bits.ci_green == 0 and .bits.rejected == 1
   and .signature == "needs-ops"' > /dev/null \
  || ac_fail "needs_ops must be {merged:0,ci_green:0,rejected:1, signature:'needs-ops'}, got: $(last_json "$TAPE1")"
ac_log "AC 1 OK"

# ── AC 2: failed walk (agent_failed) -> merged:0, no rejected, agent-loop ────
ac_log "AC 2: failed walk (reason agent_failed) -> merged:0, no rejected, signature 'agent-loop'"
id1609="1609-failed-walk"
id_for 1609 "$id1609"
TAPE2="$TMP_DIR/tape-failed-walk"
rc=0
out="$(run_close "$TAPE2" 1609 walk "" 1 agent_failed)" || rc=$?
ac_assert_eq "$rc" "0" "failed-walk outcome must succeed (rc=$rc): $out"
ac_assert_eq "$(line_count "$TAPE2")" "1" "exactly one outcome record (got $(line_count "$TAPE2"))"
last_json "$TAPE2" | jq -e \
  --arg pid "$id1609" \
  '.type == "outcome" and .proposal_id == $pid
   and .bits.merged == 0 and .bits.ci_green == 0
   and (.bits.rejected // 0) == 0
   and .signature == "agent-loop"' > /dev/null \
  || ac_fail "failed walk (agent_failed) must be {merged:0,ci_green:0, no rejected, signature:'agent-loop'}, got: $(last_json "$TAPE2")"
ac_log "AC 2 OK"

# ── AC 3: merged walk -> no rejected, no signature ───────────────────────────
ac_log "AC 3: merged walk -> no rejected, no signature"
id1610="1610-merged"
id_for 1610 "$id1610"
TAPE3="$TMP_DIR/tape-merged"
rc=0
out="$(run_close "$TAPE3" 1610 walk "" 0 "")" || rc=$?
ac_assert_eq "$rc" "0" "merged-walk outcome must succeed (rc=$rc): $out"
ac_assert_eq "$(line_count "$TAPE3")" "1" "exactly one outcome record (got $(line_count "$TAPE3"))"
last_json "$TAPE3" | jq -e \
  --arg pid "$id1610" \
  '.type == "outcome" and .proposal_id == $pid
   and .bits.merged == 1 and .bits.ci_green == 1
   and (.bits.rejected // 0) == 0
   and has("signature") == false' > /dev/null \
  || ac_fail "merged walk must be {merged:1,ci_green:1, no rejected, no signature}, got: $(last_json "$TAPE3")"
ac_log "AC 3 OK"

# ── AC 4: unmet_dependency refusal -> no rejected ────────────────────────────
ac_log "AC 4: unmet_dependency refusal -> no rejected"
id1611="1611-unmet"
id_for 1611 "$id1611"
TAPE4="$TMP_DIR/tape-unmet"
rc=0
out="$(run_close "$TAPE4" 1611 refusal unmet_dependency 1 "")" || rc=$?
ac_assert_eq "$rc" "0" "unmet_dependency outcome must succeed (rc=$rc): $out"
ac_assert_eq "$(line_count "$TAPE4")" "1" "exactly one outcome record (got $(line_count "$TAPE4"))"
last_json "$TAPE4" | jq -e \
  --arg pid "$id1611" \
  '.type == "outcome" and .proposal_id == $pid
   and .bits.merged == 0 and (.bits.rejected // 0) == 0' > /dev/null \
  || ac_fail "unmet_dependency must have no rejected bit, got: $(last_json "$TAPE4")"
ac_log "AC 4 OK"

# ── AC 5: handle_refusal sets _DEV_REFUSAL_STATUS for the four dispositions;
#    leaves it empty for unmet_dependency + an unknown status ─────────────────
ac_log "AC 5: handle_refusal -> _DEV_REFUSAL_STATUS set for 4 dispositions, empty for unmet_dependency/unknown"
declare -a statuses=(too_large already_done needs_ops design_conflict)
for s in "${statuses[@]}"; do
  _DEV_REFUSAL_STATUS=""
  CALLS=(); REFUSALS=()
  handle_refusal "$s" '{"status":"'"$s"'"}'
  ac_assert_eq "${_DEV_REFUSAL_STATUS:-__unset__}" "$s" \
    "handle_refusal('$s') must set _DEV_REFUSAL_STATUS to '$s'"
done
# unmet_dependency must NOT be recorded
_DEV_REFUSAL_STATUS=""
handle_refusal "unmet_dependency" '{"status":"unmet_dependency","blocked_by":"a running host"}'
ac_assert_eq "${_DEV_REFUSAL_STATUS:-__unset__}" "__unset__" \
  "handle_refusal('unmet_dependency') must NOT record _DEV_REFUSAL_STATUS"
# unknown status (no-op) must NOT be recorded
_DEV_REFUSAL_STATUS=""
handle_refusal "not_a_real_status" '{}'
ac_assert_eq "${_DEV_REFUSAL_STATUS:-__unset__}" "__unset__" \
  "handle_refusal(unknown) must NOT record _DEV_REFUSAL_STATUS"
ac_log "AC 5 OK"

ac_pass
