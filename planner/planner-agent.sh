#!/usr/bin/env bash
# =============================================================================
# planner-agent.sh — Rebuild STATE.md from git history, then gap-analyse
#
# Two-phase planner run:
#   Phase 1: Rebuild STATE.md from git log + closed issues (compact snapshot)
#   Phase 2: Compare STATE.md vs VISION.md, create backlog issues for gaps
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
STATE_FILE="${PROJECT_REPO_ROOT}/STATE.md"
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
    log "WARNING: marker SHA ${LAST_SHA:0:7} not found, using 30-day window"
    local first_sha
    first_sha=$(git log --format=%H --after='30 days ago' --reverse 2>/dev/null | head -1) || true
    GIT_RANGE="${first_sha:-HEAD~30}..HEAD"
  fi
else
  log "No marker file, using 30-day window"
  local first_sha
  first_sha=$(git log --format=%H --after='30 days ago' --reverse 2>/dev/null | head -1) || true
  GIT_RANGE="${first_sha:-HEAD~30}..HEAD"
fi

GIT_LOG=$(git log "$GIT_RANGE" --oneline --no-merges 2>/dev/null || true)
MERGE_LOG=$(git log "$GIT_RANGE" --oneline --merges 2>/dev/null || true)
COMMIT_COUNT=$(echo "$GIT_LOG" | grep -c '.' || true)
log "Range: $GIT_RANGE ($COMMIT_COUNT commits)"

if [ "$COMMIT_COUNT" -eq 0 ] && [ -f "$STATE_FILE" ]; then
  log "No new commits since last run — skipping STATE.md rebuild"
  # Still run gap analysis (vision or issues may have changed)
else
  # ── Phase 1: Rebuild STATE.md ──────────────────────────────────────────
  log "Phase 1: rebuilding STATE.md"

  CURRENT_STATE=""
  [ -f "$STATE_FILE" ] && CURRENT_STATE=$(cat "$STATE_FILE")

  # Fetch recently closed issues for context
  CLOSED_ISSUES=$(codeberg_api GET "/issues?state=closed&type=issues&limit=30&sort=updated&direction=desc" 2>/dev/null | \
    jq -r '.[] | "#\(.number) \(.title)"' 2>/dev/null || true)

  PHASE1_PROMPT="You are maintaining STATE.md — a compact factual snapshot of what ${PROJECT_NAME} currently is and does.

## Current STATE.md
${CURRENT_STATE:-"(empty — create from scratch)"}

## New commits since last snapshot
${GIT_LOG:-"(none)"}

## Merge commits
${MERGE_LOG:-"(none)"}

## Recently closed issues
${CLOSED_ISSUES:-"(none)"}

## Task
Update STATE.md by merging the new commits/issues into the existing snapshot.
- Collapse redundant entries, merge related ones, discard superseded facts
- Output should read as a description of what the project IS, not a history of changes
- Plain bullets, no headers, no dates, no changelog framing
- Preserve issue/PR references (e.g. #42) on each line for traceability
- No more than 30 bullet points — be concise and factual
- If current STATE.md is empty, build the snapshot from scratch using the git log and issues

Output ONLY the bullet list — no preamble, no markdown fences, no explanation."

  PHASE1_OUTPUT=$(timeout "$CLAUDE_TIMEOUT" claude -p "$PHASE1_PROMPT" \
    --model sonnet \
    2>/dev/null) || {
    log "ERROR: claude exited with code $? during phase 1"
    exit 1
  }

  if [ -z "$PHASE1_OUTPUT" ]; then
    log "ERROR: empty output from phase 1"
    exit 1
  fi

  # Atomic write
  TEMP_STATE=$(mktemp "${STATE_FILE}.XXXXXX")
  printf '%s\n' "$PHASE1_OUTPUT" > "$TEMP_STATE"
  mv "$TEMP_STATE" "$STATE_FILE"

  # Commit STATE.md if changed
  if ! git diff --quiet "$STATE_FILE" 2>/dev/null; then
    git add "$STATE_FILE"
    git commit -m "chore: planner rebuild STATE.md" --quiet 2>/dev/null
    git push origin "${PRIMARY_BRANCH}" --quiet 2>/dev/null || true
    log "STATE.md committed and pushed"
  fi

  # Update marker
  echo "$HEAD_SHA" > "$MARKER_FILE"
  log "Phase 1 done — STATE.md rebuilt ($(wc -l < "$STATE_FILE") lines)"
fi

# ── Phase 2: Gap analysis ───────────────────────────────────────────────
log "Phase 2: gap analysis"

CURRENT_STATE=$(cat "$STATE_FILE" 2>/dev/null || true)
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

# Fetch vision-labeled issues specifically
VISION_ISSUES=$(echo "$OPEN_ISSUES" | jq -r '.[] | select(.labels | map(.name) | index("vision")) | "#\(.number) \(.title)\n\(.body)"' 2>/dev/null || true)

PHASE2_PROMPT="You are the planner for ${CODEBERG_REPO}. Your job: find gaps between the project vision and current reality.

## VISION.md (human-maintained goals)
${VISION}

## STATE.md (current project snapshot)
${CURRENT_STATE}

## Vision-labeled issues (goal anchors)
${VISION_ISSUES:-"(none)"}

## All open issues
${OPEN_SUMMARY}

## Task
Identify gaps — things implied by VISION.md that are neither reflected in STATE.md nor covered by an existing open issue.

For each gap, output a JSON object (one per line, no array wrapper):
{\"title\": \"action-oriented title\", \"body\": \"problem statement + why it matters + rough approach\", \"depends\": [list of blocking issue numbers or empty]}

## Rules
- Max 5 new issues — focus on highest-leverage gaps only
- Do NOT create issues for things already in STATE.md (already done)
- Do NOT create issues that overlap with ANY existing open issue, even partially
- Do NOT create issues about vision items, tech-debt, or in-progress work
- Each title should be a plain, action-oriented sentence
- Each body should explain: what's missing, why it matters for the vision, rough approach
- Reference blocking issues by number in depends array

If there are no gaps, output exactly: NO_GAPS

Output ONLY the JSON lines (or NO_GAPS) — no preamble, no markdown fences."

PHASE2_OUTPUT=$(timeout "$CLAUDE_TIMEOUT" claude -p "$PHASE2_PROMPT" \
  --model sonnet \
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
# Find backlog label ID
BACKLOG_LABEL_ID=$(codeberg_api GET "/labels" 2>/dev/null | \
  jq -r '.[] | select(.name == "backlog") | .id' 2>/dev/null || true)

CREATED=0
while IFS= read -r line; do
  [ -z "$line" ] && continue
  # Skip non-JSON lines
  echo "$line" | jq -e . >/dev/null 2>&1 || continue

  TITLE=$(echo "$line" | jq -r '.title')
  BODY=$(echo "$line" | jq -r '.body')
  DEPS=$(echo "$line" | jq -r '.depends // [] | map("#\(.)") | join(", ")')

  # Add dependency section if present
  if [ -n "$DEPS" ] && [ "$DEPS" != "" ]; then
    BODY="${BODY}

## Depends on
${DEPS}"
  fi

  # Create issue
  CREATE_PAYLOAD=$(jq -nc --arg t "$TITLE" --arg b "$BODY" '{title:$t, body:$b}')

  # Add label if we found the backlog label ID
  if [ -n "$BACKLOG_LABEL_ID" ]; then
    CREATE_PAYLOAD=$(echo "$CREATE_PAYLOAD" | jq --argjson lid "$BACKLOG_LABEL_ID" '.labels = [$lid]')
  fi

  RESULT=$(codeberg_api POST "/issues" -d "$CREATE_PAYLOAD" 2>/dev/null || true)
  ISSUE_NUM=$(echo "$RESULT" | jq -r '.number // "?"' 2>/dev/null || echo "?")
  log "Created #${ISSUE_NUM}: ${TITLE}"
  CREATED=$((CREATED + 1))

  [ "$CREATED" -ge 5 ] && break
done <<< "$PHASE2_OUTPUT"

log "Phase 2 done — created $CREATED issues"
log "--- Planner done ---"
