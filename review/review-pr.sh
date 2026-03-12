#!/usr/bin/env bash
# review-pr.sh — AI-powered PR review using claude CLI
#
# Usage: ./review-pr.sh <pr-number> [--force]
#
# Features:
#   - Full review on first pass
#   - Incremental re-review when previous review exists (verifies findings addressed)
#   - Auto-creates follow-up issues for pre-existing bugs flagged by reviewer
#   - JSON output format with validation + retry
#
# Peek while running:  cat /tmp/harb-review-status
# Watch log:           tail -f ~/scripts/harb-review/review.log

set -euo pipefail

# Load shared environment
source "$(dirname "$0")/../lib/env.sh"


PR_NUMBER="${1:?Usage: review-pr.sh <pr-number> [--force]}"
FORCE="${2:-}"
REPO="${CODEBERG_REPO}"
REPO_ROOT="/home/debian/harb"

# Bot account for posting reviews (separate user required for branch protection approvals)
API_BASE="${CODEBERG_API}"
LOCKFILE="/tmp/harb-review.lock"
STATUSFILE="/tmp/harb-review-status"
LOGDIR="${FACTORY_ROOT}/review"
LOGFILE="$LOGDIR/review.log"
MIN_MEM_MB=1500
MAX_DIFF=25000
MAX_ATTEMPTS=2
TMPDIR=$(mktemp -d)

log() {
  printf '[%s] PR#%s %s\n' "$(date -u '+%Y-%m-%d %H:%M:%S UTC')" "$PR_NUMBER" "$*" >> "$LOGFILE"
}

status() {
  printf '[%s] PR #%s: %s\n' "$(date -u '+%Y-%m-%d %H:%M:%S UTC')" "$PR_NUMBER" "$*" > "$STATUSFILE"
  log "$*"
}

cleanup() {
  rm -rf "$TMPDIR"
  rm -f "$LOCKFILE" "$STATUSFILE"
}
trap cleanup EXIT

# Log rotation (100KB + 1 archive)
if [ -f "$LOGFILE" ] && [ "$(stat -c%s "$LOGFILE" 2>/dev/null || echo 0)" -gt 102400 ]; then
  mv "$LOGFILE" "$LOGFILE.old"
  log "Log rotated"
fi

# Memory guard
AVAIL_MB=$(awk '/MemAvailable/{printf "%d", $2/1024}' /proc/meminfo)
if [ "$AVAIL_MB" -lt "$MIN_MEM_MB" ]; then
  log "SKIP: only ${AVAIL_MB}MB available (need ${MIN_MEM_MB}MB)"
  exit 0
fi

# Concurrency lock
if [ -f "$LOCKFILE" ]; then
  LOCK_PID=$(cat "$LOCKFILE" 2>/dev/null || echo "")
  if [ -n "$LOCK_PID" ] && kill -0 "$LOCK_PID" 2>/dev/null; then
    log "SKIP: another review running (PID ${LOCK_PID})"
    exit 0
  fi
  log "Removing stale lock (PID ${LOCK_PID:-?})"
  rm -f "$LOCKFILE"
fi
echo $$ > "$LOCKFILE"

# Fetch PR metadata
status "fetching metadata"
PR_JSON=$(curl -sf -H "Authorization: token ${CODEBERG_TOKEN}" \
  "${API_BASE}/pulls/${PR_NUMBER}")

PR_TITLE=$(echo "$PR_JSON" | jq -r '.title')
PR_BODY=$(echo "$PR_JSON" | jq -r '.body // ""')
PR_HEAD=$(echo "$PR_JSON" | jq -r '.head.ref')
PR_BASE=$(echo "$PR_JSON" | jq -r '.base.ref')
PR_SHA=$(echo "$PR_JSON" | jq -r '.head.sha')
PR_STATE=$(echo "$PR_JSON" | jq -r '.state')

log "${PR_TITLE} (${PR_HEAD}→${PR_BASE} ${PR_SHA:0:7})"

if [ "$PR_STATE" != "open" ]; then
  log "SKIP: state=${PR_STATE}"
  cd "$REPO_ROOT"
  git worktree remove "/tmp/harb-review-${PR_NUMBER}" --force 2>/dev/null || true
  rm -rf "/tmp/harb-review-${PR_NUMBER}" 2>/dev/null || true
  exit 0
fi

status "checking CI"
CI_STATE=$(curl -sf -H "Authorization: token ${CODEBERG_TOKEN}" \
  "${API_BASE}/commits/${PR_SHA}/status" | jq -r '.state // "unknown"')

if [ "$CI_STATE" != "success" ]; then
  log "SKIP: CI=${CI_STATE}"
  exit 0
fi

# --- Check for existing reviews ---
status "checking existing reviews"
ALL_COMMENTS=$(curl -sf -H "Authorization: token ${CODEBERG_TOKEN}" \
  "${API_BASE}/issues/${PR_NUMBER}/comments?limit=50")

# Check formal Codeberg reviews — skip if a non-stale review exists for this SHA
EXISTING=$(curl -sf -H "Authorization: token ${CODEBERG_TOKEN}" \
  "${API_BASE}/pulls/${PR_NUMBER}/reviews" | \
  jq -r --arg sha "$PR_SHA" \
  '[.[] | select(.commit_id == $sha) | select(.state != "COMMENT")] | length')

if [ "${EXISTING:-0}" -gt "0" ] && [ "$FORCE" != "--force" ]; then
  log "SKIP: formal review exists for ${PR_SHA:0:7}"
  exit 0
fi

# Find previous review for re-review mode
PREV_REVIEW_JSON=$(echo "$ALL_COMMENTS" | \
  jq -r --arg sha "$PR_SHA" \
  '[.[] | select(.body | contains("<!-- reviewed:")) | select(.body | contains($sha) | not)] | last // empty')

PREV_REVIEW_BODY=""
PREV_REVIEW_SHA=""
IS_RE_REVIEW=false

if [ -n "$PREV_REVIEW_JSON" ] && [ "$PREV_REVIEW_JSON" != "null" ]; then
  PREV_REVIEW_BODY=$(echo "$PREV_REVIEW_JSON" | jq -r '.body')
  PREV_REVIEW_SHA=$(echo "$PREV_REVIEW_BODY" | grep -oP '<!-- reviewed: \K[a-f0-9]+' | head -1)
  IS_RE_REVIEW=true
  log "re-review mode: previous review at ${PREV_REVIEW_SHA:0:7}"

  DEV_RESPONSE=$(echo "$ALL_COMMENTS" | \
    jq -r '[.[] | select(.body | contains("<!-- dev-response:"))] | last // empty')
  DEV_RESPONSE_BODY=""
  if [ -n "$DEV_RESPONSE" ] && [ "$DEV_RESPONSE" != "null" ]; then
    DEV_RESPONSE_BODY=$(echo "$DEV_RESPONSE" | jq -r '.body')
  fi
fi

# --- Fetch diffs ---
status "fetching diff"
curl -s -H "Authorization: token ${CODEBERG_TOKEN}" \
  "${API_BASE}/pulls/${PR_NUMBER}.diff" > "${TMPDIR}/full.diff"

FULL_SIZE=$(stat -c%s "${TMPDIR}/full.diff" 2>/dev/null || echo 0)
DIFF=$(head -c "$MAX_DIFF" "${TMPDIR}/full.diff")
DIFF_TRUNCATED=false
if [ "$FULL_SIZE" -gt "$MAX_DIFF" ]; then
  DIFF_TRUNCATED=true
  log "diff truncated: ${FULL_SIZE} → ${MAX_DIFF} bytes"
fi

DIFF_STAT=$(echo "$DIFF" | grep -E '^\+\+\+ b/|^--- a/' | sed 's|^+++ b/||;s|^--- a/||' | grep -v '/dev/null' | sort -u)
ALL_FILES=$(grep -E '^\+\+\+ b/|^--- a/' "${TMPDIR}/full.diff" | sed 's|^+++ b/||;s|^--- a/||' | grep -v '/dev/null' | sort -u)
TRUNCATED_FILES=""
if [ "$DIFF_TRUNCATED" = true ]; then
  TRUNCATED_FILES=$(comm -23 <(echo "$ALL_FILES") <(echo "$DIFF_STAT") | tr '\n' ', ' | sed 's/,$//')
fi

# Fetch incremental diff for re-reviews
INCREMENTAL_DIFF=""
if [ "$IS_RE_REVIEW" = true ] && [ -n "$PREV_REVIEW_SHA" ]; then
  status "fetching incremental diff (${PREV_REVIEW_SHA:0:7}..${PR_SHA:0:7})"
  cd "$REPO_ROOT"
  git fetch origin "$PR_HEAD" 2>/dev/null || true
  INCREMENTAL_DIFF=$(git diff "${PREV_REVIEW_SHA}..${PR_SHA}" 2>/dev/null | head -c "$MAX_DIFF") || true
  if [ -z "$INCREMENTAL_DIFF" ]; then
    log "incremental diff empty (SHA not available locally?)"
    IS_RE_REVIEW=false
  fi
fi

# --- Checkout PR branch ---
status "checking out PR branch"
cd "$REPO_ROOT"
git fetch origin "$PR_HEAD" 2>/dev/null || true
REVIEW_WORKTREE="/tmp/harb-review-${PR_NUMBER}"

if [ -d "$REVIEW_WORKTREE" ]; then
  cd "$REVIEW_WORKTREE"
  git checkout --detach "${PR_SHA}" 2>/dev/null || {
    cd "$REPO_ROOT"
    git worktree remove "$REVIEW_WORKTREE" --force 2>/dev/null || true
    rm -rf "$REVIEW_WORKTREE"
    git worktree add "$REVIEW_WORKTREE" "${PR_SHA}" --detach 2>/dev/null
  }
else
  git worktree add "$REVIEW_WORKTREE" "${PR_SHA}" --detach 2>/dev/null
fi

# --- Classify scope ---
HAS_CONTRACTS=false
HAS_FRONTEND=false
HAS_DOCS=false
HAS_INFRA=false

for f in $ALL_FILES; do
  case "$f" in
    onchain/*) HAS_CONTRACTS=true ;;
    landing/*|web-app/*) HAS_FRONTEND=true ;;
    docs/*|*.md) HAS_DOCS=true ;;
    containers/*|.woodpecker/*|scripts/*|docker*|*.sh|*.yml) HAS_INFRA=true ;;
  esac
done

NEEDS_CLAIM_CHECK=false
NEEDS_UX_CHECK=false
if [ "$HAS_FRONTEND" = true ] || [ "$HAS_DOCS" = true ]; then NEEDS_CLAIM_CHECK=true; fi
if [ "$HAS_FRONTEND" = true ]; then NEEDS_UX_CHECK=true; fi

SCOPE_DESC=""
if [ "$HAS_CONTRACTS" = true ] && [ "$HAS_FRONTEND" = false ] && [ "$HAS_DOCS" = false ]; then
  SCOPE_DESC="contracts-only"
elif [ "$HAS_FRONTEND" = true ] && [ "$HAS_CONTRACTS" = false ]; then
  SCOPE_DESC="frontend-only"
elif [ "$HAS_DOCS" = true ] && [ "$HAS_CONTRACTS" = false ] && [ "$HAS_FRONTEND" = false ]; then
  SCOPE_DESC="docs-only"
elif [ "$HAS_INFRA" = true ] && [ "$HAS_CONTRACTS" = false ] && [ "$HAS_FRONTEND" = false ] && [ "$HAS_DOCS" = false ]; then
  SCOPE_DESC="infra-only"
else
  SCOPE_DESC="mixed"
fi
log "scope: ${SCOPE_DESC} (contracts=${HAS_CONTRACTS} frontend=${HAS_FRONTEND} docs=${HAS_DOCS} infra=${HAS_INFRA})"

# --- Build JSON output schema instructions ---
# These are appended to EVERY prompt (fresh + re-review) so they're always at the end,
# closest to where claude generates output — resists context window forgetting.

JSON_SCHEMA_FRESH='You MUST respond with a single JSON object. No markdown, no commentary outside the JSON.

{
  "sections": [
    {
      "title": "string — section heading (e.g. Code Review, Architecture Check)",
      "findings": [
        {
          "severity": "bug | warning | nit | info",
          "location": "file:line or file — where the issue is",
          "description": "what is wrong and why"
        }
      ]
    }
  ],
  "followups": [
    {
      "title": "string — one-line issue title",
      "details": "string — what is wrong and where (pre-existing, not introduced by this PR)"
    }
  ],
  "verdict": "APPROVE | REQUEST_CHANGES | DISCUSS",
  "verdict_reason": "string — one line explanation"
}'

JSON_SCHEMA_REREVIEW='You MUST respond with a single JSON object. No markdown, no commentary outside the JSON.

{
  "previous_findings": [
    {
      "summary": "string — what was flagged",
      "status": "fixed | not_fixed | partial",
      "explanation": "string — how it was addressed or why not"
    }
  ],
  "new_issues": [
    {
      "severity": "bug | warning | nit | info",
      "location": "file:line or file",
      "description": "string"
    }
  ],
  "followups": [
    {
      "title": "string — one-line issue title",
      "details": "string — pre-existing tech debt"
    }
  ],
  "verdict": "APPROVE | REQUEST_CHANGES | DISCUSS",
  "verdict_reason": "string — one line"
}'

# --- Build prompt ---
status "building prompt"
cat > "${TMPDIR}/prompt.md" << PROMPT_EOF
# PR #${PR_NUMBER}: ${PR_TITLE}

## PR Description
${PR_BODY}

## Changed Files
${ALL_FILES}

## Full Repo Access
You are running in a checkout of the PR branch. You can read ANY file in the repo to verify
claims, check existing code, or understand context. Use this to avoid false positives —
if you're unsure whether something "already exists", read the file before flagging it.

Key docs available: docs/PRODUCT-TRUTH.md, docs/ARCHITECTURE.md, docs/UX-DECISIONS.md, docs/ENVIRONMENT.md
PROMPT_EOF

if [ "$DIFF_TRUNCATED" = true ]; then
  cat >> "${TMPDIR}/prompt.md" << TRUNC_EOF

## Diff Truncated
The full diff is ${FULL_SIZE} bytes but was truncated to ${MAX_DIFF} bytes.
Files NOT included in the diff below: ${TRUNCATED_FILES:-unknown}
Do NOT flag missing files — they exist but were cut for size. Only review what you can see.
TRUNC_EOF
fi

if [ "$IS_RE_REVIEW" = true ]; then
  cat >> "${TMPDIR}/prompt.md" << REREVIEW_EOF

## This is a RE-REVIEW

A previous review at ${PREV_REVIEW_SHA:0:7} requested changes. The developer has pushed fixes.

### Previous Review
${PREV_REVIEW_BODY}
REREVIEW_EOF

  if [ -n "$DEV_RESPONSE_BODY" ]; then
    cat >> "${TMPDIR}/prompt.md" << DEVRESP_EOF

### Developer's Response
${DEV_RESPONSE_BODY}
DEVRESP_EOF
  fi

  cat >> "${TMPDIR}/prompt.md" << INCR_EOF

### Incremental Diff (${PREV_REVIEW_SHA:0:7}..${PR_SHA:0:7})
\`\`\`diff
${INCREMENTAL_DIFF}
\`\`\`

### Full Diff (master..${PR_SHA:0:7})
\`\`\`diff
${DIFF}
\`\`\`

## Your Task
Review the incremental diff. For each finding in the previous review, check if it was addressed.
Then check for new issues introduced by the fix.

## OUTPUT FORMAT — MANDATORY
${JSON_SCHEMA_REREVIEW}
INCR_EOF

else
  # Build task description based on scope
  TASK_DESC="Review this ${SCOPE_DESC} PR."
  if [ "$NEEDS_CLAIM_CHECK" = true ]; then
    TASK_DESC="${TASK_DESC} Check all user-facing claims against docs/PRODUCT-TRUTH.md."
  fi
  TASK_DESC="${TASK_DESC} Check for bugs, logic errors, missing edge cases, broken imports."
  TASK_DESC="${TASK_DESC} Verify architecture patterns match docs/ARCHITECTURE.md."
  if [ "$NEEDS_UX_CHECK" = true ]; then
    TASK_DESC="${TASK_DESC} Check UX/messaging against docs/UX-DECISIONS.md."
  fi

  cat >> "${TMPDIR}/prompt.md" << DIFF_EOF

## Diff
\`\`\`diff
${DIFF}
\`\`\`

## Your Task
${TASK_DESC}

## OUTPUT FORMAT — MANDATORY
${JSON_SCHEMA_FRESH}
DIFF_EOF
fi

PROMPT_SIZE=$(stat -c%s "${TMPDIR}/prompt.md")
log "Prompt: ${PROMPT_SIZE} bytes (re-review: ${IS_RE_REVIEW})"

# --- Run claude with retry on invalid JSON ---
CONTINUE_FLAG=""
if [ "$IS_RE_REVIEW" = true ]; then
  CONTINUE_FLAG="-c"
fi

REVIEW_JSON=""
for attempt in $(seq 1 "$MAX_ATTEMPTS"); do
  status "running claude attempt ${attempt}/${MAX_ATTEMPTS}"
  SECONDS=0

  RAW_OUTPUT=$(cd "$REVIEW_WORKTREE" && claude -p $CONTINUE_FLAG \
    --model sonnet \
    --dangerously-skip-permissions \
    --output-format text \
    < "${TMPDIR}/prompt.md" 2>"${TMPDIR}/claude-stderr.log") || true

  ELAPSED=$SECONDS

  if [ -z "$RAW_OUTPUT" ]; then
    log "attempt ${attempt}: empty output after ${ELAPSED}s"
    continue
  fi

  RAW_SIZE=$(printf '%s' "$RAW_OUTPUT" | wc -c)
  log "attempt ${attempt}: ${RAW_SIZE} bytes in ${ELAPSED}s"

  # Extract JSON — claude might wrap it in ```json ... ``` or add preamble
  # Try raw first, then extract from code fence
  if printf '%s' "$RAW_OUTPUT" | jq -e '.verdict' > /dev/null 2>&1; then
    REVIEW_JSON="$RAW_OUTPUT"
  else
    # Try extracting from code fence
    EXTRACTED=$(printf '%s' "$RAW_OUTPUT" | sed -n '/^```json/,/^```$/p' | sed '1d;$d')
    if [ -n "$EXTRACTED" ] && printf '%s' "$EXTRACTED" | jq -e '.verdict' > /dev/null 2>&1; then
      REVIEW_JSON="$EXTRACTED"
    else
      # Try extracting first { ... } block
      EXTRACTED=$(printf '%s' "$RAW_OUTPUT" | sed -n '/^{/,/^}/p')
      if [ -n "$EXTRACTED" ] && printf '%s' "$EXTRACTED" | jq -e '.verdict' > /dev/null 2>&1; then
        REVIEW_JSON="$EXTRACTED"
      fi
    fi
  fi

  if [ -n "$REVIEW_JSON" ]; then
    # Validate required fields
    VERDICT=$(printf '%s' "$REVIEW_JSON" | jq -r '.verdict // empty')
    if [ -n "$VERDICT" ]; then
      log "attempt ${attempt}: valid JSON, verdict=${VERDICT}"
      break
    else
      log "attempt ${attempt}: JSON missing verdict"
      REVIEW_JSON=""
    fi
  else
    log "attempt ${attempt}: no valid JSON found in output"
    # Save raw output for debugging
    printf '%s' "$RAW_OUTPUT" > "${TMPDIR}/raw-attempt-${attempt}.txt"
  fi

  # For retry, add explicit correction to prompt
  if [ "$attempt" -lt "$MAX_ATTEMPTS" ]; then
    cat >> "${TMPDIR}/prompt.md" << RETRY_EOF

## RETRY — Your previous response was not valid JSON
You MUST output a single JSON object with a "verdict" field. No markdown wrapping. No prose.
Start your response with { and end with }.
RETRY_EOF
    log "appended retry instruction to prompt"
  fi
done

# --- Handle failure: post error comment ---
if [ -z "$REVIEW_JSON" ]; then
  log "ERROR: no valid JSON after ${MAX_ATTEMPTS} attempts"

  ERROR_BODY="## 🤖 AI Review — Error
<!-- review-error: ${PR_SHA} -->

⚠️ Review failed: could not produce structured output after ${MAX_ATTEMPTS} attempts.

A maintainer should review this PR manually, or re-trigger with \`--force\`.

---
*Failed at \`${PR_SHA:0:7}\`*"

  printf '%s' "$ERROR_BODY" > "${TMPDIR}/comment-body.txt"
  jq -Rs '{body: .}' < "${TMPDIR}/comment-body.txt" > "${TMPDIR}/comment.json"

  curl -s -o /dev/null -w "%{http_code}" \
    -X POST \
    -H "Authorization: token ${CODEBERG_TOKEN}" \
    -H "Content-Type: application/json" \
    "${API_BASE}/issues/${PR_NUMBER}/comments" \
    --data-binary @"${TMPDIR}/comment.json" > /dev/null

  # Save raw outputs for debugging
  for f in "${TMPDIR}"/raw-attempt-*.txt; do
    [ -f "$f" ] && cp "$f" "${LOGDIR}/review-pr${PR_NUMBER}-$(basename "$f")"
  done

  openclaw system event \
    --text "⚠️ PR #${PR_NUMBER} review failed — no valid JSON output" \
    --mode now 2>/dev/null || true

  exit 1
fi

# --- Render JSON → Markdown ---
VERDICT=$(printf '%s' "$REVIEW_JSON" | jq -r '.verdict')
VERDICT_REASON=$(printf '%s' "$REVIEW_JSON" | jq -r '.verdict_reason // ""')

render_markdown() {
  local json="$1"
  local md=""

  if [ "$IS_RE_REVIEW" = true ]; then
    # Re-review format
    local prev_count
    prev_count=$(printf '%s' "$json" | jq '.previous_findings | length')

    if [ "$prev_count" -gt 0 ]; then
      md+="### Previous Findings"$'\n'
      while IFS= read -r finding; do
        local summary status explanation
        summary=$(printf '%s' "$finding" | jq -r '.summary')
        status=$(printf '%s' "$finding" | jq -r '.status')
        explanation=$(printf '%s' "$finding" | jq -r '.explanation')

        local icon="❓"
        case "$status" in
          fixed) icon="✅" ;;
          not_fixed) icon="❌" ;;
          partial) icon="⚠️" ;;
        esac

        md+="- ${summary} → ${icon} ${explanation}"$'\n'
      done < <(printf '%s' "$json" | jq -c '.previous_findings[]')
      md+=$'\n'
    fi

    local new_count
    new_count=$(printf '%s' "$json" | jq '.new_issues | length')
    if [ "$new_count" -gt 0 ]; then
      md+="### New Issues"$'\n'
      while IFS= read -r issue; do
        local sev loc desc
        sev=$(printf '%s' "$issue" | jq -r '.severity')
        loc=$(printf '%s' "$issue" | jq -r '.location')
        desc=$(printf '%s' "$issue" | jq -r '.description')

        local icon="ℹ️"
        case "$sev" in
          bug) icon="🐛" ;;
          warning) icon="⚠️" ;;
          nit) icon="💅" ;;
        esac

        md+="- ${icon} **${sev}** \`${loc}\`: ${desc}"$'\n'
      done < <(printf '%s' "$json" | jq -c '.new_issues[]')
      md+=$'\n'
    fi

  else
    # Fresh review format
    while IFS= read -r section; do
      local title
      title=$(printf '%s' "$section" | jq -r '.title')
      local finding_count
      finding_count=$(printf '%s' "$section" | jq '.findings | length')

      md+="### ${title}"$'\n'

      if [ "$finding_count" -eq 0 ]; then
        md+="No issues found."$'\n'$'\n'
      else
        while IFS= read -r finding; do
          local sev loc desc
          sev=$(printf '%s' "$finding" | jq -r '.severity')
          loc=$(printf '%s' "$finding" | jq -r '.location')
          desc=$(printf '%s' "$finding" | jq -r '.description')

          local icon="ℹ️"
          case "$sev" in
            bug) icon="🐛" ;;
            warning) icon="⚠️" ;;
            nit) icon="💅" ;;
          esac

          md+="- ${icon} **${sev}** \`${loc}\`: ${desc}"$'\n'
        done < <(printf '%s' "$section" | jq -c '.findings[]')
        md+=$'\n'
      fi
    done < <(printf '%s' "$json" | jq -c '.sections[]')
  fi

  # Follow-ups
  local followup_count
  followup_count=$(printf '%s' "$json" | jq '.followups | length')
  if [ "$followup_count" -gt 0 ]; then
    md+="### Follow-up Issues"$'\n'
    while IFS= read -r fu; do
      local fu_title fu_details
      fu_title=$(printf '%s' "$fu" | jq -r '.title')
      fu_details=$(printf '%s' "$fu" | jq -r '.details')
      md+="- **${fu_title}**: ${fu_details}"$'\n'
    done < <(printf '%s' "$json" | jq -c '.followups[]')
    md+=$'\n'
  fi

  # Verdict
  md+="### Verdict"$'\n'
  md+="**${VERDICT}** — ${VERDICT_REASON}"$'\n'

  printf '%s' "$md"
}

REVIEW_MD=$(render_markdown "$REVIEW_JSON")

# --- Post review to Codeberg ---
status "posting to Codeberg"

REVIEW_TYPE="Review"
if [ "$IS_RE_REVIEW" = true ]; then
  ROUND=$(($(echo "$ALL_COMMENTS" | jq '[.[] | select(.body | contains("<!-- reviewed:"))] | length') + 1))
  REVIEW_TYPE="Re-review (round ${ROUND})"
fi

COMMENT_BODY="## 🤖 AI ${REVIEW_TYPE}
<!-- reviewed: ${PR_SHA} -->

${REVIEW_MD}

---
*Reviewed at \`${PR_SHA:0:7}\`$(if [ "$IS_RE_REVIEW" = true ]; then echo " · Previous: \`${PREV_REVIEW_SHA:0:7}\`"; fi) · [PRODUCT-TRUTH.md](../docs/PRODUCT-TRUTH.md) · [ARCHITECTURE.md](../docs/ARCHITECTURE.md)*"

printf '%s' "$COMMENT_BODY" > "${TMPDIR}/comment-body.txt"
jq -Rs '{body: .}' < "${TMPDIR}/comment-body.txt" > "${TMPDIR}/comment.json"

POST_CODE=$(curl -s -o "${TMPDIR}/post-response.txt" -w "%{http_code}" \
  -X POST \
  -H "Authorization: token ${REVIEW_BOT_TOKEN}" \
  -H "Content-Type: application/json" \
  "${API_BASE}/issues/${PR_NUMBER}/comments" \
  --data-binary @"${TMPDIR}/comment.json")

if [ "${POST_CODE}" = "201" ]; then
  log "POSTED comment to Codeberg (as review_bot)"

  # Submit formal Codeberg review (required for branch protection approval)
  REVIEW_EVENT="COMMENT"
  case "$VERDICT" in
    APPROVE) REVIEW_EVENT="APPROVED" ;;
    REQUEST_CHANGES|DISCUSS) REVIEW_EVENT="REQUEST_CHANGES" ;;
  esac

  FORMAL_BODY="AI ${REVIEW_TYPE}: **${VERDICT}** — ${VERDICT_REASON}"
  jq -n --arg body "$FORMAL_BODY" --arg event "$REVIEW_EVENT" --arg sha "$PR_SHA" \
    '{body: $body, event: $event, commit_id: $sha}' > "${TMPDIR}/formal-review.json"

  REVIEW_CODE=$(curl -s -o "${TMPDIR}/review-response.txt" -w "%{http_code}" \
    -X POST \
    -H "Authorization: token ${REVIEW_BOT_TOKEN}" \
    -H "Content-Type: application/json" \
    "${API_BASE}/pulls/${PR_NUMBER}/reviews" \
    --data-binary @"${TMPDIR}/formal-review.json")

  if [ "${REVIEW_CODE}" = "200" ]; then
    log "SUBMITTED formal ${REVIEW_EVENT} review"
  else
    log "WARNING: formal review failed (HTTP ${REVIEW_CODE}): $(head -c 200 "${TMPDIR}/review-response.txt" 2>/dev/null)"
    # Non-fatal — the comment is already posted
  fi
else
  log "ERROR: Codeberg HTTP ${POST_CODE}: $(head -c 200 "${TMPDIR}/post-response.txt" 2>/dev/null)"
  echo "$REVIEW_MD" > "${LOGDIR}/review-pr${PR_NUMBER}-${PR_SHA:0:7}.md"
  log "Review saved to ${LOGDIR}/review-pr${PR_NUMBER}-${PR_SHA:0:7}.md"
  exit 1
fi

# --- Auto-create follow-up issues from JSON ---
FOLLOWUP_COUNT=$(printf '%s' "$REVIEW_JSON" | jq '.followups | length')
if [ "$FOLLOWUP_COUNT" -gt 0 ]; then
  log "processing ${FOLLOWUP_COUNT} follow-up issues"

  TECH_DEBT_ID=$(curl -sf -H "Authorization: token ${CODEBERG_TOKEN}" \
    "${API_BASE}/labels" | jq -r '.[] | select(.name=="tech-debt") | .id')

  if [ -z "$TECH_DEBT_ID" ]; then
    TECH_DEBT_ID=$(curl -sf -X POST \
      -H "Authorization: token ${CODEBERG_TOKEN}" \
      -H "Content-Type: application/json" \
      "${API_BASE}/labels" \
      -d '{"name":"tech-debt","color":"#6B7280","description":"Pre-existing tech debt flagged by AI review"}' | jq -r '.id')
  fi

  CREATED_COUNT=0
  while IFS= read -r fu; do
    FU_TITLE=$(printf '%s' "$fu" | jq -r '.title')
    FU_DETAILS=$(printf '%s' "$fu" | jq -r '.details')

    # Check for duplicate
    EXISTING=$(curl -sf -H "Authorization: token ${CODEBERG_TOKEN}" \
      "${API_BASE}/issues?state=open&labels=tech-debt&limit=50" | \
      jq -r --arg t "$FU_TITLE" '[.[] | select(.title == $t)] | length')

    if [ "${EXISTING:-0}" -gt 0 ]; then
      log "skip duplicate follow-up: ${FU_TITLE}"
      continue
    fi

    ISSUE_BODY="Flagged by AI reviewer in PR #${PR_NUMBER}.

## Problem

${FU_DETAILS}

---
*Auto-created from AI review of PR #${PR_NUMBER}*"

    printf '%s' "$ISSUE_BODY" > "${TMPDIR}/followup-body.txt"
    jq -n \
      --arg title "$FU_TITLE" \
      --rawfile body "${TMPDIR}/followup-body.txt" \
      --argjson labels "[$TECH_DEBT_ID]" \
      '{title: $title, body: $body, labels: $labels}' > "${TMPDIR}/followup-issue.json"

    CREATED=$(curl -sf -X POST \
      -H "Authorization: token ${CODEBERG_TOKEN}" \
      -H "Content-Type: application/json" \
      "${API_BASE}/issues" \
      --data-binary @"${TMPDIR}/followup-issue.json" | jq -r '.number // empty')

    if [ -n "$CREATED" ]; then
      log "created follow-up issue #${CREATED}: ${FU_TITLE}"
      CREATED_COUNT=$((CREATED_COUNT + 1))
    fi
  done < <(printf '%s' "$REVIEW_JSON" | jq -c '.followups[]')

  log "created ${CREATED_COUNT} follow-up issues total"
fi

# --- Notify OpenClaw ---
openclaw system event \
  --text "🤖 PR #${PR_NUMBER} ${REVIEW_TYPE}: ${VERDICT} — ${PR_TITLE}" \
  --mode now 2>/dev/null || true

log "DONE: ${VERDICT} (${ELAPSED}s, re-review: ${IS_RE_REVIEW})"
