#!/usr/bin/env bash
# =============================================================================
# gardener-run.sh — Cron wrapper: gardener execution via SDK + formula
#
# Synchronous bash loop using claude -p (one-shot invocation).
# No tmux sessions, no phase files — the bash script IS the state machine.
#
# Flow:
#   1. Guards: cron lock, memory check
#   2. Load formula (formulas/run-gardener.toml)
#   3. Build context: AGENTS.md, scratch file, prompt footer
#   4. agent_run(worktree, prompt) → Claude does maintenance, pushes if needed
#   5. If pushed: pr_walk_to_merge() from lib/pr-lifecycle.sh
#   6. Post-merge: execute pending actions manifest (gardener/pending-actions.json)
#   7. Mirror push
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
# Use gardener-bot's own Forgejo identity (#747)
FORGE_TOKEN="${FORGE_GARDENER_TOKEN:-${FORGE_TOKEN}}"
# shellcheck source=../lib/formula-session.sh
source "$FACTORY_ROOT/lib/formula-session.sh"
# shellcheck source=../lib/worktree.sh
source "$FACTORY_ROOT/lib/worktree.sh"
# shellcheck source=../lib/ci-helpers.sh
source "$FACTORY_ROOT/lib/ci-helpers.sh"
# shellcheck source=../lib/mirrors.sh
source "$FACTORY_ROOT/lib/mirrors.sh"
# shellcheck source=../lib/guard.sh
source "$FACTORY_ROOT/lib/guard.sh"
# shellcheck source=../lib/agent-sdk.sh
source "$FACTORY_ROOT/lib/agent-sdk.sh"
# shellcheck source=../lib/pr-lifecycle.sh
source "$FACTORY_ROOT/lib/pr-lifecycle.sh"

LOG_FILE="$SCRIPT_DIR/gardener.log"
# shellcheck disable=SC2034  # consumed by agent-sdk.sh
LOGFILE="$LOG_FILE"
# shellcheck disable=SC2034  # consumed by agent-sdk.sh
SID_FILE="/tmp/gardener-session-${PROJECT_NAME}.sid"
SCRATCH_FILE="/tmp/gardener-${PROJECT_NAME}-scratch.md"
RESULT_FILE="/tmp/gardener-result-${PROJECT_NAME}.txt"
GARDENER_PR_FILE="/tmp/gardener-pr-${PROJECT_NAME}.txt"
WORKTREE="/tmp/${PROJECT_NAME}-gardener-run"

log() { echo "[$(date -u +%Y-%m-%dT%H:%M:%S)Z] $*" >> "$LOG_FILE"; }

# ── Guards ────────────────────────────────────────────────────────────────
check_active gardener
acquire_cron_lock "/tmp/gardener-run.lock"
check_memory 2000

log "--- Gardener run start ---"

# ── Resolve agent identity for .profile repo ────────────────────────────
if [ -z "${AGENT_IDENTITY:-}" ] && [ -n "${FORGE_GARDENER_TOKEN:-}" ]; then
  AGENT_IDENTITY=$(curl -sf -H "Authorization: token ${FORGE_GARDENER_TOKEN}" \
    "${FORGE_URL:-http://localhost:3000}/api/v1/user" 2>/dev/null | jq -r '.login // empty' 2>/dev/null || true)
fi

# ── Load formula + context ───────────────────────────────────────────────
load_formula_or_profile "gardener" "$FACTORY_ROOT/formulas/run-gardener.toml" || exit 1
build_context_block AGENTS.md

# ── Prepare .profile context (lessons injection) ─────────────────────────
formula_prepare_profile_context

# ── Read scratch file (compaction survival) ───────────────────────────────
SCRATCH_CONTEXT=$(read_scratch_context "$SCRATCH_FILE")
SCRATCH_INSTRUCTION=$(build_scratch_instruction "$SCRATCH_FILE")

# ── Build prompt ─────────────────────────────────────────────────────────
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
  {\"action\":\"close_pr\",    \"pr\":NNN}

The commit-and-pr step converts JSONL to JSON array. The orchestrator executes
actions after the PR merges. Do NOT call mutation APIs directly during the run."

build_sdk_prompt_footer "$GARDENER_API_EXTRA"
PROMPT_FOOTER="${PROMPT_FOOTER}## Completion protocol (REQUIRED)
When the commit-and-pr step creates a PR, write the PR number and stop:
  echo \"\$PR_NUMBER\" > '${GARDENER_PR_FILE}'
Then STOP. Do NOT write PHASE: signals — the orchestrator handles CI, review, and merge.
If no file changes exist (empty commit-and-pr), just stop — no PR needed."

PROMPT="You are the issue gardener for ${FORGE_REPO}. Work through the formula below.

You have full shell access and --dangerously-skip-permissions.
Fix what you can. File vault items for what you cannot. Do NOT ask permission — act first, report after.

## Project context
${CONTEXT_BLOCK}${LESSONS_INJECTION:+## Lessons learned
${LESSONS_INJECTION}

}
${SCRATCH_CONTEXT:+${SCRATCH_CONTEXT}
}
## Result file
Write actions and dust items to: ${RESULT_FILE}

## Formula
${FORMULA_CONTENT}

${SCRATCH_INSTRUCTION}
${PROMPT_FOOTER}"

# ── Create worktree ──────────────────────────────────────────────────────
cd "$PROJECT_REPO_ROOT"
git fetch origin "$PRIMARY_BRANCH" 2>/dev/null || true
worktree_cleanup "$WORKTREE"
git worktree add "$WORKTREE" "origin/${PRIMARY_BRANCH}" --detach 2>/dev/null

cleanup() {
  worktree_cleanup "$WORKTREE"
  rm -f "$GARDENER_PR_FILE"
}
trap cleanup EXIT

# ── Post-merge manifest execution ────────────────────────────────────────
# Reads gardener/pending-actions.json and executes each action via API.
# Failed actions are logged but do not block completion.
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
        label_id=$(curl -sf -H "Authorization: token ${FORGE_TOKEN}" \
          "${FORGE_API}/labels" | jq -r --arg n "$label" \
          '.[] | select(.name == $n) | .id') || true
        if [ -n "$label_id" ]; then
          if curl -sf -X POST -H "Authorization: token ${FORGE_TOKEN}" \
               -H 'Content-Type: application/json' \
               "${FORGE_API}/issues/${issue}/labels" \
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
        label_id=$(curl -sf -H "Authorization: token ${FORGE_TOKEN}" \
          "${FORGE_API}/labels" | jq -r --arg n "$label" \
          '.[] | select(.name == $n) | .id') || true
        if [ -n "$label_id" ]; then
          if curl -sf -X DELETE -H "Authorization: token ${FORGE_TOKEN}" \
               "${FORGE_API}/issues/${issue}/labels/${label_id}" >/dev/null 2>&1; then
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
        if curl -sf -X PATCH -H "Authorization: token ${FORGE_TOKEN}" \
             -H 'Content-Type: application/json' \
             "${FORGE_API}/issues/${issue}" \
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
        if curl -sf -X POST -H "Authorization: token ${FORGE_TOKEN}" \
             -H 'Content-Type: application/json' \
             "${FORGE_API}/issues/${issue}/comments" \
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
          all_labels=$(curl -sf -H "Authorization: token ${FORGE_TOKEN}" \
            "${FORGE_API}/labels") || true
          while IFS= read -r lname; do
            local lid
            lid=$(echo "$all_labels" | jq -r --arg n "$lname" \
              '.[] | select(.name == $n) | .id') || true
            [ -n "$lid" ] && ids_json="${ids_json:+${ids_json},}${lid}"
          done <<< "$labels"
          [ -n "$ids_json" ] && label_ids="[${ids_json}]"
        fi
        if curl -sf -X POST -H "Authorization: token ${FORGE_TOKEN}" \
             -H 'Content-Type: application/json' \
             "${FORGE_API}/issues" \
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
        if curl -sf -X PATCH -H "Authorization: token ${FORGE_TOKEN}" \
             -H 'Content-Type: application/json' \
             "${FORGE_API}/issues/${issue}" \
             -d "{\"body\":${escaped_body}}" >/dev/null 2>&1; then
          log "manifest: edited body of #${issue}"
        else
          log "manifest: FAILED edit_body #${issue}"
        fi
        ;;

      close_pr)
        local pr
        pr=$(jq -r ".[$i].pr" "$manifest_file")
        if curl -sf -X PATCH -H "Authorization: token ${FORGE_TOKEN}" \
             -H 'Content-Type: application/json' \
             "${FORGE_API}/pulls/${pr}" \
             -d '{"state":"closed"}' >/dev/null 2>&1; then
          log "manifest: closed PR #${pr}"
        else
          log "manifest: FAILED close_pr #${pr}"
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

# ── Reset result file ────────────────────────────────────────────────────
rm -f "$RESULT_FILE" "$GARDENER_PR_FILE"
touch "$RESULT_FILE"

# ── Run agent ─────────────────────────────────────────────────────────────
export CLAUDE_MODEL="sonnet"

agent_run --worktree "$WORKTREE" "$PROMPT"
log "agent_run complete"

# ── Detect PR ─────────────────────────────────────────────────────────────
PR_NUMBER=""
if [ -f "$GARDENER_PR_FILE" ]; then
  PR_NUMBER=$(tr -d '[:space:]' < "$GARDENER_PR_FILE")
fi

# Fallback: search for open gardener PRs
if [ -z "$PR_NUMBER" ]; then
  PR_NUMBER=$(curl -sf -H "Authorization: token ${FORGE_TOKEN}" \
    "${FORGE_API}/pulls?state=open&limit=10" | \
    jq -r '[.[] | select(.head.ref | startswith("chore/gardener-"))] | .[0].number // empty') || true
fi

# ── Walk PR to merge ──────────────────────────────────────────────────────
if [ -n "$PR_NUMBER" ]; then
  log "walking PR #${PR_NUMBER} to merge"
  pr_walk_to_merge "$PR_NUMBER" "$_AGENT_SESSION_ID" "$WORKTREE" || true

  if [ "$_PR_WALK_EXIT_REASON" = "merged" ]; then
    # Post-merge: pull primary, mirror push, execute manifest
    git -C "$PROJECT_REPO_ROOT" fetch origin "$PRIMARY_BRANCH" 2>/dev/null || true
    git -C "$PROJECT_REPO_ROOT" checkout "$PRIMARY_BRANCH" 2>/dev/null || true
    git -C "$PROJECT_REPO_ROOT" pull --ff-only origin "$PRIMARY_BRANCH" 2>/dev/null || true
    mirror_push
    _gardener_execute_manifest
    rm -f "$SCRATCH_FILE"
    log "gardener PR #${PR_NUMBER} merged — manifest executed"
  else
    log "PR #${PR_NUMBER} not merged (reason: ${_PR_WALK_EXIT_REASON:-unknown})"
  fi
else
  log "no PR created — gardener run complete"
  rm -f "$SCRATCH_FILE"
fi

# Write journal entry post-session
profile_write_journal "gardener-run" "Gardener run $(date -u +%Y-%m-%d)" "complete" "" || true

rm -f "$GARDENER_PR_FILE"
log "--- Gardener run done ---"
