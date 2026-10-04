#!/usr/bin/env bash
# =============================================================================
# tests/acceptance/issue-1695.sh
#
# Issue #1695: the PR walk waits up to an hour for CI.
#
# pr_poll_ci's timeout default was a hardcoded 1800s. A still-pending pipeline
# ended the walk with ci_timeout, and the attempt was lost to waiting. The
# default is now ${PR_CI_TIMEOUT_S:-3600}; an explicit timeout argument still
# wins over the env var.
#
# Contract under test (#1695):
#   (1) no timeout argument, PR_CI_TIMEOUT_S unset, ci_commit_status always
#       pending: return 2 after 120 polls (3600/30);
#   (2) the same with PR_CI_TIMEOUT_S=60: return 2 after 2 polls;
#   (3) an explicit timeout of 90 with PR_CI_TIMEOUT_S=60: return 2 after
#       3 polls (the argument wins);
#   (4) a stub that prints success on the first poll: return 0;
#   (5) this test exits 0 and calls ac_pass.
#
# Hermetic: no network. pr_poll_ci is extracted with ac_extract_fn. forge_api,
# ci_required_for_pr, ci_commit_status, sleep, and _prl_log are stubbed.
# WOODPECKER_REPO_ID=1 so the "no CI" short-circuit is not taken.
#
# Acceptance: `bash tests/acceptance/issue-1695.sh` exits 0 and calls ac_pass.
# Run via `tools/run-acceptance.sh 1695`.
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=../../tests/lib/acceptance-helpers.sh
source "$REPO_ROOT/tests/lib/acceptance-helpers.sh"

ac_require_cmd bash jq
SRC="$REPO_ROOT/lib/pr-lifecycle.sh"
ac_assert_file "$SRC" "lib/pr-lifecycle.sh is present"

ac_log "Extracting pr_poll_ci from $SRC"
FN="$(ac_extract_fn pr_poll_ci "$SRC")"
[ -n "$FN" ] || ac_fail "pr_poll_ci() is not defined in lib/pr-lifecycle.sh"
# shellcheck disable=SC2086
eval "$FN"

# The doc row must name the env default (review formula 3b, #1695).
# shellcheck disable=SC2016  # backticks and ${} in the pattern are literal
grep -qF 'pr_poll_ci` waits `PR_CI_TIMEOUT_S` seconds for CI (default 3600) unless the caller passes a timeout; a longer wait ends the walk with `ci_timeout` (#1695).' \
  "$REPO_ROOT/lib/AGENTS.md" \
  || ac_fail "lib/AGENTS.md must document the PR_CI_TIMEOUT_S wait (#1695)"

TMP_DIR="$(mktemp -d /tmp/acceptance-1695.XXXXXX)"
trap 'rm -rf "$TMP_DIR"' EXIT
POLL_FILE="$TMP_DIR/polls"

# Not "0": that short-circuits to success before any poll.
export WOODPECKER_REPO_ID=1

forge_api() { printf '%s\n' '{"head":{"sha":"abc"}}'; }
ci_required_for_pr() { return 0; }
_prl_log() { :; }
# No-op: the poll interval is counted, not slept.
sleep() { :; }

# Command substitution isolates ci_commit_status, so a shell counter would
# not survive. Append one line per call; the caller counts the file.
ci_commit_status() {
  printf 'x\n' >> "$POLL_FILE"
  printf '%s\n' "${CI_STATE:-pending}"
}

# run_poll [pr_poll_ci args...] — print "<rc> <polls>".
# PR_CI_TIMEOUT_S and CI_STATE are inherited from the caller.
run_poll() {
  : > "$POLL_FILE"
  local rc=0 polls
  pr_poll_ci "$@" || rc=$?
  polls="$(wc -l < "$POLL_FILE" | tr -d '[:space:]')"
  printf '%s %s\n' "$rc" "$polls"
}

# --- AC1: unset env, no timeout argument ------------------------------------
ac_log "AC1: PR_CI_TIMEOUT_S unset, no timeout arg, pending → rc 2 after 120 polls"
unset PR_CI_TIMEOUT_S
CI_STATE=pending
out="$(run_poll 7)"
ac_assert_eq "$out" "2 120" \
  "unset timeout must return 2 after 120 polls (got $out)"

# --- AC2: env timeout of 60s ------------------------------------------------
ac_log "AC2: PR_CI_TIMEOUT_S=60, pending → rc 2 after 2 polls"
export PR_CI_TIMEOUT_S=60
CI_STATE=pending
out="$(run_poll 7)"
ac_assert_eq "$out" "2 2" \
  "PR_CI_TIMEOUT_S=60 must return 2 after 2 polls (got $out)"

# --- AC3: explicit argument wins over the env var ---------------------------
ac_log "AC3: explicit timeout 90 with PR_CI_TIMEOUT_S=60 → rc 2 after 3 polls"
out="$(run_poll 7 90)"
ac_assert_eq "$out" "2 3" \
  "explicit timeout 90 must return 2 after 3 polls (got $out)"

# --- AC4: success on the first poll -----------------------------------------
ac_log "AC4: success on the first poll → rc 0"
CI_STATE=success
out="$(run_poll 7)"
ac_assert_eq "$out" "0 1" \
  "success on the first poll must return 0 after 1 poll (got $out)"

ac_pass
