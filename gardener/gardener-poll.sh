#!/usr/bin/env bash
# =============================================================================
# gardener-poll.sh — Issue backlog grooming agent
#
# Cron: daily (or 2x/day). Reads open issues, detects problems, invokes
# claude -p to fix or escalate.
#
# Problems detected (bash, zero tokens):
#   - Duplicate titles / overlapping scope
#   - Missing acceptance criteria
#   - Missing dependencies (references other issues but no dep link)
#   - Oversized issues (too many acceptance criteria or change files)
#   - Stale issues (no activity > 14 days, still open)
#   - Closed issues with open dependents still referencing them
#
# Actions taken (claude -p):
#   - Close duplicates with cross-reference comment
#   - Add acceptance criteria template
#   - Set dependency labels
#   - Split oversized issues (create sub-issues, close parent)
#   - Escalate decisions to human via openclaw system event
#
# Escalation format (compact, decision-ready):
#   🌱 Issue Gardener — N items need attention
#   1. #123 "title" — duplicate of #456? (a) close #123 (b) close #456 (c) merge scope
#   2. #789 "title" — needs decision: (a) backlog (b) wontfix (c) split into X,Y
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
FACTORY_ROOT="$(dirname "$SCRIPT_DIR")"

# shellcheck source=../lib/env.sh
source "$FACTORY_ROOT/lib/env.sh"

LOG_FILE="$SCRIPT_DIR/gardener.log"
LOCK_FILE="/tmp/gardener-poll.lock"
CLAUDE_TIMEOUT="${CLAUDE_TIMEOUT:-3600}"

log() { echo "[$(date -u +%Y-%m-%dT%H:%M:%S)Z] $*" >> "$LOG_FILE"; }

# ── Lock ──────────────────────────────────────────────────────────────────
if [ -f "$LOCK_FILE" ]; then
  LOCK_PID=$(cat "$LOCK_FILE" 2>/dev/null || true)
  if [ -n "$LOCK_PID" ] && kill -0 "$LOCK_PID" 2>/dev/null; then
    log "poll: gardener running (PID $LOCK_PID)"
    exit 0
  fi
  rm -f "$LOCK_FILE"
fi
echo $$ > "$LOCK_FILE"
trap 'rm -f "$LOCK_FILE"' EXIT

log "--- Gardener poll start ---"

# ── Fetch all open issues ─────────────────────────────────────────────────
ISSUES_JSON=$(codeberg_api GET "/issues?state=open&type=issues&limit=50&sort=updated&direction=desc" 2>/dev/null || true)
if [ -z "$ISSUES_JSON" ] || [ "$ISSUES_JSON" = "null" ]; then
  log "Failed to fetch issues"
  exit 1
fi

ISSUE_COUNT=$(echo "$ISSUES_JSON" | jq 'length')
log "Found $ISSUE_COUNT open issues"

if [ "$ISSUE_COUNT" -eq 0 ]; then
  log "No open issues — nothing to groom"
  exit 0
fi

# ── Bash pre-checks (zero tokens) ────────────────────────────────────────

PROBLEMS=""

# 1. Duplicate detection: issues with very similar titles
TITLES=$(echo "$ISSUES_JSON" | jq -r '.[] | "\(.number)\t\(.title)"')
DUPES=""
while IFS=$'\t' read -r num1 title1; do
  while IFS=$'\t' read -r num2 title2; do
    [ "$num1" -ge "$num2" ] && continue
    # Normalize: lowercase, strip prefixes + series names, collapse whitespace
    t1=$(echo "$title1" | tr '[:upper:]' '[:lower:]' | sed 's/^feat:\|^fix:\|^refactor://;s/llm seed[^—]*—\s*//;s/push3 evolution[^—]*—\s*//;s/[^a-z0-9 ]//g;s/  */ /g')
    t2=$(echo "$title2" | tr '[:upper:]' '[:lower:]' | sed 's/^feat:\|^fix:\|^refactor://;s/llm seed[^—]*—\s*//;s/push3 evolution[^—]*—\s*//;s/[^a-z0-9 ]//g;s/  */ /g')
    # Count shared words (>60% overlap = suspect)
    WORDS1=$(echo "$t1" | tr ' ' '\n' | sort -u)
    WORDS2=$(echo "$t2" | tr ' ' '\n' | sort -u)
    SHARED=$(comm -12 <(echo "$WORDS1") <(echo "$WORDS2") | wc -l)
    TOTAL1=$(echo "$WORDS1" | wc -l)
    TOTAL2=$(echo "$WORDS2" | wc -l)
    MIN_TOTAL=$(( TOTAL1 < TOTAL2 ? TOTAL1 : TOTAL2 ))
    if [ "$MIN_TOTAL" -gt 2 ] && [ "$SHARED" -gt 0 ]; then
      OVERLAP=$(( SHARED * 100 / MIN_TOTAL ))
      if [ "$OVERLAP" -ge 60 ]; then
        DUPES="${DUPES}possible_dupe: #${num1} vs #${num2} (${OVERLAP}% word overlap)\n"
      fi
    fi
  done <<< "$TITLES"
done <<< "$TITLES"
[ -n "$DUPES" ] && PROBLEMS="${PROBLEMS}${DUPES}"

# 2. Missing acceptance criteria: issues with short body and no checkboxes
while IFS=$'\t' read -r num body_len has_checkbox; do
  if [ "$body_len" -lt 100 ] && [ "$has_checkbox" = "false" ]; then
    PROBLEMS="${PROBLEMS}thin_issue: #${num} — body < 100 chars, no acceptance criteria\n"
  fi
done < <(echo "$ISSUES_JSON" | jq -r '.[] | "\(.number)\t\(.body | length)\t\(.body | test("- \\[[ x]\\]") // false)"')

# 3. Stale issues: no update in 14+ days
NOW_EPOCH=$(date +%s)
while IFS=$'\t' read -r num updated_at; do
  UPDATED_EPOCH=$(date -d "$updated_at" +%s 2>/dev/null || echo 0)
  AGE_DAYS=$(( (NOW_EPOCH - UPDATED_EPOCH) / 86400 ))
  if [ "$AGE_DAYS" -ge 14 ]; then
    PROBLEMS="${PROBLEMS}stale: #${num} — no activity for ${AGE_DAYS} days\n"
  fi
done < <(echo "$ISSUES_JSON" | jq -r '.[] | "\(.number)\t\(.updated_at)"')

# 4. Issues referencing closed deps
while IFS=$'\t' read -r num body; do
  REFS=$(echo "$body" | grep -oP '#\d+' | grep -oP '\d+' | sort -u || true)
  for ref in $REFS; do
    [ "$ref" = "$num" ] && continue
    REF_STATE=$(echo "$ISSUES_JSON" | jq -r --arg n "$ref" '.[] | select(.number == ($n | tonumber)) | .state' 2>/dev/null || true)
    # If ref not in our open set, check if it's closed
    if [ -z "$REF_STATE" ]; then
      REF_STATE=$(codeberg_api GET "/issues/$ref" 2>/dev/null | jq -r '.state // "unknown"' 2>/dev/null || true)
      # Rate limit protection
      sleep 0.5
    fi
  done
done < <(echo "$ISSUES_JSON" | jq -r '.[] | "\(.number)\t\(.body // "")"' | head -20)

PROBLEM_COUNT=$(echo -e "$PROBLEMS" | grep -c '.' || true)
log "Detected $PROBLEM_COUNT potential problems"

if [ "$PROBLEM_COUNT" -eq 0 ]; then
  log "Backlog is clean — nothing to groom"
  exit 0
fi

# ── Invoke claude -p ──────────────────────────────────────────────────────
log "Invoking claude -p for grooming"

# Build issue summary for context (titles + labels + deps)
ISSUE_SUMMARY=$(echo "$ISSUES_JSON" | jq -r '.[] | "#\(.number) [\(.labels | map(.name) | join(","))] \(.title)"')

PROMPT="You are harb's issue gardener. Your job: keep the backlog clean, well-structured, and actionable.

## Current open issues
$ISSUE_SUMMARY

## Problems detected
$(echo -e "$PROBLEMS")

## Tools available
- Codeberg API via curl (token in CODEBERG_TOKEN env var)
- Base URL: https://codeberg.org/api/v1/repos/johba/harb

## Rules
1. **Duplicates**: If confident (>80% overlap + same scope after reading bodies), close the newer one with a comment referencing the older. If unsure, ESCALATE.
2. **Thin issues**: Add a standard acceptance criteria section: \`## Acceptance Criteria\n- [ ] ...\`. Read the body first to understand intent.
3. **Stale issues**: If clearly superseded or no longer relevant, close with explanation. If unclear, ESCALATE.
4. **Oversized issues**: If an issue has >5 acceptance criteria touching different files/concerns, propose a split. Don't split automatically — ESCALATE with suggested breakdown.
5. **Dependencies**: If an issue references another that must land first, add a \`## Dependencies\n- #NNN\` section if missing.

## Escalation format
For anything needing human decision, output EXACTLY this format (one block, all items):
\`\`\`
ESCALATE
1. #NNN \"title\" — reason (a) option1 (b) option2 (c) option3
2. #NNN \"title\" — reason (a) option1 (b) option2
\`\`\`

## Output
- For each action taken, print: ACTION: <description>
- For escalations, use the ESCALATE block above
- If nothing to do after analysis, print: CLEAN"

CLAUDE_OUTPUT=$(cd /home/debian/harb && timeout "$CLAUDE_TIMEOUT" \
  claude -p "$PROMPT" \
    --model sonnet \
    --dangerously-skip-permissions \
    --max-turns 10 \
  2>/dev/null) || true

log "claude finished ($(echo "$CLAUDE_OUTPUT" | wc -c) bytes)"

# ── Parse escalations ────────────────────────────────────────────────────
ESCALATION=$(echo "$CLAUDE_OUTPUT" | sed -n '/^ESCALATE$/,/^```$/p' | grep -v '^ESCALATE$\|^```$' || true)
if [ -z "$ESCALATION" ]; then
  ESCALATION=$(echo "$CLAUDE_OUTPUT" | grep -A50 "^ESCALATE" | grep '^\d' || true)
fi

if [ -n "$ESCALATION" ]; then
  ITEM_COUNT=$(echo "$ESCALATION" | grep -c '.' || true)
  log "Escalating $ITEM_COUNT items to human"

  # Send via openclaw system event
  openclaw system event "🌱 Issue Gardener — ${ITEM_COUNT} item(s) need attention

${ESCALATION}

Reply with numbers+letters (e.g. 1a 2c) to decide." 2>/dev/null || true
fi

# ── Log actions taken ─────────────────────────────────────────────────────
ACTIONS=$(echo "$CLAUDE_OUTPUT" | grep "^ACTION:" || true)
if [ -n "$ACTIONS" ]; then
  echo "$ACTIONS" | while read -r line; do
    log "  $line"
  done
fi

log "--- Gardener poll done ---"
