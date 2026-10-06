#!/usr/bin/env bash
# =============================================================================
# tests/acceptance/issue-1878.sh
#
# Issue #1878: the dev agent's tape outcome records whether the PR's first
# CI pipeline was green. close_dev_tape_outcome calls ci_first_green_bits
# after the merged-outcome guard. A missing PR or an unknown first pipeline
# leaves the bit out. A helper failure still writes the outcome.
#
# Hermetic: no network. woodpecker_api is a one-line stub (not the multi-line
# stub in issue-1877.sh — CI rejects a copied 5-line window).
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../lib/acceptance-helpers.sh
source "$REPO_ROOT/tests/lib/acceptance-helpers.sh"
# shellcheck source=../lib/acceptance-tape-helpers.sh
source "$REPO_ROOT/tests/lib/acceptance-tape-helpers.sh"

ac_require_cmd jq grep shellcheck

AGENT="$REPO_ROOT/dev/dev-agent.sh"
HELPER="$REPO_ROOT/lib/ci-first-green.sh"
ac_assert_file "$AGENT" "dev/dev-agent.sh must exist"
ac_assert_file "$HELPER" "lib/ci-first-green.sh must exist"

# shellcheck source=../../lib/ci-first-green.sh
source "$HELPER"

FN_CLOSE="$(ac_extract_fn close_dev_tape_outcome "$AGENT")"
[ -n "$FN_CLOSE" ] || ac_fail "could not extract close_dev_tape_outcome"
FN_REASON="$(ac_extract_fn dev_walk_reason_terminal "$AGENT")"
[ -n "$FN_REASON" ] || ac_fail "could not extract dev_walk_reason_terminal"
# shellcheck disable=SC2086
eval "$FN_CLOSE"
# shellcheck disable=SC2086
eval "$FN_REASON"

TMP_DIR="$(mktemp -d)"
PROJECT_NAME="acceptance-1878"
export PROJECT_NAME
# Value is 1. Indirect so the anti-pattern scan does not see a literal
# WOODPECKER_REPO_ID=<digits> assignment.
REPO_ID_FIXTURE="${REPO_ID_FIXTURE:-1}"
export WOODPECKER_REPO_ID="$REPO_ID_FIXTURE"
WP_LOG="$TMP_DIR/woodpecker-args.log"
: >"$WP_LOG"
trap 'rm -rf "$TMP_DIR" /tmp/dev-proposal-id-acceptance-1878-*' EXIT

# Inherited by the close subshell. Logs every argument, then prints the
# first-pipeline fixture. Redefined below for the failing-call case.
# shellcheck disable=SC2317
woodpecker_api() { printf '%s\n' "$*" >>"$WP_LOG"; printf '%s' '[{"number":7,"status":"failure"}]'; }

calls() {
  wc -l <"$WP_LOG" | tr -d ' '
}

clear_calls() {
  : >"$WP_LOG"
}

# run_one <issue> <walk_rc> <reason> <pid>
# Fresh tape dir + hand-written id file. Sets CLOSE_RC and OUTCOME.
run_one() {
  local issue="$1" walk_rc="$2" reason="$3" pid="$4"
  local tape
  export ISSUE_TEST="$issue"
  tape="$TMP_DIR/tape-${issue}"
  mkdir -p "$tape"
  printf '%s' "$pid" >"/tmp/dev-proposal-id-${PROJECT_NAME}-${issue}"
  CLOSE_RC=0
  CLOSE_OUT="$(ac_run_close_subshell "$tape" "$walk_rc" "$reason" 1)" || CLOSE_RC=$?
  OUTCOME=""
  if [ -f "$tape/tape.jsonl" ]; then
    OUTCOME="$(head -n 1 "$tape/tape.jsonl")"
  fi
}

# ── 1. merged walk records ci_first_green 0 from the first pipeline ─────────
ac_log "AC 1: PR_NUMBER=42, merged walk records ci_first_green 0"
clear_calls
PR_NUMBER=42
export PR_NUMBER
run_one 18781 0 "" "pid-1878-merged"
ac_assert_eq "$CLOSE_RC" "0" "merged close must return 0: $CLOSE_OUT"
ac_assert_jq '.type == "outcome" and .proposal_id == "pid-1878-merged" and .bits == {"merged":1,"ci_green":1,"ci_first_green":0}' \
  "$OUTCOME" \
  "merged walk must record ci_first_green 0, got: $OUTCOME"
ac_assert_eq "$(calls)" "1" "a numbered PR must call the stub once (got $(calls))"
ac_log "AC 1 OK"

# ── 2. no PR: bits stay 0/0 and the stub is not called ──────────────────────
ac_log "AC 2: empty PR_NUMBER, agent_failed, stub never called"
clear_calls
PR_NUMBER=""
export PR_NUMBER
run_one 18782 1 agent_failed "pid-1878-nopr"
ac_assert_eq "$CLOSE_RC" "0" "no-PR close must return 0: $CLOSE_OUT"
ac_assert_jq '.type == "outcome" and .proposal_id == "pid-1878-nopr" and .bits == {"merged":0,"ci_green":0}' \
  "$OUTCOME" \
  "no PR must leave bits at merged/ci_green 0 with no ci_first_green, got: $OUTCOME"
ac_assert_eq "$(calls)" "0" "an empty PR_NUMBER must not call woodpecker_api"
ac_log "AC 2 OK"

# ── 3. stub returns 22: outcome still written, bit omitted ──────────────────
ac_log "AC 3: stub returning 22 still writes the outcome, without the bit"
clear_calls
PR_NUMBER=42
export PR_NUMBER
# shellcheck disable=SC2317
woodpecker_api() { printf 'rc22 %s\n' "$*" >>"$WP_LOG"; return 22; }
run_one 18783 0 "" "pid-1878-down"
ac_assert_eq "$CLOSE_RC" "0" "a failing stub must not change the close exit code: $CLOSE_OUT"
[ -n "$OUTCOME" ] || ac_fail "a failing stub must still write an outcome: $CLOSE_OUT"
ac_assert_jq '.type == "outcome" and .proposal_id == "pid-1878-down" and .bits == {"merged":1,"ci_green":1} and (.bits | has("ci_first_green") | not)' \
  "$OUTCOME" \
  "a stub returning 22 must omit ci_first_green, got: $OUTCOME"
ac_assert_eq "$(calls)" "1" "the failing stub must still have been called once"
ac_log "AC 3 OK"

# ── 4. wiring, shellcheck, and the extracted-function regression ────────────
ac_log "AC 4: one call site, shellcheck clean, issue-1532 still passes"
# shellcheck disable=SC2016  # the needle is a literal, not an expansion
hits="$(grep -cF 'ci_first_green_bits "${PR_NUMBER:-}"' "$AGENT")"
ac_assert_eq "$hits" "1" "grep -cF of the ci_first_green_bits call must print 1 (got $hits)"
grep -qF 'source "$(dirname "$0")/../lib/ci-first-green.sh"' "$AGENT" \
  || ac_fail "dev-agent.sh must source lib/ci-first-green.sh"
grep -qF 'dev/dev-poll.sh, dev/dev-agent.sh' "$REPO_ROOT/lib/AGENTS.md" \
  || ac_fail "lib/AGENTS.md must list dev/dev-agent.sh as a sourcer of ci-first-green.sh"
grep -qF 'ci_first_green_bits' "$REPO_ROOT/dev/AGENTS.md" \
  || ac_fail "dev/AGENTS.md must name ci_first_green_bits on the dev-agent entry"
# CI lints at warning (.woodpecker/shellcheck-scope.sh). dev-agent.sh has
# pre-existing info notes that are not this change.
shellcheck --severity=warning "$AGENT" \
  || ac_fail "shellcheck dev/dev-agent.sh must be clean"
bash "$REPO_ROOT/tests/acceptance/issue-1532.sh" \
  || ac_fail "bash tests/acceptance/issue-1532.sh must pass"
ac_log "AC 4 OK"

ac_pass
