#!/usr/bin/env bash
# dev/phase-handler.sh — Phase callback functions for dev-agent.sh
#
# Source this file from dev-agent.sh after lib/agent-session.sh is loaded.
# Defines: post_refusal_comment(), _on_phase_change()
#
# Required globals from dev-agent.sh:
#   ISSUE, CODEBERG_TOKEN, API, CODEBERG_WEB, PROJECT_NAME, FACTORY_ROOT
#   PR_NUMBER, BRANCH, PHASE_FILE, WORKTREE, IMPL_SUMMARY_FILE, THREAD_FILE
#   PRIMARY_BRANCH, SESSION_NAME, LOGFILE, ISSUE_TITLE
#   CI_POLL_TIMEOUT, MAX_CI_FIXES, MAX_REVIEW_ROUNDS, REVIEW_POLL_TIMEOUT
#   CI_RETRY_COUNT, CI_FIX_COUNT, REVIEW_ROUND, CLAIMED
#   WOODPECKER_REPO_ID, WOODPECKER_TOKEN, WOODPECKER_SERVER
#
# Calls back to dev-agent.sh-defined helpers:
#   cleanup_worktree(), cleanup_labels()
#
# shellcheck shell=bash
# shellcheck disable=SC2154  # globals are set in dev-agent.sh before calling
# shellcheck disable=SC2034  # CLAIMED is read by cleanup() in dev-agent.sh

# --- Refusal comment helper ---
post_refusal_comment() {
  local emoji="$1" title="$2" body="$3"
  local last_has_title
  last_has_title=$(curl -sf -H "Authorization: token ${CODEBERG_TOKEN}" \
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
    -H "Authorization: token ${CODEBERG_TOKEN}" \
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
        -H "Authorization: token ${CODEBERG_TOKEN}" \
        -H "Content-Type: application/json" \
        "${API}/pulls" \
        --data-binary @"/tmp/pr-request-${ISSUE}.json")

      PR_HTTP_CODE=$(echo "$PR_RESPONSE" | tail -1)
      PR_RESPONSE_BODY=$(echo "$PR_RESPONSE" | sed '$d')
      rm -f "/tmp/pr-body-${ISSUE}.txt" "/tmp/pr-request-${ISSUE}.json"

      if [ "$PR_HTTP_CODE" = "201" ] || [ "$PR_HTTP_CODE" = "200" ]; then
        PR_NUMBER=$(echo "$PR_RESPONSE_BODY" | jq -r '.number')
        log "created PR #${PR_NUMBER}"
        PR_URL="${CODEBERG_WEB}/pulls/${PR_NUMBER}"
        notify_ctx \
          "PR #${PR_NUMBER} created: ${ISSUE_TITLE}" \
          "PR <a href='${PR_URL}'>#${PR_NUMBER}</a> created: ${ISSUE_TITLE}"
      elif [ "$PR_HTTP_CODE" = "409" ]; then
        # PR already exists (race condition) — find it
        FOUND_PR=$(curl -sf -H "Authorization: token ${CODEBERG_TOKEN}" \
          "${API}/pulls?state=open&limit=20" | \
          jq -r --arg branch "$BRANCH" \
          '.[] | select(.head.ref == $branch) | .number' | head -1) || true
        if [ -n "$FOUND_PR" ]; then
          PR_NUMBER="$FOUND_PR"
          log "PR already exists: #${PR_NUMBER}"
        else
          log "ERROR: PR creation got 409 but no existing PR found"
          agent_inject_into_session "$SESSION_NAME" "ERROR: Could not create PR (HTTP 409, no existing PR found). Check the Codeberg API. Retry by writing PHASE:awaiting_ci again after verifying the branch was pushed."
          return 0
        fi
      else
        log "ERROR: PR creation failed (HTTP ${PR_HTTP_CODE})"
        notify "failed to create PR (HTTP ${PR_HTTP_CODE})"
        agent_inject_into_session "$SESSION_NAME" "ERROR: Could not create PR (HTTP ${PR_HTTP_CODE}). Check branch was pushed: git push origin ${BRANCH}. Then write PHASE:awaiting_ci again."
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
      curl -sf -H "Authorization: token ${CODEBERG_TOKEN}" \
        "${API}/pulls/${PR_NUMBER}" | jq -r '.head.sha')

    CI_DONE=false
    CI_STATE="unknown"
    CI_POLL_ELAPSED=0
    while [ "$CI_POLL_ELAPSED" -lt "$CI_POLL_TIMEOUT" ]; do
      sleep 30
      CI_POLL_ELAPSED=$(( CI_POLL_ELAPSED + 30 ))

      # Check session still alive during CI wait
      if ! tmux has-session -t "${SESSION_NAME}" 2>/dev/null; then
        log "session died during CI wait"
        break
      fi

      CI_STATE=$(curl -sf -H "Authorization: token ${CODEBERG_TOKEN}" \
        "${API}/commits/${CI_CURRENT_SHA}/status" | jq -r '.state // "unknown"')
      if [ "$CI_STATE" = "success" ] || [ "$CI_STATE" = "failure" ] || [ "$CI_STATE" = "error" ]; then
        CI_DONE=true
        [ "$CI_STATE" = "success" ] && CI_FIX_COUNT=0
        break
      fi
    done

    if ! $CI_DONE; then
      log "TIMEOUT: CI didn't complete in ${CI_POLL_TIMEOUT}s"
      notify "CI timeout on PR #${PR_NUMBER}"
      agent_inject_into_session "$SESSION_NAME" "CI TIMEOUT: CI did not complete within 30 minutes for PR #${PR_NUMBER} (SHA: ${CI_CURRENT_SHA:0:7}). This may be an infrastructure issue. Write PHASE:needs_human if you cannot proceed."
      return 0
    fi

    log "CI: ${CI_STATE}"

    if [ "$CI_STATE" = "success" ]; then
      agent_inject_into_session "$SESSION_NAME" "CI passed on PR #${PR_NUMBER}.
Write PHASE:awaiting_review to the phase file, then stop and wait for review feedback:
  echo \"PHASE:awaiting_review\" > \"${PHASE_FILE}\""
    else
      # Fetch CI error details
      PIPELINE_NUM=$(curl -sf -H "Authorization: token ${CODEBERG_TOKEN}" \
        "${API}/commits/${CI_CURRENT_SHA}/status" | \
        jq -r '.statuses[0].target_url // ""' | grep -oP 'pipeline/\K[0-9]+' | head -1 || true)

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

      case "${FAILED_STEP}" in git*) IS_INFRA=true ;; esac
      case "${FAILED_EXIT}" in 128|137) IS_INFRA=true ;; esac

      if [ "$IS_INFRA" = true ] && [ "${CI_RETRY_COUNT:-0}" -lt 1 ]; then
        CI_RETRY_COUNT=$(( CI_RETRY_COUNT + 1 ))
        log "infra failure — retrigger CI (retry ${CI_RETRY_COUNT})"
        (cd "$WORKTREE" && git commit --allow-empty \
          -m "ci: retrigger after infra failure (#${ISSUE})" --no-verify 2>&1 | tail -1)
        (cd "$WORKTREE" && git push origin "$BRANCH" --force 2>&1 | tail -3)
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
        echo "{\"issue\":${ISSUE},\"pr\":${PR_NUMBER},\"reason\":\"ci_exhausted\",\"step\":\"${FAILED_STEP:-unknown}\",\"attempts\":${CI_FIX_COUNT},\"ts\":\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\"}" \
          >> "${FACTORY_ROOT}/supervisor/escalations-${PROJECT_NAME}.jsonl"
        notify_ctx \
          "CI exhausted after ${CI_FIX_COUNT} attempts — escalated to supervisor" \
          "CI exhausted after ${CI_FIX_COUNT} attempts on PR <a href='${PR_URL:-${CODEBERG_WEB}/pulls/${PR_NUMBER}}'>#${PR_NUMBER}</a> | <a href='${_ci_pipeline_url}'>Pipeline</a><br>Step: <code>${FAILED_STEP:-unknown}</code> — escalated to supervisor"
        printf 'PHASE:failed\nReason: ci_exhausted after %d attempts\n' "$CI_FIX_COUNT" > "$PHASE_FILE"
        # Do NOT update LAST_PHASE_MTIME here — let the main loop detect PHASE:failed
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

      # Notify Matrix with rich CI failure context
      _ci_snippet=$(printf '%s' "${CI_ERROR_LOG:-}" | tail -5 | head -c 500 | sed 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g')
      notify_ctx \
        "CI failed on PR #${PR_NUMBER}: step=${FAILED_STEP:-unknown} (attempt ${CI_FIX_COUNT}/${MAX_CI_FIXES})" \
        "CI failed on PR <a href='${PR_URL:-${CODEBERG_WEB}/pulls/${PR_NUMBER}}'>#${PR_NUMBER}</a> | <a href='${_ci_pipeline_url}'>Pipeline #${PIPELINE_NUM:-?}</a><br>Step: <code>${FAILED_STEP:-unknown}</code> (exit ${FAILED_EXIT:-?})<br>Attempt ${CI_FIX_COUNT}/${MAX_CI_FIXES}<br><pre>${_ci_snippet:-no logs}</pre>"

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
4. Commit your fix and push: git push origin ${BRANCH}
5. Write: echo \"PHASE:awaiting_ci\" > \"${PHASE_FILE}\"
6. Stop and wait."
    fi

  # ── PHASE: awaiting_review ──────────────────────────────────────────────────
  elif [ "$phase" = "PHASE:awaiting_review" ]; then
    status "waiting for review on PR #${PR_NUMBER:-?}"
    CI_FIX_COUNT=0  # Reset CI fix budget for this review cycle

    if [ -z "${PR_NUMBER:-}" ]; then
      log "WARNING: awaiting_review but PR_NUMBER unknown — searching for PR"
      FOUND_PR=$(curl -sf -H "Authorization: token ${CODEBERG_TOKEN}" \
        "${API}/pulls?state=open&limit=20" | \
        jq -r --arg branch "$BRANCH" \
        '.[] | select(.head.ref == $branch) | .number' | head -1) || true
      if [ -n "$FOUND_PR" ]; then
        PR_NUMBER="$FOUND_PR"
        log "found PR #${PR_NUMBER}"
      else
        agent_inject_into_session "$SESSION_NAME" "ERROR: Cannot find open PR for branch ${BRANCH}. Did you push? Verify with git status and git push origin ${BRANCH}, then write PHASE:awaiting_ci."
        return 0
      fi
    fi

    REVIEW_POLL_ELAPSED=0
    REVIEW_FOUND=false
    while [ "$REVIEW_POLL_ELAPSED" -lt "$REVIEW_POLL_TIMEOUT" ]; do
      sleep 300  # 5 min between review checks
      REVIEW_POLL_ELAPSED=$(( REVIEW_POLL_ELAPSED + 300 ))

      # Check session still alive
      if ! tmux has-session -t "${SESSION_NAME}" 2>/dev/null; then
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

      REVIEW_SHA=$(curl -sf -H "Authorization: token ${CODEBERG_TOKEN}" \
        "${API}/pulls/${PR_NUMBER}" | jq -r '.head.sha') || true
      REVIEW_COMMENT=$(codeberg_api_all "/issues/${PR_NUMBER}/comments" | \
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

        # Also check formal Codeberg reviews
        if [ -z "$VERDICT" ]; then
          VERDICT=$(curl -sf -H "Authorization: token ${CODEBERG_TOKEN}" \
            "${API}/pulls/${PR_NUMBER}/reviews" | \
            jq -r '[.[] | select(.stale == false)] | last | .state // empty' || true)
          if [ "$VERDICT" = "APPROVED" ]; then
            VERDICT="APPROVE"
          elif [ "$VERDICT" != "REQUEST_CHANGES" ]; then
            VERDICT=""
          fi
          [ -n "$VERDICT" ] && log "verdict from formal review: $VERDICT"
        fi

        # Skip injection if review-poll.sh already injected (sentinel present)
        REVIEW_SENTINEL="/tmp/review-injected-${PROJECT_NAME}-${PR_NUMBER}"
        if [ -n "$VERDICT" ] && [ -f "$REVIEW_SENTINEL" ]; then
          log "review already injected by review-poll (sentinel exists) — skipping"
          rm -f "$REVIEW_SENTINEL"
          REVIEW_FOUND=true
          break
        fi

        if [ "$VERDICT" = "APPROVE" ]; then
          REVIEW_FOUND=true
          agent_inject_into_session "$SESSION_NAME" "Approved! PR #${PR_NUMBER} has been approved.

Merge the PR and close the issue directly — do NOT wait for the orchestrator:

  # Merge the PR:
  curl -sf -X POST \\
    -H \"Authorization: token \${CODEBERG_TOKEN}\" \\
    -H 'Content-Type: application/json' \\
    \"${API}/pulls/${PR_NUMBER}/merge\" \\
    -d '{\"Do\":\"merge\",\"delete_branch_after_merge\":true}'

  # Close the issue:
  curl -sf -X PATCH \\
    -H \"Authorization: token \${CODEBERG_TOKEN}\" \\
    -H 'Content-Type: application/json' \\
    \"${API}/issues/${ISSUE}\" \\
    -d '{\"state\":\"closed\"}'

If merge fails due to conflicts, rebase first:
  git fetch origin ${PRIMARY_BRANCH} && git rebase origin/${PRIMARY_BRANCH}
  git push --force-with-lease origin ${BRANCH}
  # Then retry the merge curl above.

After a successful merge write PHASE:done:
  echo \"PHASE:done\" > \"${PHASE_FILE}\"

If merge repeatedly fails, write PHASE:needs_human with a reason."
          break

        elif [ "$VERDICT" = "REQUEST_CHANGES" ] || [ "$VERDICT" = "DISCUSS" ]; then
          REVIEW_ROUND=$(( REVIEW_ROUND + 1 ))
          if [ "$REVIEW_ROUND" -ge "$MAX_REVIEW_ROUNDS" ]; then
            log "hit max review rounds (${MAX_REVIEW_ROUNDS})"
            notify "PR #${PR_NUMBER}: hit ${MAX_REVIEW_ROUNDS} review rounds, needs human attention"
          fi
          REVIEW_FOUND=true
          agent_inject_into_session "$SESSION_NAME" "Review feedback (round ${REVIEW_ROUND}) on PR #${PR_NUMBER}:

${REVIEW_TEXT}

Instructions:
1. Address each piece of feedback carefully.
2. Run lint and tests when done.
3. Commit your changes and push: git push origin ${BRANCH}
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
      PR_JSON=$(curl -sf -H "Authorization: token ${CODEBERG_TOKEN}" \
        "${API}/pulls/${PR_NUMBER}") || true
      PR_STATE=$(echo "$PR_JSON" | jq -r '.state // "unknown"')
      PR_MERGED=$(echo "$PR_JSON" | jq -r '.merged // false')
      if [ "$PR_STATE" != "open" ]; then
        if [ "$PR_MERGED" = "true" ]; then
          log "PR #${PR_NUMBER} was merged externally"
          notify_ctx \
            "✅ PR #${PR_NUMBER} merged externally! Issue #${ISSUE} done." \
            "✅ PR <a href='${CODEBERG_WEB}/pulls/${PR_NUMBER}'>#${PR_NUMBER}</a> merged externally! <a href='${CODEBERG_WEB}/issues/${ISSUE}'>Issue #${ISSUE}</a> done."
          curl -sf -X PATCH -H "Authorization: token ${CODEBERG_TOKEN}" \
            -H "Content-Type: application/json" \
            "${API}/issues/${ISSUE}" -d '{"state":"closed"}' >/dev/null 2>&1 || true
          cleanup_labels
          agent_kill_session "$SESSION_NAME"
          cleanup_worktree
          rm -f "$PHASE_FILE" "$IMPL_SUMMARY_FILE" "$THREAD_FILE"
          exit 0
        else
          log "PR #${PR_NUMBER} was closed WITHOUT merge — NOT closing issue"
          notify "⚠️ PR #${PR_NUMBER} closed without merge. Issue #${ISSUE} remains open."
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
      notify "no review received for PR #${PR_NUMBER} after 3h"
      agent_inject_into_session "$SESSION_NAME" "TIMEOUT: No review received after 3 hours for PR #${PR_NUMBER}. Write PHASE:needs_human to escalate to a human reviewer."
    fi

  # ── PHASE: needs_human ──────────────────────────────────────────────────────
  elif [ "$phase" = "PHASE:needs_human" ]; then
    status "needs human input on issue #${ISSUE}"
    HUMAN_REASON=$(sed -n '2p' "$PHASE_FILE" 2>/dev/null | sed 's/^Reason: //' || echo "")
    _issue_url="${CODEBERG_WEB}/issues/${ISSUE}"
    _pr_link=""
    [ -n "${PR_NUMBER:-}" ] && _pr_link=" | PR <a href='${CODEBERG_WEB}/pulls/${PR_NUMBER}'>#${PR_NUMBER}</a>"
    notify_ctx \
      "⚠️ Issue #${ISSUE} (PR #${PR_NUMBER:-none}) needs human input.${HUMAN_REASON:+ Reason: ${HUMAN_REASON}}" \
      "⚠️ <a href='${_issue_url}'>Issue #${ISSUE}</a>${_pr_link} needs human input.${HUMAN_REASON:+ Reason: ${HUMAN_REASON}}<br>Reply in this thread to send guidance to the dev agent."
    log "phase: needs_human — notified via Matrix, waiting for external injection"
    # Don't inject anything — supervisor-poll.sh (#81) injects human replies, gardener-poll.sh as backup

  # ── PHASE: done ─────────────────────────────────────────────────────────────
  # The agent already merged the PR and closed the issue. Just clean up local state.
  elif [ "$phase" = "PHASE:done" ]; then
    status "phase done — agent merged PR #${PR_NUMBER:-?}, cleaning up"

    # Notify Matrix (agent already closed the issue and removed labels via API)
    notify_ctx \
      "✅ PR #${PR_NUMBER:-?} merged! Issue #${ISSUE} done." \
      "✅ PR <a href='${CODEBERG_WEB}/pulls/${PR_NUMBER:-?}'>#${PR_NUMBER:-?}</a> merged! <a href='${CODEBERG_WEB}/issues/${ISSUE}'>Issue #${ISSUE}</a> done."

    # Belt-and-suspenders: ensure in-progress label removed (idempotent)
    cleanup_labels

    # Local cleanup
    agent_kill_session "$SESSION_NAME"
    cleanup_worktree
    rm -f "$PHASE_FILE" "$IMPL_SUMMARY_FILE" "$THREAD_FILE"
    CLAIMED=false  # Don't unclaim again in cleanup()

  # ── PHASE: failed ───────────────────────────────────────────────────────────
  elif [ "$phase" = "PHASE:failed" ]; then
    FAILURE_REASON=$(sed -n '2p' "$PHASE_FILE" 2>/dev/null | sed 's/^Reason: //' || echo "unspecified")
    log "phase: failed — reason: ${FAILURE_REASON}"

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
        -H "Authorization: token ${CODEBERG_TOKEN}" \
        -H "Content-Type: application/json" \
        "${API}/issues/${ISSUE}/labels" \
        -d '{"labels":["backlog"]}' >/dev/null 2>&1 || true

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
          notify "refused #${ISSUE}: unmet dependency — ${BLOCKED_BY_MSG}"
          ;;
        too_large)
          REASON=$(printf '%s' "$REFUSAL_JSON" | jq -r '.reason // "unspecified"')
          post_refusal_comment "📏" "Too large for single session" "### Why this can't be implemented as-is

${REASON}

### Next steps
A maintainer should split this issue or add more detail to the spec."
          curl -sf -X POST \
            -H "Authorization: token ${CODEBERG_TOKEN}" \
            -H "Content-Type: application/json" \
            "${API}/issues/${ISSUE}/labels" \
            -d '{"labels":["underspecified"]}' >/dev/null 2>&1 || true
          curl -sf -X DELETE \
            -H "Authorization: token ${CODEBERG_TOKEN}" \
            "${API}/issues/${ISSUE}/labels/backlog" >/dev/null 2>&1 || true
          notify "refused #${ISSUE}: too large — ${REASON}"
          ;;
        already_done)
          REASON=$(printf '%s' "$REFUSAL_JSON" | jq -r '.reason // "unspecified"')
          post_refusal_comment "✅" "Already implemented" "### Existing implementation

${REASON}

Closing as already implemented."
          curl -sf -X PATCH \
            -H "Authorization: token ${CODEBERG_TOKEN}" \
            -H "Content-Type: application/json" \
            "${API}/issues/${ISSUE}" \
            -d '{"state":"closed"}' >/dev/null 2>&1 || true
          notify "refused #${ISSUE}: already done — ${REASON}"
          ;;
        *)
          post_refusal_comment "❓" "Unable to proceed" "The dev-agent could not process this issue.

Raw response:
\`\`\`json
$(printf '%s' "$REFUSAL_JSON" | head -c 2000)
\`\`\`"
          notify "refused #${ISSUE}: unknown reason"
          ;;
      esac

      CLAIMED=false  # Don't unclaim again in cleanup()
      agent_kill_session "$SESSION_NAME"
      cleanup_worktree
      rm -f "$PHASE_FILE" "$IMPL_SUMMARY_FILE" "$THREAD_FILE"
      return 1

    else
      # Genuine unrecoverable failure — escalate to supervisor
      log "session failed: ${FAILURE_REASON}"
      notify_ctx \
        "❌ Issue #${ISSUE} session failed: ${FAILURE_REASON}" \
        "❌ <a href='${CODEBERG_WEB}/issues/${ISSUE}'>Issue #${ISSUE}</a> session failed: ${FAILURE_REASON}${PR_NUMBER:+ | PR <a href='${CODEBERG_WEB}/pulls/${PR_NUMBER}'>#${PR_NUMBER}</a>}"
      echo "{\"issue\":${ISSUE},\"pr\":${PR_NUMBER:-0},\"reason\":\"${FAILURE_REASON}\",\"ts\":\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\"}" \
        >> "${FACTORY_ROOT}/supervisor/escalations-${PROJECT_NAME}.jsonl"

      # Restore backlog label
      cleanup_labels
      curl -sf -X POST \
        -H "Authorization: token ${CODEBERG_TOKEN}" \
        -H "Content-Type: application/json" \
        "${API}/issues/${ISSUE}/labels" \
        -d '{"labels":["backlog"]}' >/dev/null 2>&1 || true

      CLAIMED=false  # Don't unclaim again in cleanup()
      agent_kill_session "$SESSION_NAME"
      if [ -n "${PR_NUMBER:-}" ]; then
        log "keeping worktree (PR #${PR_NUMBER} still open)"
      else
        cleanup_worktree
      fi
      rm -f "$PHASE_FILE" "$IMPL_SUMMARY_FILE" "$THREAD_FILE"
      return 1
    fi

  else
    log "WARNING: unknown phase value: ${phase}"
  fi
}
