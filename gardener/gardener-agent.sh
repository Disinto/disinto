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
# shellcheck source=../lib/formula-session.sh
source "$FACTORY_ROOT/lib/formula-session.sh"

LOG_FILE="$SCRIPT_DIR/gardener.log"
SESSION_NAME="gardener-${PROJECT_NAME}"
PHASE_FILE="/tmp/gardener-session-${PROJECT_NAME}.phase"
RESULT_FILE="/tmp/gardener-result-${PROJECT_NAME}.txt"
DUST_FILE="$SCRIPT_DIR/dust.jsonl"
SCRATCH_FILE="/tmp/gardener-${PROJECT_NAME}-scratch.md"

# shellcheck disable=SC2034  # read by monitor_phase_loop in lib/agent-session.sh
PHASE_POLL_INTERVAL=15

log() { echo "[$(date -u +%Y-%m-%dT%H:%M:%S)Z] $*" >> "$LOG_FILE"; }

# Gitea labels API requires []int64 — look up the "backlog" label ID once
# Falls back to the known Codeberg repo ID if the API call fails
BACKLOG_LABEL_ID=$(codeberg_api GET "/labels" 2>/dev/null \
  | jq -r '.[] | select(.name == "backlog") | .id' 2>/dev/null || true)
BACKLOG_LABEL_ID="${BACKLOG_LABEL_ID:-1300815}"

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

# ── Load formula ─────────────────────────────────────────────────────────
log "Loading groom-backlog formula"
FORMULA_FILE="$FACTORY_ROOT/formulas/groom-backlog.toml"
if [ ! -f "$FORMULA_FILE" ]; then
  log "ERROR: formula not found: $FORMULA_FILE"
  exit 1
fi
FORMULA_CONTENT=$(cat "$FORMULA_FILE")

# ── Read context files from project root ──────────────────────────────────
CONTEXT_BLOCK=""
for ctx in README.md AGENTS.md VISION.md; do
  ctx_path="${PROJECT_REPO_ROOT}/${ctx}"
  if [ -f "$ctx_path" ]; then
    CONTEXT_BLOCK="${CONTEXT_BLOCK}
### ${ctx}
$(cat "$ctx_path")
"
  fi
done

# ── Build issue context ────────────────────────────────────────────────────
ISSUE_SUMMARY=$(echo "$ISSUES_JSON" | jq -r '.[] | "#\(.number) [\(.labels | map(.name) | join(","))] \(.title)"')

STAGED_DUST=""
if [ -s "$DUST_FILE" ]; then
  STAGED_DUST=$(jq -r '"#\(.issue) (\(.group))"' "$DUST_FILE" 2>/dev/null | sort -u || true)
fi

# ── Build optional prompt sections ────────────────────────────────────────
CONTEXT_SECTION=""
if [ -n "$CONTEXT_BLOCK" ]; then
  CONTEXT_SECTION="## Project context
${CONTEXT_BLOCK}"
fi

STAGED_DUST_SECTION=""
if [ -n "$STAGED_DUST" ]; then
  STAGED_DUST_SECTION="
### Already staged as dust — do NOT re-emit DUST for these
${STAGED_DUST}"
fi

ESCALATION_SECTION=""
if [ -n "$ESCALATION_REPLY" ]; then
  ESCALATION_SECTION="
### Human response to previous escalation
Format: '1a 2c 3b' means question 1→option (a), 2→option (c), 3→option (b).
Execute each chosen option via the Codeberg API FIRST, before processing new items.
If a choice is unclear, re-escalate that single item with a clarifying question.

${ESCALATION_REPLY}"
fi

# ── Read scratch file (compaction survival) ───────────────────────────────
SCRATCH_CONTEXT=$(read_scratch_context "$SCRATCH_FILE")
SCRATCH_INSTRUCTION=$(build_scratch_instruction "$SCRATCH_FILE")

# ── Build prompt from formula + dynamic context ────────────────────────────
log "Building gardener prompt from formula"

PROMPT="You are the issue gardener for ${CODEBERG_REPO}. Work through the formula below. You MUST write PHASE:done to '${PHASE_FILE}' when finished — the orchestrator will time you out if you return to the prompt without signalling.

${CONTEXT_SECTION}
${SCRATCH_CONTEXT:+${SCRATCH_CONTEXT}
}## Formula
${FORMULA_CONTENT}

## Runtime context (bash pre-analysis)
### All open issues
${ISSUE_SUMMARY}

### Problems detected
$(echo -e "$PROBLEMS")${STAGED_DUST_SECTION}${ESCALATION_SECTION}
## Codeberg API reference
Base URL: ${CODEBERG_API}
Auth header: -H \"Authorization: token \$CODEBERG_TOKEN\"
  Read issue:  curl -sf -H \"Authorization: token \$CODEBERG_TOKEN\" '${CODEBERG_API}/issues/{number}' | jq '.body'
  Relabel:     curl -sf -H \"Authorization: token \$CODEBERG_TOKEN\" -X PUT -H 'Content-Type: application/json' '${CODEBERG_API}/issues/{number}/labels' -d '{\"labels\":[LABEL_ID]}'
  Comment:     curl -sf -H \"Authorization: token \$CODEBERG_TOKEN\" -X POST -H 'Content-Type: application/json' '${CODEBERG_API}/issues/{number}/comments' -d '{\"body\":\"...\"}'
  Close:       curl -sf -H \"Authorization: token \$CODEBERG_TOKEN\" -X PATCH -H 'Content-Type: application/json' '${CODEBERG_API}/issues/{number}' -d '{\"state\":\"closed\"}'
  Edit body:   curl -sf -H \"Authorization: token \$CODEBERG_TOKEN\" -X PATCH -H 'Content-Type: application/json' '${CODEBERG_API}/issues/{number}' -d '{\"body\":\"new body\"}'
  List labels: curl -sf -H \"Authorization: token \$CODEBERG_TOKEN\" '${CODEBERG_API}/labels'
NEVER echo or include the actual token value in output — always reference \$CODEBERG_TOKEN.

## Output format (MANDATORY — write each line to result file using bash)
  echo \"ACTION: description of what you did\" >> '${RESULT_FILE}'
  echo 'DUST: {\"issue\": NNN, \"group\": \"...\", \"title\": \"...\", \"reason\": \"...\"}' >> '${RESULT_FILE}'
  printf 'ESCALATE\n1. #NNN \"title\" — reason (a) option1 (b) option2\n' >> '${RESULT_FILE}'
  echo 'CLEAN' >> '${RESULT_FILE}'  # only if truly nothing to do

${SCRATCH_INSTRUCTION}

## Phase protocol (REQUIRED)
When all work is done and verify confirms zero tech-debt:
  echo 'PHASE:done' > '${PHASE_FILE}'
On unrecoverable error:
  printf 'PHASE:failed\nReason: %s\n' 'describe error' > '${PHASE_FILE}'"

# Write phase protocol to context file for compaction survival
write_compact_context "$PHASE_FILE" "## Phase protocol (REQUIRED)
When all work is done and verify confirms zero tech-debt:
  echo 'PHASE:done' > '${PHASE_FILE}'
On unrecoverable error:
  printf 'PHASE:failed\nReason: %s\n' 'describe error' > '${PHASE_FILE}'"

# ── Reset phase + result files ────────────────────────────────────────────
agent_kill_session "$SESSION_NAME"
rm -f "$PHASE_FILE" "${PHASE_FILE%.phase}.context" "$RESULT_FILE"
touch "$RESULT_FILE"

# ── Create tmux session ───────────────────────────────────────────────────
log "Creating tmux session: ${SESSION_NAME}"
if ! create_agent_session "$SESSION_NAME" "$PROJECT_REPO_ROOT" "$PHASE_FILE"; then
  log "ERROR: failed to create tmux session ${SESSION_NAME}"
  exit 1
fi

agent_inject_into_session "$SESSION_NAME" "$PROMPT"
log "Prompt sent to tmux session"
matrix_send "gardener" "🌱 Gardener session started for ${CODEBERG_REPO}" 2>/dev/null || true

# ── Phase monitoring loop ─────────────────────────────────────────────────
log "Monitoring phase file: ${PHASE_FILE}"
_FORMULA_CRASH_COUNT=0

gardener_phase_callback() {
  # Gardener-specific cleanup before shared crash recovery
  if [ "$1" = "PHASE:crashed" ]; then
    rm -f "$RESULT_FILE"
    touch "$RESULT_FILE"
  fi
  formula_phase_callback "$1"
}

monitor_phase_loop "$PHASE_FILE" 7200 "gardener_phase_callback"

FINAL_PHASE=$(read_phase)
log "Final phase: ${FINAL_PHASE:-none}"

if [ "$FINAL_PHASE" != "PHASE:done" ]; then
  case "${_MONITOR_LOOP_EXIT:-}" in
    idle_prompt)
      log "gardener-agent: Claude returned to prompt without writing phase signal — no phase file written"
      ;;
    idle_timeout)
      log "gardener-agent: timed out after 2h with no phase signal"
      ;;
    *)
      log "gardener-agent finished without PHASE:done (phase: ${FINAL_PHASE:-none}, exit: ${_MONITOR_LOOP_EXIT:-})"
      ;;
  esac
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
        --argjson lid "$BACKLOG_LABEL_ID" '{"title":$t,"body":$b,"labels":[$lid]}')" 2>/dev/null | jq -r '.number // ""') || true

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

# ── Cleanup scratch file on normal exit ──────────────────────────────────
if [ "$FINAL_PHASE" = "PHASE:done" ]; then
  rm -f "$SCRATCH_FILE"
fi

log "--- gardener-agent done ---"
