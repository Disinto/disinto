#!/usr/bin/env bash
# dev-agent.sh — Autonomous developer agent for a single issue
#
# Usage: ./dev-agent.sh <issue-number>
#
# Lifecycle:
#   1. Fetch issue, check dependencies (preflight)
#   2. Claim issue (label: in-progress, remove backlog)
#   3. Create worktree + branch
#   4. Run claude -p with implementation prompt
#   5. Commit + push + create PR
#   6. Wait for CI + AI review
#   7. Feed review back via claude -p -c (continues session)
#   8. On APPROVE → merge, delete branch, clean labels, close issue
#
# Preflight JSON output:
#   {"status": "ready"}
#   {"status": "unmet_dependency", "blocked_by": [315, 316], "suggestion": 317}
#   {"status": "too_large", "reason": "..."}
#   {"status": "already_done", "reason": "..."}
#
# Peek:    cat /tmp/dev-agent-status
# Log:     tail -f dev-agent.log

set -euo pipefail

# Load shared environment
source "$(dirname "$0")/../lib/env.sh"


# --- Config ---
ISSUE="${1:?Usage: dev-agent.sh <issue-number>}"
REPO="${CODEBERG_REPO}"
REPO_ROOT="${PROJECT_REPO_ROOT}"

API="${CODEBERG_API}"
LOCKFILE="/tmp/dev-agent-${PROJECT_NAME:-harb}.lock"
STATUSFILE="/tmp/dev-agent-status"
LOGFILE="${FACTORY_ROOT}/dev/dev-agent.log"
PREFLIGHT_RESULT="/tmp/dev-agent-preflight.json"
BRANCH="fix/issue-${ISSUE}"
WORKTREE="/tmp/${PROJECT_NAME}-worktree-${ISSUE}"
REVIEW_POLL_INTERVAL=300  # 5 min between review checks
MAX_REVIEW_ROUNDS=5
CLAUDE_TIMEOUT=7200

# --- Logging ---
log() {
  printf '[%s] #%s %s\n' "$(date -u '+%Y-%m-%d %H:%M:%S UTC')" "$ISSUE" "$*" >> "$LOGFILE"
}

status() {
  printf '[%s] dev-agent #%s: %s\n' "$(date -u '+%Y-%m-%d %H:%M:%S UTC')" "$ISSUE" "$*" > "$STATUSFILE"
  log "$*"
}

notify() {
  matrix_send "dev" "🔧 #${ISSUE}: $*" 2>/dev/null || true
}

cleanup_worktree() {
  cd "$REPO_ROOT"
  git worktree remove "$WORKTREE" --force 2>/dev/null || true
  rm -rf "$WORKTREE"
  # Clear Claude Code session history for this worktree to prevent hallucinated "already done"
  CLAUDE_PROJECT_DIR="$HOME/.claude/projects/$(echo "$WORKTREE" | sed 's|/|-|g; s|^-||')"
  rm -rf "$CLAUDE_PROJECT_DIR" 2>/dev/null || true
}

cleanup_labels() {
  curl -sf -X DELETE \
    -H "Authorization: token ${CODEBERG_TOKEN}" \
    "${API}/issues/${ISSUE}/labels/in-progress" >/dev/null 2>&1 || true
}

CLAIMED=false
cleanup() {
  rm -f "$LOCKFILE" "$STATUSFILE"
  # If we claimed the issue but never created a PR, unclaim it
  if [ "$CLAIMED" = true ] && [ -z "${PR_NUMBER:-}" ]; then
    log "cleanup: unclaiming issue (no PR created)"
    curl -sf -X DELETE \
      -H "Authorization: token ${CODEBERG_TOKEN}" \
      "${API}/issues/${ISSUE}/labels/in-progress" >/dev/null 2>&1 || true
    curl -sf -X POST \
      -H "Authorization: token ${CODEBERG_TOKEN}" \
      -H "Content-Type: application/json" \
      "${API}/issues/${ISSUE}/labels" \
      -d '{"labels":["backlog"]}' >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT


# --- Log rotation ---
if [ -f "$LOGFILE" ] && [ "$(stat -c%s "$LOGFILE" 2>/dev/null || echo 0)" -gt 102400 ]; then
  mv "$LOGFILE" "$LOGFILE.old"
  log "Log rotated"
fi

# --- Memory guard ---
AVAIL_MB=$(awk '/MemAvailable/ {printf "%d", $2/1024}' /proc/meminfo)
if [ "$AVAIL_MB" -lt 2000 ]; then
  log "SKIP: only ${AVAIL_MB}MB available (need 2000MB)"
  exit 0
fi

# --- Concurrency lock ---
if [ -f "$LOCKFILE" ]; then
  LOCK_PID=$(cat "$LOCKFILE" 2>/dev/null || echo "")
  if [ -n "$LOCK_PID" ] && kill -0 "$LOCK_PID" 2>/dev/null; then
    log "SKIP: another dev-agent running (PID ${LOCK_PID})"
    exit 0
  fi
  log "Removing stale lock (PID ${LOCK_PID:-?})"
  rm -f "$LOCKFILE"
fi
echo $$ > "$LOCKFILE"

# --- Fetch issue ---
status "fetching issue"
ISSUE_JSON=$(curl -s -H "Authorization: token ${CODEBERG_TOKEN}" "${API}/issues/${ISSUE}") || true
if [ -z "$ISSUE_JSON" ] || ! echo "$ISSUE_JSON" | jq -e '.id' >/dev/null 2>&1; then
  log "ERROR: failed to fetch issue #${ISSUE} (API down or invalid response)"
  exit 1
fi
ISSUE_TITLE=$(echo "$ISSUE_JSON" | jq -r '.title')
ISSUE_BODY=$(echo "$ISSUE_JSON" | jq -r '.body // ""')
ISSUE_STATE=$(echo "$ISSUE_JSON" | jq -r '.state')

if [ "$ISSUE_STATE" != "open" ]; then
  log "SKIP: issue #${ISSUE} is ${ISSUE_STATE}"
  echo '{"status":"already_done","reason":"issue is closed"}' > "$PREFLIGHT_RESULT"
  exit 0
fi

log "Issue: ${ISSUE_TITLE}"

# =============================================================================
# PREFLIGHT: Check dependencies before doing any work
# =============================================================================
status "preflight check"

# Extract dependency references from issue body
# Only from ## Dependencies / ## Depends on / ## Blocked by sections
# and inline "depends on #NNN" / "blocked by #NNN" phrases.
# NEVER extract from ## Related or other sections.
DEP_NUMBERS=""

# 1. Inline phrases anywhere in body (explicit dep language only)
INLINE_DEPS=$(echo "$ISSUE_BODY" | \
  grep -ioP '(?:depends on|blocked by)\s+#\K[0-9]+' | \
  sort -un || true)
[ -n "$INLINE_DEPS" ] && DEP_NUMBERS="$INLINE_DEPS"

# 2. ## Dependencies / ## Depends on / ## Blocked by section (bullet items)
DEP_SECTION=$(echo "$ISSUE_BODY" | sed -n '/^##\?\s*\(Dependencies\|Depends on\|Blocked by\)/I,/^##/p' | sed '1d;$d')
if [ -n "$DEP_SECTION" ]; then
  SECTION_DEPS=$(echo "$DEP_SECTION" | grep -oP '#\K[0-9]+' | sort -un || true)
  DEP_NUMBERS=$(printf '%s\n%s' "$DEP_NUMBERS" "$SECTION_DEPS" | sort -un | grep -v '^$' || true)
fi

BLOCKED_BY=()
if [ -n "$DEP_NUMBERS" ]; then
  while IFS= read -r dep_num; do
    [ -z "$dep_num" ] && continue
    # Check if dependency issue is closed (= satisfied)
    DEP_STATE=$(curl -sf -H "Authorization: token ${CODEBERG_TOKEN}" \
      "${API}/issues/${dep_num}" | jq -r '.state // "unknown"')

    if [ "$DEP_STATE" != "closed" ]; then
      BLOCKED_BY+=("$dep_num")
      log "dependency #${dep_num} is ${DEP_STATE} (not satisfied)"
    else
      log "dependency #${dep_num} is closed (satisfied)"
    fi
  done <<< "$DEP_NUMBERS"
fi

if [ "${#BLOCKED_BY[@]}" -gt 0 ]; then
  # Find a suggestion: look for the first blocker that itself has no unmet deps
  SUGGESTION=""
  for blocker in "${BLOCKED_BY[@]}"; do
    BLOCKER_BODY=$(curl -sf -H "Authorization: token ${CODEBERG_TOKEN}" \
      "${API}/issues/${blocker}" | jq -r '.body // ""')
    BLOCKER_STATE=$(curl -sf -H "Authorization: token ${CODEBERG_TOKEN}" \
      "${API}/issues/${blocker}" | jq -r '.state')

    if [ "$BLOCKER_STATE" != "open" ]; then
      continue
    fi

    # Check if this blocker has its own unmet deps
    BLOCKER_DEPS=$(echo "$BLOCKER_BODY" | \
      grep -ioP '(?:depends on|blocked by|requires|after)\s+#\K[0-9]+' | sort -un || true)
    BLOCKER_SECTION=$(echo "$BLOCKER_BODY" | sed -n '/^## Dependencies/,/^## /p' | sed '1d;$d')
    if [ -n "$BLOCKER_SECTION" ]; then
      BLOCKER_SECTION_DEPS=$(echo "$BLOCKER_SECTION" | grep -oP '#\K[0-9]+' | sort -un || true)
      BLOCKER_DEPS=$(printf '%s\n%s' "$BLOCKER_DEPS" "$BLOCKER_SECTION_DEPS" | sort -un | grep -v '^$' || true)
    fi

    BLOCKER_BLOCKED=false
    if [ -n "$BLOCKER_DEPS" ]; then
      while IFS= read -r bd; do
        [ -z "$bd" ] && continue
        BD_STATE=$(curl -sf -H "Authorization: token ${CODEBERG_TOKEN}" \
          "${API}/issues/${bd}" | jq -r '.state // "unknown"')
        if [ "$BD_STATE" != "closed" ]; then
          BLOCKER_BLOCKED=true
          break
        fi
      done <<< "$BLOCKER_DEPS"
    fi

    if [ "$BLOCKER_BLOCKED" = false ]; then
      SUGGESTION="$blocker"
      break
    fi
  done

  # Write preflight result
  BLOCKED_JSON=$(printf '%s\n' "${BLOCKED_BY[@]}" | jq -R 'tonumber' | jq -sc '.')
  if [ -n "$SUGGESTION" ]; then
    jq -n --argjson blocked "$BLOCKED_JSON" --argjson suggestion "$SUGGESTION" \
      '{"status":"unmet_dependency","blocked_by":$blocked,"suggestion":$suggestion}' > "$PREFLIGHT_RESULT"
  else
    jq -n --argjson blocked "$BLOCKED_JSON" \
      '{"status":"unmet_dependency","blocked_by":$blocked,"suggestion":null}' > "$PREFLIGHT_RESULT"
  fi

  # Post comment ONLY if last comment isn't already an unmet dependency notice
  BLOCKED_LIST=$(printf '#%s, ' "${BLOCKED_BY[@]}" | sed 's/, $//')
  LAST_COMMENT_IS_BLOCK=$(curl -sf -H "Authorization: token ${CODEBERG_TOKEN}" \
    "${API}/issues/${ISSUE}/comments?limit=1" | \
    jq -r '.[0].body // ""' | grep -c 'Dev-agent: Unmet dependency' || true)

  if [ "$LAST_COMMENT_IS_BLOCK" -eq 0 ]; then
    BLOCK_COMMENT="🚧 **Dev-agent: Unmet dependency**

### Blocked by open issues

This issue depends on ${BLOCKED_LIST}, which $(if [ "${#BLOCKED_BY[@]}" -eq 1 ]; then echo "is"; else echo "are"; fi) not yet closed."
    if [ -n "$SUGGESTION" ]; then
      BLOCK_COMMENT="${BLOCK_COMMENT}

**Suggestion:** Work on #${SUGGESTION} first."
    fi
    BLOCK_COMMENT="${BLOCK_COMMENT}

---
*Automated assessment by dev-agent · $(date -u '+%Y-%m-%d %H:%M UTC')*"

    printf '%s' "$BLOCK_COMMENT" > /tmp/block-comment.txt
    jq -Rs '{body: .}' < /tmp/block-comment.txt > /tmp/block-comment.json
    curl -sf -o /dev/null -X POST \
      -H "Authorization: token ${CODEBERG_TOKEN}" \
      -H "Content-Type: application/json" \
      "${API}/issues/${ISSUE}/comments" \
      --data-binary @/tmp/block-comment.json 2>/dev/null || true
    rm -f /tmp/block-comment.txt /tmp/block-comment.json
  else
    log "skipping duplicate dependency comment"
  fi

  log "BLOCKED: unmet dependencies: ${BLOCKED_BY[*]}$(if [ -n "$SUGGESTION" ]; then echo ", suggest #${SUGGESTION}"; fi)"
  notify "blocked by unmet dependencies: ${BLOCKED_BY[*]}"
  exit 0
fi

# Bash preflight passed (no explicit unmet deps)
log "bash preflight passed — no explicit unmet dependencies"

# =============================================================================
# CLAIM ISSUE (tentative — will unclaim if claude refuses)
# =============================================================================

curl -sf -X POST \
  -H "Authorization: token ${CODEBERG_TOKEN}" \
  -H "Content-Type: application/json" \
  "${API}/issues/${ISSUE}/labels" \
  -d '{"labels":["in-progress"]}' >/dev/null 2>&1 || true

curl -sf -X DELETE \
  -H "Authorization: token ${CODEBERG_TOKEN}" \
  "${API}/issues/${ISSUE}/labels/backlog" >/dev/null 2>&1 || true

curl -sf -X DELETE \
  -H "Authorization: token ${CODEBERG_TOKEN}" \
  "${API}/issues/${ISSUE}/labels/backlog" >/dev/null 2>&1 || true

CLAIMED=true

# =============================================================================
# CHECK FOR EXISTING PR (recovery mode)
# =============================================================================
EXISTING_PR=""
EXISTING_BRANCH=""
RECOVERY_MODE=false

BODY_PR=$(echo "$ISSUE_BODY" | grep -oP 'Existing PR:\s*#\K[0-9]+' | head -1) || true
if [ -n "$BODY_PR" ]; then
  PR_CHECK=$(curl -sf -H "Authorization: token ${CODEBERG_TOKEN}" \
    "${API}/pulls/${BODY_PR}" | jq -r '{state, head_ref: .head.ref}')
  PR_CHECK_STATE=$(echo "$PR_CHECK" | jq -r '.state')
  if [ "$PR_CHECK_STATE" = "open" ]; then
    EXISTING_PR="$BODY_PR"
    EXISTING_BRANCH=$(echo "$PR_CHECK" | jq -r '.head_ref')
    log "found existing PR #${EXISTING_PR} on branch ${EXISTING_BRANCH} (from issue body)"
  fi
fi

if [ -z "$EXISTING_PR" ]; then
  # Priority 1: match by branch name (most reliable)
  FOUND_PR=$(curl -sf -H "Authorization: token ${CODEBERG_TOKEN}" \
    "${API}/pulls?state=open&limit=20" | \
    jq -r --arg branch "$BRANCH" \
    '.[] | select(.head.ref == $branch) | "\(.number) \(.head.ref)"' | head -1) || true
  if [ -n "$FOUND_PR" ]; then
    EXISTING_PR=$(echo "$FOUND_PR" | awk '{print $1}')
    EXISTING_BRANCH=$(echo "$FOUND_PR" | awk '{print $2}')
    log "found existing PR #${EXISTING_PR} on branch ${EXISTING_BRANCH} (from branch match)"
  fi
fi

if [ -z "$EXISTING_PR" ]; then
  # Priority 2: match "Fixes #NNN" or "fixes #NNN" in PR body (stricter: word boundary)
  FOUND_PR=$(curl -sf -H "Authorization: token ${CODEBERG_TOKEN}" \
    "${API}/pulls?state=open&limit=20" | \
    jq -r --arg issue "ixes #${ISSUE}\\b" \
    '.[] | select(.body | test($issue; "i")) | "\(.number) \(.head.ref)"' | head -1) || true
  if [ -n "$FOUND_PR" ]; then
    EXISTING_PR=$(echo "$FOUND_PR" | awk '{print $1}')
    EXISTING_BRANCH=$(echo "$FOUND_PR" | awk '{print $2}')
    log "found existing PR #${EXISTING_PR} on branch ${EXISTING_BRANCH} (from body match)"
  fi
fi

# Priority 3: check CLOSED PRs for prior art (don't redo work from scratch)
PRIOR_ART_DIFF=""
if [ -z "$EXISTING_PR" ]; then
  CLOSED_PR=$(curl -sf -H "Authorization: token ${CODEBERG_TOKEN}" \
    "${API}/pulls?state=closed&limit=30" | \
    jq -r --arg issue "#${ISSUE}" \
    '.[] | select(.merged != true) | select((.title | contains($issue)) or (.body // "" | test("ixes " + $issue + "\\b"; "i"))) | "\(.number) \(.head.ref)"' | head -1) || true
  if [ -n "$CLOSED_PR" ]; then
    CLOSED_PR_NUM=$(echo "$CLOSED_PR" | awk '{print $1}')
    log "found closed (unmerged) PR #${CLOSED_PR_NUM} as prior art"
    # Fetch the diff for claude to reference
    PRIOR_ART_DIFF=$(curl -sf -H "Authorization: token ${CODEBERG_TOKEN}" \
      "${API}/pulls/${CLOSED_PR_NUM}.diff" | head -500) || true
    if [ -n "$PRIOR_ART_DIFF" ]; then
      log "captured prior art diff from PR #${CLOSED_PR_NUM} ($(echo "$PRIOR_ART_DIFF" | wc -l) lines)"
    fi
  fi
fi

if [ -n "$EXISTING_PR" ]; then
  RECOVERY_MODE=true
  PR_NUMBER="$EXISTING_PR"
  BRANCH="$EXISTING_BRANCH"
  log "RECOVERY MODE: adopting PR #${PR_NUMBER} on branch ${BRANCH}"

  PR_SHA=$(curl -sf -H "Authorization: token ${CODEBERG_TOKEN}" \
    "${API}/pulls/${PR_NUMBER}" | jq -r '.head.sha')

  PENDING_REVIEW=$(curl -sf -H "Authorization: token ${CODEBERG_TOKEN}" \
    "${API}/issues/${PR_NUMBER}/comments?limit=50" | \
    jq -r --arg sha "$PR_SHA" \
    '[.[] | select(.body | contains("<!-- reviewed: " + $sha)) | select((.body | contains("REQUEST_CHANGES")) or (.body | contains("DISCUSS")))] | last // empty')

  if [ -n "$PENDING_REVIEW" ] && [ "$PENDING_REVIEW" != "null" ]; then
    PENDING_REVIEW_TEXT=$(echo "$PENDING_REVIEW" | jq -r '.body')
    log "found unaddressed REQUEST_CHANGES review at ${PR_SHA:0:7}"

    status "setting up worktree for recovery"
    cd "$REPO_ROOT"
    git fetch origin "$BRANCH" 2>/dev/null

    # Reuse existing worktree if it's on the right branch (preserves .claude session)
    REUSE_WORKTREE=false
    if [ -d "$WORKTREE/.git" ] || [ -f "$WORKTREE/.git" ]; then
      WT_BRANCH=$(cd "$WORKTREE" && git rev-parse --abbrev-ref HEAD 2>/dev/null || true)
      if [ "$WT_BRANCH" = "$BRANCH" ]; then
        log "reusing existing worktree (preserves claude session)"
        cd "$WORKTREE"
        git pull --ff-only origin "$BRANCH" 2>/dev/null || git reset --hard "origin/${BRANCH}" 2>/dev/null || true
        REUSE_WORKTREE=true
      fi
    fi

    if [ "$REUSE_WORKTREE" = false ]; then
      cleanup_worktree
      git worktree add "$WORKTREE" "origin/${BRANCH}" -B "$BRANCH" 2>&1 || {
        log "ERROR: worktree creation failed for recovery"
        cleanup_labels
        exit 1
      }
      cd "$WORKTREE"
      git submodule update --init --recursive 2>/dev/null || true
    fi

    REVIEW_ROUND=1
    status "claude addressing review (recovery)"

    # Use -c (continue) if session exists, fresh -p otherwise
    CLAUDE_CONTINUE=""
    if [ -d "$WORKTREE/.claude" ] && [ "$REUSE_WORKTREE" = true ]; then
      CLAUDE_CONTINUE="-c"
      log "continuing previous claude session"
    fi

    REVIEW_PROMPT="You are working in a git worktree at ${WORKTREE} on branch ${BRANCH}.
This is issue #${ISSUE} for the ${CODEBERG_REPO} project.

## Issue: ${ISSUE_TITLE}

${ISSUE_BODY}

## Instructions
The AI reviewer has reviewed the PR and requests changes.
Read AGENTS.md for project context. Address each finding below.
Run lint and tests when done. Commit your fixes.

When you're done, output a SHORT summary of what you changed, formatted as a bullet list.

## Review Feedback:
${PENDING_REVIEW_TEXT}"

    REVIEW_OUTPUT=$(cd "$WORKTREE" && timeout "$CLAUDE_TIMEOUT" \
      claude -p $CLAUDE_CONTINUE --model sonnet --dangerously-skip-permissions "$REVIEW_PROMPT" 2>&1) || {
      EXIT_CODE=$?
      if [ -n "$CLAUDE_CONTINUE" ]; then
        log "claude -c recovery failed (exit ${EXIT_CODE}), retrying without continue"
        REVIEW_OUTPUT=$(cd "$WORKTREE" && timeout "$CLAUDE_TIMEOUT" \
          claude -p --model sonnet --dangerously-skip-permissions "$REVIEW_PROMPT" 2>&1) || {
          log "claude recovery failed completely (exit $?)"
          exit 1
        }
      else
        log "claude recovery failed (exit ${EXIT_CODE})"
        exit 1
      fi
    }

    log "claude finished recovery review addressing"

    cd "$WORKTREE"
    if [ -n "$(git status --porcelain)" ]; then
      git add -A
      git commit --no-verify -m "fix: address review findings (#${ISSUE})" 2>&1 | tail -2
    fi

    REMOTE_SHA=$(git ls-remote origin "$BRANCH" 2>/dev/null | awk '{print $1}')
    LOCAL_SHA=$(git rev-parse HEAD)
    PUSHED=false
    if [ "$LOCAL_SHA" != "$REMOTE_SHA" ]; then
      git push origin "$BRANCH" --force 2>&1 | tail -3
      log "pushed recovery fixes"
      PUSHED=true
      notify "PR #${PR_NUMBER}: pushed recovery fixes for issue #${ISSUE}"
    else
      log "no changes after recovery review addressing"
    fi

    if [ "$PUSHED" = true ]; then
      CHANGE_SUMMARY=$(echo "$REVIEW_OUTPUT" | grep '^\s*-' | tail -20)
      [ -z "$CHANGE_SUMMARY" ] && CHANGE_SUMMARY="Changes pushed (see diff for details)."

      DEV_COMMENT="## 🔧 Dev-agent response (recovery)
<!-- dev-response: $(git rev-parse HEAD) round:recovery -->

### Changes made:
${CHANGE_SUMMARY}

---
*Addressed at \`$(git rev-parse HEAD | head -c 7)\` · automated by dev-agent (recovery mode)*"

      printf '%s' "$DEV_COMMENT" > /tmp/dev-comment-body.txt
      jq -Rs '{body: .}' < /tmp/dev-comment-body.txt > /tmp/dev-comment.json
      curl -sf -o /dev/null -X POST \
        -H "Authorization: token ${CODEBERG_TOKEN}" \
        -H "Content-Type: application/json" \
        "${API}/issues/${PR_NUMBER}/comments" \
        --data-binary @/tmp/dev-comment.json 2>/dev/null || \
        log "WARNING: failed to post dev-response comment"
      rm -f /tmp/dev-comment-body.txt /tmp/dev-comment.json
    fi
  else
    # Check if PR already has approval — try merge immediately
    EXISTING_APPROVAL=$(curl -sf -H "Authorization: token ${CODEBERG_TOKEN}" \
      "${API}/pulls/${PR_NUMBER}/reviews" | \
      jq -r '[.[] | select(.stale == false and .state == "APPROVED")] | length')
    CI_NOW=$(curl -sf -H "Authorization: token ${CODEBERG_TOKEN}" \
      "${API}/commits/$(git -C "$REPO_ROOT" rev-parse "origin/${BRANCH}" 2>/dev/null || echo HEAD)/status" | jq -r '.state // "unknown"')
    CI_PASS=false
    if [ "$CI_NOW" = "success" ]; then
      CI_PASS=true
    elif [ "${WOODPECKER_REPO_ID:-2}" = "0" ] && { [ -z "$CI_NOW" ] || [ "$CI_NOW" = "pending" ] || [ "$CI_NOW" = "unknown" ]; }; then
      CI_PASS=true  # no CI configured for this project
    fi
    if [ "${EXISTING_APPROVAL:-0}" -gt 0 ] && [ "$CI_PASS" = true ]; then
      log "PR already approved + CI green — attempting merge"
      MERGE_HTTP=$(curl -s -o /dev/null -w "%{http_code}" -X POST \
        -H "Authorization: token ${CODEBERG_TOKEN}" \
        -H "Content-Type: application/json" \
        "${API}/pulls/${PR_NUMBER}/merge" \
        -d '{"Do":"merge","delete_branch_after_merge":true}')
      if [ "$MERGE_HTTP" = "200" ] || [ "$MERGE_HTTP" = "204" ]; then
        log "PR #${PR_NUMBER} merged!"
        notify "✅ PR #${PR_NUMBER} merged! Issue #${ISSUE} done."
        curl -sf -X PATCH -H "Authorization: token ${CODEBERG_TOKEN}" \
          -H "Content-Type: application/json" \
          "${API}/issues/${ISSUE}" -d '{"state":"closed"}' >/dev/null 2>&1 || true
        cleanup_labels
        cleanup_worktree
        exit 0
      fi
      # Merge failed — rebase and retry
      log "merge failed (HTTP ${MERGE_HTTP}) — rebasing"
      cd "$REPO_ROOT"
      git fetch origin "${PRIMARY_BRANCH}" "$BRANCH" 2>/dev/null
      TMP_WT="/tmp/rebase-pr-${PR_NUMBER}"
      rm -rf "$TMP_WT"
      if git worktree add "$TMP_WT" "$BRANCH" 2>/dev/null && \
         (cd "$TMP_WT" && git rebase "origin/${PRIMARY_BRANCH}" 2>&1) && \
         (cd "$TMP_WT" && git push --force-with-lease origin "$BRANCH" 2>&1); then
        log "rebased — waiting for CI + re-approval"
        git worktree remove "$TMP_WT" 2>/dev/null || true
        NEW_SHA=$(git rev-parse "origin/${BRANCH}" 2>/dev/null || true)
        # Wait for CI
        for _r in $(seq 1 20); do
          _ci=$(curl -sf -H "Authorization: token ${CODEBERG_TOKEN}" \
            "${API}/commits/${NEW_SHA}/status" | jq -r '.state // "unknown"')
          [ "$_ci" = "success" ] && break
          sleep 30
        done
        # Re-approve (force push dismissed stale approval)
        curl -sf -X POST -H "Authorization: token ${REVIEW_BOT_TOKEN}" \
          -H "Content-Type: application/json" \
          "${API}/pulls/${PR_NUMBER}/reviews" \
          -d '{"event":"APPROVED","body":"Auto-approved after rebase."}' >/dev/null 2>&1 || true
        # Retry merge
        MERGE_HTTP=$(curl -s -o /dev/null -w "%{http_code}" -X POST \
          -H "Authorization: token ${CODEBERG_TOKEN}" \
          -H "Content-Type: application/json" \
          "${API}/pulls/${PR_NUMBER}/merge" \
          -d '{"Do":"merge","delete_branch_after_merge":true}')
        if [ "$MERGE_HTTP" = "200" ] || [ "$MERGE_HTTP" = "204" ]; then
          log "PR #${PR_NUMBER} merged after rebase!"
          notify "✅ PR #${PR_NUMBER} merged! Issue #${ISSUE} done."
          curl -sf -X PATCH -H "Authorization: token ${CODEBERG_TOKEN}" \
            -H "Content-Type: application/json" \
            "${API}/issues/${ISSUE}" -d '{"state":"closed"}' >/dev/null 2>&1 || true
          cleanup_labels
          cleanup_worktree
          exit 0
        fi
        notify "PR #${PR_NUMBER} merge failed after rebase (HTTP ${MERGE_HTTP}). Needs human attention."
      else
        git worktree remove --force "$TMP_WT" 2>/dev/null || true
        notify "PR #${PR_NUMBER} rebase failed. Needs human attention."
      fi
      exit 0
    fi
    log "no unaddressed review found — PR exists, entering review loop to wait"
    cd "$REPO_ROOT"
    git fetch origin "$BRANCH" 2>/dev/null

    # Reuse existing worktree if on the right branch (preserves .claude session)
    if [ -d "$WORKTREE/.git" ] || [ -f "$WORKTREE/.git" ]; then
      WT_BRANCH=$(cd "$WORKTREE" && git rev-parse --abbrev-ref HEAD 2>/dev/null || true)
      if [ "$WT_BRANCH" = "$BRANCH" ]; then
        log "reusing existing worktree (preserves claude session)"
        cd "$WORKTREE"
        git pull --ff-only origin "$BRANCH" 2>/dev/null || git reset --hard "origin/${BRANCH}" 2>/dev/null || true
      else
        cleanup_worktree
        git worktree add "$WORKTREE" "origin/${BRANCH}" -B "$BRANCH" 2>&1 || {
          log "ERROR: worktree setup failed for recovery"
          exit 1
        }
        cd "$WORKTREE"
        git submodule update --init --recursive 2>/dev/null || true
      fi
    else
      cleanup_worktree
      git worktree add "$WORKTREE" "origin/${BRANCH}" -B "$BRANCH" 2>&1 || {
        log "ERROR: worktree setup failed for recovery"
        exit 1
      }
      cd "$WORKTREE"
      git submodule update --init --recursive 2>/dev/null || true
    fi
  fi
else
  # =============================================================================
  # NORMAL MODE: implement from scratch
  # =============================================================================

  status "creating worktree"
  cd "$REPO_ROOT"

  # Ensure repo is in clean state (abort stale rebases, checkout primary branch)
  if [ -d "$REPO_ROOT/.git/rebase-merge" ] || [ -d "$REPO_ROOT/.git/rebase-apply" ]; then
    log "WARNING: stale rebase detected in main repo — aborting"
    git rebase --abort 2>/dev/null || true
  fi
  CURRENT_BRANCH=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "unknown")
  if [ "$CURRENT_BRANCH" != "${PRIMARY_BRANCH}" ]; then
    log "WARNING: main repo on '$CURRENT_BRANCH' instead of ${PRIMARY_BRANCH} — switching"
    git checkout "${PRIMARY_BRANCH}" 2>/dev/null || true
  fi

  git fetch origin "${PRIMARY_BRANCH}" 2>/dev/null
  git pull --ff-only origin "${PRIMARY_BRANCH}" 2>/dev/null || true
  cleanup_worktree
  git worktree add "$WORKTREE" "origin/${PRIMARY_BRANCH}" -B "$BRANCH" 2>&1 || {
    log "ERROR: worktree creation failed"
    git worktree add "$WORKTREE" "origin/${PRIMARY_BRANCH}" -B "$BRANCH" 2>&1 | while read -r wt_line; do log "  $wt_line"; done || true
    cleanup_labels
    exit 1
  }
  cd "$WORKTREE"
  git checkout -B "$BRANCH" "origin/${PRIMARY_BRANCH}" 2>/dev/null
  git submodule update --init --recursive 2>/dev/null || true


  # Symlink lib node_modules from main repo (submodule init doesn't run npm install)
  for lib_dir in "$REPO_ROOT"/onchain/lib/*/; do
    lib_name=$(basename "$lib_dir")
    if [ -d "$lib_dir/node_modules" ] && [ ! -d "$WORKTREE/onchain/lib/$lib_name/node_modules" ]; then
      ln -s "$lib_dir/node_modules" "$WORKTREE/onchain/lib/$lib_name/node_modules" 2>/dev/null || true
    fi
  done

  # --- Build the unified prompt: implement OR refuse ---
  # Gather open issue list for context (so claude can suggest alternatives)
  OPEN_ISSUES_SUMMARY=$(curl -sf -H "Authorization: token ${CODEBERG_TOKEN}" \
    "${API}/issues?state=open&labels=backlog&limit=20&type=issues" | \
    jq -r '.[] | "#\(.number) \(.title)"' 2>/dev/null || echo "(could not fetch)")

  PROMPT="You are working in a git worktree at ${WORKTREE} on branch ${BRANCH}.
You have been assigned issue #${ISSUE} for the ${CODEBERG_REPO} project.

## Issue: ${ISSUE_TITLE}

${ISSUE_BODY}

## Other open issues labeled 'backlog' (for context if you need to suggest alternatives):
${OPEN_ISSUES_SUMMARY}

$(if [ -n "$PRIOR_ART_DIFF" ]; then echo "## Prior Art (closed PR — DO NOT start from scratch)

A previous PR attempted this issue but was closed without merging. Review the diff below and reuse as much as possible. Fix whatever caused it to fail (merge conflicts, CI errors, review findings).

\`\`\`diff
${PRIOR_ART_DIFF}
\`\`\`"; fi)

## Instructions

**Before implementing, assess whether you should proceed.** You have two options:

### Option A: Implement
If the issue is clear, dependencies are met, and scope is reasonable:
1. Read AGENTS.md in this repo for project context and coding conventions.
2. Implement the changes described in the issue.
3. Run lint and tests before you're done (see AGENTS.md for commands).
4. Commit your changes with message: fix: ${ISSUE_TITLE} (#${ISSUE})
5. Do NOT push or create PRs — the orchestrator handles that.
6. When finished, output a summary of what you changed and why.

### Option B: Refuse (output JSON only)
If you cannot or should not implement this issue, output ONLY a JSON object (no other text) with one of these structures:

**Unmet dependency** — required code/infrastructure doesn't exist in the repo yet:
\`\`\`
{\"status\": \"unmet_dependency\", \"blocked_by\": \"short explanation of what's missing\", \"suggestion\": <issue-number-to-work-on-first or null>}
\`\`\`

**Too large** — issue needs to be split, spec is too vague, or scope exceeds a single session:
\`\`\`
{\"status\": \"too_large\", \"reason\": \"what makes it too large and how to split it\"}
\`\`\`

**Already done** — the work described is already implemented in the codebase:
\`\`\`
{\"status\": \"already_done\", \"reason\": \"where the existing implementation is\"}
\`\`\`

### How to decide
- Read the issue carefully. Check if files/functions it references actually exist in the repo.
- If it depends on other issues, check if those issues' deliverables are present in the codebase.
- If the issue spec is vague or requires designing multiple new systems, refuse as too_large.
- If another open issue should be done first, suggest it.
- When in doubt, implement. Only refuse if there's a clear, specific reason.

**Do NOT invent dependencies that aren't real.** If the code compiles and tests pass, that's ready."

  status "claude assessing + implementing"
  IMPL_OUTPUT=$(cd "$WORKTREE" && timeout "$CLAUDE_TIMEOUT" \
    claude -p --model sonnet --dangerously-skip-permissions "$PROMPT" 2>&1) || {
    EXIT_CODE=$?
    if [ "$EXIT_CODE" -eq 124 ]; then
      log "TIMEOUT: claude took longer than ${CLAUDE_TIMEOUT}s"
      notify "timed out during implementation"
    else
      log "ERROR: claude exited with code ${EXIT_CODE}"
      notify "claude failed (exit ${EXIT_CODE})"
    fi
    cleanup_labels
    cleanup_worktree
    exit 1
  }

  log "claude finished ($(printf '%s' "$IMPL_OUTPUT" | wc -c) bytes)"
  printf '%s' "$IMPL_OUTPUT" > /tmp/dev-agent-last-output.txt

  # --- Check if claude refused (JSON response) vs implemented (commits) ---
  REFUSAL_JSON=""

  # Check for refusal: try to parse output as JSON with a status field
  # First try raw output
  if printf '%s' "$IMPL_OUTPUT" | jq -e '.status' > /dev/null 2>&1; then
    REFUSAL_JSON="$IMPL_OUTPUT"
  else
    # Try extracting from code fence
    EXTRACTED=$(printf '%s' "$IMPL_OUTPUT" | sed -n '/^```/,/^```$/p' | sed '1d;$d')
    if [ -n "$EXTRACTED" ] && printf '%s' "$EXTRACTED" | jq -e '.status' > /dev/null 2>&1; then
      REFUSAL_JSON="$EXTRACTED"
    else
      # Try extracting first { ... } block (handles preamble text before JSON)
      EXTRACTED=$(printf '%s' "$IMPL_OUTPUT" | grep -Pzo '\{[^{}]*"status"[^{}]*\}' 2>/dev/null | tr '\0' '\n' | head -1 || true)
      if [ -n "$EXTRACTED" ] && printf '%s' "$EXTRACTED" | jq -e '.status' > /dev/null 2>&1; then
        REFUSAL_JSON="$EXTRACTED"
      fi
    fi
  fi

  # But only treat as refusal if there are NO commits (claude might output JSON-like text AND commit)
  cd "$WORKTREE"
  AHEAD=$(git rev-list "origin/${PRIMARY_BRANCH}..HEAD" --count 2>/dev/null || echo "0")
  HAS_CHANGES=$(git status --porcelain)

  if [ -n "$REFUSAL_JSON" ] && [ "$AHEAD" -eq 0 ] && [ -z "$HAS_CHANGES" ]; then
    # Claude refused — parse and handle
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

    # --- Post refusal comment on the issue (deduplicated) ---
    post_refusal_comment() {
      local emoji="$1" title="$2" body="$3"

      # Skip if last comment already has same title (prevent spam)
      local last_has_title
      last_has_title=$(curl -sf -H "Authorization: token ${CODEBERG_TOKEN}" \
        "${API}/issues/${ISSUE}/comments?limit=1" | \
        jq -r --arg t "Dev-agent: ${title}" '.[0].body // "" | contains($t)') || true
      if [ "$last_has_title" = "true" ]; then
        log "skipping duplicate refusal comment: ${title}"
        return 0
      fi

      local comment="${emoji} **Dev-agent: ${title}**

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

    case "$REFUSAL_STATUS" in
      unmet_dependency)
        BLOCKED_BY=$(printf '%s' "$REFUSAL_JSON" | jq -r '.blocked_by // "unknown"')
        SUGGESTION=$(printf '%s' "$REFUSAL_JSON" | jq -r '.suggestion // empty')
        log "unmet dependency: ${BLOCKED_BY}. suggestion: ${SUGGESTION:-none}"
        notify "refused #${ISSUE}: unmet dependency — ${BLOCKED_BY}"

        COMMENT_BODY="### Blocked by unmet dependency

${BLOCKED_BY}"
        if [ -n "$SUGGESTION" ] && [ "$SUGGESTION" != "null" ]; then
          COMMENT_BODY="${COMMENT_BODY}

**Suggestion:** Work on #${SUGGESTION} first."
        fi
        post_refusal_comment "🚧" "Unmet dependency" "$COMMENT_BODY"
        ;;
      too_large)
        REASON=$(printf '%s' "$REFUSAL_JSON" | jq -r '.reason // "unspecified"')
        log "too large: ${REASON}"
        notify "refused #${ISSUE}: too large — ${REASON}"

        post_refusal_comment "📏" "Too large for single session" "### Why this can't be implemented as-is

${REASON}

### Next steps
A maintainer should split this issue or add more detail to the spec."

        # Label as underspecified
        curl -sf -X POST \
          -H "Authorization: token ${CODEBERG_TOKEN}" \
          -H "Content-Type: application/json" \
          "${API}/issues/${ISSUE}/labels" \
          -d '{"labels":["underspecified"]}' >/dev/null 2>&1 || true
        curl -sf -X DELETE \
          -H "Authorization: token ${CODEBERG_TOKEN}" \
          "${API}/issues/${ISSUE}/labels/backlog" >/dev/null 2>&1 || true
        ;;
      already_done)
        REASON=$(printf '%s' "$REFUSAL_JSON" | jq -r '.reason // "unspecified"')
        log "already done: ${REASON}"
        notify "refused #${ISSUE}: already done — ${REASON}"

        post_refusal_comment "✅" "Already implemented" "### Existing implementation

${REASON}

Closing as already implemented."

        # Close the issue to prevent retry loops
        curl -sf -X PATCH \
          -H "Authorization: token ${CODEBERG_TOKEN}" \
          -H "Content-Type: application/json" \
          "${API}/issues/${ISSUE}" \
          -d '{"state":"closed"}' >/dev/null 2>&1 || true
        ;;
      *)
        log "unknown refusal status: ${REFUSAL_STATUS}"
        notify "refused #${ISSUE}: unknown reason"

        post_refusal_comment "❓" "Unable to proceed" "The dev-agent could not process this issue.

Raw response:
\`\`\`json
$(printf '%s' "$REFUSAL_JSON" | head -c 2000)
\`\`\`"
        ;;
    esac

    cleanup_worktree
    exit 0
  fi

  # --- Claude implemented (has commits or changes) ---
  # Write ready status for dev-poll.sh
  echo '{"status":"ready"}' > "$PREFLIGHT_RESULT"

  if [ -z "$HAS_CHANGES" ] && [ "$AHEAD" -eq 0 ]; then
    log "ERROR: no changes and no refusal JSON"
    notify "no changes made, aborting"
    cleanup_labels
    cleanup_worktree
    exit 1
  fi

  if [ -n "$HAS_CHANGES" ]; then
    status "committing changes"
    git add -A
    git commit --no-verify -m "fix: ${ISSUE_TITLE} (#${ISSUE})" 2>&1 | tail -2
  else
    log "claude already committed (${AHEAD} commits ahead)"
  fi

  log "HEAD: $(git log --oneline -1)"

  status "pushing branch"
  if ! git push origin "$BRANCH" --force 2>&1 | tail -3; then
    log "ERROR: git push failed"
    notify "failed to push branch ${BRANCH}"
    cleanup_labels
    cleanup_worktree
    exit 1
  fi
  log "pushed ${BRANCH}"

  status "creating PR"
  IMPL_SUMMARY=$(echo "$IMPL_OUTPUT" | tail -40 | head -c 4000)

  # Build PR body safely via file (avoids command-line arg size limits)
  printf 'Fixes #%s\n\n## Changes\n%s' "$ISSUE" "$IMPL_SUMMARY" > /tmp/pr-body-${ISSUE}.txt
  jq -n \
    --arg title "fix: ${ISSUE_TITLE} (#${ISSUE})" \
    --rawfile body "/tmp/pr-body-${ISSUE}.txt" \
    --arg head "$BRANCH" \
    --arg base "${PRIMARY_BRANCH}" \
    '{title: $title, body: $body, head: $head, base: $base}' > /tmp/pr-request-${ISSUE}.json

  PR_RESPONSE=$(curl -s -w "\n%{http_code}" -X POST \
    -H "Authorization: token ${CODEBERG_TOKEN}" \
    -H "Content-Type: application/json" \
    "${API}/pulls" \
    --data-binary @/tmp/pr-request-${ISSUE}.json)

  PR_HTTP_CODE=$(echo "$PR_RESPONSE" | tail -1)
  PR_RESPONSE=$(echo "$PR_RESPONSE" | sed '$d')
  rm -f /tmp/pr-body-${ISSUE}.txt /tmp/pr-request-${ISSUE}.json

  if [ "$PR_HTTP_CODE" != "201" ] && [ "$PR_HTTP_CODE" != "200" ]; then
    log "ERROR: PR creation failed (HTTP ${PR_HTTP_CODE}): $(echo "$PR_RESPONSE" | head -3)"
    notify "failed to create PR (HTTP ${PR_HTTP_CODE})"
    cleanup_labels
    cleanup_worktree
    exit 1
  fi

  PR_NUMBER=$(echo "$PR_RESPONSE" | jq -r '.number')

  if [ "$PR_NUMBER" = "null" ] || [ -z "$PR_NUMBER" ]; then
    log "ERROR: failed to create PR: $(echo "$PR_RESPONSE" | head -5)"
    notify "failed to create PR"
    cleanup_labels
    cleanup_worktree
    exit 1
  fi

  log "created PR #${PR_NUMBER}"
  notify "PR #${PR_NUMBER} created for issue #${ISSUE}: ${ISSUE_TITLE}"
fi

# MERGE HELPER
# =============================================================================
do_merge() {
  local sha="$1"

  for m in $(seq 1 20); do
    local ci
    ci=$(curl -sf -H "Authorization: token ${CODEBERG_TOKEN}" \
      "${API}/commits/${sha}/status" | jq -r '.state // "unknown"')
    [ "$ci" = "success" ] && break
    sleep 30
  done

  # Pre-emptive rebase to avoid merge conflicts
  local mergeable
  mergeable=$(curl -sf -H "Authorization: token ${CODEBERG_TOKEN}" \
    "${API}/pulls/${PR_NUMBER}" | jq -r '.mergeable // true')
  if [ "$mergeable" = "false" ]; then
    log "PR #${PR_NUMBER} has merge conflicts — attempting rebase"
    local work_dir="${WORKTREE:-$REPO_ROOT}"
    if (cd "$work_dir" && git fetch origin "${PRIMARY_BRANCH}" && git rebase "origin/${PRIMARY_BRANCH}" 2>&1); then
      log "rebase succeeded — force pushing"
      (cd "$work_dir" && git push origin "${BRANCH}" --force-with-lease 2>&1) || true
      # Wait for CI on the new commit
      sha=$(cd "$work_dir" && git rev-parse HEAD)
      log "waiting for CI on rebased commit ${sha:0:7}"
      for r in $(seq 1 20); do
        ci=$(curl -sf -H "Authorization: token ${CODEBERG_TOKEN}" \
          "${API}/commits/${sha}/status" | jq -r '.state // "unknown"')
        [ "$ci" = "success" ] && break
        [ "$ci" = "failure" ] || [ "$ci" = "error" ] && { log "CI failed after rebase"; notify "PR #${PR_NUMBER} CI failed after rebase. Needs manual fix."; exit 0; }
        sleep 30
      done
    else
      log "rebase failed — aborting and escalating"
      (cd "$work_dir" && git rebase --abort 2>/dev/null) || true
      notify "PR #${PR_NUMBER} has merge conflicts that need manual resolution."
      exit 0
    fi
  fi

  local http_code
  http_code=$(curl -s -o /dev/null -w "%{http_code}" -X POST \
    -H "Authorization: token ${CODEBERG_TOKEN}" \
    -H "Content-Type: application/json" \
    "${API}/pulls/${PR_NUMBER}/merge" \
    -d '{"Do":"merge","delete_branch_after_merge":true}')

  if [ "$http_code" = "200" ] || [ "$http_code" = "204" ]; then
    log "PR #${PR_NUMBER} merged!"


    curl -sf -X DELETE \
      -H "Authorization: token ${CODEBERG_TOKEN}" \
      "${API}/branches/${BRANCH}" >/dev/null 2>&1 || true

    curl -sf -X PATCH \
      -H "Authorization: token ${CODEBERG_TOKEN}" \
      -H "Content-Type: application/json" \
      "${API}/issues/${ISSUE}" \
      -d '{"state":"closed"}' >/dev/null 2>&1 || true
    cleanup_labels

    notify "✅ PR #${PR_NUMBER} merged! Issue #${ISSUE} done."
    cleanup_worktree
    exit 0
  else
    log "merge failed (HTTP ${http_code}) — attempting rebase and retry"
    local work_dir="${WORKTREE:-$REPO_ROOT}"
    if (cd "$work_dir" && git fetch origin "${PRIMARY_BRANCH}" && git rebase "origin/${PRIMARY_BRANCH}" 2>&1); then
      log "rebase succeeded — force pushing"
      (cd "$work_dir" && git push origin "${BRANCH}" --force-with-lease 2>&1) || true
      sha=$(cd "$work_dir" && git rev-parse HEAD)
      log "waiting for CI on rebased commit ${sha:0:7}"
      for r in $(seq 1 20); do
        ci=$(curl -sf -H "Authorization: token ${CODEBERG_TOKEN}" \
          "${API}/commits/${sha}/status" | jq -r '.state // "unknown"')
        [ "$ci" = "success" ] && break
        [ "$ci" = "failure" ] || [ "$ci" = "error" ] && { log "CI failed after merge-retry rebase"; notify "PR #${PR_NUMBER} CI failed after rebase. Needs manual fix."; exit 0; }
        sleep 30
      done
      # Re-approve (force push dismisses stale approvals)
      curl -sf -X POST -H "Authorization: token ${REVIEW_BOT_TOKEN}" \
        -H "Content-Type: application/json" \
        "${API}/pulls/${PR_NUMBER}/reviews" \
        -d "{\"event\":\"APPROVED\",\"body\":\"Auto-approved after rebase.\"}" >/dev/null 2>&1 || true
      # Retry merge
      http_code=$(curl -s -o /dev/null -w "%{http_code}" -X POST \
        -H "Authorization: token ${CODEBERG_TOKEN}" \
        -H "Content-Type: application/json" \
        "${API}/pulls/${PR_NUMBER}/merge" \
        -d '{"Do":"merge","delete_branch_after_merge":true}')
      if [ "$http_code" = "200" ] || [ "$http_code" = "204" ]; then
        log "PR #${PR_NUMBER} merged after rebase!"
        notify "✅ PR #${PR_NUMBER} merged! Issue #${ISSUE} done."
        curl -sf -X PATCH -H "Authorization: token ${CODEBERG_TOKEN}" \
          -H "Content-Type: application/json" \
          "${API}/issues/${ISSUE}" -d '{"state":"closed"}' >/dev/null 2>&1 || true
        cleanup_labels
        cleanup_worktree
        exit 0
      fi
    else
      (cd "$work_dir" && git rebase --abort 2>/dev/null) || true
    fi
    log "merge still failing after rebase (HTTP ${http_code})"
    notify "PR #${PR_NUMBER} merge failed after rebase (HTTP ${http_code}). Needs human attention."
    exit 0
  fi
}

# =============================================================================
# REVIEW LOOP
# =============================================================================
REVIEW_ROUND=0
CI_RETRY_COUNT=0
CI_FIX_COUNT=0

while [ "$REVIEW_ROUND" -lt "$MAX_REVIEW_ROUNDS" ]; do
  status "waiting for CI + review on PR #${PR_NUMBER} (round $((REVIEW_ROUND + 1)))"

  CI_DONE=false
  for i in $(seq 1 60); do
    sleep 30
    CURRENT_SHA=$(curl -sf -H "Authorization: token ${CODEBERG_TOKEN}" \
      "${API}/pulls/${PR_NUMBER}" | jq -r '.head.sha')
    CI_STATE=$(curl -sf -H "Authorization: token ${CODEBERG_TOKEN}" \
      "${API}/commits/${CURRENT_SHA}/status" | jq -r '.state // "unknown"')

    # No CI configured — treat as success immediately
    if [ "${WOODPECKER_REPO_ID:-2}" = "0" ] && { [ -z "$CI_STATE" ] || [ "$CI_STATE" = "pending" ] || [ "$CI_STATE" = "unknown" ]; }; then
      log "no CI configured — skipping CI wait"
      CI_STATE="success"
      CI_DONE=true
      CI_FIX_COUNT=0
      break
    fi

    if [ "$CI_STATE" = "success" ] || [ "$CI_STATE" = "failure" ] || [ "$CI_STATE" = "error" ]; then
      log "CI: ${CI_STATE}"
      CI_DONE=true
      # Reset CI fix budget on success — each phase gets fresh attempts
      if [ "$CI_STATE" = "success" ]; then
        CI_FIX_COUNT=0
      fi
      break
    fi
  done

  if ! $CI_DONE; then
    log "TIMEOUT: CI didn't complete in 30min"
    notify "CI timeout on PR #${PR_NUMBER}"
    exit 1
  fi

  # --- Handle CI failure ---
  if [ "$CI_STATE" = "failure" ] || [ "$CI_STATE" = "error" ]; then
    PIPELINE_NUM=$(curl -sf -H "Authorization: token ${CODEBERG_TOKEN}" \
      "${API}/commits/${CURRENT_SHA}/status" | jq -r '.statuses[0].target_url // ""' | grep -oP 'pipeline/\K[0-9]+' | head -1 || true)

    FAILED_STEP=""
    FAILED_EXIT=""
    if [ -n "$PIPELINE_NUM" ]; then
      FAILED_INFO=$(curl -sf \
        -H "Authorization: Bearer ${WOODPECKER_TOKEN}" \
        "${WOODPECKER_SERVER}/api/repos/${WOODPECKER_REPO_ID}/pipelines/${PIPELINE_NUM}" | \
        jq -r '.workflows[]?.children[]? | select(.state=="failure") | "\(.name)|\(.exit_code)"' | head -1)
      FAILED_STEP=$(echo "$FAILED_INFO" | cut -d'|' -f1)
      FAILED_EXIT=$(echo "$FAILED_INFO" | cut -d'|' -f2)
    fi

    log "CI failed: step=${FAILED_STEP:-unknown} exit=${FAILED_EXIT:-?}"

    IS_INFRA=false
    case "${FAILED_STEP}" in git*) IS_INFRA=true ;; esac
    case "${FAILED_EXIT}" in 128|137) IS_INFRA=true ;; esac

    if [ "$IS_INFRA" = true ] && [ "${CI_RETRY_COUNT:-0}" -lt 1 ]; then
      CI_RETRY_COUNT=$(( ${CI_RETRY_COUNT:-0} + 1 ))
      log "infra failure — retrigger CI (retry ${CI_RETRY_COUNT})"
      cd "$WORKTREE"
      git commit --allow-empty -m "ci: retrigger after infra failure" --no-verify 2>&1 | tail -1
      git push origin "$BRANCH" --force 2>&1 | tail -3
      continue
    fi

    CI_FIX_COUNT=$(( ${CI_FIX_COUNT:-0} + 1 ))
    if [ "$CI_FIX_COUNT" -gt 2 ]; then
      log "CI failure not recoverable after ${CI_FIX_COUNT} fix attempts"
      # Escalate to supervisor — write marker for supervisor-poll.sh to pick up
      echo "{\"issue\":${ISSUE},\"pr\":${PR_NUMBER},\"reason\":\"ci_exhausted\",\"step\":\"${FAILED_STEP:-unknown}\",\"attempts\":${CI_FIX_COUNT},\"ts\":\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\"}" \
        >> "${FACTORY_ROOT}/supervisor/escalations.jsonl"
      log "escalated to supervisor via escalations.jsonl"
      break
    fi

    CI_ERROR_LOG=""
    if [ -n "$PIPELINE_NUM" ]; then
      CI_ERROR_LOG=$(bash "${FACTORY_ROOT}/lib/ci-debug.sh" failures "$PIPELINE_NUM" 2>/dev/null | tail -80 | head -c 8000 || echo "")
    fi

    log "CI code failure — feeding back to claude (attempt ${CI_FIX_COUNT})"
    status "claude fixing CI failure (attempt ${CI_FIX_COUNT})"

    CI_FIX_PROMPT="CI failed on your PR for issue #${ISSUE}: ${ISSUE_TITLE}
You are in worktree ${WORKTREE} on branch ${BRANCH}.

## CI Debug Tool
\`\`\`bash
bash "${FACTORY_ROOT}/lib/ci-debug.sh" status ${PIPELINE_NUM:-0}
bash "${FACTORY_ROOT}/lib/ci-debug.sh" logs ${PIPELINE_NUM:-0} <step-name>
bash "${FACTORY_ROOT}/lib/ci-debug.sh" failures ${PIPELINE_NUM:-0}
\`\`\`

## Failed step: ${FAILED_STEP:-unknown} (exit code ${FAILED_EXIT:-?}, pipeline #${PIPELINE_NUM:-?})

## Error snippet:
\`\`\`
${CI_ERROR_LOG:-No logs available. Use ci-debug.sh to query the pipeline.}
\`\`\`

## Instructions
1. Run ci-debug.sh failures to get full error output.
2. Read the failing test file(s) — understand what the tests EXPECT.
3. Read AGENTS.md for conventions.
4. Fix the root cause — do NOT weaken tests.
5. Run lint/typecheck if applicable. Commit your fix.
6. Output a SHORT bullet-list summary."

    CI_FIX_OUTPUT=""
    if [ "$CI_FIX_COUNT" -eq 1 ] && [ "$REVIEW_ROUND" -eq 0 ]; then
      CI_FIX_OUTPUT=$(cd "$WORKTREE" && timeout "$CLAUDE_TIMEOUT" \
        claude -p -c --model sonnet --dangerously-skip-permissions "$CI_FIX_PROMPT" 2>&1) || {
        CI_FIX_OUTPUT=$(cd "$WORKTREE" && timeout "$CLAUDE_TIMEOUT" \
          claude -p --model sonnet --dangerously-skip-permissions "$CI_FIX_PROMPT" 2>&1) || true
      }
    else
      CI_FIX_OUTPUT=$(cd "$WORKTREE" && timeout "$CLAUDE_TIMEOUT" \
        claude -p -c --model sonnet --dangerously-skip-permissions "$CI_FIX_PROMPT" 2>&1) || {
        CI_FIX_OUTPUT=$(cd "$WORKTREE" && timeout "$CLAUDE_TIMEOUT" \
          claude -p --model sonnet --dangerously-skip-permissions "$CI_FIX_PROMPT" 2>&1) || true
      }
    fi

    log "claude finished CI fix attempt ${CI_FIX_COUNT}"

    cd "$WORKTREE"
    if [ -n "$(git status --porcelain)" ]; then
      git add -A
      git commit --no-verify -m "fix: CI failure in ${FAILED_STEP:-build} (#${ISSUE})" 2>&1 | tail -2
    fi

    REMOTE_SHA=$(git ls-remote origin "$BRANCH" 2>/dev/null | awk '{print $1}')
    LOCAL_SHA=$(git rev-parse HEAD)
    if [ "$LOCAL_SHA" != "$REMOTE_SHA" ]; then
      git push origin "$BRANCH" --force 2>&1 | tail -3
      log "pushed CI fix (attempt ${CI_FIX_COUNT})"
      notify "PR #${PR_NUMBER}: pushed CI fix attempt ${CI_FIX_COUNT} (${FAILED_STEP:-build})"
    else
      log "no changes after CI fix attempt — bailing"
      notify "❌ PR #${PR_NUMBER}: claude couldn't fix CI failure in ${FAILED_STEP:-unknown}. Needs human attention."
      break
    fi

    continue
  fi

  # --- Wait for review ---
  REVIEW_TEXT=""
  for i in $(seq 1 36); do
    sleep "$REVIEW_POLL_INTERVAL"

    CURRENT_SHA=$(curl -sf -H "Authorization: token ${CODEBERG_TOKEN}" \
      "${API}/pulls/${PR_NUMBER}" | jq -r '.head.sha')

    REVIEW_COMMENT=$(curl -sf -H "Authorization: token ${CODEBERG_TOKEN}" \
      "${API}/issues/${PR_NUMBER}/comments?limit=50" | \
      jq -r --arg sha "$CURRENT_SHA" \
      '[.[] | select(.body | contains("<!-- reviewed: " + $sha))] | last // empty')

    if [ -n "$REVIEW_COMMENT" ] && [ "$REVIEW_COMMENT" != "null" ]; then
      REVIEW_TEXT=$(echo "$REVIEW_COMMENT" | jq -r '.body')

      # Skip error reviews — they have no verdict
      if echo "$REVIEW_TEXT" | grep -q "review-error\|Review — Error"; then
        log "review was an error, waiting for re-review"
        continue
      fi

      VERDICT=$(echo "$REVIEW_TEXT" | grep -oP '\*\*(APPROVE|REQUEST_CHANGES|DISCUSS)\*\*' | head -1 | tr -d '*' || true)
      log "review received: ${VERDICT:-unknown}"

      # Also check formal Codeberg reviews
      if [ -z "$VERDICT" ]; then
        VERDICT=$(curl -sf -H "Authorization: token ${CODEBERG_TOKEN}" \
          "${API}/pulls/${PR_NUMBER}/reviews" | \
          jq -r '[.[] | select(.stale == false)] | last | .state // empty' || true)
        if [ "$VERDICT" = "APPROVED" ]; then
          VERDICT="APPROVE"
        elif [ "$VERDICT" = "REQUEST_CHANGES" ]; then
          VERDICT="REQUEST_CHANGES"
        else
          VERDICT=""
        fi
        if [ -n "$VERDICT" ]; then
          log "verdict from formal review: $VERDICT"
        fi
      fi

      if [ "$VERDICT" = "APPROVE" ]; then
        do_merge "$CURRENT_SHA"
      fi

      [ -n "$VERDICT" ] && break

      # No verdict found in comment or formal review — keep waiting
      log "review comment found but no verdict, continuing to wait"
      continue
    fi

    PR_JSON=$(curl -sf -H "Authorization: token ${CODEBERG_TOKEN}" \
      "${API}/pulls/${PR_NUMBER}")
    PR_STATE=$(echo "$PR_JSON" | jq -r '.state')
    PR_MERGED=$(echo "$PR_JSON" | jq -r '.merged')
    if [ "$PR_STATE" != "open" ]; then
      if [ "$PR_MERGED" = "true" ]; then
        log "PR #${PR_NUMBER} was merged externally"
        notify "✅ PR #${PR_NUMBER} merged! Issue #${ISSUE} done."
        curl -sf -X PATCH -H "Authorization: token ${CODEBERG_TOKEN}" \
          -H "Content-Type: application/json" \
          "${API}/issues/${ISSUE}" -d '{"state":"closed"}' >/dev/null 2>&1 || true
      else
        log "PR #${PR_NUMBER} was closed WITHOUT merge — NOT closing issue"
        notify "⚠️ PR #${PR_NUMBER} closed without merge. Issue #${ISSUE} remains open."
      fi
      cleanup_labels
      cleanup_worktree
      exit 0
    fi

    status "waiting for review on PR #${PR_NUMBER} (${i}/36)"
  done

  if [ -z "$REVIEW_TEXT" ]; then
    log "TIMEOUT: no review after 3h"
    notify "no review received for PR #${PR_NUMBER} after 3h"
    break
  fi

  # --- Address review ---
  REVIEW_ROUND=$((REVIEW_ROUND + 1))
  status "claude addressing review round ${REVIEW_ROUND}"

  REVIEW_PROMPT="The AI reviewer has reviewed your PR and requests changes.
Address each finding below. Run lint and tests when done. Commit your fixes.

When you're done, output a SHORT summary of what you changed, formatted as a bullet list.

## Review Feedback (Round ${REVIEW_ROUND}):
${REVIEW_TEXT}"

  REVIEW_OUTPUT=$(cd "$WORKTREE" && timeout "$CLAUDE_TIMEOUT" \
    claude -p -c --model sonnet --dangerously-skip-permissions "$REVIEW_PROMPT" 2>&1) || {
    EXIT_CODE=$?
    log "claude -c failed (exit ${EXIT_CODE}), retrying without --continue"
    REVIEW_OUTPUT=$(cd "$WORKTREE" && timeout "$CLAUDE_TIMEOUT" \
      claude -p --model sonnet --dangerously-skip-permissions "$REVIEW_PROMPT" 2>&1) || true
  }

  log "claude finished review round ${REVIEW_ROUND}"

  cd "$WORKTREE"
  if [ -n "$(git status --porcelain)" ]; then
    git add -A
    git commit --no-verify -m "fix: address review round ${REVIEW_ROUND} (#${ISSUE})" 2>&1 | tail -2
  fi

  REMOTE_SHA=$(git ls-remote origin "$BRANCH" 2>/dev/null | awk '{print $1}')
  LOCAL_SHA=$(git rev-parse HEAD)
  PUSHED=false
  if [ "$LOCAL_SHA" != "$REMOTE_SHA" ]; then
    git push origin "$BRANCH" --force 2>&1 | tail -3
    log "pushed review fixes (round ${REVIEW_ROUND})"
    PUSHED=true
    notify "PR #${PR_NUMBER}: pushed review round ${REVIEW_ROUND} fixes"
  else
    log "no changes after review round ${REVIEW_ROUND}"
  fi

  if [ "$PUSHED" = true ]; then
    CHANGE_SUMMARY=$(echo "$REVIEW_OUTPUT" | grep '^\s*-' | tail -20)
    [ -z "$CHANGE_SUMMARY" ] && CHANGE_SUMMARY="Changes pushed (see diff for details)."

    DEV_COMMENT="## 🔧 Dev-agent response (round ${REVIEW_ROUND})
<!-- dev-response: $(git rev-parse HEAD) round:${REVIEW_ROUND} -->

### Changes made:
${CHANGE_SUMMARY}

---
*Addressed at \`$(git rev-parse HEAD | head -c 7)\` · automated by dev-agent*"

    curl -sf -o /dev/null -X POST \
      -H "Authorization: token ${CODEBERG_TOKEN}" \
      -H "Content-Type: application/json" \
      "${API}/issues/${PR_NUMBER}/comments" \
      -d "$(jq -n --arg body "$DEV_COMMENT" '{body: $body}')" 2>/dev/null || \
      log "WARNING: failed to post dev-response comment"
  fi
done

if [ "$REVIEW_ROUND" -ge "$MAX_REVIEW_ROUNDS" ]; then
  log "hit max review rounds (${MAX_REVIEW_ROUNDS})"
  notify "PR #${PR_NUMBER}: hit ${MAX_REVIEW_ROUNDS} review rounds, needs human attention"
fi

cleanup_labels
# Keep worktree if PR is still open (recovery can reuse session context)
if [ -n "${PR_NUMBER:-}" ]; then
  PR_STATE=$(curl -sf -H "Authorization: token ${CODEBERG_TOKEN}" \
    "${API}/pulls/${PR_NUMBER}" | jq -r '.state // "unknown"') || true
  if [ "$PR_STATE" = "open" ]; then
    log "keeping worktree (PR #${PR_NUMBER} still open, session preserved for recovery)"
  else
    cleanup_worktree
  fi
else
  cleanup_worktree
fi
log "dev-agent finished for issue #${ISSUE}"
