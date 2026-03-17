#!/usr/bin/env bash
# =============================================================================
# planner-agent.sh — Update AGENTS.md tree, then gap-analyse against VISION.md
#
# Two-phase planner run:
#   Phase 1: Navigate and update AGENTS.md tree using Claude with tool access
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
VISION_FILE="${PROJECT_REPO_ROOT}/VISION.md"
RESOURCES_FILE="${FACTORY_ROOT}/RESOURCES.md"

log() { echo "[$(date -u +%Y-%m-%dT%H:%M:%S)Z] $*" >> "$LOG_FILE"; }

# ── Preflight ────────────────────────────────────────────────────────────
cd "$PROJECT_REPO_ROOT"
git fetch origin "${PRIMARY_BRANCH}" --quiet 2>/dev/null || true
git checkout "${PRIMARY_BRANCH}" --quiet 2>/dev/null || true
git pull --ff-only origin "${PRIMARY_BRANCH}" --quiet 2>/dev/null || true

HEAD_SHA=$(git rev-parse HEAD)
log "--- Planner start (HEAD: ${HEAD_SHA:0:7}) ---"

# ── Phase 1: Update AGENTS.md tree ──────────────────────────────────────
log "Phase 1: updating AGENTS.md tree"

# Find all AGENTS.md files and their watermarks
AGENTS_FILES=$(find . -name "AGENTS.md" -not -path "./.git/*" | sort)
AGENTS_INFO=""
NEEDS_UPDATE=false

for f in $AGENTS_FILES; do
  WATERMARK=$(grep -oP '(?<=<!-- last-reviewed: )[a-f0-9]+' "$f" 2>/dev/null | head -1 || true)
  LINE_COUNT=$(wc -l < "$f")
  if [ -n "$WATERMARK" ]; then
    if git cat-file -e "$WATERMARK" 2>/dev/null; then
      CHANGES=$(git log --oneline "${WATERMARK}..HEAD" -- "$(dirname "$f")" 2>/dev/null | wc -l || true)
    else
      CHANGES="unknown"
    fi
  else
    WATERMARK="none"
    CHANGES="all"
  fi
  AGENTS_INFO="${AGENTS_INFO}  ${f} (${LINE_COUNT} lines, watermark: ${WATERMARK:0:7}, changes: ${CHANGES})\n"
  [ "$CHANGES" != "0" ] && NEEDS_UPDATE=true
done

if [ "$NEEDS_UPDATE" = false ] && [ -n "$AGENTS_FILES" ]; then
  log "All AGENTS.md files up to date — skipping phase 1"
else
  # Create branch for changes
  BRANCH_NAME="chore/planner-agents-$(date -u +%Y%m%d)"
  git checkout -B "$BRANCH_NAME" 2>/dev/null

  PHASE1_PROMPT="You maintain the AGENTS.md documentation tree for this repository.
Your job: keep every AGENTS.md file accurate, concise, and current.

## How AGENTS.md works
- Each directory with significant logic has its own AGENTS.md
- Root AGENTS.md references sub-directory files
- Each file has a watermark: \`<!-- last-reviewed: <sha> -->\` on line 1
- The watermark tells you which commits are already reflected

## Current AGENTS.md files
$(echo -e "$AGENTS_INFO")
## Current HEAD: ${HEAD_SHA}

## Your workflow
1. Read the root AGENTS.md. Note its watermark SHA.
2. Run \`git log --stat <watermark>..HEAD\` to see what changed since last review.
   If watermark is 'none', use \`git log --stat -20\` for recent history.
3. For structural changes (new files, renames, major refactors), run \`git show <sha>\`
   or read the affected source files to understand the change.
4. Follow references to sub-directory AGENTS.md files. Repeat steps 1-3 for each.
5. Update any AGENTS.md file that is stale or missing information about changes.
6. If a directory has significant logic but no AGENTS.md, create one.

## AGENTS.md conventions (follow these strictly)
- Max ~200 lines per file — if longer, split into sub-directory files
- Describe architecture and conventions (WHAT and WHY), not implementation details
- Link to source files for specifics: \`See [file.sol](path) for X\`
- Progressive disclosure: high-level in root, details in sub-directory files
- After updating a file, set its watermark to: \`<!-- last-reviewed: ${HEAD_SHA} -->\`
- The watermark MUST be the very first line of the file

## Important
- Only update files that are actually stale (have changes since watermark)
- Do NOT rewrite files that are already current
- Do NOT remove existing accurate content — only add, update, or restructure
- Keep the writing factual and architectural — no changelog language"

  PHASE1_OUTPUT=$(timeout "$CLAUDE_TIMEOUT" claude -p "$PHASE1_PROMPT" \
    --model sonnet \
    --dangerously-skip-permissions \
    --max-turns 30 \
    2>/dev/null) || {
    EXIT_CODE=$?
    log "ERROR: claude exited with code $EXIT_CODE during phase 1"
    git checkout "${PRIMARY_BRANCH}" --quiet 2>/dev/null || true
    exit 1
  }

  log "Phase 1 claude finished ($(echo "$PHASE1_OUTPUT" | wc -c) bytes)"

  # Check if any files were modified
  if git diff --quiet && [ -z "$(git ls-files --others --exclude-standard)" ]; then
    log "No AGENTS.md changes — nothing to commit"
    git checkout "${PRIMARY_BRANCH}" --quiet 2>/dev/null || true
  else
    # Commit and push
    find . -name "AGENTS.md" -not -path "./.git/*" -exec git add {} +

    if ! git diff --cached --quiet; then
      git commit -m "chore: planner update AGENTS.md tree" --quiet 2>/dev/null
      git push -f origin "$BRANCH_NAME" --quiet 2>/dev/null || {
        log "ERROR: failed to push $BRANCH_NAME"
        git checkout "${PRIMARY_BRANCH}" --quiet 2>/dev/null || true
        exit 1
      }
      git checkout "${PRIMARY_BRANCH}" --quiet 2>/dev/null || true

      # Create or update PR
      EXISTING_PR=$(codeberg_api GET "/pulls?state=open&limit=50" 2>/dev/null | \
        jq -r --arg branch "$BRANCH_NAME" '.[] | select(.head.ref == $branch) | .number' | head -1)
      if [ -z "$EXISTING_PR" ]; then
        PR_RESPONSE=$(codeberg_api POST "/pulls" \
          "$(jq -nc --arg h "$BRANCH_NAME" --arg b "$PRIMARY_BRANCH" \
            '{title:"chore: planner update AGENTS.md tree",head:$h,base:$b,body:"Automated AGENTS.md tree update from git history analysis."}')" \
          2>/dev/null)
        PR_NUM=$(echo "$PR_RESPONSE" | jq -r '.number // empty')
        if [ -n "$PR_NUM" ]; then
          log "Created PR #${PR_NUM} for AGENTS.md update"
          matrix_send "planner" "📋 PR #${PR_NUM}: planner update AGENTS.md tree" 2>/dev/null || true
        else
          log "ERROR: failed to create PR"
        fi
      else
        log "Updated existing PR #${EXISTING_PR}"
      fi
    else
      git checkout "${PRIMARY_BRANCH}" --quiet 2>/dev/null || true
      log "No AGENTS.md changes after filtering"
    fi
  fi

  log "Phase 1 done"
fi

# ── Phase 2: Gap analysis ───────────────────────────────────────────────
log "Phase 2: gap analysis"

# Build project state from AGENTS.md tree
PROJECT_STATE=""
for f in $(find . -name "AGENTS.md" -not -path "./.git/*" | sort); do
  PROJECT_STATE="${PROJECT_STATE}
### ${f}
$(cat "$f")
"
done

VISION=""
[ -f "$VISION_FILE" ] && VISION=$(cat "$VISION_FILE")

if [ -z "$VISION" ]; then
  log "No VISION.md found — skipping gap analysis"
  log "--- Planner done ---"
  exit 0
fi

RESOURCES=""
[ -f "$RESOURCES_FILE" ] && RESOURCES=$(cat "$RESOURCES_FILE")

# Fetch open issues (all labels)
OPEN_ISSUES=$(codeberg_api GET "/issues?state=open&type=issues&limit=50&sort=updated&direction=desc" 2>/dev/null || true)
if [ -z "$OPEN_ISSUES" ] || [ "$OPEN_ISSUES" = "null" ]; then
  log "Failed to fetch open issues"
  exit 1
fi

OPEN_SUMMARY=$(echo "$OPEN_ISSUES" | jq -r '.[] | "#\(.number) [\(.labels | map(.name) | join(","))] \(.title)"' 2>/dev/null || true)

# Fetch vision-labeled issues specifically
VISION_ISSUES=$(echo "$OPEN_ISSUES" | jq -r '.[] | select(.labels | map(.name) | index("vision")) | "#\(.number) \(.title)\n\(.body)"' 2>/dev/null || true)

# Read supervisor metrics for trend analysis (last 7 days)
METRICS_FILE="${FACTORY_ROOT}/metrics/supervisor-metrics.jsonl"
METRICS_SUMMARY="(no metrics data — supervisor has not yet written metrics)"
if [ -f "$METRICS_FILE" ] && [ -s "$METRICS_FILE" ]; then
  _METRICS_CUTOFF=$(date -u -d '7 days ago' +%Y-%m-%dT%H:%M)
  METRICS_SUMMARY=$(jq -c --arg cutoff "$_METRICS_CUTOFF" 'select(.ts >= $cutoff)' \
    "$METRICS_FILE" 2>/dev/null | \
    jq -rs --arg proj "${PROJECT_NAME:-}" '
      ( [.[] | select(.type=="ci" and .project==$proj) | .duration_min] | if length>0 then add/length|round else null end ) as $ci_avg |
      ( [.[] | select(.type=="ci" and .project==$proj) | select(.status=="success")] | length ) as $ci_ok |
      ( [.[] | select(.type=="ci" and .project==$proj)] | length ) as $ci_n |
      ( [.[] | select(.type=="infra") | .ram_used_pct] | if length>0 then add/length|round else null end ) as $ram_avg |
      ( [.[] | select(.type=="infra") | .disk_used_pct] | if length>0 then add/length|round else null end ) as $disk_avg |
      ( [.[] | select(.type=="dev" and .project==$proj)] | last ) as $dev_last |
      "CI (\($ci_n) pipelines): avg \(if $ci_avg then "\($ci_avg)min" else "n/a" end), success rate \(if $ci_n > 0 then "\($ci_ok * 100 / $ci_n | round)%" else "n/a" end)\n" +
      "Infra: avg RAM \(if $ram_avg then "\($ram_avg)%" else "n/a" end) used, avg disk \(if $disk_avg then "\($disk_avg)%" else "n/a" end) used\n" +
      "Dev (latest): \(if $dev_last then "\($dev_last.issues_in_backlog) in backlog, \($dev_last.issues_blocked) blocked (\(if $dev_last.issues_in_backlog > 0 then $dev_last.issues_blocked * 100 / $dev_last.issues_in_backlog | round else 0 end)% blocked), \($dev_last.pr_open) open PRs" else "n/a" end)
    ' 2>/dev/null) || METRICS_SUMMARY="(metrics parse error)"
  log "Metrics: ${METRICS_SUMMARY:0:120}"
fi

PHASE2_PROMPT="You are the planner for ${CODEBERG_REPO}. Your job: find gaps between the project vision and current reality.

## VISION.md (human-maintained goals)
${VISION}

## Current project state (AGENTS.md tree)
${PROJECT_STATE}

## RESOURCES.md (shared factory infrastructure)
${RESOURCES:-"(not found — copy RESOURCES.example.md to RESOURCES.md and fill in your infrastructure)"}

## Vision-labeled issues (goal anchors)
${VISION_ISSUES:-"(none)"}

## All open issues
${OPEN_SUMMARY}

## Operational metrics (last 7 days from supervisor)
${METRICS_SUMMARY}

## Task
Identify gaps — things implied by VISION.md that are neither reflected in the project state nor covered by an existing open issue.
When a gap involves deploying, hosting, or operating a service, reference the specific resource alias from RESOURCES.md (e.g. \"deploy to <host-alias>\") so issues are actionable.

For each gap, output a JSON object (one per line, no array wrapper):
{\"title\": \"action-oriented title\", \"body\": \"problem statement + why it matters + rough approach\", \"depends\": [list of blocking issue numbers or empty]}

## Rules
- Max 5 new issues — focus on highest-leverage gaps only
- Do NOT create issues for things already documented in AGENTS.md
- Do NOT create issues that overlap with ANY existing open issue, even partially
- Do NOT create issues about vision items, tech-debt, or in-progress work
- Each title should be a plain, action-oriented sentence
- Each body should explain: what's missing, why it matters for the vision, rough approach
- Reference blocking issues by number in depends array
- When metrics indicate a systemic problem conflicting with VISION.md (slow CI, high blocked ratio, disk pressure), create an optimization issue even if not explicitly in VISION.md

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
  matrix_send "planner" "📋 Gap issue #${ISSUE_NUM}: ${TITLE}" 2>/dev/null || true
  CREATED=$((CREATED + 1))

  [ "$CREATED" -ge 5 ] && break
done <<< "$PHASE2_OUTPUT"

log "Phase 2 done — created $CREATED issues"
log "--- Planner done ---"
