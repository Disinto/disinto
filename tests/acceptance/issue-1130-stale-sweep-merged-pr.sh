#!/usr/bin/env bash
# =============================================================================
# tests/acceptance/issue-1130-stale-sweep-merged-pr.sh
#
# Issue #1130: the stale in-progress sweeper in dev/dev-poll.sh only looked
# for OPEN PRs when deciding whether an in-progress issue has been abandoned.
# Between the moment a PR merges and the moment the issue is closed, the
# issue has no assignee, no open PR, and no agent lock — indistinguishable
# from abandonment — so the sweeper relabeled the issue "blocked" seconds
# after its PR merged (observed on #1094: merged 05:23:52, relabeled
# blocked 05:24:16).
#
# A merged PR is proof of completion, not staleness.
#
# Acceptance (self-contained — forge_api and curl are stubbed in-process):
#   1. in-progress issue, no assignee, no open PR, no lock, and a MERGED
#      linked PR → NOT relabeled to blocked.
#   2. In that case the issue is closed instead (issue_close called and the
#      in-progress label removed).
#   3. The same shape but no merged PR (only unrelated PRs, a
#      closed-but-unmerged PR, or no PR at all) → still relabeled to blocked
#      as before, and the issue is not closed.
#   4. An issue with an open PR is untouched — the stale-sweep handling is
#      only reached under the OPEN_PR=false guard (wiring intact).
#
# Read-only: no live services, no network. dev-poll.sh cannot be sourced
# (it is a top-level executable that would run the whole poll on source),
# so its two decision functions are extracted from the checkout with awk —
# the same approach as tests/acceptance/issue-846.sh.
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck disable=SC1091
source "$REPO_ROOT/tests/lib/acceptance-helpers.sh"

ac_require_cmd awk
ac_require_cmd jq

TARGET="$REPO_ROOT/dev/dev-poll.sh"
ac_assert_file "$TARGET" "dev/dev-poll.sh must exist"

ISSUE=1130
BRANCH="fix/issue-${ISSUE}"

# ── Env for the extracted code (mirrors dev-poll.sh globals) ───────────────
export API="http://forge.test/api/v1"
export FORGE_TOKEN="test-token"

# ── Stubs: serve the PR list, record every "mutating" call ─────────────────
# PR_JSON is what GET /pulls?state=all&limit=50 returns for the current
# scenario. CALLS records the mutating calls (issue_close,
# relabel_stale_issue, curl DELETE) so the sweep's decision can be asserted.
PR_JSON='[]'
CALLS=()

log() { :; }
_ilc_log() { :; }

forge_api() {
  local method="$1" path="$2"
  case "${method} ${path}" in
    "GET /pulls?state=all"*)
      printf '%s' "$PR_JSON"
      ;;
    *)
      printf 'null'
      ;;
  esac
}

curl() {
  CALLS+=("curl $*")
}

issue_close() { CALLS+=("issue_close $1"); }
relabel_stale_issue() { CALLS+=("relabel_stale_issue $1 $2"); }
_ilc_in_progress_id() { printf '4242'; }

has_call() {
  local c
  for c in "${CALLS[@]}"; do
    [ "$c" = "$1" ] && return 0
  done
  return 1
}

has_call_matching() {
  local c
  for c in "${CALLS[@]}"; do
    case "$c" in
      *"$1"*) return 0 ;;
    esac
  done
  return 1
}

# ── Extract the decision functions from dev-poll.sh ─────────────────────────
# dev-poll.sh is a top-level executable script (sourcing it would run the
# whole poll), so the functions are extracted by header — from `name() {` to
# the next column-0 closing brace — as issue-846.sh does for
# fetch_alloc_logs.
extract_fn() {
  local fn="$1"
  awk -v fn="$fn" '
    $0 ~ "^" fn "\\(\\) " { in_fn = 1; print; next }
    in_fn && /^\}/ { print; exit }
    in_fn { print }
  ' "$TARGET"
}

for fn in merged_pr_for_issue handle_stale_in_progress; do
  fn_body="$(extract_fn "$fn")"
  [ -n "$fn_body" ] || ac_fail "could not locate ${fn}() in dev/dev-poll.sh"
  eval "$fn_body"
done

# ── 1 + 2. Merged linked PR → close the issue, do NOT relabel blocked ──────
PR_JSON=$(jq -n --arg b "$BRANCH" '[
  { number: 2001, state: "open",   merged: false, head: { ref: "fix/issue-9999" } },
  { number: 2050, state: "closed", merged: false, head: { ref: "fix/issue-9998" } },
  { number: 2129, state: "closed", merged: true,  head: { ref: $b } }
]')

CALLS=()
handle_stale_in_progress "$ISSUE"

if has_call "relabel_stale_issue ${ISSUE} no_assignee_no_open_pr_no_lock"; then
  ac_fail "an issue whose PR has merged must NOT be relabeled to blocked (#1130)"
fi
has_call "issue_close ${ISSUE}" \
  || ac_fail "an issue with a merged PR must be closed (issue_close), but it was not"
has_call_matching "-X DELETE" \
  || ac_fail "closing via a merged PR must remove the in-progress label (no DELETE call recorded)"
has_call_matching "/issues/${ISSUE}/labels/" \
  || ac_fail "the in-progress label DELETE must target /issues/${ISSUE}/labels/"

# ── 3. No merged PR → relabel to blocked exactly as before ─────────────────
assert_relabel_only() {
  local what="$1"
  has_call "relabel_stale_issue ${ISSUE} no_assignee_no_open_pr_no_lock" \
    || ac_fail "expected a relabel to blocked, none recorded (${what})"
  if has_call "issue_close ${ISSUE}"; then
    ac_fail "the issue must not be closed when no PR has merged (${what})"
  fi
}

# 3a. Only unrelated PRs exist.
PR_JSON='[{"number":2001,"state":"open","merged":false,"head":{"ref":"fix/issue-9999"}}]'
CALLS=()
handle_stale_in_progress "$ISSUE"
assert_relabel_only "only unrelated PRs exist"

# 3b. A closed-but-UNMERGED PR on the issue's branch is not completion.
PR_JSON=$(jq -n --arg b "$BRANCH" '[
  { number: 2130, state: "closed", merged: false, head: { ref: $b } }
]')
CALLS=()
handle_stale_in_progress "$ISSUE"
assert_relabel_only "the linked PR was closed but never merged"

# 3c. No PR at all.
PR_JSON='[]'
CALLS=()
handle_stale_in_progress "$ISSUE"
assert_relabel_only "no PRs at all"

# ── 4. Open PR → untouched (sweep only reached under OPEN_PR=false) ─────────
guard_line=$(grep -n 'if \[ "$OPEN_PR" = false \] && \[ "$BLOCKED_BY_INPROGRESS" = false \]; then' "$TARGET" | head -n 1 | cut -d: -f1 || true)
sweep_line=$(grep -n 'handle_stale_in_progress "$ISSUE_NUM"' "$TARGET" | head -n 1 | cut -d: -f1 || true)
[ -n "$guard_line" ] \
  || ac_fail "dev/dev-poll.sh no longer guards the stale sweep on \$OPEN_PR=false — an issue with an open PR must be left untouched"
[ -n "$sweep_line" ] \
  || ac_fail "dev/dev-poll.sh no longer routes the stale in-progress case through handle_stale_in_progress"
[ "$sweep_line" -gt "$guard_line" ] \
  || ac_fail "handle_stale_in_progress is no longer reached under the OPEN_PR=false guard"

ac_pass
