#!/usr/bin/env bash
# =============================================================================
# tests/acceptance/issue-1690.sh
#
# Issue #1690: two reviewers poll the same PRs, and each container's review
# lock is in its own /tmp, so both can post a verdict on one head. A reviewer
# can be limited to PRs by some authors:
#   pr_author_allowed LOGIN  (lib/pr-author-filter.sh)
#     * REVIEW_ONLY_AUTHORS set and non-empty, LOGIN not one of them: return 1
#     * LOGIN one of REVIEW_SKIP_AUTHORS: return 1
#     * otherwise return 0 (both unset: every author allowed)
# review-poll.sh sources the filter, prints .user.login as the 4th PR field,
# and skips a head whose author this reviewer does not handle.
# agents-review-qwen sets REVIEW_SKIP_AUTHORS = "dev-grok-bot".
#
# Hermetic: no network, no forge, no agent. Sources the lib and greps wiring.
#
# Acceptance: `bash tests/acceptance/issue-1690.sh` exits 0 and calls ac_pass.
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=../../tests/lib/acceptance-helpers.sh
source "$REPO_ROOT/tests/lib/acceptance-helpers.sh"

ac_require_cmd bash grep
ac_assert_file "$REPO_ROOT/lib/pr-author-filter.sh" "lib/pr-author-filter.sh is missing"
ac_assert_file "$REPO_ROOT/review/review-poll.sh" "review/review-poll.sh is missing"
ac_assert_file "$REPO_ROOT/nomad/jobs/agents-review-qwen.hcl" \
  "nomad/jobs/agents-review-qwen.hcl is missing"

# shellcheck source=../../lib/pr-author-filter.sh
source "$REPO_ROOT/lib/pr-author-filter.sh"

# allowed_rc LOGIN — return code of pr_author_allowed in a subshell that
# sees only the REVIEW_* vars exported by the caller. A return of 1 must
# not trip set -e.
allowed_rc() {
  local login="$1"
  local rc=0
  pr_author_allowed "$login" || rc=$?
  printf '%s' "$rc"
}

# ── AC1: both variables unset — every author is allowed ─────────────────────
ac_log "AC1: both unset, pr_author_allowed dev-bot returns 0"
rc="$(
  unset REVIEW_ONLY_AUTHORS REVIEW_SKIP_AUTHORS
  allowed_rc dev-bot
)"
ac_assert_eq "$rc" "0" \
  "unset filters must allow dev-bot (got $rc)"

# ── AC2: REVIEW_ONLY_AUTHORS names one login ────────────────────────────────
ac_log "AC2: REVIEW_ONLY_AUTHORS=dev-grok-bot allows that login, refuses dev-bot"
rc="$(
  unset REVIEW_SKIP_AUTHORS
  export REVIEW_ONLY_AUTHORS="dev-grok-bot"
  allowed_rc dev-grok-bot
)"
ac_assert_eq "$rc" "0" \
  "ONLY list must allow dev-grok-bot (got $rc)"
rc="$(
  unset REVIEW_SKIP_AUTHORS
  export REVIEW_ONLY_AUTHORS="dev-grok-bot"
  allowed_rc dev-bot
)"
ac_assert_eq "$rc" "1" \
  "ONLY list must refuse dev-bot (got $rc)"

# ── AC3: REVIEW_SKIP_AUTHORS names two logins ───────────────────────────────
ac_log "AC3: REVIEW_SKIP_AUTHORS refuses gardener-bot, allows dev-bot"
rc="$(
  unset REVIEW_ONLY_AUTHORS
  export REVIEW_SKIP_AUTHORS="dev-grok-bot gardener-bot"
  allowed_rc gardener-bot
)"
ac_assert_eq "$rc" "1" \
  "SKIP list must refuse gardener-bot (got $rc)"
rc="$(
  unset REVIEW_ONLY_AUTHORS
  export REVIEW_SKIP_AUTHORS="dev-grok-bot gardener-bot"
  allowed_rc dev-bot
)"
ac_assert_eq "$rc" "0" \
  "SKIP list must allow dev-bot (got $rc)"

# ── AC4: review-poll wiring ─────────────────────────────────────────────────
ac_log "AC4: review-poll.sh sources the filter and gates on the author"
POLL="$REPO_ROOT/review/review-poll.sh"
grep -q 'source "$(dirname "$0")/../lib/pr-author-filter.sh"' "$POLL" \
  || ac_fail "review-poll.sh must source lib/pr-author-filter.sh"
grep -q '"\\(\.number) \\(\.head.sha) \\(\.head.ref) \\(\.user.login)"' "$POLL" \
  || ac_fail "review-poll.sh PRS jq must print .user.login as the 4th field"
HITS="$(grep -c 'pr_author_allowed "$PR_AUTHOR"' "$POLL" || true)"
ac_assert_eq "$HITS" "1" \
  "review-poll.sh must call pr_author_allowed \"\$PR_AUTHOR\" exactly once (got $HITS)"

# ── AC5: qwen reviewer skips dev-grok-bot ───────────────────────────────────
ac_log "AC5: agents-review-qwen.hcl sets REVIEW_SKIP_AUTHORS"
grep -q 'REVIEW_SKIP_AUTHORS = "dev-grok-bot"' \
  "$REPO_ROOT/nomad/jobs/agents-review-qwen.hcl" \
  || ac_fail "agents-review-qwen.hcl must set REVIEW_SKIP_AUTHORS = \"dev-grok-bot\""

ac_pass "issue #1690: a reviewer can be limited to PRs by some authors"
