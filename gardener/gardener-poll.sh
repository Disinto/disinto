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

# Load shared environment (with optional project TOML override)
# Usage: gardener-poll.sh [projects/harb.toml]
export PROJECT_TOML="${1:-}"
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

# ── Check for escalation replies from Matrix ──────────────────────────────
ESCALATION_REPLY=""
if [ -s /tmp/gardener-escalation-reply ]; then
  ESCALATION_REPLY=$(cat /tmp/gardener-escalation-reply)
  rm -f /tmp/gardener-escalation-reply
  log "Got escalation reply: $(echo "$ESCALATION_REPLY" | head -1)"
fi

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

# 5. Blocker detection: find issues blocking backlog items that aren't themselves backlog
# This is the HIGHEST PRIORITY — a non-backlog blocker starves the entire factory
BACKLOG_ISSUES=$(echo "$ISSUES_JSON" | jq -r '.[] | select(.labels | map(.name) | index("backlog")) | .number')
BLOCKER_NUMS=""
for BNUM in $BACKLOG_ISSUES; do
  BBODY=$(echo "$ISSUES_JSON" | jq -r --arg n "$BNUM" '.[] | select(.number == ($n | tonumber)) | .body // ""')
  # Extract deps from ## Dependencies / ## Depends on / ## Blocked by
  IN_SECTION=false
  while IFS= read -r line; do
    if echo "$line" | grep -qiP '^##?\s*(Dependencies|Depends on|Blocked by)'; then IN_SECTION=true; continue; fi
    if echo "$line" | grep -qP '^##?\s' && [ "$IN_SECTION" = true ]; then IN_SECTION=false; fi
    if [ "$IN_SECTION" = true ]; then
      for dep in $(echo "$line" | grep -oP '#\d+' | grep -oP '\d+'); do
        [ "$dep" = "$BNUM" ] && continue
        # Check if dep is open but NOT backlog-labeled
        DEP_STATE=$(echo "$ISSUES_JSON" | jq -r --arg n "$dep" '.[] | select(.number == ($n | tonumber)) | .state' 2>/dev/null || true)
        DEP_LABELS=$(echo "$ISSUES_JSON" | jq -r --arg n "$dep" '.[] | select(.number == ($n | tonumber)) | [.labels[].name] | join(",")' 2>/dev/null || true)
        if [ "$DEP_STATE" = "open" ] && ! echo ",$DEP_LABELS," | grep -q ',backlog,'; then
          BLOCKER_NUMS="${BLOCKER_NUMS} ${dep}"
        fi
      done
    fi
  done <<< "$BBODY"
done
# Deduplicate blockers
BLOCKER_NUMS=$(echo "$BLOCKER_NUMS" | tr ' ' '\n' | sort -un | head -10)
if [ -n "$BLOCKER_NUMS" ]; then
  BLOCKER_LIST=""
  for bnum in $BLOCKER_NUMS; do
    BTITLE=$(echo "$ISSUES_JSON" | jq -r --arg n "$bnum" '.[] | select(.number == ($n | tonumber)) | .title' 2>/dev/null || true)
    BLABELS=$(echo "$ISSUES_JSON" | jq -r --arg n "$bnum" '.[] | select(.number == ($n | tonumber)) | [.labels[].name] | join(",")' 2>/dev/null || true)
    BLOCKER_LIST="${BLOCKER_LIST}#${bnum} [${BLABELS:-unlabeled}] ${BTITLE}\n"
  done
  PROBLEMS="${PROBLEMS}PRIORITY_blockers_starving_factory: these issues block backlog items but are NOT labeled backlog — promote them FIRST:\n${BLOCKER_LIST}\n"
fi

# 6. Tech-debt issues needing promotion to backlog (secondary to blockers)
TECH_DEBT_ISSUES=$(echo "$ISSUES_JSON" | jq -r '.[] | select(.labels | map(.name) | index("tech-debt")) | "#\(.number) \(.title)"' | head -10)
if [ -n "$TECH_DEBT_ISSUES" ]; then
  TECH_DEBT_COUNT=$(echo "$TECH_DEBT_ISSUES" | wc -l)
  PROBLEMS="${PROBLEMS}tech_debt_promotion: ${TECH_DEBT_COUNT} tech-debt issues need promotion to backlog (max 10 per run):\n${TECH_DEBT_ISSUES}\n"
fi

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

PROMPT="You are the issue gardener for ${CODEBERG_REPO}. Your job: keep the backlog clean, well-structured, and actionable.

## Current open issues
$ISSUE_SUMMARY

## Problems detected
$(echo -e "$PROBLEMS")

## Tools available
- Codeberg API: use curl with the CODEBERG_TOKEN env var (already set in your environment)
- Base URL: ${CODEBERG_API}
- Read issue: \`curl -sf -H \"Authorization: token \$CODEBERG_TOKEN\" '${CODEBERG_API}/issues/{number}' | jq '.body'\`
- Relabel: \`curl -sf -H \"Authorization: token \$CODEBERG_TOKEN\" -X PUT -H 'Content-Type: application/json' '${CODEBERG_API}/issues/{number}/labels' -d '{\"labels\":[LABEL_ID]}'\`
- Comment: \`curl -sf -H \"Authorization: token \$CODEBERG_TOKEN\" -X POST -H 'Content-Type: application/json' '${CODEBERG_API}/issues/{number}/comments' -d '{\"body\":\"...\"}'\`
- Close: \`curl -sf -H \"Authorization: token \$CODEBERG_TOKEN\" -X PATCH -H 'Content-Type: application/json' '${CODEBERG_API}/issues/{number}' -d '{\"state\":\"closed\"}'\`
- Edit body: \`curl -sf -H \"Authorization: token \$CODEBERG_TOKEN\" -X PATCH -H 'Content-Type: application/json' '${CODEBERG_API}/issues/{number}' -d '{\"body\":\"new body\"}'\`
- List labels: \`curl -sf -H \"Authorization: token \$CODEBERG_TOKEN\" '${CODEBERG_API}/labels'\` (to find label IDs)
- NEVER echo, log, or include the actual token value in any output — always reference \$CODEBERG_TOKEN
- You're running in the project repo root. Read README.md and any docs/ files before making decisions.

## Primary mission: unblock the factory
Issues prefixed with PRIORITY_blockers_starving_factory are your TOP priority. These are non-backlog issues that block existing backlog items — the dev-agent is completely starved until these are promoted. Process ALL of them before touching regular tech-debt.

## Secondary mission: promote tech-debt → backlog
Most open issues are raw review-bot findings labeled \`tech-debt\`. Convert them into well-structured \`backlog\` items the dev-agent can execute. For each tech-debt issue:
1. Read the issue body + referenced source files to understand the real problem
2. Check AGENTS.md (and sub-directory AGENTS.md files) for architecture context
3. Add missing sections: \`## Affected files\`, \`## Acceptance criteria\` (checkboxes, max 5), \`## Dependencies\`
4. If the issue is clear and actionable → relabel: remove \`tech-debt\`, add \`backlog\`
5. If scope is ambiguous or needs a design decision → ESCALATE with options
6. If superseded by a merged PR or another issue → close with explanation

Process up to 10 tech-debt issues per run (stay within API rate limits).

## Other rules
1. **Duplicates**: If confident (>80% overlap + same scope after reading bodies), close the newer one with a comment referencing the older. If unsure, ESCALATE.
2. **Thin issues** (non-tech-debt): Add acceptance criteria. Read the body first.
3. **Stale issues**: If clearly superseded or no longer relevant, close with explanation. If unclear, ESCALATE.
4. **Oversized issues**: If >5 acceptance criteria touching different files/concerns, ESCALATE with suggested split.
5. **Dependencies**: If an issue references another that must land first, add a \`## Dependencies\n- #NNN\` section if missing.
6. **Sibling issues**: When creating multiple issues from the same source (PR review, code audit), NEVER add bidirectional dependencies between them. Siblings are independent work items, not parent/child. Use \`## Related\n- #NNN (sibling)\` for cross-references between siblings — NOT \`## Dependencies\`. The dev-poll \`get_deps()\` parser only reads \`## Dependencies\` / \`## Depends on\` / \`## Blocked by\` headers, so \`## Related\` is safely ignored. Bidirectional deps create permanent deadlocks that stall the entire factory.

## Escalation format
For anything needing human decision, output EXACTLY this format (one block, all items):
\`\`\`
ESCALATE
1. #NNN \"title\" — reason (a) option1 (b) option2 (c) option3
2. #NNN \"title\" — reason (a) option1 (b) option2
\`\`\`

## Output format (MANDATORY — the script parses these exact prefixes)
- After EVERY action you take, print exactly: ACTION: <description>
- For issues needing human decision, output EXACTLY:
ESCALATE
1. #NNN \"title\" — reason (a) option1 (b) option2
- If truly nothing to do, print: CLEAN

## Important
- You MUST process the tech_debt_promotion items listed above. Read each issue, add acceptance criteria + affected files, then relabel to backlog.
- If an issue is ambiguous or needs a design decision, ESCALATE it — don't skip it silently.
- Every tech-debt issue in the list above should result in either an ACTION (promoted) or an ESCALATE (needs decision). Never skip silently.
$(if [ -n "$ESCALATION_REPLY" ]; then echo "
## Human Response to Previous Escalation
The human replied with shorthand choices keyed to the previous ESCALATE block.
Format: '1a 2c 3b' means question 1→option (a), question 2→option (c), question 3→option (b).

Raw reply:
${ESCALATION_REPLY}

Execute each chosen option NOW via the Codeberg API before processing new items.
If a choice is unclear, re-escalate that single item with a clarifying question."; fi)"

CLAUDE_OUTPUT=$(cd "${PROJECT_REPO_ROOT}" && CODEBERG_TOKEN="$CODEBERG_TOKEN" timeout "$CLAUDE_TIMEOUT" \
  claude -p "$PROMPT" \
    --model sonnet \
    --dangerously-skip-permissions \
    --max-turns 30 \
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

  # Send via Matrix (threaded — replies route back via listener)
  matrix_send "gardener" "🌱 Issue Gardener — ${ITEM_COUNT} item(s) need attention

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

# ── Process dev-agent escalations (per-project) ──────────────────────────
ESCALATION_FILE="${FACTORY_ROOT}/supervisor/escalations-${PROJECT_NAME}.jsonl"
ESCALATION_DONE="${FACTORY_ROOT}/supervisor/escalations-${PROJECT_NAME}.done.jsonl"

if [ -s "$ESCALATION_FILE" ]; then
  # Atomically snapshot the file before processing to prevent race with
  # concurrent dev-poll appends: new entries go to a fresh ESCALATION_FILE
  # while we process the snapshot, so nothing is ever silently dropped.
  ESCALATION_SNAP="${ESCALATION_FILE}.processing.$$"
  mv "$ESCALATION_FILE" "$ESCALATION_SNAP"

  ESCALATION_COUNT=$(wc -l < "$ESCALATION_SNAP")
  log "Processing ${ESCALATION_COUNT} escalation(s) for ${PROJECT_NAME}"

  while IFS= read -r esc_entry; do
    [ -z "$esc_entry" ] && continue

    ESC_ISSUE=$(echo "$esc_entry" | jq -r '.issue // empty')
    ESC_PR=$(echo "$esc_entry" | jq -r '.pr // empty')
    ESC_ATTEMPTS=$(echo "$esc_entry" | jq -r '.attempts // 3')

    if [ -z "$ESC_ISSUE" ] || [ -z "$ESC_PR" ]; then
      echo "$esc_entry" >> "$ESCALATION_DONE"
      continue
    fi

    log "Escalation: issue #${ESC_ISSUE} PR #${ESC_PR} (${ESC_ATTEMPTS} CI attempt(s))"

    # Fetch the failing pipeline for this PR
    ESC_PR_SHA=$(curl -sf -H "Authorization: token ${CODEBERG_TOKEN}" \
      "${CODEBERG_API}/pulls/${ESC_PR}" 2>/dev/null | jq -r '.head.sha // ""') || true

    ESC_PIPELINE=""
    ESC_SUB_ISSUES_CREATED=0
    ESC_GENERIC_FAIL=""
    ESC_LOGS_AVAILABLE=0

    if [ -n "$ESC_PR_SHA" ]; then
      # Validate SHA is a 40-char hex string before interpolating into SQL
      if [[ "$ESC_PR_SHA" =~ ^[0-9a-fA-F]{40}$ ]]; then
        ESC_PIPELINE=$(wpdb -c "SELECT number FROM pipelines WHERE repo_id=${WOODPECKER_REPO_ID} AND commit='${ESC_PR_SHA}' ORDER BY created DESC LIMIT 1;" 2>/dev/null | xargs || true)
      else
        log "WARNING: ESC_PR_SHA '${ESC_PR_SHA}' is not a valid hex SHA — skipping pipeline lookup"
      fi
    fi

    if [ -n "$ESC_PIPELINE" ]; then
      FAILED_STEPS=$(curl -sf \
        -H "Authorization: Bearer ${WOODPECKER_TOKEN}" \
        "${WOODPECKER_SERVER}/api/repos/${WOODPECKER_REPO_ID}/pipelines/${ESC_PIPELINE}" 2>/dev/null | \
        jq -r '.workflows[]?.children[]? | select(.state=="failure") | "\(.pid)\t\(.name)"' 2>/dev/null || true)

      while IFS=$'\t' read -r step_pid step_name; do
        [ -z "$step_pid" ] && continue
        [[ "$step_pid" =~ ^[0-9]+$ ]] || { log "WARNING: invalid step_pid '${step_pid}' — skipping"; continue; }
        step_logs=$(woodpecker-cli pipeline log show "${CODEBERG_REPO}" "${ESC_PIPELINE}" "${step_pid}" 2>/dev/null | tail -150 || true)
        [ -z "$step_logs" ] && continue
        ESC_LOGS_AVAILABLE=1

        if echo "$step_name" | grep -qi "shellcheck"; then
          # Create one sub-issue per file with ShellCheck errors
          sc_files=$(echo "$step_logs" | grep -oP '(?<=In )\S+(?= line \d+:)' | sort -u || true)

          while IFS= read -r sc_file; do
            [ -z "$sc_file" ] && continue
            # grep -F for literal filename match (dots in filenames are regex wildcards)
            file_errors=$(echo "$step_logs" | grep -F -A3 "In ${sc_file} line" | head -30)
            # SC codes only from this file's errors, not the whole step log
            sc_codes=$(echo "$file_errors" | grep -oP 'SC\d+' | sort -u | tr '\n' ' ' | sed 's/ $//' || true)

            sub_title="fix: ShellCheck errors in ${sc_file} (from PR #${ESC_PR})"
            sub_body="## ShellCheck CI failure — \`${sc_file}\`

Spawned by gardener from escalated issue #${ESC_ISSUE} (PR #${ESC_PR} failed CI after ${ESC_ATTEMPTS} attempt(s)).

### Errors
\`\`\`
${file_errors}
\`\`\`

Fix all ShellCheck errors${sc_codes:+ (${sc_codes})} in \`${sc_file}\` so PR #${ESC_PR} CI passes.

### Context
- Parent issue: #${ESC_ISSUE}
- PR: #${ESC_PR}
- Pipeline: #${ESC_PIPELINE} (step: ${step_name})"

            new_issue=$(curl -sf -X POST \
              -H "Authorization: token ${CODEBERG_TOKEN}" \
              -H "Content-Type: application/json" \
              "${CODEBERG_API}/issues" \
              -d "$(jq -nc --arg t "$sub_title" --arg b "$sub_body" \
                '{"title":$t,"body":$b,"labels":["backlog"]}')" 2>/dev/null | jq -r '.number // ""') || true

            if [ -n "$new_issue" ]; then
              log "Created sub-issue #${new_issue}: ShellCheck in ${sc_file} (from #${ESC_ISSUE})"
              ESC_SUB_ISSUES_CREATED=$((ESC_SUB_ISSUES_CREATED + 1))
              matrix_send "gardener" "📋 Created sub-issue #${new_issue}: ShellCheck in ${sc_file} (from escalated #${ESC_ISSUE})" 2>/dev/null || true
            fi
          done <<< "$sc_files"

        else
          # Accumulate non-ShellCheck failures for one combined issue
          esc_section="=== ${step_name} ===
$(echo "$step_logs" | tail -50)"
          if [ -z "$ESC_GENERIC_FAIL" ]; then
            ESC_GENERIC_FAIL="$esc_section"
          else
            ESC_GENERIC_FAIL="${ESC_GENERIC_FAIL}
${esc_section}"
          fi
        fi
      done <<< "$FAILED_STEPS"
    fi

    # Create one sub-issue for all non-ShellCheck CI failures
    if [ -n "$ESC_GENERIC_FAIL" ]; then
      sub_title="fix: CI failures in PR #${ESC_PR} (from issue #${ESC_ISSUE})"
      sub_body="## CI failure — fix required

Spawned by gardener from escalated issue #${ESC_ISSUE} (PR #${ESC_PR} failed CI after ${ESC_ATTEMPTS} attempt(s)).

### Failed step output
\`\`\`
${ESC_GENERIC_FAIL}
\`\`\`

### Context
- Parent issue: #${ESC_ISSUE}
- PR: #${ESC_PR}${ESC_PIPELINE:+
- Pipeline: #${ESC_PIPELINE}}"

      new_issue=$(curl -sf -X POST \
        -H "Authorization: token ${CODEBERG_TOKEN}" \
        -H "Content-Type: application/json" \
        "${CODEBERG_API}/issues" \
        -d "$(jq -nc --arg t "$sub_title" --arg b "$sub_body" \
          '{"title":$t,"body":$b,"labels":["backlog"]}')" 2>/dev/null | jq -r '.number // ""') || true

      if [ -n "$new_issue" ]; then
        log "Created sub-issue #${new_issue}: CI failures for PR #${ESC_PR} (from #${ESC_ISSUE})"
        ESC_SUB_ISSUES_CREATED=$((ESC_SUB_ISSUES_CREATED + 1))
        matrix_send "gardener" "📋 Created sub-issue #${new_issue}: CI failures for PR #${ESC_PR} (from escalated #${ESC_ISSUE})" 2>/dev/null || true
      fi
    fi

    # Fallback: no sub-issues created — differentiate logs-unavailable from creation failure
    if [ "$ESC_SUB_ISSUES_CREATED" -eq 0 ]; then
      sub_title="fix: investigate CI failure for PR #${ESC_PR} (from issue #${ESC_ISSUE})"
      if [ "$ESC_LOGS_AVAILABLE" -eq 1 ]; then
        # Logs were fetched but all issue creation API calls failed
        sub_body="## CI failure — investigation required

Spawned by gardener from escalated issue #${ESC_ISSUE} (PR #${ESC_PR} failed CI after ${ESC_ATTEMPTS} attempt(s)). CI logs were retrieved but sub-issue creation failed (API error).

Check PR #${ESC_PR} CI output, identify the failing checks, and fix them so the PR can merge."
      else
        # Could not retrieve CI logs at all
        sub_body="## CI failure — investigation required

Spawned by gardener from escalated issue #${ESC_ISSUE} (PR #${ESC_PR} failed CI after ${ESC_ATTEMPTS} attempt(s)). CI logs were unavailable at escalation time.

Check PR #${ESC_PR} CI output, identify the failing checks, and fix them so the PR can merge."
      fi

      new_issue=$(curl -sf -X POST \
        -H "Authorization: token ${CODEBERG_TOKEN}" \
        -H "Content-Type: application/json" \
        "${CODEBERG_API}/issues" \
        -d "$(jq -nc --arg t "$sub_title" --arg b "$sub_body" \
          '{"title":$t,"body":$b,"labels":["backlog"]}')" 2>/dev/null | jq -r '.number // ""') || true

      if [ -n "$new_issue" ]; then
        log "Created fallback sub-issue #${new_issue} for escalated #${ESC_ISSUE}"
        matrix_send "gardener" "📋 Created sub-issue #${new_issue}: investigate CI for PR #${ESC_PR} (from escalated #${ESC_ISSUE})" 2>/dev/null || true
      fi
    fi

    # Mark as processed
    echo "$esc_entry" >> "$ESCALATION_DONE"
  done < "$ESCALATION_SNAP"

  rm -f "$ESCALATION_SNAP"
  log "Escalations processed — moved to $(basename "$ESCALATION_DONE")"
fi

log "--- Gardener poll done ---"
