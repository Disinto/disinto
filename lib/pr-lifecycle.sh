#!/usr/bin/env bash
# pr-lifecycle.sh — Reusable PR lifecycle library: create, poll, review, merge
#
# Source after lib/env.sh and lib/ci-helpers.sh:
#   source "$FACTORY_ROOT/lib/ci-helpers.sh"
#   source "$FACTORY_ROOT/lib/pr-lifecycle.sh"
#
# Required globals: FORGE_TOKEN, FORGE_API, PRIMARY_BRANCH
# Optional: FORGE_REMOTE (default: origin), WOODPECKER_REPO_ID,
#   WOODPECKER_TOKEN, WOODPECKER_SERVER, FACTORY_ROOT
#
# For pr_walk_to_merge(): caller must define agent_run() — a synchronous Claude
# invocation (one-shot claude -p). Expected signature:
#   agent_run [--resume SESSION] [--worktree DIR] PROMPT
#
# Functions:
#   pr_create              BRANCH TITLE BODY [BASE_BRANCH]
#   pr_find_by_branch      BRANCH
#   pr_poll_ci             PR_NUMBER [TIMEOUT_SECS] [POLL_INTERVAL]
#   pr_poll_review         PR_NUMBER [TIMEOUT_SECS] [POLL_INTERVAL]
#   pr_merge               PR_NUMBER [COMMIT_MSG]
#   pr_is_merged           PR_NUMBER
#   pr_walk_to_merge       PR_NUMBER SESSION_ID WORKTREE [MAX_CI_FIXES] [MAX_REVIEW_ROUNDS]
#   build_phase_protocol_prompt  BRANCH [REMOTE]
#
# Output variables (set by poll/merge functions, read by callers):
#   _PR_CI_STATE          success | failure | timeout
#   _PR_CI_SHA            commit SHA that was polled
#   _PR_CI_PIPELINE       Woodpecker pipeline number (on failure)
#   _PR_CI_FAILURE_TYPE   infra | code (on failure)
#   _PR_CI_ERROR_LOG      CI error log snippet (on failure)
#   _PR_REVIEW_VERDICT    APPROVE | REQUEST_CHANGES | DISCUSS | TIMEOUT |
#                         MERGED_EXTERNALLY | CLOSED_EXTERNALLY
#   _PR_REVIEW_TEXT       review feedback body text
#   _PR_MERGE_ERROR       merge error description (on failure)
#   _PR_WALK_EXIT_REASON  merged | ci_exhausted | review_exhausted |
#                         ci_timeout | review_timeout | merge_blocked |
#                         closed_externally | unexpected_verdict
#
# shellcheck shell=bash

set -euo pipefail

# Default agent_run stub — callers override by defining agent_run() or sourcing
# an SDK (e.g., lib/sdk.sh) after this file.
if ! type agent_run &>/dev/null; then
  agent_run() {
    printf 'ERROR: agent_run() not defined — source your SDK before calling pr_walk_to_merge\n' >&2
    return 1
  }
fi

# Internal log helper.
_prl_log() {
  if declare -f log >/dev/null 2>&1; then
    log "pr-lifecycle: $*"
  else
    printf '[%s] pr-lifecycle: %s\n' "$(date -u '+%Y-%m-%d %H:%M:%S UTC')" "$*" >&2
  fi
}

# ---------------------------------------------------------------------------
# pr_create — Create a PR via forge API.
# Args: branch title body [base_branch] [api_url]
# Stdout: PR number
# Returns: 0=created (or found existing), 1=failed
# api_url defaults to FORGE_API if not provided
# ---------------------------------------------------------------------------
pr_create() {
  local branch="$1" title="$2" body="$3"
  local base="${4:-${PRIMARY_BRANCH:-main}}"
  local api_url="${5:-${FORGE_API}}"
  local tmpfile resp http_code resp_body pr_num

  tmpfile=$(mktemp /tmp/prl-create-XXXXXX.json)
  jq -n --arg t "$title" --arg b "$body" --arg h "$branch" --arg base "$base" \
    '{title:$t, body:$b, head:$h, base:$base}' > "$tmpfile"

  resp=$(curl -s -w "\n%{http_code}" -X POST \
    -H "Authorization: token ${FORGE_TOKEN}" \
    -H "Content-Type: application/json" \
    "${api_url}/pulls" \
    --data-binary @"$tmpfile") || true
  rm -f "$tmpfile"

  http_code=$(printf '%s\n' "$resp" | tail -1)
  resp_body=$(printf '%s\n' "$resp" | sed '$d')

  case "$http_code" in
    200|201)
      pr_num=$(printf '%s' "$resp_body" | jq -r '.number')
      _prl_log "created PR #${pr_num}"
      printf '%s' "$pr_num"
      return 0
      ;;
    409)
      pr_num=$(pr_find_by_branch "$branch" "$api_url") || true
      if [ -n "$pr_num" ]; then
        _prl_log "PR already exists: #${pr_num}"
        printf '%s' "$pr_num"
        return 0
      fi
      _prl_log "PR creation failed: 409 conflict, no existing PR found"
      return 1
      ;;
    *)
      _prl_log "PR creation failed (HTTP ${http_code})"
      return 1
      ;;
  esac
}

# ---------------------------------------------------------------------------
# pr_find_by_branch — Find an open PR by head branch name.
# Args: branch [api_url]
# Stdout: PR number
# Returns: 0=found, 1=not found
# api_url defaults to FORGE_API if not provided
# ---------------------------------------------------------------------------
pr_find_by_branch() {
  local branch="$1"
  local api_url="${2:-${FORGE_API}}"
  local pr_num
  pr_num=$(curl -sf -H "Authorization: token ${FORGE_TOKEN}" \
    "${api_url}/pulls?state=open&limit=20" | \
    jq -r --arg b "$branch" '.[] | select(.head.ref == $b) | .number' \
    | head -1) || true
  if [ -n "$pr_num" ]; then
    printf '%s' "$pr_num"
    return 0
  fi
  return 1
}

# ---------------------------------------------------------------------------
# pr_poll_ci — Poll CI status until complete or timeout.
# Args: pr_number [timeout_secs=1800] [poll_interval=30]
# Sets: _PR_CI_STATE _PR_CI_SHA _PR_CI_PIPELINE _PR_CI_FAILURE_TYPE _PR_CI_ERROR_LOG
# Returns: 0=success, 1=failure, 2=timeout
# ---------------------------------------------------------------------------
# shellcheck disable=SC2034  # output vars read by callers
pr_poll_ci() {
  local pr_num="$1"
  local timeout="${2:-1800}" interval="${3:-30}"
  local elapsed=0

  _PR_CI_STATE="" ; _PR_CI_SHA="" ; _PR_CI_PIPELINE=""
  _PR_CI_FAILURE_TYPE="" ; _PR_CI_ERROR_LOG=""

  _PR_CI_SHA=$(forge_api GET "/pulls/${pr_num}" | jq -r '.head.sha') || true
  if [ -z "$_PR_CI_SHA" ]; then
    _prl_log "cannot get HEAD SHA for PR #${pr_num}"
    _PR_CI_STATE="failure"
    return 1
  fi

  if [ "${WOODPECKER_REPO_ID:-2}" = "0" ]; then
    _PR_CI_STATE="success"
    _prl_log "no CI configured"
    return 0
  fi

  if ! ci_required_for_pr "$pr_num"; then
    _PR_CI_STATE="success"
    _prl_log "PR #${pr_num} non-code — CI not required"
    return 0
  fi

  _prl_log "polling CI for PR #${pr_num} SHA ${_PR_CI_SHA:0:7}"
  while [ "$elapsed" -lt "$timeout" ]; do
    sleep "$interval"
    elapsed=$((elapsed + interval))

    local state
    state=$(ci_commit_status "$_PR_CI_SHA") || true
    case "$state" in
      success)
        _PR_CI_STATE="success"
        _prl_log "CI passed"
        return 0
        ;;
      failure|error)
        _PR_CI_STATE="failure"
        _PR_CI_PIPELINE=$(ci_pipeline_number "$_PR_CI_SHA") || true
        if [ -n "$_PR_CI_PIPELINE" ] && [ -n "${WOODPECKER_REPO_ID:-}" ]; then
          _PR_CI_FAILURE_TYPE=$(classify_pipeline_failure \
            "$WOODPECKER_REPO_ID" "$_PR_CI_PIPELINE" 2>/dev/null \
            | cut -d' ' -f1) || _PR_CI_FAILURE_TYPE="code"
          if [ -n "${FACTORY_ROOT:-}" ]; then
            _PR_CI_ERROR_LOG=$(bash "${FACTORY_ROOT}/lib/ci-debug.sh" \
              failures "$_PR_CI_PIPELINE" 2>/dev/null \
              | tail -80 | head -c 8000) || true
          fi
        fi
        _prl_log "CI failed (type: ${_PR_CI_FAILURE_TYPE:-unknown})"
        return 1
        ;;
    esac
  done

  _PR_CI_STATE="timeout"
  _prl_log "CI timeout after ${timeout}s"
  return 2
}

# ---------------------------------------------------------------------------
# pr_poll_review — Poll for review verdict on a PR.
# Args: pr_number [timeout_secs=10800] [poll_interval=300]
# Sets: _PR_REVIEW_VERDICT _PR_REVIEW_TEXT
# Returns: 0=verdict found, 1=timeout, 2=PR closed/merged externally
# ---------------------------------------------------------------------------
# shellcheck disable=SC2034  # output vars read by callers
pr_poll_review() {
  local pr_num="$1"
  local timeout="${2:-10800}" interval="${3:-300}"
  local elapsed=0

  _PR_REVIEW_VERDICT="" ; _PR_REVIEW_TEXT=""

  _prl_log "polling review for PR #${pr_num}"
  while [ "$elapsed" -lt "$timeout" ]; do
    sleep "$interval"
    elapsed=$((elapsed + interval))

    local pr_json sha
    pr_json=$(forge_api GET "/pulls/${pr_num}") || true
    sha=$(printf '%s' "$pr_json" | jq -r '.head.sha // empty') || true

    # Check if PR closed/merged externally
    local pr_state pr_merged
    pr_state=$(printf '%s' "$pr_json" | jq -r '.state // "unknown"')
    pr_merged=$(printf '%s' "$pr_json" | jq -r '.merged // false')
    if [ "$pr_state" != "open" ]; then
      if [ "$pr_merged" = "true" ]; then
        _PR_REVIEW_VERDICT="MERGED_EXTERNALLY"
        _prl_log "PR #${pr_num} merged externally"
        return 2
      fi
      _PR_REVIEW_VERDICT="CLOSED_EXTERNALLY"
      _prl_log "PR #${pr_num} closed externally"
      return 2
    fi

    # Check bot review comment (<!-- reviewed: SHA -->)
    local review_comment review_text="" verdict=""
    review_comment=$(forge_api_all "/issues/${pr_num}/comments" | \
      jq -r --arg sha "${sha:-}" \
      '[.[] | select(.body | contains("<!-- reviewed: " + $sha))] | last // empty') || true

    if [ -n "$review_comment" ] && [ "$review_comment" != "null" ]; then
      review_text=$(printf '%s' "$review_comment" | jq -r '.body')
      # Skip error reviews
      if printf '%s' "$review_text" | grep -q 'review-error\|Review — Error'; then
        _prl_log "review error — waiting for re-review"
        continue
      fi
      verdict=$(printf '%s' "$review_text" | \
        grep -oP '\*\*(APPROVE|REQUEST_CHANGES|DISCUSS)\*\*' | head -1 | tr -d '*') || true
    fi

    # Fallback: formal forge reviews
    if [ -z "$verdict" ]; then
      verdict=$(forge_api GET "/pulls/${pr_num}/reviews" | \
        jq -r '[.[] | select(.stale == false)] | last | .state // empty') || true
      case "$verdict" in
        APPROVED) verdict="APPROVE" ;;
        REQUEST_CHANGES) ;;
        *) verdict="" ;;
      esac
    fi

    if [ -n "$verdict" ]; then
      _PR_REVIEW_VERDICT="$verdict"
      _PR_REVIEW_TEXT="${review_text:-}"
      _prl_log "review verdict: ${verdict}"
      return 0
    fi

    _prl_log "waiting for review on PR #${pr_num} (${elapsed}s)"
  done

  _PR_REVIEW_VERDICT="TIMEOUT"
  _prl_log "review timeout after ${timeout}s"
  return 1
}

# ---------------------------------------------------------------------------
# pr_merge — Merge a PR via forge API.
# Args: pr_number [commit_message]
# Sets: _PR_MERGE_ERROR (on failure)
# Returns: 0=merged, 1=error, 2=blocked (HTTP 405)
# ---------------------------------------------------------------------------
# shellcheck disable=SC2034  # _PR_MERGE_ERROR read by callers
pr_merge() {
  local pr_num="$1" commit_msg="${2:-}"
  local merge_data resp http_code body

  _PR_MERGE_ERROR=""

  merge_data='{"Do":"merge","delete_branch_after_merge":true}'
  if [ -n "$commit_msg" ]; then
    merge_data=$(jq -nc --arg m "$commit_msg" \
      '{Do:"merge",delete_branch_after_merge:true,MergeMessageField:$m}')
  fi

  resp=$(curl -s -w "\n%{http_code}" -X POST \
    -H "Authorization: token ${FORGE_TOKEN}" \
    -H 'Content-Type: application/json' \
    "${FORGE_API}/pulls/${pr_num}/merge" \
    -d "$merge_data") || true
  http_code=$(printf '%s\n' "$resp" | tail -1)
  body=$(printf '%s\n' "$resp" | sed '$d')

  case "$http_code" in
    200|204)
      _prl_log "PR #${pr_num} merged"
      return 0
      ;;
    405)
      # Check if already merged (race with another agent)
      local merged
      merged=$(forge_api GET "/pulls/${pr_num}" | jq -r '.merged // false') || true
      if [ "$merged" = "true" ]; then
        _prl_log "PR #${pr_num} already merged"
        return 0
      fi
      _PR_MERGE_ERROR="blocked (HTTP 405): ${body:0:200}"
      _prl_log "PR #${pr_num} merge blocked: ${_PR_MERGE_ERROR}"
      return 2
      ;;
    *)
      _PR_MERGE_ERROR="failed (HTTP ${http_code}): ${body:0:200}"
      _prl_log "PR #${pr_num} merge failed: ${_PR_MERGE_ERROR}"
      return 1
      ;;
  esac
}

# ---------------------------------------------------------------------------
# pr_is_merged — Check if a PR is merged.
# Args: pr_number
# Returns: 0=merged, 1=not merged
# ---------------------------------------------------------------------------
pr_is_merged() {
  local pr_num="$1"
  local merged
  merged=$(forge_api GET "/pulls/${pr_num}" | jq -r '.merged // false') || true
  [ "$merged" = "true" ]
}

# ---------------------------------------------------------------------------
# pr_close — Close a PR via forge API.
# Args: pr_number
# Returns: 0=closed, 1=error
# ---------------------------------------------------------------------------
pr_close() {
  local pr_num="$1"

  _prl_log "closing PR #${pr_num}"
  curl -sf -X PATCH \
    -H "Authorization: token ${FORGE_TOKEN}" \
    -H "Content-Type: application/json" \
    "${FORGE_API}/pulls/${pr_num}" \
    -d '{"state":"closed"}' >/dev/null 2>&1 || true
}

# ---------------------------------------------------------------------------
# pr_walk_to_merge — Walk a PR through CI, review, and merge.
#
# Requires agent_run() defined by the caller (synchronous Claude invocation).
# The orchestrator bash loop IS the state machine — no phase files needed.
#
# Args: pr_number session_id worktree [max_ci_fixes=3] [max_review_rounds=5]
# Returns: 0=merged, 1=exhausted or unrecoverable failure
# Sets: _PR_WALK_EXIT_REASON
# ---------------------------------------------------------------------------
# shellcheck disable=SC2034  # _PR_WALK_EXIT_REASON read by callers
pr_walk_to_merge() {
  local pr_num="$1" session_id="$2" worktree="$3"
  local max_ci_fixes="${4:-3}" max_review_rounds="${5:-5}"
  local ci_fix_count=0 ci_retry_count=0 review_round=0
  local rc=0 remote="${FORGE_REMOTE:-origin}"

  _PR_WALK_EXIT_REASON=""
  _prl_log "walking PR #${pr_num} to merge (max CI: ${max_ci_fixes}, max review: ${max_review_rounds})"

  while true; do
    # ── Poll CI ────────────────────────────────────────────────────────
    rc=0; pr_poll_ci "$pr_num" || rc=$?

    if [ "$rc" -eq 2 ]; then
      _PR_WALK_EXIT_REASON="ci_timeout"
      return 1
    fi

    if [ "$rc" -eq 1 ]; then
      # Infra failure — retry once via empty commit + push
      if [ "${_PR_CI_FAILURE_TYPE:-}" = "infra" ] && [ "$ci_retry_count" -lt 1 ]; then
        ci_retry_count=$((ci_retry_count + 1))
        _prl_log "infra failure — retriggering CI (retry ${ci_retry_count})"
        ( cd "$worktree" && \
          git commit --allow-empty -m "ci: retrigger after infra failure" --no-verify && \
          git fetch "$remote" "${PRIMARY_BRANCH}" 2>/dev/null && \
          git rebase "${remote}/${PRIMARY_BRANCH}" && \
          git push --force-with-lease "$remote" HEAD ) 2>&1 | tail -5 || true
        continue
      fi

      ci_fix_count=$((ci_fix_count + 1))
      if [ "$ci_fix_count" -gt "$max_ci_fixes" ]; then
        _prl_log "CI fix budget exhausted (${ci_fix_count}/${max_ci_fixes})"
        _PR_WALK_EXIT_REASON="ci_exhausted"
        return 1
      fi

      _prl_log "CI failed — invoking agent (attempt ${ci_fix_count}/${max_ci_fixes})"

      # Get CI logs from SQLite database if available
      local ci_logs=""
      if [ -n "$_PR_CI_PIPELINE" ] && [ -n "${FACTORY_ROOT:-}" ]; then
        ci_logs=$(ci_get_logs "$_PR_CI_PIPELINE" 2>/dev/null | tail -50) || ci_logs=""
      fi

      local logs_section=""
      if [ -n "$ci_logs" ]; then
        logs_section="
CI Log Output (last 50 lines):
\`\`\`
${ci_logs}
\`\`\`
"
      fi

      agent_run --resume "$session_id" --worktree "$worktree" \
        "CI failed on PR #${pr_num} (attempt ${ci_fix_count}/${max_ci_fixes}).

Pipeline: #${_PR_CI_PIPELINE:-?}
Failure type: ${_PR_CI_FAILURE_TYPE:-unknown}

Error log:
${_PR_CI_ERROR_LOG:-No logs available.}${logs_section}

Fix the issue, run tests, commit, rebase on ${PRIMARY_BRANCH}, and push:
  git fetch ${remote} ${PRIMARY_BRANCH} && git rebase ${remote}/${PRIMARY_BRANCH}
  git push --force-with-lease ${remote} HEAD" || true
      continue
    fi

    # CI passed — reset fix budget
    ci_fix_count=0

    # ── Poll review ──────────────────────────────────────────────────────
    rc=0; pr_poll_review "$pr_num" || rc=$?

    if [ "$rc" -eq 1 ]; then
      _PR_WALK_EXIT_REASON="review_timeout"
      return 1
    fi

    if [ "$rc" -eq 2 ]; then
      if [ "$_PR_REVIEW_VERDICT" = "MERGED_EXTERNALLY" ]; then
        _PR_WALK_EXIT_REASON="merged"
        return 0
      fi
      _PR_WALK_EXIT_REASON="closed_externally"
      return 1
    fi

    case "$_PR_REVIEW_VERDICT" in
      APPROVE)
        # ── Merge ──────────────────────────────────────────────────────
        rc=0; pr_merge "$pr_num" || rc=$?
        if [ "$rc" -eq 0 ]; then
          _PR_WALK_EXIT_REASON="merged"
          return 0
        fi
        if [ "$rc" -eq 2 ]; then
          _PR_WALK_EXIT_REASON="merge_blocked"
          return 1
        fi
        # Merge failed (conflict) — ask agent to rebase
        _prl_log "merge failed — invoking agent to rebase"
        agent_run --resume "$session_id" --worktree "$worktree" \
          "PR #${pr_num} approved but merge failed: ${_PR_MERGE_ERROR:-unknown}

Rebase onto ${PRIMARY_BRANCH} and push:
  git fetch ${remote} ${PRIMARY_BRANCH} && git rebase ${remote}/${PRIMARY_BRANCH}
  git push --force-with-lease ${remote} HEAD" || true
        continue
        ;;

      REQUEST_CHANGES|DISCUSS)
        review_round=$((review_round + 1))
        if [ "$review_round" -gt "$max_review_rounds" ]; then
          _prl_log "review budget exhausted (${review_round}/${max_review_rounds})"
          _PR_WALK_EXIT_REASON="review_exhausted"
          return 1
        fi
        ci_fix_count=0  # Reset CI fix budget per review cycle

        _prl_log "review changes requested (round ${review_round}/${max_review_rounds})"
        agent_run --resume "$session_id" --worktree "$worktree" \
          "Review feedback (round ${review_round}/${max_review_rounds}) on PR #${pr_num}:

${_PR_REVIEW_TEXT:-No review text available.}

Address each piece of feedback. Run lint and tests.
Commit, rebase on ${PRIMARY_BRANCH}, and push:
  git fetch ${remote} ${PRIMARY_BRANCH} && git rebase ${remote}/${PRIMARY_BRANCH}
  git push --force-with-lease ${remote} HEAD" || true
        continue
        ;;

      *)
        _prl_log "unexpected verdict: ${_PR_REVIEW_VERDICT:-empty}"
        _PR_WALK_EXIT_REASON="unexpected_verdict"
        return 1
        ;;
    esac
  done
}

# ---------------------------------------------------------------------------
# build_phase_protocol_prompt — Generate push/commit instructions for Claude.
#
# For the synchronous agent_run architecture: tells Claude how to commit and
# push (no phase files).
#
# Args: branch [remote]
# Stdout: instruction text
# ---------------------------------------------------------------------------
build_phase_protocol_prompt() {
  local branch="$1" remote="${2:-${FORGE_REMOTE:-origin}}"
  cat <<_PRL_PROMPT_EOF_
## Git workflow

After implementing changes:
1. Stage and commit with a descriptive message.
2. Rebase on the target branch before pushing:
   git fetch ${remote} ${PRIMARY_BRANCH} && git rebase ${remote}/${PRIMARY_BRANCH}
3. Push your branch:
   git push ${remote} ${branch}
   If rejected, use: git push --force-with-lease ${remote} ${branch}

If you encounter rebase conflicts:
1. Resolve conflicts in the affected files.
2. Stage resolved files: git add <files>
3. Continue rebase: git rebase --continue
4. Push with --force-with-lease.
_PRL_PROMPT_EOF_
}
