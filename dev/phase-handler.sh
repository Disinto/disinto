#!/usr/bin/env bash
# dev/phase-handler.sh — Phase callback functions for dev-agent.sh
#
# Source this file from agent orchestrators after lib/agent-session.sh is loaded.
# Defines: post_refusal_comment(), _on_phase_change(), build_phase_protocol_prompt()
#
# Required globals (set by calling agent before or after sourcing):
#   ISSUE, FORGE_TOKEN, API, FORGE_WEB, PROJECT_NAME, FACTORY_ROOT
#   BRANCH, PHASE_FILE, WORKTREE, IMPL_SUMMARY_FILE
#   PRIMARY_BRANCH, SESSION_NAME, LOGFILE, ISSUE_TITLE
#   WOODPECKER_REPO_ID, WOODPECKER_TOKEN, WOODPECKER_SERVER
#
# Globals with defaults (agents can override after sourcing):
#   PR_NUMBER, CI_POLL_TIMEOUT, MAX_CI_FIXES, MAX_REVIEW_ROUNDS,
#   REVIEW_POLL_TIMEOUT, CI_RETRY_COUNT, CI_FIX_COUNT, REVIEW_ROUND,
#   CLAIMED, PHASE_POLL_INTERVAL
#
# Calls back to agent-defined helpers:
#   cleanup_worktree(), cleanup_labels(), status(), log()
#
# shellcheck shell=bash
# shellcheck disable=SC2154  # globals are set in dev-agent.sh before calling
# shellcheck disable=SC2034  # CLAIMED is read by cleanup() in dev-agent.sh

# Load secret scanner for redacting tmux output before posting to issues
# shellcheck source=../lib/secret-scan.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib/secret-scan.sh"

# Load shared CI helpers (is_infra_step, classify_pipeline_failure, etc.)
# shellcheck source=../lib/ci-helpers.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib/ci-helpers.sh"

# Load mirror push helper
# shellcheck source=../lib/mirrors.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib/mirrors.sh"

# --- Default callback stubs (agents can override after sourcing) ---
# cleanup_worktree and cleanup_labels are called during phase transitions.
# Provide no-op defaults so phase-handler.sh is self-contained; sourcing
# agents override these with real implementations.
if ! declare -f cleanup_worktree >/dev/null 2>&1; then
  cleanup_worktree() { :; }
fi
if ! declare -f cleanup_labels >/dev/null 2>&1; then
  cleanup_labels() { :; }
fi

# --- Default globals (agents can override after sourcing) ---
: "${CI_POLL_TIMEOUT:=1800}"
: "${REVIEW_POLL_TIMEOUT:=10800}"
: "${MAX_CI_FIXES:=3}"
: "${MAX_REVIEW_ROUNDS:=5}"
: "${CI_RETRY_COUNT:=0}"
: "${CI_FIX_COUNT:=0}"
: "${REVIEW_ROUND:=0}"
: "${PR_NUMBER:=}"
: "${CLAIMED:=false}"
: "${PHASE_POLL_INTERVAL:=30}"

# --- Post diagnostic comment + label issue as blocked ---
# Captures tmux pane output, posts a structured comment on the issue, removes
# in-progress label, and adds the "blocked" label.
#
# Args: reason [session_name]
# Uses globals: ISSUE, SESSION_NAME, PR_NUMBER, FORGE_TOKEN, API
post_blocked_diagnostic() {
  local reason="$1"
  local session="${2:-${SESSION_NAME:-}}"

  # Capture last 50 lines from tmux pane (before kill)
  local tmux_output=""
  if [ -n "$session" ] && tmux has-session -t "$session" 2>/dev/null; then
    tmux_output=$(tmux capture-pane -p -t "$session" -S -50 2>/dev/null || true)
  fi

  # Redact any secrets from tmux output before posting to issue
  if [ -n "$tmux_output" ]; then
    tmux_output=$(redact_secrets "$tmux_output")
  fi

  # Build diagnostic comment body
  local comment
  comment="### Session failure diagnostic

| Field | Value |
|---|---|
| Exit reason | \`${reason}\` |
| Timestamp | \`$(date -u +%Y-%m-%dT%H:%M:%SZ)\` |"
  [ -n "${PR_NUMBER:-}" ] && [ "${PR_NUMBER:-0}" != "0" ] && \
    comment="${comment}
| PR | #${PR_NUMBER} |"

  if [ -n "$tmux_output" ]; then
    comment="${comment}

<details><summary>Last 50 lines from tmux pane</summary>

\`\`\`
${tmux_output}
\`\`\`
</details>"
  fi

  # Post comment to issue
  curl -sf -X POST \
    -H "Authorization: token ${FORGE_TOKEN}" \
    -H "Content-Type: application/json" \
    "${API}/issues/${ISSUE}/comments" \
    -d "$(jq -nc --arg b "$comment" '{body:$b}')" >/dev/null 2>&1 || true

  # Remove in-progress, add blocked
  cleanup_labels
  local blocked_id
  blocked_id=$(ensure_blocked_label_id)
  if [ -n "$blocked_id" ]; then
    curl -sf -X POST \
      -H "Authorization: token ${FORGE_TOKEN}" \
      -H "Content-Type: application/json" \
      "${API}/issues/${ISSUE}/labels" \
      -d "{\"labels\":[${blocked_id}]}" >/dev/null 2>&1 || true
  fi
  CLAIMED=false
  _BLOCKED_POSTED=true
}

# --- Build phase protocol prompt (shared across agents) ---
# Generates the phase-signaling instructions for Claude prompts.
# Args: phase_file summary_file branch [remote]
# Output: The protocol text (stdout)
build_phase_protocol_prompt() {
  local _pf="$1" _sf="$2" _br="$3" _remote="${4:-${FORGE_REMOTE:-origin}}"
  cat <<_PHASE_PROTOCOL_EOF_
## Phase-Signaling Protocol (REQUIRED)

You are running in a persistent tmux session managed by an orchestrator.
Communicate progress by writing to the phase file. The orchestrator watches
this file and injects events (CI results, review feedback) back into this session.

### Key files
\`\`\`
PHASE_FILE="${_pf}"
SUMMARY_FILE="${_sf}"
\`\`\`

### Phase transitions — write these exactly:

**After committing and pushing your branch:**
\`\`\`bash
# Rebase on target branch before push to avoid merge conflicts
git fetch ${_remote} ${PRIMARY_BRANCH} && git rebase ${_remote}/${PRIMARY_BRANCH}
git push ${_remote} ${_br}
# Write a short summary of what you implemented:
printf '%s' "<your summary>" > "\${SUMMARY_FILE}"
# Signal the orchestrator to create the PR and watch for CI:
echo "PHASE:awaiting_ci" > "${_pf}"
\`\`\`
Then STOP and wait. The orchestrator will inject CI results.

**When you receive a "CI passed" injection:**
\`\`\`bash
echo "PHASE:awaiting_review" > "${_pf}"
\`\`\`
Then STOP and wait. The orchestrator will inject review feedback.

**When you receive a "CI failed:" injection:**
Fix the CI issue, then rebase on target branch and push:
\`\`\`bash
git fetch ${_remote} ${PRIMARY_BRANCH} && git rebase ${_remote}/${PRIMARY_BRANCH}
git push --force-with-lease ${_remote} ${_br}
echo "PHASE:awaiting_ci" > "${_pf}"
\`\`\`
Then STOP and wait.

**When you receive a "Review: REQUEST_CHANGES" injection:**
Address ALL review feedback, then rebase on target branch and push:
\`\`\`bash
git fetch ${_remote} ${PRIMARY_BRANCH} && git rebase ${_remote}/${PRIMARY_BRANCH}
git push --force-with-lease ${_remote} ${_br}
echo "PHASE:awaiting_ci" > "${_pf}"
\`\`\`
(CI runs again after each push — always write awaiting_ci, not awaiting_review)

**When you need human help (CI exhausted, merge blocked, stuck on a decision):**
\`\`\`bash
printf 'PHASE:escalate\nReason: %s\n' "describe what you need" > "${_pf}"
\`\`\`
Then STOP and wait. A human will review and respond via the forge.

**On unrecoverable failure:**
\`\`\`bash
printf 'PHASE:failed\nReason: %s\n' "describe what failed" > "${_pf}"
\`\`\`
_PHASE_PROTOCOL_EOF_
}

# --- Merge helper ---
# do_merge — attempt to merge PR via forge API.
# Args: pr_num
# Returns:
#   0 = merged successfully
#   1 = other failure (conflict, network error, etc.)
#   2 = not enough approvals (HTTP 405) — PHASE:escalate already written
do_merge() {
  local pr_num="$1"
  local merge_response merge_http_code merge_body
  merge_response=$(curl -s -w "\n%{http_code}" -X POST \
    -H "Authorization: token ${FORGE_TOKEN}" \
    -H 'Content-Type: application/json' \
    "${API}/pulls/${pr_num}/merge" \
    -d '{"Do":"merge","delete_branch_after_merge":true}') || true
  merge_http_code=$(echo "$merge_response" | tail -1)
  merge_body=$(echo "$merge_response" | sed '$d')

  if [ "$merge_http_code" = "200" ] || [ "$merge_http_code" = "204" ]; then
    log "do_merge: PR #${pr_num} merged (HTTP ${merge_http_code})"
    return 0
  fi

  # HTTP 405 — could be "merge requirements not met" OR "already merged" (race with dev-poll).
  # Before escalating, check whether the PR was already merged by another agent.
  if [ "$merge_http_code" = "405" ]; then
    local pr_state
    pr_state=$(curl -sf -H "Authorization: token ${FORGE_TOKEN}" \
      "${API}/pulls/${pr_num}" | jq -r '.merged // false') || pr_state="false"
    if [ "$pr_state" = "true" ]; then
      log "do_merge: PR #${pr_num} already merged (detected after HTTP 405) — treating as success"
      return 0
    fi
    log "do_merge: PR #${pr_num} blocked — merge requirements not met (HTTP 405): ${merge_body:0:200}"
    printf 'PHASE:escalate\nReason: %s\n' \
      "PR #${pr_num} merge blocked — merge requirements not met (HTTP 405): ${merge_body:0:200}" \
      > "$PHASE_FILE"
    return 2
  fi

  log "do_merge: PR #${pr_num} merge failed (HTTP ${merge_http_code}): ${merge_body:0:200}"
  return 1
}

# --- Refusal comment helper ---
post_refusal_comment() {
  local emoji="$1" title="$2" body="$3"
  local last_has_title
  last_has_title=$(curl -sf -H "Authorization: token ${FORGE_TOKEN}" \
    "${API}/issues/${ISSUE}/comments?limit=5" | \
    jq -r --arg t "Dev-agent: ${title}" '[.[] | .body // ""] | any(contains($t)) | tostring') || true
  if [ "$last_has_title" = "true" ]; then
    log "skipping duplicate refusal comment: ${title}"
    return 0
  fi
  local comment
  comment="${emoji} **Dev-agent: ${title}**

${body}

---
*Automated assessment by dev-agent · $(date -u '+%Y-%m-%d %H:%M UTC')*"
  printf '%s' "$comment" > "/tmp/refusal-comment.txt"
  jq -Rs '{body: .}' < "/tmp/refusal-comment.txt" > "/tmp/refusal-comment.json"
  curl -sf -o /dev/null -X POST \
    -H "Authorization: token ${FORGE_TOKEN}" \
    -H "Content-Type: application/json" \
    "${API}/issues/${ISSUE}/comments" \
    --data-binary @"/tmp/refusal-comment.json" 2>/dev/null || \
    log "WARNING: failed to post refusal comment"
  rm -f "/tmp/refusal-comment.txt" "/tmp/refusal-comment.json"
}

# =============================================================================
# PHASE DISPATCH CALLBACK
# =============================================================================

# _on_phase_change — Phase dispatch callback for monitor_phase_loop
# Receives the current phase as $1.
# Returns 0 to continue the loop, 1 to break (terminal phase reached).
_on_phase_change() {
  local phase="$1"

  # ── PHASE: awaiting_ci ──────────────────────────────────────────────────────
  if [ "$phase" = "PHASE:awaiting_ci" ]; then
    # Release session lock — Claude is idle during CI polling (#724)
    session_lock_release

    # Create PR if not yet created
    if [ -z "${PR_NUMBER:-}" ]; then
      status "creating PR for issue #${ISSUE}"
      IMPL_SUMMARY=""
      if [ -f "$IMPL_SUMMARY_FILE" ]; then
        # Don't treat refusal JSON as a PR summary
        if ! jq -e '.status' < "$IMPL_SUMMARY_FILE" >/dev/null 2>&1; then
          IMPL_SUMMARY=$(head -c 4000 "$IMPL_SUMMARY_FILE")
        fi
      fi

      printf 'Fixes #%s\n\n## Changes\n%s' "$ISSUE" "$IMPL_SUMMARY" > "/tmp/pr-body-${ISSUE}.txt"
      jq -n \
        --arg title "fix: ${ISSUE_TITLE} (#${ISSUE})" \
        --rawfile body "/tmp/pr-body-${ISSUE}.txt" \
        --arg head "$BRANCH" \
        --arg base "${PRIMARY_BRANCH}" \
        '{title: $title, body: $body, head: $head, base: $base}' > "/tmp/pr-request-${ISSUE}.json"

      PR_RESPONSE=$(curl -s -w "\n%{http_code}" -X POST \
        -H "Authorization: token ${FORGE_TOKEN}" \
        -H "Content-Type: application/json" \
        "${API}/pulls" \
        --data-binary @"/tmp/pr-request-${ISSUE}.json")

      PR_HTTP_CODE=$(echo "$PR_RESPONSE" | tail -1)
      PR_RESPONSE_BODY=$(echo "$PR_RESPONSE" | sed '$d')
      rm -f "/tmp/pr-body-${ISSUE}.txt" "/tmp/pr-request-${ISSUE}.json"

      if [ "$PR_HTTP_CODE" = "201" ] || [ "$PR_HTTP_CODE" = "200" ]; then
        PR_NUMBER=$(echo "$PR_RESPONSE_BODY" | jq -r '.number')
        log "created PR #${PR_NUMBER}"
      elif [ "$PR_HTTP_CODE" = "409" ]; then
        # PR already exists (race condition) — find it
        FOUND_PR=$(curl -sf -H "Authorization: token ${FORGE_TOKEN}" \
          "${API}/pulls?state=open&limit=20" | \
          jq -r --arg branch "$BRANCH" \
          '.[] | select(.head.ref == $branch) | .number' | head -1) || true
        if [ -n "$FOUND_PR" ]; then
          PR_NUMBER="$FOUND_PR"
          log "PR already exists: #${PR_NUMBER}"
        else
          log "ERROR: PR creation got 409 but no existing PR found"
          agent_inject_into_session "$SESSION_NAME" "ERROR: Could not create PR (HTTP 409, no existing PR found). Check the forge API. Retry by writing PHASE:awaiting_ci again after verifying the branch was pushed."
          return 0
        fi
      else
        log "ERROR: PR creation failed (HTTP ${PR_HTTP_CODE})"
        agent_inject_into_session "$SESSION_NAME" "ERROR: Could not create PR (HTTP ${PR_HTTP_CODE}). Check branch was pushed: git push ${FORGE_REMOTE:-origin} ${BRANCH}. Then write PHASE:awaiting_ci again."
        return 0
      fi
    fi

    # No CI configured? Treat as success immediately
    if [ "${WOODPECKER_REPO_ID:-2}" = "0" ]; then
      log "no CI configured — treating as passed"
      agent_inject_into_session "$SESSION_NAME" "CI passed on PR #${PR_NUMBER} (no CI configured for this project).
Write PHASE:awaiting_review to the phase file, then stop and wait for review feedback."
      return 0
    fi

    # Poll CI until done or timeout
    status "waiting for CI on PR #${PR_NUMBER}"
    CI_CURRENT_SHA=$(git -C "${WORKTREE}" rev-parse HEAD 2>/dev/null || \
      curl -sf -H "Authorization: token ${FORGE_TOKEN}" \
        "${API}/pulls/${PR_NUMBER}" | jq -r '.head.sha')

    CI_DONE=false
    CI_STATE="unknown"
    CI_POLL_ELAPSED=0
    while [ "$CI_POLL_ELAPSED" -lt "$CI_POLL_TIMEOUT" ]; do
      sleep 30
      CI_POLL_ELAPSED=$(( CI_POLL_ELAPSED + 30 ))

      # Check session still alive during CI wait (exit_marker + tmux fallback)
      if [ -f "/tmp/claude-exited-${SESSION_NAME}.ts" ] || ! tmux has-session -t "${SESSION_NAME}" 2>/dev/null; then
        log "session died during CI wait"
        break
      fi

      # Re-fetch HEAD — Claude may have pushed new commits since loop started
      CI_CURRENT_SHA=$(git -C "${WORKTREE}" rev-parse HEAD 2>/dev/null || echo "$CI_CURRENT_SHA")

      CI_STATE=$(ci_commit_status "$CI_CURRENT_SHA")
      if [ "$CI_STATE" = "success" ] || [ "$CI_STATE" = "failure" ] || [ "$CI_STATE" = "error" ]; then
        CI_DONE=true
        [ "$CI_STATE" = "success" ] && CI_FIX_COUNT=0
        break
      fi
    done

    if ! $CI_DONE; then
      log "TIMEOUT: CI didn't complete in ${CI_POLL_TIMEOUT}s"
      agent_inject_into_session "$SESSION_NAME" "CI TIMEOUT: CI did not complete within 30 minutes for PR #${PR_NUMBER} (SHA: ${CI_CURRENT_SHA:0:7}). This may be an infrastructure issue. Write PHASE:escalate if you cannot proceed."
      return 0
    fi

    log "CI: ${CI_STATE}"

    if [ "$CI_STATE" = "success" ]; then
      agent_inject_into_session "$SESSION_NAME" "CI passed on PR #${PR_NUMBER}.
Write PHASE:awaiting_review to the phase file, then stop and wait for review feedback:
  echo \"PHASE:awaiting_review\" > \"${PHASE_FILE}\""
    else
      # Fetch CI error details
      PIPELINE_NUM=$(ci_pipeline_number "$CI_CURRENT_SHA")

      FAILED_STEP=""
      FAILED_EXIT=""
      IS_INFRA=false
      if [ -n "$PIPELINE_NUM" ]; then
        FAILED_INFO=$(curl -sf \
          -H "Authorization: Bearer ${WOODPECKER_TOKEN}" \
          "${WOODPECKER_SERVER}/api/repos/${WOODPECKER_REPO_ID}/pipelines/${PIPELINE_NUM}" | \
          jq -r '.workflows[]?.children[]? | select(.state=="failure") | "\(.name)|\(.exit_code)"' | head -1 || true)
        FAILED_STEP=$(echo "$FAILED_INFO" | cut -d'|' -f1)
        FAILED_EXIT=$(echo "$FAILED_INFO" | cut -d'|' -f2)
      fi

      log "CI failed: step=${FAILED_STEP:-unknown} exit=${FAILED_EXIT:-?}"

      if [ -n "$FAILED_STEP" ] && is_infra_step "$FAILED_STEP" "${FAILED_EXIT:-0}" >/dev/null 2>&1; then
        IS_INFRA=true
      fi

      if [ "$IS_INFRA" = true ] && [ "${CI_RETRY_COUNT:-0}" -lt 1 ]; then
        CI_RETRY_COUNT=$(( CI_RETRY_COUNT + 1 ))
        log "infra failure — retrigger CI (retry ${CI_RETRY_COUNT})"
        (cd "$WORKTREE" && git commit --allow-empty \
          -m "ci: retrigger after infra failure (#${ISSUE})" --no-verify 2>&1 | tail -1)
        # Rebase on target branch before push to avoid merge conflicts
        if ! (cd "$WORKTREE" && \
          git fetch "${FORGE_REMOTE:-origin}" "${PRIMARY_BRANCH}" 2>/dev/null && \
          git rebase "${FORGE_REMOTE:-origin}/${PRIMARY_BRANCH}" 2>&1 | tail -5); then
          log "rebase conflict detected — aborting, agent must resolve"
          (cd "$WORKTREE" && git rebase --abort 2>/dev/null || git reset --hard HEAD 2>/dev/null) || true
          agent_inject_into_session "$SESSION_NAME" "REBASE CONFLICT: Cannot rebase onto ${PRIMARY_BRANCH} automatically.

Please resolve merge conflicts manually:
1. Check conflict status: git status
2. Resolve conflicts in the conflicted files
3. Stage resolved files: git add <files>
4. Continue rebase: git rebase --continue

If you cannot resolve conflicts, abort: git rebase --abort
Then write PHASE:escalate with a reason."
          return 0
        fi
        # Rebase succeeded — push the result
        (cd "$WORKTREE" && git push --force-with-lease "${FORGE_REMOTE:-origin}" "$BRANCH" 2>&1 | tail -3)
        # Touch phase file so we recheck CI on the new SHA
        # Do NOT update LAST_PHASE_MTIME here — let the main loop detect the fresh mtime
        touch "$PHASE_FILE"
        CI_CURRENT_SHA=$(git -C "${WORKTREE}" rev-parse HEAD 2>/dev/null || true)
        return 0
      fi

      CI_FIX_COUNT=$(( CI_FIX_COUNT + 1 ))
      _ci_pipeline_url="${WOODPECKER_SERVER}/repos/${WOODPECKER_REPO_ID}/pipeline/${PIPELINE_NUM:-0}"
      if [ "$CI_FIX_COUNT" -gt "$MAX_CI_FIXES" ]; then
        log "CI failure not recoverable after ${CI_FIX_COUNT} fix attempts — escalating"
        printf 'PHASE:escalate\nReason: ci_exhausted after %d attempts (step: %s)\n' "$CI_FIX_COUNT" "${FAILED_STEP:-unknown}" > "$PHASE_FILE"
        # Do NOT update LAST_PHASE_MTIME here — let the main loop detect PHASE:escalate
        return 0
      fi

      CI_ERROR_LOG=""
      if [ -n "$PIPELINE_NUM" ]; then
        CI_ERROR_LOG=$(bash "${FACTORY_ROOT}/lib/ci-debug.sh" failures "$PIPELINE_NUM" 2>/dev/null | tail -80 | head -c 8000 || echo "")
      fi

      # Save CI result for crash recovery
      printf 'CI failed (attempt %d/%d)\nStep: %s\nExit: %s\n\n%s' \
        "$CI_FIX_COUNT" "$MAX_CI_FIXES" "${FAILED_STEP:-unknown}" "${FAILED_EXIT:-?}" "$CI_ERROR_LOG" \
        > "/tmp/ci-result-${PROJECT_NAME}-${ISSUE}.txt" 2>/dev/null || true

      agent_inject_into_session "$SESSION_NAME" "CI failed on PR #${PR_NUMBER} (attempt ${CI_FIX_COUNT}/${MAX_CI_FIXES}).

Failed step: ${FAILED_STEP:-unknown} (exit code ${FAILED_EXIT:-?}, pipeline #${PIPELINE_NUM:-?})

CI debug tool:
  bash ${FACTORY_ROOT}/lib/ci-debug.sh failures ${PIPELINE_NUM:-0}
  bash ${FACTORY_ROOT}/lib/ci-debug.sh logs ${PIPELINE_NUM:-0} <step-name>

Error snippet:
${CI_ERROR_LOG:-No logs available. Use ci-debug.sh to query the pipeline.}

Instructions:
1. Run ci-debug.sh failures to get the full error output.
2. Read the failing test file(s) — understand what the tests EXPECT.
3. Fix the root cause — do NOT weaken tests.
4. Rebase on target branch and push: git fetch ${FORGE_REMOTE:-origin} ${PRIMARY_BRANCH} && git rebase ${FORGE_REMOTE:-origin}/${PRIMARY_BRANCH}
  git push --force-with-lease ${FORGE_REMOTE:-origin} ${BRANCH}
5. Write: echo \"PHASE:awaiting_ci\" > \"${PHASE_FILE}\"
6. Stop and wait."
    fi

  # ── PHASE: awaiting_review ──────────────────────────────────────────────────
  elif [ "$phase" = "PHASE:awaiting_review" ]; then
    # Release session lock — Claude is idle during review wait (#724)
    session_lock_release
    status "waiting for review on PR #${PR_NUMBER:-?}"
    CI_FIX_COUNT=0  # Reset CI fix budget for this review cycle

    if [ -z "${PR_NUMBER:-}" ]; then
      log "WARNING: awaiting_review but PR_NUMBER unknown — searching for PR"
      FOUND_PR=$(curl -sf -H "Authorization: token ${FORGE_TOKEN}" \
        "${API}/pulls?state=open&limit=20" | \
        jq -r --arg branch "$BRANCH" \
        '.[] | select(.head.ref == $branch) | .number' | head -1) || true
      if [ -n "$FOUND_PR" ]; then
        PR_NUMBER="$FOUND_PR"
        log "found PR #${PR_NUMBER}"
      else
        agent_inject_into_session "$SESSION_NAME" "ERROR: Cannot find open PR for branch ${BRANCH}. Did you push? Verify with git status and git push ${FORGE_REMOTE:-origin} ${BRANCH}, then write PHASE:awaiting_ci."
        return 0
      fi
    fi

    REVIEW_POLL_ELAPSED=0
    REVIEW_FOUND=false
    while [ "$REVIEW_POLL_ELAPSED" -lt "$REVIEW_POLL_TIMEOUT" ]; do
      sleep 300  # 5 min between review checks
      REVIEW_POLL_ELAPSED=$(( REVIEW_POLL_ELAPSED + 300 ))

      # Check session still alive (exit_marker + tmux fallback)
      if [ -f "/tmp/claude-exited-${SESSION_NAME}.ts" ] || ! tmux has-session -t "${SESSION_NAME}" 2>/dev/null; then
        log "session died during review wait"
        REVIEW_FOUND=false
        break
      fi

      # Check if phase was updated while we wait (e.g., Claude reacted to something)
      NEW_MTIME=$(stat -c %Y "$PHASE_FILE" 2>/dev/null || echo 0)
      if [ "$NEW_MTIME" -gt "$LAST_PHASE_MTIME" ]; then
        log "phase file updated during review wait — re-entering main loop"
        # Do NOT update LAST_PHASE_MTIME here — leave it stale so the outer
        # loop detects the change on its next tick and dispatches the new phase.
        REVIEW_FOUND=true  # Prevent timeout injection
        # Clean up review-poll sentinel if it exists (session already advanced)
        rm -f "/tmp/review-injected-${PROJECT_NAME}-${PR_NUMBER}"
        break
      fi

      REVIEW_SHA=$(curl -sf -H "Authorization: token ${FORGE_TOKEN}" \
        "${API}/pulls/${PR_NUMBER}" | jq -r '.head.sha') || true
      REVIEW_COMMENT=$(forge_api_all "/issues/${PR_NUMBER}/comments" | \
        jq -r --arg sha "$REVIEW_SHA" \
        '[.[] | select(.body | contains("<!-- reviewed: " + $sha))] | last // empty') || true

      if [ -n "$REVIEW_COMMENT" ] && [ "$REVIEW_COMMENT" != "null" ]; then
        REVIEW_TEXT=$(echo "$REVIEW_COMMENT" | jq -r '.body')

        # Skip error reviews — they have no verdict
        if echo "$REVIEW_TEXT" | grep -q "review-error\|Review — Error"; then
          log "review was an error, waiting for re-review"
          continue
        fi

        VERDICT=$(echo "$REVIEW_TEXT" | grep -oP '\*\*(APPROVE|REQUEST_CHANGES|DISCUSS)\*\*' | head -1 | tr -d '*' || true)
        log "review verdict: ${VERDICT:-unknown}"

        # Also check formal forge reviews
        if [ -z "$VERDICT" ]; then
          VERDICT=$(curl -sf -H "Authorization: token ${FORGE_TOKEN}" \
            "${API}/pulls/${PR_NUMBER}/reviews" | \
            jq -r '[.[] | select(.stale == false)] | last | .state // empty' || true)
          if [ "$VERDICT" = "APPROVED" ]; then
            VERDICT="APPROVE"
          elif [ "$VERDICT" != "REQUEST_CHANGES" ]; then
            VERDICT=""
          fi
          [ -n "$VERDICT" ] && log "verdict from formal review: $VERDICT"
        fi

        # Skip injection if review-poll.sh already injected (sentinel present).
        # Exception: APPROVE always falls through so do_merge() runs even when
        # review-poll injected first — prevents Claude writing PHASE:done on a
        # failed merge without the orchestrator detecting the error.
        REVIEW_SENTINEL="/tmp/review-injected-${PROJECT_NAME}-${PR_NUMBER}"
        if [ -n "$VERDICT" ] && [ -f "$REVIEW_SENTINEL" ] && [ "$VERDICT" != "APPROVE" ]; then
          log "review already injected by review-poll (sentinel exists) — skipping"
          rm -f "$REVIEW_SENTINEL"
          REVIEW_FOUND=true
          break
        fi
        rm -f "$REVIEW_SENTINEL"  # consume sentinel before APPROVE handling below

        if [ "$VERDICT" = "APPROVE" ]; then
          REVIEW_FOUND=true
          _merge_rc=0; do_merge "$PR_NUMBER" || _merge_rc=$?
          if [ "$_merge_rc" -eq 0 ]; then
            # Merge succeeded — close issue and signal done
            curl -sf -X PATCH \
              -H "Authorization: token ${FORGE_TOKEN}" \
              -H 'Content-Type: application/json' \
              "${API}/issues/${ISSUE}" \
              -d '{"state":"closed"}' >/dev/null 2>&1 || true
            # Pull merged primary branch and push to mirrors
            git -C "$PROJECT_REPO_ROOT" fetch "${FORGE_REMOTE:-origin}" "$PRIMARY_BRANCH" 2>/dev/null || true
            git -C "$PROJECT_REPO_ROOT" checkout "$PRIMARY_BRANCH" 2>/dev/null || true
            git -C "$PROJECT_REPO_ROOT" pull --ff-only "${FORGE_REMOTE:-origin}" "$PRIMARY_BRANCH" 2>/dev/null || true
            mirror_push
            printf 'PHASE:done\n' > "$PHASE_FILE"
          elif [ "$_merge_rc" -ne 2 ]; then
            # Other merge failure (conflict, etc.) — delegate to Claude for rebase + retry
            agent_inject_into_session "$SESSION_NAME" "Approved! PR #${PR_NUMBER} has been approved, but the merge failed (likely conflicts).

Rebase onto ${PRIMARY_BRANCH} and push:
  git fetch ${FORGE_REMOTE:-origin} ${PRIMARY_BRANCH} && git rebase ${FORGE_REMOTE:-origin}/${PRIMARY_BRANCH}
  git push --force-with-lease ${FORGE_REMOTE:-origin} ${BRANCH}
  echo \"PHASE:awaiting_ci\" > \"${PHASE_FILE}\"

Do NOT merge or close the issue — the orchestrator handles that after CI passes.
If rebase repeatedly fails, write PHASE:escalate with a reason."
          fi
          # _merge_rc=2: PHASE:escalate already written by do_merge()
          break

        elif [ "$VERDICT" = "REQUEST_CHANGES" ] || [ "$VERDICT" = "DISCUSS" ]; then
          REVIEW_ROUND=$(( REVIEW_ROUND + 1 ))
          if [ "$REVIEW_ROUND" -ge "$MAX_REVIEW_ROUNDS" ]; then
            log "hit max review rounds (${MAX_REVIEW_ROUNDS})"
            log "PR #${PR_NUMBER}: hit ${MAX_REVIEW_ROUNDS} review rounds, needs human attention"
          fi
          REVIEW_FOUND=true
          agent_inject_into_session "$SESSION_NAME" "Review feedback (round ${REVIEW_ROUND}) on PR #${PR_NUMBER}:

${REVIEW_TEXT}

Instructions:
1. Address each piece of feedback carefully.
2. Run lint and tests when done.
3. Rebase on target branch and push: git fetch ${FORGE_REMOTE:-origin} ${PRIMARY_BRANCH} && git rebase ${FORGE_REMOTE:-origin}/${PRIMARY_BRANCH}
  git push --force-with-lease ${FORGE_REMOTE:-origin} ${BRANCH}
4. Write: echo \"PHASE:awaiting_ci\" > \"${PHASE_FILE}\"
5. Stop and wait for the next CI result."
          log "review REQUEST_CHANGES received (round ${REVIEW_ROUND})"
          break

        else
          # No verdict found in comment or formal review — keep waiting
          log "review comment found but no verdict, continuing to wait"
          continue
        fi
      fi

      # Check if PR was merged or closed externally
      PR_JSON=$(curl -sf -H "Authorization: token ${FORGE_TOKEN}" \
        "${API}/pulls/${PR_NUMBER}") || true
      PR_STATE=$(echo "$PR_JSON" | jq -r '.state // "unknown"')
      PR_MERGED=$(echo "$PR_JSON" | jq -r '.merged // false')
      if [ "$PR_STATE" != "open" ]; then
        if [ "$PR_MERGED" = "true" ]; then
          log "PR #${PR_NUMBER} was merged externally"
          curl -sf -X PATCH -H "Authorization: token ${FORGE_TOKEN}" \
            -H "Content-Type: application/json" \
            "${API}/issues/${ISSUE}" -d '{"state":"closed"}' >/dev/null 2>&1 || true
          cleanup_labels
          agent_kill_session "$SESSION_NAME"
          cleanup_worktree
          rm -f "$PHASE_FILE" "$IMPL_SUMMARY_FILE" "${SCRATCH_FILE:-}"
          exit 0
        else
          log "PR #${PR_NUMBER} was closed WITHOUT merge — NOT closing issue"
          cleanup_labels
          agent_kill_session "$SESSION_NAME"
          cleanup_worktree
          exit 0
        fi
      fi

      log "waiting for review on PR #${PR_NUMBER} (${REVIEW_POLL_ELAPSED}s elapsed)"
    done

    if ! $REVIEW_FOUND && [ "$REVIEW_POLL_ELAPSED" -ge "$REVIEW_POLL_TIMEOUT" ]; then
      log "TIMEOUT: no review after 3h"
      agent_inject_into_session "$SESSION_NAME" "TIMEOUT: No review received after 3 hours for PR #${PR_NUMBER}. Write PHASE:escalate to escalate to a human reviewer."
    fi

  # ── PHASE: escalate ──────────────────────────────────────────────────────
  elif [ "$phase" = "PHASE:escalate" ]; then
    status "escalated — waiting for human input on issue #${ISSUE}"
    ESCALATE_REASON=$(sed -n '2p' "$PHASE_FILE" 2>/dev/null | sed 's/^Reason: //' || echo "")
    log "phase: escalate — reason: ${ESCALATE_REASON:-none}"
    # Session stays alive — human input arrives via vault/forge

  # ── PHASE: done ─────────────────────────────────────────────────────────────
  # PR merged and issue closed (by orchestrator or Claude). Just clean up local state.
  elif [ "$phase" = "PHASE:done" ]; then
    if [ -n "${PR_NUMBER:-}" ]; then
      status "phase done — PR #${PR_NUMBER} merged, cleaning up"
    else
      status "phase done — issue #${ISSUE} complete, cleaning up"
    fi

    # Belt-and-suspenders: ensure in-progress label removed (idempotent)
    cleanup_labels

    # Local cleanup
    agent_kill_session "$SESSION_NAME"
    cleanup_worktree
    rm -f "$PHASE_FILE" "$IMPL_SUMMARY_FILE" "${SCRATCH_FILE:-}" \
      "/tmp/ci-result-${PROJECT_NAME}-${ISSUE}.txt"
    [ -n "${PR_NUMBER:-}" ] && rm -f "/tmp/review-injected-${PROJECT_NAME}-${PR_NUMBER}"
    CLAIMED=false  # Don't unclaim again in cleanup()

  # ── PHASE: failed ───────────────────────────────────────────────────────────
  elif [ "$phase" = "PHASE:failed" ]; then
    if [[ -f "$PHASE_FILE" ]]; then
      FAILURE_REASON=$(sed -n '2p' "$PHASE_FILE" | sed 's/^Reason: //')
    fi
    FAILURE_REASON="${FAILURE_REASON:-unspecified}"
    log "phase: failed — reason: ${FAILURE_REASON}"
    # Gitea labels API requires []int64 — look up the "backlog" label ID once
    BACKLOG_LABEL_ID=$(forge_api GET "/labels" 2>/dev/null \
      | jq -r '.[] | select(.name == "backlog") | .id' 2>/dev/null || true)
    BACKLOG_LABEL_ID="${BACKLOG_LABEL_ID:-1300815}"
    UNDERSPECIFIED_LABEL_ID=$(forge_api GET "/labels" 2>/dev/null \
      | jq -r '.[] | select(.name == "underspecified") | .id' 2>/dev/null || true)
    UNDERSPECIFIED_LABEL_ID="${UNDERSPECIFIED_LABEL_ID:-1300816}"

    # Check if this is a refusal (Claude wrote refusal JSON to IMPL_SUMMARY_FILE)
    REFUSAL_JSON=""
    if [ -f "$IMPL_SUMMARY_FILE" ] && jq -e '.status' < "$IMPL_SUMMARY_FILE" >/dev/null 2>&1; then
      REFUSAL_JSON=$(cat "$IMPL_SUMMARY_FILE")
    fi

    if [ -n "$REFUSAL_JSON" ] && [ "$FAILURE_REASON" = "refused" ]; then
      REFUSAL_STATUS=$(printf '%s' "$REFUSAL_JSON" | jq -r '.status')
      log "claude refused: ${REFUSAL_STATUS}"

      # Write preflight result for dev-poll.sh
      printf '%s' "$REFUSAL_JSON" > "$PREFLIGHT_RESULT"

      # Unclaim issue (restore backlog label, remove in-progress)
      cleanup_labels
      curl -sf -X POST \
        -H "Authorization: token ${FORGE_TOKEN}" \
        -H "Content-Type: application/json" \
        "${API}/issues/${ISSUE}/labels" \
        -d "{\"labels\":[${BACKLOG_LABEL_ID}]}" >/dev/null 2>&1 || true

      case "$REFUSAL_STATUS" in
        unmet_dependency)
          BLOCKED_BY_MSG=$(printf '%s' "$REFUSAL_JSON" | jq -r '.blocked_by // "unknown"')
          SUGGESTION=$(printf '%s' "$REFUSAL_JSON" | jq -r '.suggestion // empty')
          COMMENT_BODY="### Blocked by unmet dependency

${BLOCKED_BY_MSG}"
          if [ -n "$SUGGESTION" ] && [ "$SUGGESTION" != "null" ]; then
            COMMENT_BODY="${COMMENT_BODY}

**Suggestion:** Work on #${SUGGESTION} first."
          fi
          post_refusal_comment "🚧" "Unmet dependency" "$COMMENT_BODY"
          ;;
        too_large)
          REASON=$(printf '%s' "$REFUSAL_JSON" | jq -r '.reason // "unspecified"')
          post_refusal_comment "📏" "Too large for single session" "### Why this can't be implemented as-is

${REASON}

### Next steps
A maintainer should split this issue or add more detail to the spec."
          curl -sf -X POST \
            -H "Authorization: token ${FORGE_TOKEN}" \
            -H "Content-Type: application/json" \
            "${API}/issues/${ISSUE}/labels" \
            -d "{\"labels\":[${UNDERSPECIFIED_LABEL_ID}]}" >/dev/null 2>&1 || true
          curl -sf -X DELETE \
            -H "Authorization: token ${FORGE_TOKEN}" \
            "${API}/issues/${ISSUE}/labels/${BACKLOG_LABEL_ID}" >/dev/null 2>&1 || true
          ;;
        already_done)
          REASON=$(printf '%s' "$REFUSAL_JSON" | jq -r '.reason // "unspecified"')
          post_refusal_comment "✅" "Already implemented" "### Existing implementation

${REASON}

Closing as already implemented."
          curl -sf -X PATCH \
            -H "Authorization: token ${FORGE_TOKEN}" \
            -H "Content-Type: application/json" \
            "${API}/issues/${ISSUE}" \
            -d '{"state":"closed"}' >/dev/null 2>&1 || true
          ;;
        *)
          post_refusal_comment "❓" "Unable to proceed" "The dev-agent could not process this issue.

Raw response:
\`\`\`json
$(printf '%s' "$REFUSAL_JSON" | head -c 2000)
\`\`\`"
          ;;
      esac

      CLAIMED=false  # Don't unclaim again in cleanup()
      agent_kill_session "$SESSION_NAME"
      cleanup_worktree
      rm -f "$PHASE_FILE" "$IMPL_SUMMARY_FILE" "${SCRATCH_FILE:-}" \
        "/tmp/ci-result-${PROJECT_NAME}-${ISSUE}.txt"
      [ -n "${PR_NUMBER:-}" ] && rm -f "/tmp/review-injected-${PROJECT_NAME}-${PR_NUMBER}"
      return 1

    else
      # Genuine unrecoverable failure — label blocked with diagnostic
      log "session failed: ${FAILURE_REASON}"
      post_blocked_diagnostic "$FAILURE_REASON"

      agent_kill_session "$SESSION_NAME"
      if [ -n "${PR_NUMBER:-}" ]; then
        log "keeping worktree (PR #${PR_NUMBER} still open)"
      else
        cleanup_worktree
      fi
      rm -f "$PHASE_FILE" "$IMPL_SUMMARY_FILE" "${SCRATCH_FILE:-}" \
        "/tmp/ci-result-${PROJECT_NAME}-${ISSUE}.txt"
      [ -n "${PR_NUMBER:-}" ] && rm -f "/tmp/review-injected-${PROJECT_NAME}-${PR_NUMBER}"
      return 1
    fi

  # ── PHASE: crashed ──────────────────────────────────────────────────────────
  # Session died unexpectedly (OOM kill, tmux crash, etc.). Label blocked with
  # diagnostic comment so humans can triage directly on the issue.
  elif [ "$phase" = "PHASE:crashed" ]; then
    log "session crashed for issue #${ISSUE}"
    post_blocked_diagnostic "crashed"
    log "PRESERVED crashed worktree for debugging: $WORKTREE"
    rm -f "$PHASE_FILE" "$IMPL_SUMMARY_FILE" "${SCRATCH_FILE:-}" \
      "/tmp/ci-result-${PROJECT_NAME}-${ISSUE}.txt"
    [ -n "${PR_NUMBER:-}" ] && rm -f "/tmp/review-injected-${PROJECT_NAME}-${PR_NUMBER}"

  else
    log "WARNING: unknown phase value: ${phase}"
  fi
}
