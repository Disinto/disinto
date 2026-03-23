#!/usr/bin/env bash
# =============================================================================
# gardener-run.sh — Cron wrapper: gardener execution via Claude + formula
#
# Runs 4x/day (or on-demand). Guards against concurrent runs and low memory.
# Creates a tmux session with Claude (sonnet) reading formulas/run-gardener.toml.
# No action issues — the gardener is a nervous system component, not work (AD-001).
#
# Usage:
#   gardener-run.sh [projects/disinto.toml]   # project config (default: disinto)
#
# Cron: 0 0,6,12,18 * * * cd /home/debian/dark-factory && bash gardener/gardener-run.sh projects/disinto.toml
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
FACTORY_ROOT="$(dirname "$SCRIPT_DIR")"

# Accept project config from argument; default to disinto
export PROJECT_TOML="${1:-$FACTORY_ROOT/projects/disinto.toml}"
# shellcheck source=../lib/env.sh
source "$FACTORY_ROOT/lib/env.sh"
# shellcheck source=../lib/agent-session.sh
source "$FACTORY_ROOT/lib/agent-session.sh"
# shellcheck source=../lib/formula-session.sh
source "$FACTORY_ROOT/lib/formula-session.sh"
# shellcheck source=../lib/ci-helpers.sh
source "$FACTORY_ROOT/lib/ci-helpers.sh"

LOG_FILE="$SCRIPT_DIR/gardener.log"
# shellcheck disable=SC2034  # consumed by run_formula_and_monitor
SESSION_NAME="gardener-${PROJECT_NAME}"
PHASE_FILE="/tmp/gardener-session-${PROJECT_NAME}.phase"

# shellcheck disable=SC2034  # read by monitor_phase_loop in lib/agent-session.sh
PHASE_POLL_INTERVAL=15

SCRATCH_FILE="/tmp/gardener-${PROJECT_NAME}-scratch.md"
RESULT_FILE="/tmp/gardener-result-${PROJECT_NAME}.txt"
GARDENER_PR_FILE="/tmp/gardener-pr-${PROJECT_NAME}.txt"

# Merge-through state (used by _gardener_on_phase_change callback)
_GARDENER_PR=""
_GARDENER_MERGE_START=0
_GARDENER_MERGE_TIMEOUT=1800  # 30 min
_GARDENER_CI_FIX_COUNT=0
_GARDENER_REVIEW_ROUND=0
_GARDENER_CRASH_COUNT=0

log() { echo "[$(date -u +%Y-%m-%dT%H:%M:%S)Z] $*" >> "$LOG_FILE"; }

# ── Guards ────────────────────────────────────────────────────────────────
acquire_cron_lock "/tmp/gardener-run.lock"
check_memory 2000

log "--- Gardener run start ---"

# ── Consume escalation replies ────────────────────────────────────────────
consume_escalation_reply "gardener"

# ── Load formula + context ───────────────────────────────────────────────
load_formula "$FACTORY_ROOT/formulas/run-gardener.toml"
build_context_block AGENTS.md

# ── Read scratch file (compaction survival) ───────────────────────────────
SCRATCH_CONTEXT=$(read_scratch_context "$SCRATCH_FILE")
SCRATCH_INSTRUCTION=$(build_scratch_instruction "$SCRATCH_FILE")

# ── Build prompt (manifest format reference for deferred actions) ─────────
GARDENER_API_EXTRA="

## Pending-actions manifest (REQUIRED)
All repo mutations (comments, closures, label changes, issue creation) MUST be
written to the JSONL manifest instead of calling APIs directly. Append one JSON
object per line to: \$PROJECT_REPO_ROOT/gardener/pending-actions.jsonl

Supported actions:
  {\"action\":\"add_label\",    \"issue\":NNN, \"label\":\"priority\"}
  {\"action\":\"remove_label\", \"issue\":NNN, \"label\":\"backlog\"}
  {\"action\":\"close\",        \"issue\":NNN, \"reason\":\"already implemented\"}
  {\"action\":\"comment\",      \"issue\":NNN, \"body\":\"Relates to issue 1031\"}
  {\"action\":\"create_issue\", \"title\":\"...\", \"body\":\"...\", \"labels\":[\"backlog\"]}
  {\"action\":\"edit_body\",    \"issue\":NNN, \"body\":\"new body\"}

The commit-and-pr step converts JSONL to JSON array. The orchestrator executes
actions after the PR merges. Do NOT call mutation APIs directly during the run."
build_prompt_footer "$GARDENER_API_EXTRA"

# Extend phase protocol with merge-through instructions for compaction survival
PROMPT_FOOTER="${PROMPT_FOOTER}

## Merge-through protocol (commit-and-pr step)
After creating the PR, write the PR number and signal CI:
  echo \"\$PR_NUMBER\" > '${GARDENER_PR_FILE}'
  echo 'PHASE:awaiting_ci' > '${PHASE_FILE}'
Then STOP and WAIT for CI results.
When 'CI passed' is injected:
  echo 'PHASE:awaiting_review' > '${PHASE_FILE}'
Then STOP and WAIT.
When 'CI failed' is injected:
  Fix, commit, push, then: echo 'PHASE:awaiting_ci' > '${PHASE_FILE}'
When review feedback is injected:
  Address all feedback, commit, push, then: echo 'PHASE:awaiting_ci' > '${PHASE_FILE}'
If no file changes in commit-and-pr:
  echo 'PHASE:done' > '${PHASE_FILE}'"

# shellcheck disable=SC2034  # consumed by run_formula_and_monitor
PROMPT="You are the issue gardener for ${CODEBERG_REPO}. Work through the formula below. Follow the phase protocol: if the commit-and-pr step creates a PR, write PHASE:awaiting_ci and wait for orchestrator CI/review/merge handling. If no file changes, write PHASE:done. The orchestrator will time you out if you return to the prompt without signalling.

You have full shell access and --dangerously-skip-permissions.
Fix what you can. Escalate what you cannot. Do NOT ask permission — act first, report after.
${ESCALATION_REPLY:+
## Escalation Reply (from Matrix — human message)
${ESCALATION_REPLY}

Act on this reply during the grooming step.
}
## Project context
${CONTEXT_BLOCK}
${SCRATCH_CONTEXT:+${SCRATCH_CONTEXT}
}
## Result file
Write actions and dust items to: ${RESULT_FILE}

## Formula
${FORMULA_CONTENT}

${SCRATCH_INSTRUCTION}
${PROMPT_FOOTER}"

# ── Phase callback for merge-through ─────────────────────────────────────
# Handles CI polling, review injection, merge, and cleanup after PR creation.
# Lighter than dev/phase-handler.sh — tailored for gardener doc-only PRs.

# ── Post-merge manifest execution ─────────────────────────────────────
# Reads gardener/pending-actions.json and executes each action via API.
# Failed actions are logged but do not block completion.
# shellcheck disable=SC2317  # called indirectly via _gardener_merge
_gardener_execute_manifest() {
  local manifest_file="$PROJECT_REPO_ROOT/gardener/pending-actions.json"
  if [ ! -f "$manifest_file" ]; then
    log "manifest: no pending-actions.json — skipping"
    return 0
  fi

  local count
  count=$(jq 'length' "$manifest_file" 2>/dev/null || echo 0)
  if [ "$count" -eq 0 ]; then
    log "manifest: empty — skipping"
    return 0
  fi

  log "manifest: executing ${count} actions"

  local i=0
  while [ "$i" -lt "$count" ]; do
    local action issue
    action=$(jq -r ".[$i].action" "$manifest_file")
    issue=$(jq -r ".[$i].issue // empty" "$manifest_file")

    case "$action" in
      add_label)
        local label label_id
        label=$(jq -r ".[$i].label" "$manifest_file")
        label_id=$(curl -sf -H "Authorization: token ${CODEBERG_TOKEN}" \
          "${CODEBERG_API}/labels" | jq -r --arg n "$label" \
          '.[] | select(.name == $n) | .id') || true
        if [ -n "$label_id" ]; then
          if curl -sf -X POST -H "Authorization: token ${CODEBERG_TOKEN}" \
               -H 'Content-Type: application/json' \
               "${CODEBERG_API}/issues/${issue}/labels" \
               -d "{\"labels\":[${label_id}]}" >/dev/null 2>&1; then
            log "manifest: add_label '${label}' to #${issue}"
          else
            log "manifest: FAILED add_label '${label}' to #${issue}"
          fi
        else
          log "manifest: FAILED add_label — label '${label}' not found"
        fi
        ;;

      remove_label)
        local label label_id
        label=$(jq -r ".[$i].label" "$manifest_file")
        label_id=$(curl -sf -H "Authorization: token ${CODEBERG_TOKEN}" \
          "${CODEBERG_API}/labels" | jq -r --arg n "$label" \
          '.[] | select(.name == $n) | .id') || true
        if [ -n "$label_id" ]; then
          if curl -sf -X DELETE -H "Authorization: token ${CODEBERG_TOKEN}" \
               "${CODEBERG_API}/issues/${issue}/labels/${label_id}" >/dev/null 2>&1; then
            log "manifest: remove_label '${label}' from #${issue}"
          else
            log "manifest: FAILED remove_label '${label}' from #${issue}"
          fi
        else
          log "manifest: FAILED remove_label — label '${label}' not found"
        fi
        ;;

      close)
        local reason
        reason=$(jq -r ".[$i].reason // empty" "$manifest_file")
        if curl -sf -X PATCH -H "Authorization: token ${CODEBERG_TOKEN}" \
             -H 'Content-Type: application/json' \
             "${CODEBERG_API}/issues/${issue}" \
             -d '{"state":"closed"}' >/dev/null 2>&1; then
          log "manifest: closed #${issue} (${reason})"
        else
          log "manifest: FAILED close #${issue}"
        fi
        ;;

      comment)
        local body escaped_body
        body=$(jq -r ".[$i].body" "$manifest_file")
        escaped_body=$(printf '%s' "$body" | jq -Rs '.')
        if curl -sf -X POST -H "Authorization: token ${CODEBERG_TOKEN}" \
             -H 'Content-Type: application/json' \
             "${CODEBERG_API}/issues/${issue}/comments" \
             -d "{\"body\":${escaped_body}}" >/dev/null 2>&1; then
          log "manifest: commented on #${issue}"
        else
          log "manifest: FAILED comment on #${issue}"
        fi
        ;;

      create_issue)
        local title body labels escaped_title escaped_body label_ids
        title=$(jq -r ".[$i].title" "$manifest_file")
        body=$(jq -r ".[$i].body" "$manifest_file")
        labels=$(jq -r ".[$i].labels // [] | .[]" "$manifest_file")
        escaped_title=$(printf '%s' "$title" | jq -Rs '.')
        escaped_body=$(printf '%s' "$body" | jq -Rs '.')
        # Resolve label names to IDs
        label_ids="[]"
        if [ -n "$labels" ]; then
          local all_labels ids_json=""
          all_labels=$(curl -sf -H "Authorization: token ${CODEBERG_TOKEN}" \
            "${CODEBERG_API}/labels") || true
          while IFS= read -r lname; do
            local lid
            lid=$(echo "$all_labels" | jq -r --arg n "$lname" \
              '.[] | select(.name == $n) | .id') || true
            [ -n "$lid" ] && ids_json="${ids_json:+${ids_json},}${lid}"
          done <<< "$labels"
          [ -n "$ids_json" ] && label_ids="[${ids_json}]"
        fi
        if curl -sf -X POST -H "Authorization: token ${CODEBERG_TOKEN}" \
             -H 'Content-Type: application/json' \
             "${CODEBERG_API}/issues" \
             -d "{\"title\":${escaped_title},\"body\":${escaped_body},\"labels\":${label_ids}}" >/dev/null 2>&1; then
          log "manifest: created issue '${title}'"
        else
          log "manifest: FAILED create_issue '${title}'"
        fi
        ;;

      edit_body)
        local body escaped_body
        body=$(jq -r ".[$i].body" "$manifest_file")
        escaped_body=$(printf '%s' "$body" | jq -Rs '.')
        if curl -sf -X PATCH -H "Authorization: token ${CODEBERG_TOKEN}" \
             -H 'Content-Type: application/json' \
             "${CODEBERG_API}/issues/${issue}" \
             -d "{\"body\":${escaped_body}}" >/dev/null 2>&1; then
          log "manifest: edited body of #${issue}"
        else
          log "manifest: FAILED edit_body #${issue}"
        fi
        ;;

      *)
        log "manifest: unknown action '${action}' — skipping"
        ;;
    esac

    i=$((i + 1))
  done

  log "manifest: execution complete (${count} actions processed)"
}

# shellcheck disable=SC2317  # called indirectly by monitor_phase_loop
_gardener_merge() {
  local merge_response merge_http_code
  merge_response=$(curl -s -w "\n%{http_code}" -X POST \
    -H "Authorization: token ${CODEBERG_TOKEN}" \
    -H 'Content-Type: application/json' \
    "${CODEBERG_API}/pulls/${_GARDENER_PR}/merge" \
    -d '{"Do":"merge","delete_branch_after_merge":true}') || true
  merge_http_code=$(echo "$merge_response" | tail -1)

  if [ "$merge_http_code" = "200" ] || [ "$merge_http_code" = "204" ]; then
    log "gardener PR #${_GARDENER_PR} merged"
    _gardener_execute_manifest
    printf 'PHASE:done\n' > "$PHASE_FILE"
    return 0
  fi

  # Already merged (race)?
  if [ "$merge_http_code" = "405" ]; then
    local pr_merged
    pr_merged=$(curl -sf -H "Authorization: token ${CODEBERG_TOKEN}" \
      "${CODEBERG_API}/pulls/${_GARDENER_PR}" | jq -r '.merged // false') || true
    if [ "$pr_merged" = "true" ]; then
      log "gardener PR #${_GARDENER_PR} already merged"
      _gardener_execute_manifest
      printf 'PHASE:done\n' > "$PHASE_FILE"
      return 0
    fi
    log "gardener merge blocked (HTTP 405) — escalating"
    printf 'PHASE:escalate\nReason: gardener PR #%s merge blocked (HTTP 405)\n' \
      "$_GARDENER_PR" > "$PHASE_FILE"
    return 0
  fi

  # Other failure (likely conflicts) — tell Claude to rebase
  log "gardener merge failed (HTTP ${merge_http_code}) — requesting rebase"
  agent_inject_into_session "${_MONITOR_SESSION:-$SESSION_NAME}" \
    "Merge failed for PR #${_GARDENER_PR} (likely conflicts). Rebase and push:
  git fetch origin ${PRIMARY_BRANCH} && git rebase origin/${PRIMARY_BRANCH}
  git push --force-with-lease origin HEAD
  echo \"PHASE:awaiting_ci\" > \"${PHASE_FILE}\"
If rebase fails, write PHASE:escalate with a reason."
}

# shellcheck disable=SC2317  # called indirectly by monitor_phase_loop
_gardener_timeout_cleanup() {
  log "gardener merge-through timed out (${_GARDENER_MERGE_TIMEOUT}s) — closing PR"
  if [ -n "$_GARDENER_PR" ]; then
    curl -sf -X PATCH \
      -H "Authorization: token ${CODEBERG_TOKEN}" \
      -H 'Content-Type: application/json' \
      "${CODEBERG_API}/pulls/${_GARDENER_PR}" \
      -d '{"state":"closed"}' >/dev/null 2>&1 || true
  fi
  printf 'PHASE:failed\nReason: merge-through timeout (%ss)\n' \
    "$_GARDENER_MERGE_TIMEOUT" > "$PHASE_FILE"
}

# shellcheck disable=SC2317  # called indirectly by monitor_phase_loop
_gardener_handle_ci() {
  # Start merge-through timer on first CI phase
  if [ "$_GARDENER_MERGE_START" -eq 0 ]; then
    _GARDENER_MERGE_START=$(date +%s)
  fi

  # Check merge-through timeout
  local elapsed
  elapsed=$(( $(date +%s) - _GARDENER_MERGE_START ))
  if [ "$elapsed" -ge "$_GARDENER_MERGE_TIMEOUT" ]; then
    _gardener_timeout_cleanup
    return 0
  fi

  # Discover PR number if unknown
  if [ -z "$_GARDENER_PR" ]; then
    if [ -f "$GARDENER_PR_FILE" ]; then
      _GARDENER_PR=$(tr -d '[:space:]' < "$GARDENER_PR_FILE")
    fi
    # Fallback: search for open gardener PRs
    if [ -z "$_GARDENER_PR" ]; then
      _GARDENER_PR=$(curl -sf -H "Authorization: token ${CODEBERG_TOKEN}" \
        "${CODEBERG_API}/pulls?state=open&limit=10" | \
        jq -r '[.[] | select(.head.ref | startswith("chore/gardener-"))] | .[0].number // empty') || true
    fi
    if [ -z "$_GARDENER_PR" ]; then
      log "ERROR: cannot find gardener PR"
      agent_inject_into_session "${_MONITOR_SESSION:-$SESSION_NAME}" \
        "ERROR: Could not find the gardener PR. Verify branch was pushed and PR created. Write the PR number to ${GARDENER_PR_FILE}, then write PHASE:awaiting_ci again."
      return 0
    fi
    log "tracking gardener PR #${_GARDENER_PR}"
  fi

  # Skip CI for doc-only PRs
  if ! ci_required_for_pr "$_GARDENER_PR" 2>/dev/null; then
    log "CI not required (doc-only) — treating as passed"
    agent_inject_into_session "${_MONITOR_SESSION:-$SESSION_NAME}" \
      "CI passed on PR #${_GARDENER_PR} (doc-only changes, CI not required).
Write PHASE:awaiting_review to the phase file, then stop and wait:
  echo \"PHASE:awaiting_review\" > \"${PHASE_FILE}\""
    return 0
  fi

  # No CI configured?
  if [ "${WOODPECKER_REPO_ID:-2}" = "0" ]; then
    log "no CI configured — treating as passed"
    agent_inject_into_session "${_MONITOR_SESSION:-$SESSION_NAME}" \
      "CI passed on PR #${_GARDENER_PR} (no CI configured).
Write PHASE:awaiting_review to the phase file, then stop and wait:
  echo \"PHASE:awaiting_review\" > \"${PHASE_FILE}\""
    return 0
  fi

  # Get HEAD SHA from PR
  local head_sha
  head_sha=$(curl -sf -H "Authorization: token ${CODEBERG_TOKEN}" \
    "${CODEBERG_API}/pulls/${_GARDENER_PR}" | jq -r '.head.sha // empty') || true

  if [ -z "$head_sha" ]; then
    log "WARNING: could not get HEAD SHA for PR #${_GARDENER_PR}"
    agent_inject_into_session "${_MONITOR_SESSION:-$SESSION_NAME}" \
      "WARNING: Could not read HEAD SHA for PR #${_GARDENER_PR}. Verify push succeeded. Then write PHASE:awaiting_ci again."
    return 0
  fi

  # Poll CI (15 min max within this phase)
  local ci_done=false ci_state="unknown" ci_elapsed=0 ci_timeout=900
  while [ "$ci_elapsed" -lt "$ci_timeout" ]; do
    sleep 30
    ci_elapsed=$((ci_elapsed + 30))

    # Session health check
    if [ -f "/tmp/claude-exited-${_MONITOR_SESSION:-$SESSION_NAME}.ts" ] || \
       ! tmux has-session -t "${_MONITOR_SESSION:-$SESSION_NAME}" 2>/dev/null; then
      log "session died during CI wait"
      return 0
    fi

    # Merge-through timeout check
    elapsed=$(( $(date +%s) - _GARDENER_MERGE_START ))
    if [ "$elapsed" -ge "$_GARDENER_MERGE_TIMEOUT" ]; then
      _gardener_timeout_cleanup
      return 0
    fi

    # Re-fetch HEAD in case Claude pushed new commits
    head_sha=$(curl -sf -H "Authorization: token ${CODEBERG_TOKEN}" \
      "${CODEBERG_API}/pulls/${_GARDENER_PR}" | jq -r '.head.sha // empty') || true

    ci_state=$(curl -sf -H "Authorization: token ${CODEBERG_TOKEN}" \
      "${CODEBERG_API}/commits/${head_sha}/status" | jq -r '.state // "unknown"') || ci_state="unknown"

    case "$ci_state" in
      success|failure|error) ci_done=true; break ;;
    esac
  done

  if ! $ci_done; then
    log "CI timeout for PR #${_GARDENER_PR}"
    agent_inject_into_session "${_MONITOR_SESSION:-$SESSION_NAME}" \
      "CI TIMEOUT: CI did not complete within 15 minutes for PR #${_GARDENER_PR}. Write PHASE:escalate if you cannot proceed."
    return 0
  fi

  log "CI: ${ci_state} for PR #${_GARDENER_PR}"

  if [ "$ci_state" = "success" ]; then
    _GARDENER_CI_FIX_COUNT=0
    agent_inject_into_session "${_MONITOR_SESSION:-$SESSION_NAME}" \
      "CI passed on PR #${_GARDENER_PR}.
Write PHASE:awaiting_review to the phase file, then stop and wait:
  echo \"PHASE:awaiting_review\" > \"${PHASE_FILE}\""
  else
    _GARDENER_CI_FIX_COUNT=$(( _GARDENER_CI_FIX_COUNT + 1 ))
    if [ "$_GARDENER_CI_FIX_COUNT" -gt 3 ]; then
      log "CI exhausted after ${_GARDENER_CI_FIX_COUNT} attempts"
      printf 'PHASE:escalate\nReason: gardener CI exhausted after %d attempts\n' \
        "$_GARDENER_CI_FIX_COUNT" > "$PHASE_FILE"
      return 0
    fi

    # Get error details
    local pipeline_num ci_error_log
    pipeline_num=$(curl -sf -H "Authorization: token ${CODEBERG_TOKEN}" \
      "${CODEBERG_API}/commits/${head_sha}/status" | \
      jq -r '.statuses[0].target_url // ""' | grep -oP 'pipeline/\K[0-9]+' | head -1 || true)

    ci_error_log=""
    if [ -n "$pipeline_num" ]; then
      ci_error_log=$(bash "${FACTORY_ROOT}/lib/ci-debug.sh" failures "$pipeline_num" 2>/dev/null \
        | tail -80 | head -c 8000 || true)
    fi

    agent_inject_into_session "${_MONITOR_SESSION:-$SESSION_NAME}" \
      "CI failed on PR #${_GARDENER_PR} (attempt ${_GARDENER_CI_FIX_COUNT}/3).
${ci_error_log:+Error output:
${ci_error_log}
}Fix the issue, commit, push, then write:
  echo \"PHASE:awaiting_ci\" > \"${PHASE_FILE}\"
Then stop and wait."
  fi
}

# shellcheck disable=SC2317  # called indirectly by monitor_phase_loop
_gardener_handle_review() {
  log "waiting for review on PR #${_GARDENER_PR:-?}"
  _GARDENER_CI_FIX_COUNT=0  # Reset CI fix budget for next review cycle

  local review_elapsed=0 review_timeout=1800
  while [ "$review_elapsed" -lt "$review_timeout" ]; do
    sleep 60  # 1 min between review checks (gardener PRs are fast-tracked)
    review_elapsed=$((review_elapsed + 60))

    # Session health check
    if [ -f "/tmp/claude-exited-${_MONITOR_SESSION:-$SESSION_NAME}.ts" ] || \
       ! tmux has-session -t "${_MONITOR_SESSION:-$SESSION_NAME}" 2>/dev/null; then
      log "session died during review wait"
      return 0
    fi

    # Merge-through timeout check
    local elapsed
    elapsed=$(( $(date +%s) - _GARDENER_MERGE_START ))
    if [ "$elapsed" -ge "$_GARDENER_MERGE_TIMEOUT" ]; then
      _gardener_timeout_cleanup
      return 0
    fi

    # Check if phase changed while we wait (e.g. review-poll injected feedback)
    local new_mtime
    new_mtime=$(stat -c %Y "$PHASE_FILE" 2>/dev/null || echo 0)
    if [ "$new_mtime" -gt "${LAST_PHASE_MTIME:-0}" ]; then
      log "phase changed during review wait — returning to monitor loop"
      return 0
    fi

    # Check for review on current HEAD
    local review_sha review_comment
    review_sha=$(curl -sf -H "Authorization: token ${CODEBERG_TOKEN}" \
      "${CODEBERG_API}/pulls/${_GARDENER_PR}" | jq -r '.head.sha // empty') || true

    review_comment=$(codeberg_api_all "/issues/${_GARDENER_PR}/comments" 2>/dev/null | \
      jq -r --arg sha "${review_sha:-none}" \
      '[.[] | select(.body | contains("<!-- reviewed: " + $sha))] | last // empty') || true

    if [ -n "$review_comment" ] && [ "$review_comment" != "null" ]; then
      local review_text verdict
      review_text=$(echo "$review_comment" | jq -r '.body')

      # Skip error reviews
      if echo "$review_text" | grep -q "review-error\|Review — Error"; then
        continue
      fi

      verdict=$(echo "$review_text" | grep -oP '\*\*(APPROVE|REQUEST_CHANGES|DISCUSS)\*\*' | head -1 | tr -d '*' || true)

      # Check formal Codeberg reviews as fallback
      if [ -z "$verdict" ]; then
        verdict=$(curl -sf -H "Authorization: token ${CODEBERG_TOKEN}" \
          "${CODEBERG_API}/pulls/${_GARDENER_PR}/reviews" | \
          jq -r '[.[] | select(.stale == false)] | last | .state // empty' || true)
        [ "$verdict" = "APPROVED" ] && verdict="APPROVE"
        [[ "$verdict" != "REQUEST_CHANGES" && "$verdict" != "APPROVE" ]] && verdict=""
      fi

      # Check review-poll sentinel to avoid double injection
      local review_sentinel="/tmp/review-injected-${PROJECT_NAME}-${_GARDENER_PR}"
      if [ -n "$verdict" ] && [ -f "$review_sentinel" ] && [ "$verdict" != "APPROVE" ]; then
        log "review already injected by review-poll — skipping"
        rm -f "$review_sentinel"
        break
      fi
      rm -f "$review_sentinel"

      if [ "$verdict" = "APPROVE" ]; then
        log "gardener PR #${_GARDENER_PR} approved — merging"
        _gardener_merge
        return 0

      elif [ "$verdict" = "REQUEST_CHANGES" ] || [ "$verdict" = "DISCUSS" ]; then
        _GARDENER_REVIEW_ROUND=$(( _GARDENER_REVIEW_ROUND + 1 ))
        log "review REQUEST_CHANGES on PR #${_GARDENER_PR} (round ${_GARDENER_REVIEW_ROUND})"
        agent_inject_into_session "${_MONITOR_SESSION:-$SESSION_NAME}" \
          "Review feedback on PR #${_GARDENER_PR} (round ${_GARDENER_REVIEW_ROUND}):

${review_text}

Address all feedback, commit, push, then write:
  echo \"PHASE:awaiting_ci\" > \"${PHASE_FILE}\"
Then stop and wait."
        return 0
      fi
    fi

    # Check if PR was merged or closed externally
    local pr_json pr_state pr_merged
    pr_json=$(curl -sf -H "Authorization: token ${CODEBERG_TOKEN}" \
      "${CODEBERG_API}/pulls/${_GARDENER_PR}") || true
    pr_state=$(echo "$pr_json" | jq -r '.state // "unknown"')
    pr_merged=$(echo "$pr_json" | jq -r '.merged // false')

    if [ "$pr_merged" = "true" ]; then
      log "gardener PR #${_GARDENER_PR} merged externally"
      _gardener_execute_manifest
      printf 'PHASE:done\n' > "$PHASE_FILE"
      return 0
    fi
    if [ "$pr_state" != "open" ]; then
      log "gardener PR #${_GARDENER_PR} closed without merge"
      printf 'PHASE:failed\nReason: PR closed without merge\n' > "$PHASE_FILE"
      return 0
    fi

    log "waiting for review on PR #${_GARDENER_PR} (${review_elapsed}s)"
  done

  if [ "$review_elapsed" -ge "$review_timeout" ]; then
    log "review wait timed out for PR #${_GARDENER_PR}"
    agent_inject_into_session "${_MONITOR_SESSION:-$SESSION_NAME}" \
      "No review received after ${review_timeout}s for PR #${_GARDENER_PR}. Write PHASE:escalate if you cannot proceed."
  fi
}

# shellcheck disable=SC2317  # called indirectly by monitor_phase_loop
_gardener_on_phase_change() {
  local phase="$1"
  log "phase: ${phase}"

  case "$phase" in
    PHASE:awaiting_ci)
      _gardener_handle_ci
      ;;
    PHASE:awaiting_review)
      _gardener_handle_review
      ;;
    PHASE:done|PHASE:merged)
      agent_kill_session "${_MONITOR_SESSION:-$SESSION_NAME}"
      ;;
    PHASE:failed)
      agent_kill_session "${_MONITOR_SESSION:-$SESSION_NAME}"
      ;;
    PHASE:escalate)
      local reason
      reason=$(sed -n '2p' "$PHASE_FILE" 2>/dev/null | sed 's/^Reason: //' || true)
      log "escalated: ${reason}"
      matrix_send "gardener" "Gardener escalated: ${reason}" 2>/dev/null || true
      agent_kill_session "${_MONITOR_SESSION:-$SESSION_NAME}"
      ;;
    PHASE:crashed)
      if [ "${_GARDENER_CRASH_COUNT:-0}" -gt 0 ]; then
        log "ERROR: session crashed again — giving up"
        return 0
      fi
      _GARDENER_CRASH_COUNT=$(( _GARDENER_CRASH_COUNT + 1 ))
      log "WARNING: session crashed — attempting recovery"
      if create_agent_session "${_MONITOR_SESSION:-$SESSION_NAME}" \
           "${_FORMULA_SESSION_WORKDIR:-$PROJECT_REPO_ROOT}" "$PHASE_FILE" 2>/dev/null; then
        agent_inject_into_session "${_MONITOR_SESSION:-$SESSION_NAME}" "$PROMPT"
        log "recovery session started"
      else
        log "ERROR: could not restart session after crash"
      fi
      ;;
    *)
      log "WARNING: unknown phase: ${phase}"
      ;;
  esac
}

# ── Reset result file ────────────────────────────────────────────────────
rm -f "$RESULT_FILE"
touch "$RESULT_FILE"

# ── Run session ──────────────────────────────────────────────────────────
export CLAUDE_MODEL="sonnet"
run_formula_and_monitor "gardener" 7200 "_gardener_on_phase_change"

# ── Cleanup on exit ──────────────────────────────────────────────────────
# FINAL_PHASE already set by run_formula_and_monitor
if [ "${FINAL_PHASE:-}" = "PHASE:done" ]; then
  rm -f "$SCRATCH_FILE"
fi
rm -f "$GARDENER_PR_FILE"
[ -n "$_GARDENER_PR" ] && rm -f "/tmp/review-injected-${PROJECT_NAME}-${_GARDENER_PR}"
