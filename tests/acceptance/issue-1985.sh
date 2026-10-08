#!/usr/bin/env bash
# =============================================================================
# tests/acceptance/issue-1985.sh
#
# Issue #1985: the pre-lock merge also merges this agent's own issue-less PRs
# once approved and green.
#
# The pre-lock scan in dev/dev-poll.sh resolves each PR to an issue via
# extract_issue_from_pr (fix/issue-N branch, or a Closes/Fixes/Resolves #N
# title/body reference). A split-out PR — e.g. fix/edge-subpath-no-apk (#1960)
# — references no issue at all, and the scan `continue`s past it unless the
# branch matches ^chore/(gardener|planner|predictor)-. So even an approved,
# CI-green PR by the dev agent sat unmerged forever with no session owning it.
#
# Fix: in the PL_ISSUE-empty arm the scan now reads the PR author
# (.[$i].user.login) and, after the chore rule, treats PRs by $BOT_USER as
# issue 0 — the CI/approval gates below still decide whether the merge runs,
# and try_direct_merge closes nothing (issue 0). Every other author (owner,
# other bots) still `continue`s as before.
#
# Hermetic: no network. The pre-lock region is extracted from dev/dev-poll.sh
# (awk, from the "pre-lock: scanning" log line through the for-loop `done`,
# inclusive) and eval'd in a throwaway subshell against a fake forge (a PATH
# curl stub keyed on URL) and fake CI/review/merge helpers. The
# try_direct_merge stub writes its args to a file so they survive the
# subshell (the real scan's `exit 0` lives after the `done` and is outside
# the extracted region).
#
# Scenes (one PR each):
#   AC1  own (dev-grok-bot), fix/edge-x, no issue ref, approved + green
#        -> try_direct_merge "1960 0 <sha>"; own-issue-less log line present.
#   AC2  own, not yet approved -> no merge.
#   AC3  own, CI not green -> no merge.
#   AC4  author disinto-admin (owner), approved + green -> skipped.
#   AC5  author dev-bot (other bot), approved + green -> skipped.
#   AC6  chore/gardener-... (author disinto-admin), approved + green
#        -> merged as issue 0, as today.
#   AC7  fix/issue-12 (author dev-bot), approved + green
#        -> merged as issue 12 with the issue-assignee check still in the loop,
#        as today.
#
# Run via: tools/run-acceptance.sh 1985
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck disable=SC1091
source "$REPO_ROOT/tests/lib/acceptance-helpers.sh"

ac_require_cmd awk bash jq seq

DEV_POLL="$REPO_ROOT/dev/dev-poll.sh"
ac_assert_file "$DEV_POLL" "dev-poll.sh is missing"
ac_log "syntax-check dev/dev-poll.sh"
bash -n "$DEV_POLL" || ac_fail "dev-poll.sh failed bash -n"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# ── Extract the pre-lock scan region ─────────────────────────────────────────
# From the scanning log through the for-loop's closing `done` — exactly the
# loop body, no `exit 0` (that lives after the `done`), so TDM args survive
# the subshell to a temp file.
REGION="$(awk '
  /pre-lock: scanning for mergeable PRs/ { inreg=1; print; next }
  inreg && /^[[:space:]]*done[[:space:]]*$/ { print; inreg=0; next }
  inreg { print }
' "$DEV_POLL")"
[ -n "$REGION" ] || ac_fail "could not extract the pre-lock scan region from dev-poll.sh"

# The region must still carry all the wiring the sibling tests depend on.
grep -qF 'extract_issue_from_pr "$PL_PR_BRANCH" "$PL_PR_TITLE" "$PL_PR_BODY"' <<< "$REGION" \
  || ac_fail "pre-lock region lost its extract_issue_from_pr call"
grep -qF '"$PL_PR_BRANCH" =~ ^chore/(gardener|planner|predictor)-' <<< "$REGION" \
  || ac_fail "pre-lock region lost its chore rule (chore PRs must still merge as issue 0)"
grep -qF 'PL_PR_AUTHOR' <<< "$REGION" \
  || ac_fail "pre-lock region does not read the PR author (#1985)"
# shellcheck disable=SC2154  # $i is a literal jq path inside the grep pattern
grep -qF '.[$i].user.login' <<< "$REGION" \
  || ac_fail "pre-lock region must read the PR author from .[$i].user.login (#1985)"
grep -qF '"$PL_PR_AUTHOR" = "$BOT_USER"' <<< "$REGION" \
  || ac_fail "pre-lock region does not gate its own-PR arm on $BOT_USER (#1985)"
grep -qF 'has no linked issue — own PR, merge as issue-less once approved and green' <<< "$REGION" \
  || ac_fail "pre-lock region lost the own-issue-less log message (#1985)"

# ── Hermetic forge: curl stub + fake helpers ─────────────────────────────────
mkdir -p "$TMP/stub"
cat > "$TMP/stub/curl" <<'STUB'
#!/usr/bin/env bash
# Fake forge for issue-1985 (env-driven, no network). Last arg is the URL.
url="${@: -1}"
case "$url" in
  *'/pulls?state=open'*)
    printf '%s\n' "$AC_PRS_JSON"
    ;;
  *'/pulls/'*'/reviews')
    if [ "${AC_APPROVE:-0}" = "1" ]; then
      printf '%s\n' '[{"id":99,"state":"APPROVED","stale":false,"user":{"login":"review-bot"},"submitted_at":"2026-10-08T00:00:00Z"}]'
    else
      printf '%s\n' '[]'
    fi
    ;;
  *'/issues/'*)
    printf '%s\n' "${AC_ISSUE_JSON:-{}}"
    ;;
  *)
    exit 22
    ;;
esac
STUB
chmod +x "$TMP/stub/curl"

# The "own" agent identity the pre-lock region gates on (#1985). Set it here
# explicitly — and export it so every scene subshell inherits it — rather than
# relying on the surrounding environment. The scenes use a *second*, distinct
# identity (dev-bot) as the "other bot" control case.
export BOT_USER="dev-grok-bot"

# Function under test (extracted, same as issue-1671).
FN_SRC="$(ac_extract_fn extract_issue_from_pr "$DEV_POLL")"
[ -n "$FN_SRC" ] || ac_fail "could not extract extract_issue_from_pr() from dev-poll.sh"

# Build the one-PR listing JSON for a scene. The region treats $PL_PRS as a
# JSON *array* of PRs (it does jq 'length' and '.[i].field'), so wrap the
# single PR in a top-level array.
pr_json() {
  local num="$1" sha="$2" ref="$3" title="$4" body="$5" author="$6"
  jq -cn --argjson n "$num" --arg sha "$sha" --arg ref "$ref" \
     --arg title "$title" --arg body "$body" --arg author "$author" \
     '[{number:$n, head:{sha:$sha, ref:$ref}, title:$title, body:$body, user:{login:$author}}]'
}

# Run the pre-lock region in a subshell against the fake forge with these scene
# vars; capture try_direct_merge args + logs:
#   TDM_CALLS = number of try_direct_merge invocations
#   LAST_TDM  = "pr_num issue_num head_sha" (empty if none)
#   SCENE_LOG = the region's log output
#
# $1 author   $2 pr_num  $3 branch  $4 title  $5 body
# $6 ci_state $7 approved(0/1) $8 issue JSON
run_scene() {
  local author="$1" pr_num="$2" branch="$3" title="$4" body="$5"
  local ci="$6" approve="$7" issue_json="$8"
  local tdmfile logf prs_json
  tdmfile="$TMP/tdm.${pr_num}"
  logf="$TMP/log.${pr_num}"
  : > "$tdmfile"; : > "$logf"
  prs_json="$(pr_json "$pr_num" "sha-${pr_num}" "$branch" "$title" "$body" "$author")"

  local rc=0
  (
    set -euo pipefail
    export API="/api/v1" FORGE_TOKEN="acceptance-token"
    export PATH="$TMP/stub:/usr/local/bin:/usr/bin:/bin"
    export AC_PRS_JSON="$prs_json" AC_APPROVE="$approve" AC_CI_STATE="$ci"
    export AC_ISSUE_JSON="$issue_json" AC_TDM_RC=0
    TDM_FILE="$tdmfile" LOG_FILE="$logf"
    # --- fake helpers the region calls, keyed on the scene env ---
    log() { printf '%s\n' "$*" >> "$LOG_FILE"; }
    ci_commit_status() { printf '%s' "$AC_CI_STATE"; }
    ci_passed() { case "$1" in success|passed) return 0;; *) return 1;; esac; }
    ci_required_for_pr() { return 0; }
    pr_live_review_count() { printf '%s' "$AC_APPROVE"; }
    issue_is_dev_claimable() { return 0; }
    emit_tape_outcome() { :; }
    try_direct_merge() { printf '%s %s %s\n' "$1" "$2" "$3" >> "$TDM_FILE"; return "${AC_TDM_RC:-0}"; }
    # --- then the extracted function and the pre-lock region ---
    eval "$FN_SRC"
    eval "$REGION"
  ) 2>>"$logf" || rc=$?

  if [ "$rc" -ne 0 ]; then
    ac_fail "scene subshell exited $rc (pr #$pr_num, author=$author, ci=$ci, approve=$approve): $(cat "$logf" 2>/dev/null)"
  fi
  TDM_CALLS="$(wc -l < "$tdmfile" 2>/dev/null | tr -d '[:space:]')"
  LAST_TDM="$(tail -n 1 "$tdmfile" 2>/dev/null || true)"
  SCENE_LOG="$(cat "$logf" 2>/dev/null || true)"
}

OWN_BODY="no linked issue reference in this split-out PR"

# ── AC1: own issue-less PR, approved + green -> merged as issue 0 ────────────
ac_log "AC1: own (dev-grok-bot) issue-less PR, approved + green -> merged as issue 0"
run_scene "dev-grok-bot" 1960 "fix/edge-x" "fix: edge subpath no apk" "$OWN_BODY" "success" "1" "{}"
ac_assert_eq "$TDM_CALLS" "1" \
  "AC1: own issue-less approved+green PR must be merged exactly once (got $TDM_CALLS)"
ac_assert_eq "$LAST_TDM" "1960 0 sha-1960" \
  "AC1: try_direct_merge must be called with issue 0 (got: $LAST_TDM)"
grep -qF "PR #1960 has no linked issue — own PR, merge as issue-less once approved and green" <<< "$SCENE_LOG" \
  || ac_fail "AC1: own-issue-less log line missing (log: $SCENE_LOG)"

# ── AC2: own issue-less PR, not approved -> not merged ───────────────────────
ac_log "AC2: own issue-less PR, NOT approved -> not merged"
run_scene "dev-grok-bot" 1960 "fix/edge-x" "fix: edge subpath no apk" "$OWN_BODY" "success" "0" "{}"
ac_assert_eq "$TDM_CALLS" "0" \
  "AC2: own issue-less unapproved PR must not merge (got $TDM_CALLS)"

# ── AC3: own issue-less PR, CI not green -> not merged ───────────────────────
ac_log "AC3: own issue-less PR, CI not green -> not merged"
run_scene "dev-grok-bot" 1960 "fix/edge-x" "fix: edge subpath no apk" "$OWN_BODY" "failed" "1" "{}"
ac_assert_eq "$TDM_CALLS" "0" \
  "AC3: own issue-less PR with red CI must not merge (got $TDM_CALLS)"

# ── AC4: other author (owner) -> skipped, as today ───────────────────────────
ac_log "AC4: issue-less PR by disinto-admin (owner) -> skipped"
run_scene "disinto-admin" 1960 "fix/edge-x" "fix: edge subpath no apk" "$OWN_BODY" "success" "1" "{}"
ac_assert_eq "$TDM_CALLS" "0" \
  "AC4: issue-less PR by the owner must be skipped (got $TDM_CALLS)"

# ── AC5: other author (other bot) -> skipped, as today ───────────────────────
ac_log "AC5: issue-less PR by dev-bot (other bot) -> skipped"
run_scene "dev-bot" 1960 "fix/edge-x" "fix: edge subpath no apk" "$OWN_BODY" "success" "1" "{}"
ac_assert_eq "$TDM_CALLS" "0" \
  "AC5: issue-less PR by another bot must be skipped (got $TDM_CALLS)"

# ── AC6: chore/gardener-... PR -> merged as issue 0, as today ─────────────────
ac_log "AC6: chore/gardener-... PR (author disinto-admin), approved + green -> issue 0"
run_scene "disinto-admin" 2000 "chore/gardener-20261007-0320" "chore: cleanup" "housekeeping" "success" "1" "{}"
ac_assert_eq "$TDM_CALLS" "1" \
  "AC6: chore/gardener PR must still merge (got $TDM_CALLS)"
ac_assert_eq "$LAST_TDM" "2000 0 sha-2000" \
  "AC6: chore/gardener PR must merge as issue 0 (got: $LAST_TDM)"

# ── AC7: fix/issue-12 PR -> merged as issue 12, as today ──────────────────────
ac_log "AC7: fix/issue-12 PR (author dev-bot), approved + green -> issue 12"
run_scene "dev-bot" 2001 "fix/issue-12" "fix: issue 12" "Closes #12" "success" "1" \
  "$(jq -cn '{assignee:null, labels:[{name:"backlog"}]}')"
ac_assert_eq "$TDM_CALLS" "1" \
  "AC7: fix/issue-12 PR must still merge (got $TDM_CALLS)"
ac_assert_eq "$LAST_TDM" "2001 12 sha-2001" \
  "AC7: fix/issue-12 PR must merge as issue 12 (got: $LAST_TDM)"

ac_log "all acceptance criteria met for issue 1985"
ac_pass "pre-lock merge merges the agent's own issue-less PRs once approved and green"