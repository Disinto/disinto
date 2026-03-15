#!/usr/bin/env bash
# =============================================================================
# planner-agent.sh — Keep AGENTS.md current, then gap-analyse against VISION.md
#
# Two-phase planner run:
#   Phase 1: Review recent git history, suggest AGENTS.md updates via PR
#   Phase 2: Compare AGENTS.md vs VISION.md, create backlog issues for gaps
#
# Usage: planner-agent.sh  (no args — uses env vars from .env / env.sh)
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
FACTORY_ROOT="$(dirname "$SCRIPT_DIR")"

# shellcheck source=../lib/env.sh
source "$FACTORY_ROOT/lib/env.sh"

LOG_FILE="$SCRIPT_DIR/planner.log"
CLAUDE_TIMEOUT="${CLAUDE_TIMEOUT:-3600}"
MARKER_FILE="${PROJECT_REPO_ROOT}/.last-planner-sha"
AGENTS_FILE="${PROJECT_REPO_ROOT}/AGENTS.md"
VISION_FILE="${PROJECT_REPO_ROOT}/VISION.md"

log() { echo "[$(date -u +%Y-%m-%dT%H:%M:%S)Z] $*" >> "$LOG_FILE"; }

# ── Preflight ────────────────────────────────────────────────────────────
cd "$PROJECT_REPO_ROOT"
git fetch origin "${PRIMARY_BRANCH}" --quiet 2>/dev/null || true
git checkout "${PRIMARY_BRANCH}" --quiet 2>/dev/null || true
git pull --ff-only origin "${PRIMARY_BRANCH}" --quiet 2>/dev/null || true

HEAD_SHA=$(git rev-parse HEAD)
log "--- Planner start (HEAD: ${HEAD_SHA:0:7}) ---"

# ── Determine git log range ─────────────────────────────────────────────
if [ -f "$MARKER_FILE" ]; then
  LAST_SHA=$(cat "$MARKER_FILE" 2>/dev/null | tr -d '[:space:]')
  if git cat-file -e "$LAST_SHA" 2>/dev/null; then
    GIT_RANGE="${LAST_SHA}..HEAD"
  else
    log "WARNING: marker SHA ${LAST_SHA:0:7} not found, using 7-day window"
    first_sha=$(git log --format=%H --after='7 days ago' --reverse 2>/dev/null | head -1) || true
    GIT_RANGE="${first_sha:-HEAD~20}..HEAD"
  fi
else
  log "No marker file, using 7-day window"
  first_sha=$(git log --format=%H --after='7 days ago' --reverse 2>/dev/null | head -1) || true
  GIT_RANGE="${first_sha:-HEAD~20}..HEAD"
fi

GIT_LOG=$(git log "$GIT_RANGE" --oneline --no-merges 2>/dev/null || true)
COMMIT_COUNT=$(echo "$GIT_LOG" | grep -c '.' || true)
log "Range: $GIT_RANGE ($COMMIT_COUNT commits)"

# ── File tree (for context on what exists) ───────────────────────────────
FILE_TREE=$(find . -maxdepth 3 -type f \( -name '*.sol' -o -name '*.ts' -o -name '*.sh' -o -name '*.md' -o -name '*.json' \) \
  ! -path '*/node_modules/*' ! -path '*/.git/*' ! -path '*/out/*' ! -path '*/cache/*' ! -path '*/dist/*' \
  2>/dev/null | sort | head -200)

# ── Phase 1: AGENTS.md maintenance ──────────────────────────────────────
if [ "$COMMIT_COUNT" -eq 0 ]; then
  log "No new commits since last run — skipping AGENTS.md review"
else
  log "Phase 1: reviewing AGENTS.md against recent changes"

  CURRENT_AGENTS=""
  [ -f "$AGENTS_FILE" ] && CURRENT_AGENTS=$(cat "$AGENTS_FILE")

  if [ -z "$CURRENT_AGENTS" ]; then
    log "No AGENTS.md found — skipping phase 1"
  else
    # Files changed in this range
    FILES_CHANGED=$(git diff --name-only "$GIT_RANGE" 2>/dev/null | sort -u || true)

    PHASE1_PROMPT="You maintain AGENTS.md for the ${PROJECT_NAME} repository. AGENTS.md is the primary onboarding document — it describes the project's architecture, file layout, conventions, and how to work in the codebase.

## Current AGENTS.md
${CURRENT_AGENTS}

## Recent commits (since last review)
${GIT_LOG}

## Files changed
${FILES_CHANGED}

## Repository file tree (top 3 levels)
${FILE_TREE}

## Task
Review AGENTS.md against the recent changes. Output an UPDATED version of AGENTS.md that:
- Reflects any new directories, scripts, tools, or conventions introduced by the recent commits
- Removes or updates references to things that were deleted or renamed
- Keeps the existing structure, voice, and level of detail — this is a human-curated document, preserve its character
- Does NOT add issue/PR references — AGENTS.md is timeless documentation, not a changelog
- Does NOT rewrite sections that haven't changed — preserve the original text where possible

If AGENTS.md is already fully up to date and no changes are needed, output exactly: NO_CHANGES

Otherwise, output the complete updated AGENTS.md content (not a diff, the full file).
Do NOT wrap the output in markdown fences. Start directly with the file content."

    PHASE1_OUTPUT=$(timeout "$CLAUDE_TIMEOUT" claude -p "$PHASE1_PROMPT" \
      --model sonnet \
      --dangerously-skip-permissions \
      2>/dev/null) || {
      log "ERROR: claude exited with code $? during phase 1"
      # Update marker even on failure to avoid re-processing same range
      echo "$HEAD_SHA" > "$MARKER_FILE"
      exit 1
    }

    if echo "$PHASE1_OUTPUT" | grep -q "^NO_CHANGES$"; then
      log "AGENTS.md is up to date — no changes needed"
    elif [ -n "$PHASE1_OUTPUT" ]; then
      # Write updated AGENTS.md and create PR
      TEMP_FILE=$(mktemp "${AGENTS_FILE}.XXXXXX")
      printf '%s\n' "$PHASE1_OUTPUT" > "$TEMP_FILE"
      mv "$TEMP_FILE" "$AGENTS_FILE"

      if ! git diff --quiet "$AGENTS_FILE" 2>/dev/null; then
        branch_name="chore/planner-agents-$(date -u +%Y%m%d)"
        git checkout -B "$branch_name" 2>/dev/null
        git add "$AGENTS_FILE"
        git commit -m "chore: planner update AGENTS.md" --quiet 2>/dev/null
        git push -f origin "$branch_name" --quiet 2>/dev/null || { log "ERROR: failed to push $branch_name"; git checkout "${PRIMARY_BRANCH}" 2>/dev/null; }
        git checkout "${PRIMARY_BRANCH}" 2>/dev/null
        # Restore AGENTS.md to master version after branch push
        git checkout "$AGENTS_FILE" 2>/dev/null || true

        # Create or update PR
        EXISTING_PR=$(codeberg_api GET "/pulls?state=open&limit=50" 2>/dev/null | \
          jq -r --arg branch "$branch_name" '.[] | select(.head.ref == $branch) | .number' | head -1)
        if [ -z "$EXISTING_PR" ]; then
          PR_RESPONSE=$(codeberg_api POST "/pulls" \
            "{\"title\":\"chore: planner update AGENTS.md\",\"head\":\"${branch_name}\",\"base\":\"${PRIMARY_BRANCH}\",\"body\":\"Automated AGENTS.md update based on recent commits (${COMMIT_COUNT} changes since last review).\"}" \
            2>/dev/null)
          PR_NUM=$(echo "$PR_RESPONSE" | jq -r '.number // empty')
          if [ -n "$PR_NUM" ]; then
            log "Created PR #${PR_NUM} for AGENTS.md update"
            matrix_send "planner" "📋 PR #${PR_NUM}: planner update AGENTS.md (${COMMIT_COUNT} commits reviewed)" 2>/dev/null || true
          else
            log "ERROR: failed to create PR"
          fi
        else
          log "Updated existing PR #${EXISTING_PR}"
        fi
      else
        log "AGENTS.md diff was empty after write — no PR needed"
      fi
    fi
  fi

  # Update marker
  echo "$HEAD_SHA" > "$MARKER_FILE"
  log "Phase 1 done"
fi

# ── Phase 2: Gap analysis ───────────────────────────────────────────────
log "Phase 2: gap analysis"

AGENTS_CONTENT=$(cat "$AGENTS_FILE" 2>/dev/null || true)
VISION=""
[ -f "$VISION_FILE" ] && VISION=$(cat "$VISION_FILE")

if [ -z "$VISION" ]; then
  log "No VISION.md found — skipping gap analysis"
  log "--- Planner done ---"
  exit 0
fi

# Fetch open issues (all labels)
OPEN_ISSUES=$(codeberg_api GET "/issues?state=open&type=issues&limit=50&sort=updated&direction=desc" 2>/dev/null || true)
if [ -z "$OPEN_ISSUES" ] || [ "$OPEN_ISSUES" = "null" ]; then
  log "Failed to fetch open issues"
  exit 1
fi

OPEN_SUMMARY=$(echo "$OPEN_ISSUES" | jq -r '.[] | "#\(.number) [\(.labels | map(.name) | join(","))] \(.title)"' 2>/dev/null || true)

PHASE2_PROMPT="You are the planner for ${CODEBERG_REPO}. Your job: find gaps between the project vision and current reality.

## VISION.md (human-maintained goals)
${VISION}

## AGENTS.md (current project state — the ground truth)
${AGENTS_CONTENT}

## All open issues
${OPEN_SUMMARY}

## Task
Identify gaps — things implied by VISION.md that are neither reflected in AGENTS.md nor covered by an existing open issue.

For each gap, output a JSON object (one per line, no array wrapper):
{\"title\": \"action-oriented title\", \"body\": \"problem statement + why it matters + rough approach\", \"depends\": [list of blocking issue numbers or empty]}

## Rules
- Max 5 new issues — focus on highest-leverage gaps only
- Do NOT create issues for things already described in AGENTS.md (already done)
- Do NOT create issues that overlap with ANY existing open issue, even partially
- Each title should be a plain, action-oriented sentence
- Each body should explain: what's missing, why it matters for the vision, rough approach
- Reference blocking issues by number in depends array

If there are no gaps, output exactly: NO_GAPS

Output ONLY the JSON lines (or NO_GAPS) — no preamble, no markdown fences."

PHASE2_OUTPUT=$(timeout "$CLAUDE_TIMEOUT" claude -p "$PHASE2_PROMPT" \
  --model sonnet \
  --dangerously-skip-permissions \
  2>/dev/null) || {
  log "ERROR: claude exited with code $? during phase 2"
  exit 1
}

if echo "$PHASE2_OUTPUT" | grep -q "NO_GAPS"; then
  log "No gaps found — backlog is aligned with vision"
  log "--- Planner done ---"
  exit 0
fi

# ── Create issues from gap analysis ──────────────────────────────────────
BACKLOG_LABEL_ID=$(codeberg_api GET "/labels" 2>/dev/null | \
  jq -r '.[] | select(.name == "backlog") | .id' 2>/dev/null || true)

CREATED=0
while IFS= read -r line; do
  [ -z "$line" ] && continue
  echo "$line" | jq -e . >/dev/null 2>&1 || continue

  TITLE=$(echo "$line" | jq -r '.title')
  BODY=$(echo "$line" | jq -r '.body')
  DEPS=$(echo "$line" | jq -r '.depends // [] | map("#\(.)") | join(", ")')

  if [ -n "$DEPS" ] && [ "$DEPS" != "" ]; then
    BODY="${BODY}

## Depends on
${DEPS}"
  fi

  CREATE_PAYLOAD=$(jq -nc --arg t "$TITLE" --arg b "$BODY" '{title:$t, body:$b}')
  if [ -n "$BACKLOG_LABEL_ID" ]; then
    CREATE_PAYLOAD=$(echo "$CREATE_PAYLOAD" | jq --argjson lid "$BACKLOG_LABEL_ID" '.labels = [$lid]')
  fi

  RESULT=$(codeberg_api POST "/issues" -d "$CREATE_PAYLOAD" 2>/dev/null || true)
  ISSUE_NUM=$(echo "$RESULT" | jq -r '.number // "?"' 2>/dev/null || echo "?")
  log "Created #${ISSUE_NUM}: ${TITLE}"
  matrix_send "planner" "📋 Gap issue #${ISSUE_NUM}: ${TITLE}" 2>/dev/null || true
  CREATED=$((CREATED + 1))

  [ "$CREATED" -ge 5 ] && break
done <<< "$PHASE2_OUTPUT"

log "Phase 2 done — created $CREATED issues"
log "--- Planner done ---"
