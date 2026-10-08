#!/usr/bin/env bash
# =============================================================================
# tests/acceptance/issue-1941.sh — architect docs match the write contract
# and the last-seen rule
#
# Issue #1941: architect/AGENTS.md and the header of architect/architect-run.sh
# must name the contents-API commit of the pitch file, and must not say the
# last-seen marker advances after a failed dispatch. Read-only: greps those
# files. No forge, no nomad, no repo mutation.
#
# Verifies:
#   1. Both write-permission contract lists name the contents-API commit
#      (`pitch_pr_put` in `lib/pitch-pr.sh`, as `architect-bot`) and still
#      say the architect never merges.
#   2. Step 5 and the Round-robin bullet say a failed dispatch
#      (`_OPUS_DISPATCH_FAILED`) leaves the marker, so the same PR is retried.
#   3. Those sentences in architect/architect-run.sh are comment lines (the
#      issue's git-diff check: the script change is comments, not code).
#
# Run via: tools/run-acceptance.sh 1941
#
# Last stdout line is PASS or FAIL: <reason>.
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck disable=SC1091
source "$REPO_ROOT/tests/lib/acceptance-helpers.sh"

ac_require_cmd grep awk

DOCS="$REPO_ROOT/architect/AGENTS.md"
RUN="$REPO_ROOT/architect/architect-run.sh"

ac_assert_file "$DOCS" "architect/AGENTS.md is missing"
ac_assert_file "$RUN" "architect/architect-run.sh is missing"

# shellcheck disable=SC2016 # backticks are the contract's literal wording, not substitution
PITCH_COMMIT='commit the pitch file to the PR branch through the contents API (`pitch_pr_put` in `lib/pitch-pr.sh`, as `architect-bot`) when drafting or revising sub-issues'
FAILED_DISPATCH='a failed dispatch leaves the marker, so the same PR is retried next cycle'

# section_until <file> <start-regex> <stop-regex> — lines after the start
# line, up to but not including the stop line. Empty if the start is missing.
section_until() {
  awk -v start="$2" -v stop="$3" '
    $0 ~ start { found=1; next }
    found && $0 ~ stop { exit }
    found { print }
  ' "$1"
}

# require_phrase <label> <text> <phrase>
require_phrase() {
  local label="$1" text="$2" phrase="$3"
  printf '%s\n' "$text" | grep -qF -- "$phrase" \
    || ac_fail "${label} does not contain: ${phrase}"
}

# ── 1. Both contract lists name the contents-API commit ──────────────────
ac_log "AC1: both contract lists name the contents-API commit of the pitch file"

docs_contract="$(section_until "$DOCS" '^## Write-permission contract$' '^## ')"
[ -n "$docs_contract" ] || ac_fail "architect/AGENTS.md has no Write-permission contract section"
require_phrase "architect/AGENTS.md contract" "$docs_contract" "$PITCH_COMMIT"
require_phrase "architect/AGENTS.md contract" "$docs_contract" "never merges"

run_contract="$(section_until "$RUN" '^# Write-permission contract:' '^# Formula')"
[ -n "$run_contract" ] || ac_fail "architect/architect-run.sh header has no Write-permission contract"
require_phrase "architect-run.sh contract" "$run_contract" "$PITCH_COMMIT"
require_phrase "architect-run.sh contract" "$run_contract" "never merges"

ac_log "AC1: both contracts name pitch_pr_put and still never merge"

# ── 2. Step 5 and the Round-robin bullet leave a failed dispatch unseen ──
ac_log "AC2: step 5 and the Round-robin bullet do not advance the marker after a failed dispatch"

step5="$(grep -F '5. PATCH PR body to update the last-seen marker' "$DOCS" || true)"
[ -n "$step5" ] || ac_fail "architect/AGENTS.md has no round-robin step 5"
# shellcheck disable=SC2016
require_phrase "step 5" "$step5" 'unless the dispatch failed (`_OPUS_DISPATCH_FAILED`)'
require_phrase "step 5" "$step5" "$FAILED_DISPATCH"

bullet="$(grep -F '**Round-robin**:' "$DOCS" || true)"
[ -n "$bullet" ] || ac_fail "architect/AGENTS.md has no Round-robin bullet"
# shellcheck disable=SC2016
require_phrase "Round-robin bullet" "$bullet" 'not advanced after a failed dispatch (`_OPUS_DISPATCH_FAILED`)'
require_phrase "Round-robin bullet" "$bullet" "$FAILED_DISPATCH"

# The stale rule this issue removes must not come back. An agent that
# aligns the code to either sentence would drop the owner's comment.
for stale in \
  'last-seen advances every iteration' \
  'cursor advances every iteration' \
  'updated every iteration'
do
  hits="$(grep -nF -- "$stale" "$DOCS" "$RUN" || true)"
  [ -z "$hits" ] || ac_fail "stale last-seen rule still present: ${hits}"
done

ac_log "AC2: a failed dispatch leaves the marker"

# ── 3. The script sentences are comments, not code ───────────────────────
ac_log "AC3: architect-run.sh names the contract and the last-seen rule only in comments"

comment_only() {
  local phrase="$1" hits hit text
  hits="$(grep -nF -- "$phrase" "$RUN" || true)"
  [ -n "$hits" ] || ac_fail "architect-run.sh does not contain: ${phrase}"
  while IFS= read -r hit; do
    [ -n "$hit" ] || continue
    text="${hit#*:}"
    case "$text" in
      '#'*) ;;
      [[:space:]]'#'*) ;;
      *) ac_fail "architect-run.sh has a non-comment line for '${phrase}': ${hit}" ;;
    esac
  done <<< "$hits"
}

comment_only "$PITCH_COMMIT"
comment_only 'The last-seen marker is not advanced after a failed dispatch (_OPUS_DISPATCH_FAILED)'

ac_pass
