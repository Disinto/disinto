#!/usr/bin/env bash
# gardener-agent.sh — tmux + Claude interactive gardener session manager
#
# Usage: ./gardener-agent.sh [project-toml]
# Called by: gardener-poll.sh
#
# Lifecycle:
#   1. Read escalation reply (from ESCALATION_REPLY env var)
#   2. Fetch open issues + bash pre-checks (zero tokens)
#   3. If no problems detected, exit 0
#   4. Build prompt with result-file output + phase protocol instructions
#   5. Create tmux session: gardener-{project} with interactive claude
#   6. Inject prompt via tmux
#   7. Monitor phase file — Claude writes PHASE:done when finished
#   8. Parse result file (ACTION:/DUST:/ESCALATE) → Matrix + dust.jsonl
#   9. Dust bundling: groups with 3+ items → one backlog issue
#
# Phase file:  /tmp/gardener-session-{project}.phase
# Result file: /tmp/gardener-result-{project}.txt
# Session:     gardener-{project} (tmux)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
FACTORY_ROOT="$(dirname "$SCRIPT_DIR")"

export PROJECT_TOML="${1:-}"
# shellcheck source=../lib/env.sh
source "$FACTORY_ROOT/lib/env.sh"
# shellcheck source=../lib/agent-session.sh
source "$FACTORY_ROOT/lib/agent-session.sh"

LOG_FILE="$SCRIPT_DIR/gardener.log"
CLAUDE_TIMEOUT="${CLAUDE_TIMEOUT:-3600}"

SESSION_NAME="gardener-${PROJECT_NAME}"
PHASE_FILE="/tmp/gardener-session-${PROJECT_NAME}.phase"
RESULT_FILE="/tmp/gardener-result-${PROJECT_NAME}.txt"
DUST_FILE="$SCRIPT_DIR/dust.jsonl"

PHASE_POLL_INTERVAL=15
MAX_RUNTIME="${CLAUDE_TIMEOUT}"

log() { echo "[$(date -u +%Y-%m-%dT%H:%M:%S)Z] $*" >> "$LOG_FILE"; }

read_phase() {
  { cat "$PHASE_FILE" 2>/dev/null || true; } | head -1 | tr -d '[:space:]'
}

log "--- gardener-agent start ---"

# ── Read escalation reply (passed via env by gardener-poll.sh) ────────────
ESCALATION_REPLY="${ESCALATION_REPLY:-}"

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
TECH_DEBT_ISSUES=$(echo "$ISSUES_JSON" | jq -r '.[] | select(.labels | map(.name) | index("tech-debt")) | "#\(.number) \(.title)"')
if [ -n "$TECH_DEBT_ISSUES" ]; then
  TECH_DEBT_COUNT=$(echo "$TECH_DEBT_ISSUES" | wc -l)
  PROBLEMS="${PROBLEMS}tech_debt_promotion: ${TECH_DEBT_COUNT} tech-debt issues need processing (goal: zero tech-debt):\n$(echo "$TECH_DEBT_ISSUES" | head -50)\n"
fi

PROBLEM_COUNT=$(echo -e "$PROBLEMS" | grep -c '.' || true)
log "Detected $PROBLEM_COUNT potential problems"

if [ "$PROBLEM_COUNT" -eq 0 ] && [ -z "$ESCALATION_REPLY" ]; then
  log "Backlog is clean — nothing to groom"
  exit 0
fi

# ── Build prompt ──────────────────────────────────────────────────────────
log "Building gardener prompt"

# Build issue summary for context (titles + labels + deps)
ISSUE_SUMMARY=$(echo "$ISSUES_JSON" | jq -r '.[] | "#\(.number) [\(.labels | map(.name) | join(","))] \(.title)"')

# Build list of issues already staged as dust (so LLM doesn't re-emit them)
STAGED_DUST=""
if [ -s "$DUST_FILE" ]; then
  STAGED_DUST=$(jq -r '"#\(.issue) (\(.group))"' "$DUST_FILE" 2>/dev/null | sort -u || true)
fi

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

## Your objective: zero tech-debt issues

Tech-debt is unprocessed work — it sits outside the factory pipeline
(dev-agent only pulls backlog). Every tech-debt issue is a decision
you haven't made yet:

- Substantial? → promote to backlog (add affected files, acceptance
  criteria, dependencies)
- Dust? → bundle into an ore issue
- Duplicate? → close with cross-reference
- Invalid/wontfix? → close with explanation
- Needs human decision? → escalate

Process ALL tech-debt issues every run. The goal is zero tech-debt
when you're done. If you can't reach zero (needs human input,
unclear scope), escalate those specifically and close out everything
else.

Tech-debt is your inbox. An empty inbox is a healthy factory.

## Dust vs Ore — bundle trivial tech-debt
Don't promote trivial tech-debt individually — each costs a full factory cycle (CI + dev-agent + review + merge). If an issue is dust (comment fix, rename, style-only, single-line change, trivial cleanup), output a DUST line instead of promoting:

DUST: {\"issue\": NNN, \"group\": \"<file-or-subsystem>\", \"title\": \"issue title\", \"reason\": \"why it's dust\"}

Group by file or subsystem (e.g. \"gardener\", \"lib/env.sh\", \"dev-poll\"). The script collects dust items into a staging file. When a group accumulates 3+ items, the script bundles them into one backlog issue automatically.

Only promote tech-debt that is substantial: multi-file changes, behavioral fixes, architectural improvements. Dust is any issue where the fix is a single-line edit, a rename, a comment tweak, or a style-only change.
$(if [ -n "$STAGED_DUST" ]; then echo "
These issues are ALREADY staged as dust — do NOT emit DUST lines for them again:
${STAGED_DUST}"; fi)

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

## Output format (MANDATORY — write each line to result file using bash)
Write your structured output to ${RESULT_FILE}. Use bash to append each line:
  echo \"ACTION: description of what you did\" >> '${RESULT_FILE}'
  echo 'DUST: {\"issue\": NNN, \"group\": \"...\", \"title\": \"...\", \"reason\": \"...\"}' >> '${RESULT_FILE}'
For escalations, write the full block to the result file:
  printf 'ESCALATE\n1. #NNN \"title\" — reason (a) option1 (b) option2\n' >> '${RESULT_FILE}'
If truly nothing to do: echo 'CLEAN' >> '${RESULT_FILE}'

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
If a choice is unclear, re-escalate that single item with a clarifying question."; fi)

## Phase protocol (REQUIRED)
When you have finished ALL work, write to the phase file:
  echo 'PHASE:done' > '${PHASE_FILE}'
On unrecoverable error:
  printf 'PHASE:failed\nReason: %s\n' 'describe error' > '${PHASE_FILE}'"

# ── Reset phase + result files ────────────────────────────────────────────
kill_tmux_session
rm -f "$PHASE_FILE" "$RESULT_FILE"
touch "$RESULT_FILE"

# ── Create tmux session ───────────────────────────────────────────────────
log "Creating tmux session: ${SESSION_NAME}"
if ! create_agent_session "$SESSION_NAME" "$PROJECT_REPO_ROOT"; then
  log "ERROR: failed to create tmux session ${SESSION_NAME}"
  exit 1
fi

inject_into_session "$PROMPT"
log "Prompt sent to tmux session"
matrix_send "gardener" "🌱 Gardener session started for ${CODEBERG_REPO}" 2>/dev/null || true

# ── Phase monitoring loop ─────────────────────────────────────────────────
log "Monitoring phase file: ${PHASE_FILE}"
LAST_PHASE_MTIME=0
IDLE_ELAPSED=0
CRASHED=false

while true; do
  sleep "$PHASE_POLL_INTERVAL"
  IDLE_ELAPSED=$((IDLE_ELAPSED + PHASE_POLL_INTERVAL))

  # --- Session health check ---
  if ! tmux has-session -t "$SESSION_NAME" 2>/dev/null; then
    CURRENT_PHASE=$(read_phase)
    case "$CURRENT_PHASE" in
      PHASE:done|PHASE:failed)
        # Expected terminal phase — exit loop
        break
        ;;
      *)
        if [ "$CRASHED" = true ]; then
          log "ERROR: session crashed again after recovery — giving up"
          break
        fi
        CRASHED=true
        log "WARNING: tmux session died unexpectedly (phase: ${CURRENT_PHASE:-none})"
        # Attempt one crash recovery
        RECOVERY_MSG="The previous gardener session was interrupted unexpectedly.

Re-run your analysis from scratch:
1. Fetch open issues and identify problems using the Codeberg API
2. Take all necessary actions (close dupes, add criteria, promote tech-debt, etc.)
3. Write structured output to ${RESULT_FILE}:
   - echo \"ACTION: ...\" >> '${RESULT_FILE}'
   - echo 'DUST: {...}' >> '${RESULT_FILE}'
   - printf 'ESCALATE\n1. ...\n' >> '${RESULT_FILE}'
4. When finished: echo 'PHASE:done' > '${PHASE_FILE}'"

        rm -f "$RESULT_FILE"
        touch "$RESULT_FILE"
        if create_agent_session "$SESSION_NAME" "$PROJECT_REPO_ROOT" 2>/dev/null; then
          inject_into_session "$RECOVERY_MSG"
          log "Recovery session started"
          IDLE_ELAPSED=0
        else
          log "ERROR: could not restart session after crash"
          break
        fi
        continue
        ;;
    esac
  fi

  # --- Check phase file for changes ---
  PHASE_MTIME=$(stat -c %Y "$PHASE_FILE" 2>/dev/null || echo 0)
  CURRENT_PHASE=$(read_phase)

  if [ -z "$CURRENT_PHASE" ] || [ "$PHASE_MTIME" -le "$LAST_PHASE_MTIME" ]; then
    # No phase change — check idle timeout
    if [ "$IDLE_ELAPSED" -ge "$MAX_RUNTIME" ]; then
      log "TIMEOUT: gardener session idle for ${MAX_RUNTIME}s — killing"
      matrix_send "gardener" "⚠️ Gardener session timed out after ${MAX_RUNTIME}s" 2>/dev/null || true
      kill_tmux_session
      break
    fi
    continue
  fi

  # Phase changed
  LAST_PHASE_MTIME="$PHASE_MTIME"
  IDLE_ELAPSED=0
  log "phase: ${CURRENT_PHASE}"

  if [ "$CURRENT_PHASE" = "PHASE:done" ] || [ "$CURRENT_PHASE" = "PHASE:failed" ]; then
    kill_tmux_session
    break
  fi
done

FINAL_PHASE=$(read_phase)
log "Final phase: ${FINAL_PHASE:-none}"

if [ "$FINAL_PHASE" != "PHASE:done" ]; then
  log "gardener-agent finished without PHASE:done (phase: ${FINAL_PHASE:-none})"
  exit 0
fi

log "claude finished — parsing result file"

# ── Parse result file ─────────────────────────────────────────────────────
CLAUDE_OUTPUT=""
if [ -s "$RESULT_FILE" ]; then
  CLAUDE_OUTPUT=$(cat "$RESULT_FILE")
fi

# ── Parse escalations ─────────────────────────────────────────────────────
ESCALATION=$(echo "$CLAUDE_OUTPUT" | awk '/^ESCALATE$/{found=1;next} found && /^(ACTION:|DUST:|CLEAN|PHASE:)/{found=0} found{print}' || true)
if [ -z "$ESCALATION" ]; then
  ESCALATION=$(echo "$CLAUDE_OUTPUT" | grep -A50 "^ESCALATE" | grep -E '^[0-9]' || true)
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

# ── Collect dust items ────────────────────────────────────────────────────
# DUST_FILE already set above (before prompt construction)
DUST_LINES=$(echo "$CLAUDE_OUTPUT" | grep "^DUST: " | sed 's/^DUST: //' || true)
if [ -n "$DUST_LINES" ]; then
  # Build set of issue numbers already in dust.jsonl for dedup
  EXISTING_DUST_ISSUES=""
  if [ -s "$DUST_FILE" ]; then
    EXISTING_DUST_ISSUES=$(jq -r '.issue' "$DUST_FILE" 2>/dev/null | sort -nu || true)
  fi

  DUST_COUNT=0
  while IFS= read -r dust_json; do
    [ -z "$dust_json" ] && continue
    # Validate JSON
    if ! echo "$dust_json" | jq -e '.issue and .group' >/dev/null 2>&1; then
      log "WARNING: invalid dust JSON: $dust_json"
      continue
    fi
    # Deduplicate: skip if this issue is already staged
    dust_issue_num=$(echo "$dust_json" | jq -r '.issue')
    if echo "$EXISTING_DUST_ISSUES" | grep -qx "$dust_issue_num" 2>/dev/null; then
      log "Skipping duplicate dust entry for issue #${dust_issue_num}"
      continue
    fi
    EXISTING_DUST_ISSUES="${EXISTING_DUST_ISSUES}
${dust_issue_num}"
    echo "$dust_json" | jq -c '. + {"ts": "'"$(date -u +%Y-%m-%dT%H:%M:%SZ)"'"}' >> "$DUST_FILE"
    DUST_COUNT=$((DUST_COUNT + 1))
  done <<< "$DUST_LINES"
  log "Collected $DUST_COUNT dust item(s) (duplicates skipped)"
fi

# ── Expire stale dust entries (30-day TTL) ───────────────────────────────
if [ -s "$DUST_FILE" ]; then
  CUTOFF=$(date -u -d '30 days ago' +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || true)
  if [ -n "$CUTOFF" ]; then
    BEFORE_COUNT=$(wc -l < "$DUST_FILE")
    if jq -c --arg c "$CUTOFF" 'select(.ts >= $c)' "$DUST_FILE" > "${DUST_FILE}.ttl" 2>/dev/null; then
      mv "${DUST_FILE}.ttl" "$DUST_FILE"
      AFTER_COUNT=$(wc -l < "$DUST_FILE")
      EXPIRED=$((BEFORE_COUNT - AFTER_COUNT))
      [ "$EXPIRED" -gt 0 ] && log "Expired $EXPIRED stale dust entries (>30 days old)"
    else
      rm -f "${DUST_FILE}.ttl"
      log "WARNING: TTL cleanup failed — dust.jsonl left unchanged"
    fi
  fi
fi

# ── Bundle dust groups with 3+ distinct issues ──────────────────────────
if [ -s "$DUST_FILE" ]; then
  # Count distinct issues per group (not raw entries)
  DUST_GROUPS=$(jq -r '[.group, (.issue | tostring)] | join("\t")' "$DUST_FILE" 2>/dev/null \
    | sort -u | cut -f1 | sort | uniq -c | sort -rn || true)
  while read -r count group; do
    [ -z "$group" ] && continue
    [ "$count" -lt 3 ] && continue

    log "Bundling dust group '$group' ($count distinct issues)"

    # Collect deduplicated issue references and details for this group
    BUNDLE_ISSUES=$(jq -r --arg g "$group" 'select(.group == $g) | "#\(.issue) \(.title // "untitled") — \(.reason // "dust")"' "$DUST_FILE" | sort -u)
    BUNDLE_ISSUE_NUMS=$(jq -r --arg g "$group" 'select(.group == $g) | .issue' "$DUST_FILE" | sort -nu)
    DISTINCT_COUNT=$(echo "$BUNDLE_ISSUE_NUMS" | grep -c '.' || true)

    bundle_title="fix: bundled dust cleanup — ${group}"
    bundle_body="## Bundled dust cleanup — \`${group}\`

Gardener bundled ${DISTINCT_COUNT} trivial tech-debt items into one issue to save factory cycles.

### Items
$(echo "$BUNDLE_ISSUES" | sed 's/^/- /')

### Instructions
Fix all items above in a single PR. Each is a small change (rename, comment, style fix, single-line edit).

### Affected files
- Files in \`${group}\` subsystem

### Acceptance criteria
- [ ] All listed items resolved
- [ ] ShellCheck passes"

    new_bundle=$(curl -sf -X POST \
      -H "Authorization: token ${CODEBERG_TOKEN}" \
      -H "Content-Type: application/json" \
      "${CODEBERG_API}/issues" \
      -d "$(jq -nc --arg t "$bundle_title" --arg b "$bundle_body" \
        '{"title":$t,"body":$b,"labels":["backlog"]}')" 2>/dev/null | jq -r '.number // ""') || true

    if [ -n "$new_bundle" ]; then
      log "Created bundle issue #${new_bundle} for dust group '$group' ($DISTINCT_COUNT items)"
      matrix_send "gardener" "📦 Bundled ${DISTINCT_COUNT} dust items (${group}) → #${new_bundle}" 2>/dev/null || true

      # Close source issues with cross-reference
      for src_issue in $BUNDLE_ISSUE_NUMS; do
        curl -sf -X POST \
          -H "Authorization: token ${CODEBERG_TOKEN}" \
          -H "Content-Type: application/json" \
          "${CODEBERG_API}/issues/${src_issue}/comments" \
          -d "$(jq -nc --arg b "Bundled into #${new_bundle} (dust cleanup)" '{"body":$b}')" 2>/dev/null || true
        curl -sf -X PATCH \
          -H "Authorization: token ${CODEBERG_TOKEN}" \
          -H "Content-Type: application/json" \
          "${CODEBERG_API}/issues/${src_issue}" \
          -d '{"state":"closed"}' 2>/dev/null || true
        log "Closed source issue #${src_issue} → bundled into #${new_bundle}"
      done

      # Remove bundled items from dust.jsonl — only if jq succeeds
      if jq -c --arg g "$group" 'select(.group != $g)' "$DUST_FILE" > "${DUST_FILE}.tmp" 2>/dev/null; then
        mv "${DUST_FILE}.tmp" "$DUST_FILE"
      else
        rm -f "${DUST_FILE}.tmp"
        log "WARNING: failed to prune bundled group '$group' from dust.jsonl"
      fi
    fi
  done <<< "$DUST_GROUPS"
fi

log "--- gardener-agent done ---"
