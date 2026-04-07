#!/usr/bin/env bash
# entrypoint-reproduce.sh — Reproduce-agent sidecar entrypoint
#
# Acquires the stack lock, boots the project stack (if formula declares
# stack_script), then drives Claude + Playwright MCP to follow the bug
# report's repro steps.  Labels the issue based on outcome and posts
# findings + screenshots.
#
# Usage (launched by dispatcher.sh):
#   entrypoint-reproduce.sh <project_toml> <issue_number>
#
# Environment (injected by dispatcher via docker run -e):
#   FORGE_URL, FORGE_TOKEN, FORGE_REPO, PRIMARY_BRANCH, DISINTO_CONTAINER=1
#
# Volumes expected:
#   /home/agent/data          — agent-data volume (stack-lock files go here)
#   /home/agent/repos         — project-repos volume
#   /home/agent/.claude       — host ~/.claude (OAuth credentials)
#   /home/agent/.ssh          — host ~/.ssh (read-only)
#   /usr/local/bin/claude     — host claude CLI binary (read-only)
#   /var/run/docker.sock      — host docker socket

set -euo pipefail

DISINTO_DIR="${DISINTO_DIR:-/home/agent/disinto}"

# Select formula based on DISINTO_FORMULA env var (set by dispatcher)
case "${DISINTO_FORMULA:-reproduce}" in
  triage)
    ACTIVE_FORMULA="${DISINTO_DIR}/formulas/triage.toml"
    ;;
  *)
    ACTIVE_FORMULA="${DISINTO_DIR}/formulas/reproduce.toml"
    ;;
esac

REPRODUCE_TIMEOUT="${REPRODUCE_TIMEOUT_MINUTES:-15}"
LOGFILE="/home/agent/data/logs/reproduce.log"
SCREENSHOT_DIR="/home/agent/data/screenshots"

# ---------------------------------------------------------------------------
# Determine agent type early for log prefix
# ---------------------------------------------------------------------------
if [ "${DISINTO_FORMULA:-reproduce}" = "triage" ]; then
  AGENT_TYPE="triage"
else
  AGENT_TYPE="reproduce"
fi

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------
log() {
  printf '[%s] %s: %s\n' "$(date -u '+%Y-%m-%d %H:%M:%S UTC')" "$AGENT_TYPE" "$*" | tee -a "$LOGFILE"
}

# ---------------------------------------------------------------------------
# Argument validation
# ---------------------------------------------------------------------------
PROJECT_TOML="${1:-}"
ISSUE_NUMBER="${2:-}"

if [ -z "$PROJECT_TOML" ] || [ -z "$ISSUE_NUMBER" ]; then
  log "FATAL: usage: entrypoint-reproduce.sh <project_toml> <issue_number>"
  exit 1
fi

if [ ! -f "$PROJECT_TOML" ]; then
  log "FATAL: project TOML not found: ${PROJECT_TOML}"
  exit 1
fi

# ---------------------------------------------------------------------------
# Bootstrap: directories, env
# ---------------------------------------------------------------------------
mkdir -p /home/agent/data/logs /home/agent/data/locks "$SCREENSHOT_DIR"

export DISINTO_CONTAINER=1
export HOME="${HOME:-/home/agent}"
export USER="${USER:-agent}"

FORGE_API="${FORGE_URL}/api/v1/repos/${FORGE_REPO}"

# Load project name from TOML
PROJECT_NAME=$(python3 -c "
import sys, tomllib
with open(sys.argv[1], 'rb') as f:
    print(tomllib.load(f)['name'])
" "$PROJECT_TOML" 2>/dev/null) || {
  log "FATAL: could not read project name from ${PROJECT_TOML}"
  exit 1
}
export PROJECT_NAME

PROJECT_REPO_ROOT="/home/agent/repos/${PROJECT_NAME}"

if [ "$AGENT_TYPE" = "triage" ]; then
  log "Starting triage-agent for issue #${ISSUE_NUMBER} (project: ${PROJECT_NAME})"
else
  log "Starting reproduce-agent for issue #${ISSUE_NUMBER} (project: ${PROJECT_NAME})"
fi

# ---------------------------------------------------------------------------
# Verify claude CLI is available (mounted from host)
# ---------------------------------------------------------------------------
if ! command -v claude &>/dev/null; then
  log "FATAL: claude CLI not found. Mount the host binary at /usr/local/bin/claude"
  exit 1
fi

# ---------------------------------------------------------------------------
# Source stack-lock library
# ---------------------------------------------------------------------------
# shellcheck source=/home/agent/disinto/lib/stack-lock.sh
source "${DISINTO_DIR}/lib/stack-lock.sh"

LOCK_HOLDER="reproduce-agent-${ISSUE_NUMBER}"

# ---------------------------------------------------------------------------
# Read formula config
# ---------------------------------------------------------------------------
FORMULA_STACK_SCRIPT=""
FORMULA_TIMEOUT_MINUTES="${REPRODUCE_TIMEOUT}"

if [ -f "$ACTIVE_FORMULA" ]; then
  FORMULA_STACK_SCRIPT=$(python3 -c "
import sys, tomllib
with open(sys.argv[1], 'rb') as f:
    d = tomllib.load(f)
print(d.get('stack_script', ''))
" "$ACTIVE_FORMULA" 2>/dev/null || echo "")

  _tm=$(python3 -c "
import sys, tomllib
with open(sys.argv[1], 'rb') as f:
    d = tomllib.load(f)
print(d.get('timeout_minutes', '${REPRODUCE_TIMEOUT}'))
" "$ACTIVE_FORMULA" 2>/dev/null || echo "${REPRODUCE_TIMEOUT}")
  FORMULA_TIMEOUT_MINUTES="$_tm"
fi

log "Formula stack_script: '${FORMULA_STACK_SCRIPT}'"
log "Formula timeout: ${FORMULA_TIMEOUT_MINUTES}m"

# ---------------------------------------------------------------------------
# Fetch issue details for repro steps
# ---------------------------------------------------------------------------
log "Fetching issue #${ISSUE_NUMBER} from ${FORGE_API}..."
ISSUE_JSON=$(curl -sf \
  -H "Authorization: token ${FORGE_TOKEN}" \
  "${FORGE_API}/issues/${ISSUE_NUMBER}" 2>/dev/null) || {
  log "ERROR: failed to fetch issue #${ISSUE_NUMBER}"
  exit 1
}

ISSUE_TITLE=$(echo "$ISSUE_JSON" | jq -r '.title // "unknown"')
ISSUE_BODY=$(echo "$ISSUE_JSON" | jq -r '.body // ""')

log "Issue: ${ISSUE_TITLE}"

# ---------------------------------------------------------------------------
# Acquire stack lock
# ---------------------------------------------------------------------------
log "Acquiring stack lock for project ${PROJECT_NAME}..."
stack_lock_acquire "$LOCK_HOLDER" "$PROJECT_NAME" 900
log "Stack lock acquired."

# ---------------------------------------------------------------------------
# Start heartbeat in background (every 2 minutes)
# ---------------------------------------------------------------------------
heartbeat_loop() {
  while true; do
    sleep 120
    stack_lock_heartbeat "$LOCK_HOLDER" "$PROJECT_NAME" 2>/dev/null || true
  done
}
heartbeat_loop &
HEARTBEAT_PID=$!

# ---------------------------------------------------------------------------
# Debug branch cleanup trap (for triage-agent throwaway branches)
# ---------------------------------------------------------------------------
DEBUG_BRANCH="triage-debug-${ISSUE_NUMBER}"

# Combined EXIT trap: heartbeat kill + stack lock release + debug branch cleanup
trap 'kill "$HEARTBEAT_PID" 2>/dev/null || true
  stack_lock_release "$PROJECT_NAME" "$LOCK_HOLDER" || true
  git -C "$PROJECT_REPO_ROOT" checkout "$PRIMARY_BRANCH" 2>/dev/null || true
  git -C "$PROJECT_REPO_ROOT" branch -D "$DEBUG_BRANCH" 2>/dev/null || true
  log "Cleanup completed (trap)"' EXIT

# ---------------------------------------------------------------------------
# Boot the project stack if formula declares stack_script
# ---------------------------------------------------------------------------
if [ -n "$FORMULA_STACK_SCRIPT" ] && [ -d "$PROJECT_REPO_ROOT" ]; then
  log "Running stack_script: ${FORMULA_STACK_SCRIPT}"
  # Run in project repo root; script path is relative to project repo.
  # Read stack_script into array to allow arguments (e.g. "scripts/dev.sh restart --full").
  read -ra _stack_cmd <<< "$FORMULA_STACK_SCRIPT"
  (cd "$PROJECT_REPO_ROOT" && bash "${_stack_cmd[@]}") || {
    log "WARNING: stack_script exited non-zero — continuing anyway"
  }
  # Give the stack a moment to stabilise
  sleep 5
elif [ -n "$FORMULA_STACK_SCRIPT" ]; then
  log "WARNING: PROJECT_REPO_ROOT not found at ${PROJECT_REPO_ROOT} — skipping stack_script"
fi

# ---------------------------------------------------------------------------
# Build Claude prompt based on agent type
# ---------------------------------------------------------------------------
TIMESTAMP=$(date -u '+%Y%m%d-%H%M%S')
SCREENSHOT_PREFIX="${SCREENSHOT_DIR}/issue-${ISSUE_NUMBER}-${TIMESTAMP}"

if [ "$AGENT_TYPE" = "triage" ]; then
  # Triage-agent prompt: deep root cause analysis after reproduce-agent findings
  CLAUDE_PROMPT=$(cat <<PROMPT
You are the triage-agent. Your task is to perform deep root cause analysis on issue #${ISSUE_NUMBER} after the reproduce-agent has confirmed the bug.

## Issue title
${ISSUE_TITLE}

## Issue body
${ISSUE_BODY}

## Your task — 6-step triage workflow

You have a defined 6-step workflow to follow. Budget your turns: ~70% on tracing, ~30% on instrumentation.

### Step 1: Read reproduce-agent findings
Before doing anything else, parse all prior evidence from the issue comments.

1. Fetch the issue body and all comments:
     curl -sf -H "Authorization: token \${FORGE_TOKEN}" \
       "\${FORGE_API}/issues/\${ISSUE_NUMBER}" | jq -r '.body'
     curl -sf -H "Authorization: token \${FORGE_TOKEN}" \
       "\${FORGE_API}/issues/\${ISSUE_NUMBER}/comments" | jq -r '.[].body'

2. Identify the reproduce-agent comment (look for sections like
   "Reproduction steps", "Logs examined", "What was tried").

3. Extract and note:
   - The exact symptom (error message, unexpected value, visual regression)
   - Steps that reliably trigger the bug
   - Log lines or API responses already captured
   - Any hypotheses the reproduce-agent already ruled out

Do NOT repeat work the reproduce-agent already did. Your job starts where
theirs ended. If no reproduce-agent comment is found, note it and proceed
with fresh investigation using the issue body only.

### Step 2: Trace data flow from symptom to source
Systematically follow the symptom backwards through each layer of the stack.

Generic layer traversal: UI → API → backend → data store

For each layer boundary:
  1. What does the upstream layer send?
  2. What does the downstream layer expect?
  3. Is there a mismatch? If yes — is this the root cause or a symptom?

Tracing checklist:
  a. Start at the layer closest to the visible symptom.
  b. Read the relevant source files — do not guess data shapes.
  c. Cross-reference API contracts: compare what the code sends vs what it
     should send according to schemas, type definitions, or documentation.
  d. Check recent git history on suspicious files:
       git log --oneline -20 -- <file>
  e. Search for related issues or TODOs in the code:
       grep -r "TODO\|FIXME\|HACK" -- <relevant directory>

Capture for each layer:
  - The data shape flowing in and out (field names, types, nullability)
  - Whether the layer's behavior matches its documented contract
  - Any discrepancy found

If a clear root cause becomes obvious during tracing, note it and continue
checking whether additional causes exist downstream.

### Step 3: Add debug instrumentation on a throwaway branch
Use ~30% of your total turn budget here. Only instrument after tracing has
identified the most likely failure points — do not instrument blindly.

1. Create a throwaway debug branch (NEVER commit this to main):
     cd "\$PROJECT_REPO_ROOT"
     git checkout -b debug/triage-\${ISSUE_NUMBER}

2. Add targeted logging at the layer boundaries identified during tracing:
   - Console.log / structured log statements around the suspicious code path
   - Log the actual values flowing through: inputs, outputs, intermediate state
   - Add verbose mode flags if the stack supports them
   - Keep instrumentation minimal — only what confirms or refutes the hypothesis

3. Restart the stack using the configured script (if set):
     \${stack_script:-"# No stack_script configured — restart manually or connect to staging"}

4. Re-run the reproduction steps from the reproduce-agent findings.

5. Observe and capture new output:
   - Paste relevant log lines into your working notes
   - Note whether the observed values match or contradict the hypothesis

6. If the first instrumentation pass is inconclusive, iterate:
   - Narrow the scope to the next most suspicious boundary
   - Re-instrument, restart, re-run
   - Maximum 2-3 instrumentation rounds before declaring inconclusive

Do NOT push the debug branch. It will be deleted in the cleanup step.

### Step 4: Decompose root causes into backlog issues
After tracing and instrumentation, articulate each distinct root cause.

For each root cause found:

1. Determine the relationship to other causes:
   - Layered (one causes another) → use Depends-on in the issue body
   - Independent (separate code paths fail independently) → use Related

2. Create a backlog issue for each root cause:
     curl -sf -X POST "\${FORGE_API}/issues" \\
       -H "Authorization: token \${FORGE_TOKEN}" \\
       -H "Content-Type: application/json" \\
       -d '{
         "title": "fix: <specific description of root cause N>",
         "body": "## Root cause\\n<exact code path, file:line>\\n\\n## Fix suggestion\\n<recommended approach>\\n\\n## Context\\nDecomposed from #\${ISSUE_NUMBER} (cause N of M)\\n\\n## Dependencies\\n<#X if this depends on another cause being fixed first>",
         "labels": [{"name": "backlog"}]
       }'

3. Note the newly created issue numbers.

If only one root cause is found, still create a single backlog issue with
the specific code location and fix suggestion.

If the investigation is inconclusive (no clear root cause found), skip this
step and proceed directly to link-back with the inconclusive outcome.

### Step 5: Update original issue and relabel
Post a summary comment on the original issue and update its labels.

#### If root causes were found (conclusive):

Post a comment:
  "## Triage findings

  Found N root cause(s):
  - #X — <one-line description> (cause 1 of N)
  - #Y — <one-line description> (cause 2 of N, depends on #X)

  Data flow traced: <layer where the bug originates>
  Instrumentation: <key log output that confirmed the cause>

  Next step: backlog issues above will be implemented in dependency order."

Then swap labels:
  - Remove: in-triage
  - Add: in-progress

#### If investigation was inconclusive (turn budget exhausted):

Post a comment:
  "## Triage — inconclusive

  Traced: <layers checked>
  Tried: <instrumentation attempts and what they showed>
  Hypothesis: <best guess at cause, if any>

  No definitive root cause identified. Leaving in-triage for supervisor
  to handle as a stale triage session."

Do NOT relabel. Leave in-triage. The supervisor monitors stale triage
sessions and will escalate or reassign.

### Step 6: Delete throwaway debug branch
Always delete the debug branch, even if the investigation was inconclusive.

1. Switch back to the main branch:
     cd "\$PROJECT_REPO_ROOT"
     git checkout "\$PRIMARY_BRANCH"

2. Delete the local debug branch:
     git branch -D debug/triage-\${ISSUE_NUMBER}

3. Confirm no remote was pushed (if accidentally pushed, delete it too):
     git push origin --delete debug/triage-\${ISSUE_NUMBER} 2>/dev/null || true

4. Verify the worktree is clean:
     git status
     git worktree list

A clean repo is a prerequisite for the next dev-agent run. Never leave
debug branches behind — they accumulate and pollute the branch list.

## Notes
- The application is accessible at localhost (network_mode: host)
- Budget: 70% tracing data flow, 30% instrumented re-runs
- Timeout: \${FORMULA_TIMEOUT_MINUTES} minutes total (or until turn limit)
- Stack lock is held for the full run
- If stack_script is empty, connect to existing staging environment

Begin now.
PROMPT
  )
else
  # Reproduce-agent prompt: reproduce the bug and report findings
  CLAUDE_PROMPT=$(cat <<PROMPT
You are the reproduce-agent. Your task is to reproduce the bug described in issue #${ISSUE_NUMBER} and report your findings.

## Issue title
${ISSUE_TITLE}

## Issue body
${ISSUE_BODY}

## Your task — PRIMARY GOAL FIRST

This agent has ONE primary job and ONE secondary, minor job. Follow this ORDER:

### PRIMARY: Can the bug be reproduced? (60% of your turns)

This is the EXIT GATE. Answer YES or NO before doing anything else.

1. Read the issue, understand the claimed behavior
2. Navigate the app via Playwright, follow the reported steps
3. Observe: does the symptom match the report?
4. Take screenshots as evidence (save to: ${SCREENSHOT_PREFIX}-step-N.png)
5. Conclude: **reproduced** or **cannot reproduce**

If **cannot reproduce** → Write OUTCOME=cannot-reproduce, write findings, DONE. EXIT.
If **inconclusive** (timeout, env issues, app not reachable) → Write OUTCOME=needs-triage with reason, write findings, DONE. EXIT.
If **reproduced** → Continue to secondary check.

### SECONDARY (minor): Is the cause obvious? (40% of your turns, only if reproduced)

Only after reproduction is confirmed. Quick check only — do not go deep.

1. Check container logs: docker compose -f ${PROJECT_REPO_ROOT}/docker-compose.yml logs --tail=200
   Look for: stack traces, error messages, wrong addresses, missing config, parse errors
2. Check browser console output captured during reproduction
3. If the cause JUMPS OUT (clear error, obvious misconfiguration) → note it

If **obvious cause** → Write OUTCOME=reproduced and ROOT_CAUSE=<one-line summary>
If **not obvious** → Write OUTCOME=reproduced (no ROOT_CAUSE line)

## Output files

1. **Findings report** — Write to: /tmp/reproduce-findings-${ISSUE_NUMBER}.md
   Include:
   - Steps you followed
   - What you observed (screenshots referenced by path)
   - Log excerpts (truncated to relevant lines)
   - OUTCOME line: OUTCOME=reproduced OR OUTCOME=cannot-reproduce OR OUTCOME=needs-triage
   - ROOT_CAUSE line (ONLY if cause is obvious): ROOT_CAUSE=<one-line summary>

2. **Outcome file** — Write to: /tmp/reproduce-outcome-${ISSUE_NUMBER}.txt
   Write ONLY the outcome word: reproduced OR cannot-reproduce OR needs-triage

## Notes
- The application is accessible at localhost (network_mode: host)
- Take screenshots liberally — they are evidence
- If the app is not running or not reachable, write outcome: cannot-reproduce with reason "stack not reachable"
- Timeout: ${FORMULA_TIMEOUT_MINUTES} minutes total
- EXIT gates are enforced — do not continue to secondary check if primary result is NO or inconclusive

Begin now.
PROMPT
  )
fi

# ---------------------------------------------------------------------------
# Run Claude with Playwright MCP
# ---------------------------------------------------------------------------
if [ "$AGENT_TYPE" = "triage" ]; then
  log "Starting triage-agent session (timeout: ${FORMULA_TIMEOUT_MINUTES}m)..."
else
  log "Starting Claude reproduction session (timeout: ${FORMULA_TIMEOUT_MINUTES}m)..."
fi

CLAUDE_EXIT=0
timeout "$(( FORMULA_TIMEOUT_MINUTES * 60 ))" \
  claude -p "$CLAUDE_PROMPT" \
    --mcp-server playwright \
    --output-format text \
    --max-turns 40 \
  > "/tmp/reproduce-claude-output-${ISSUE_NUMBER}.txt" 2>&1 || CLAUDE_EXIT=$?

if [ $CLAUDE_EXIT -eq 124 ]; then
  log "WARNING: Claude session timed out after ${FORMULA_TIMEOUT_MINUTES}m"
fi

# ---------------------------------------------------------------------------
# Triage post-processing: enforce backlog label on created issues
# ---------------------------------------------------------------------------
# The triage agent may create sub-issues for root causes. Ensure they have
# the backlog label so dev-agent picks them up. Parse Claude output for
# newly created issue numbers and add the backlog label.
if [ "$AGENT_TYPE" = "triage" ]; then
  log "Triage post-processing: checking for created issues to label..."

  # Extract issue numbers from Claude output that were created during triage.
  # Match unambiguous creation patterns: "Created issue #123", "Created #123",
  # or "harb#123". Do NOT match bare #123 which would capture references in
  # the triage summary (e.g., "Decomposed from #5", "cause 1 of 2", etc.).
  CREATED_ISSUES=$(grep -oE '(Created|created) issue #[0-9]+|(Created|created) #[0-9]+|harb#[0-9]+' \
    "/tmp/reproduce-claude-output-${ISSUE_NUMBER}.txt" 2>/dev/null | \
    grep -oE '[0-9]+' | sort -u | head -10)

  if [ -n "$CREATED_ISSUES" ]; then
    # Get backlog label ID
    BACKLOG_ID=$(_label_id "backlog" "#fef2c0")

    if [ -z "$BACKLOG_ID" ]; then
      log "WARNING: could not get backlog label ID — skipping label enforcement"
    else
      for issue_num in $CREATED_ISSUES; do
        _add_label "$issue_num" "$BACKLOG_ID"
        log "Added backlog label to created issue #${issue_num}"
      done
    fi
  fi
fi

# ---------------------------------------------------------------------------
# Read outcome
# ---------------------------------------------------------------------------
OUTCOME="needs-triage"
if [ -f "/tmp/reproduce-outcome-${ISSUE_NUMBER}.txt" ]; then
  _raw=$(tr -d '[:space:]' < "/tmp/reproduce-outcome-${ISSUE_NUMBER}.txt" | tr '[:upper:]' '[:lower:]')
  case "$_raw" in
    reproduced|cannot-reproduce|needs-triage)
      OUTCOME="$_raw"
      ;;
    *)
      log "WARNING: unexpected outcome '${_raw}' — defaulting to needs-triage"
      ;;
  esac
else
  log "WARNING: outcome file not found — defaulting to needs-triage"
fi

log "Outcome: ${OUTCOME}"

# ---------------------------------------------------------------------------
# Read findings
# ---------------------------------------------------------------------------
FINDINGS=""
if [ -f "/tmp/reproduce-findings-${ISSUE_NUMBER}.md" ]; then
  FINDINGS=$(cat "/tmp/reproduce-findings-${ISSUE_NUMBER}.md")
else
  if [ "$AGENT_TYPE" = "triage" ]; then
    FINDINGS="Triage-agent completed but did not write a findings report. Claude output:\n\`\`\`\n$(tail -100 "/tmp/reproduce-claude-output-${ISSUE_NUMBER}.txt" 2>/dev/null || echo '(no output)')\n\`\`\`"
  else
    FINDINGS="Reproduce-agent completed but did not write a findings report. Claude output:\n\`\`\`\n$(tail -100 "/tmp/reproduce-claude-output-${ISSUE_NUMBER}.txt" 2>/dev/null || echo '(no output)')\n\`\`\`"
  fi
fi

# ---------------------------------------------------------------------------
# Collect screenshot paths for comment
# ---------------------------------------------------------------------------
SCREENSHOT_LIST=""
if find "$(dirname "${SCREENSHOT_PREFIX}")" -name "$(basename "${SCREENSHOT_PREFIX}")-*.png" -maxdepth 1 2>/dev/null | grep -q .; then
  SCREENSHOT_LIST="\n\n**Screenshots taken:**\n"
  for f in "${SCREENSHOT_PREFIX}"-*.png; do
    SCREENSHOT_LIST="${SCREENSHOT_LIST}- \`$(basename "$f")\`\n"
  done
fi

# ---------------------------------------------------------------------------
# Label helpers
# ---------------------------------------------------------------------------
_label_id() {
  local name="$1" color="$2"
  local id
  id=$(curl -sf \
    -H "Authorization: token ${FORGE_TOKEN}" \
    "${FORGE_API}/labels" 2>/dev/null \
    | jq -r --arg n "$name" '.[] | select(.name == $n) | .id' 2>/dev/null || echo "")
  if [ -z "$id" ]; then
    id=$(curl -sf -X POST \
      -H "Authorization: token ${FORGE_TOKEN}" \
      -H "Content-Type: application/json" \
      "${FORGE_API}/labels" \
      -d "{\"name\":\"${name}\",\"color\":\"${color}\"}" 2>/dev/null \
      | jq -r '.id // empty' 2>/dev/null || echo "")
  fi
  echo "$id"
}

_add_label() {
  local issue="$1" label_id="$2"
  [ -z "$label_id" ] && return 0
  curl -sf -X POST \
    -H "Authorization: token ${FORGE_TOKEN}" \
    -H "Content-Type: application/json" \
    "${FORGE_API}/issues/${issue}/labels" \
    -d "{\"labels\":[${label_id}]}" >/dev/null 2>&1 || true
}

_remove_label() {
  local issue="$1" label_id="$2"
  [ -z "$label_id" ] && return 0
  curl -sf -X DELETE \
    -H "Authorization: token ${FORGE_TOKEN}" \
    "${FORGE_API}/issues/${issue}/labels/${label_id}" >/dev/null 2>&1 || true
}

_post_comment() {
  local issue="$1" body="$2"
  curl -sf -X POST \
    -H "Authorization: token ${FORGE_TOKEN}" \
    -H "Content-Type: application/json" \
    "${FORGE_API}/issues/${issue}/comments" \
    -d "$(jq -nc --arg b "$body" '{body:$b}')" >/dev/null 2>&1 || true
}

# ---------------------------------------------------------------------------
# Apply labels and post findings
# ---------------------------------------------------------------------------

# Exit gate logic:
#   1. Can I reproduce it? → NO → rejected/blocked → EXIT
#                          → YES → continue
#   2. Is the cause obvious? → YES → backlog issue for dev → EXIT
#                            → NO → in-triage → EXIT
#
# Label combinations (on the ORIGINAL issue):
#   - Reproduced + obvious cause: reproduced (custom status) → backlog issue created
#   - Reproduced + cause unclear: in-triage → Triage-agent
#   - Cannot reproduce: rejected → Human review
#   - Inconclusive (timeout/error): blocked → Gardener/human
#
# The newly created fix issue (when cause is obvious) gets backlog label
# so dev-poll will pick it up for implementation.

# Remove bug-report label (we are resolving it)
BUG_REPORT_ID=$(_label_id "bug-report" "#e4e669")
_remove_label "$ISSUE_NUMBER" "$BUG_REPORT_ID"

# Determine agent name for comments (based on AGENT_TYPE set at script start)
if [ "$AGENT_TYPE" = "triage" ]; then
  AGENT_NAME="Triage-agent"
else
  AGENT_NAME="Reproduce-agent"
fi

# Determine outcome and apply appropriate labels
LABEL_NAME=""
LABEL_COLOR=""
COMMENT_HEADER=""
CREATE_BACKLOG_ISSUE=false

case "$OUTCOME" in
  reproduced)
    # Check if root cause is obvious (ROOT_CAUSE is set and non-trivial)
    ROOT_CAUSE=$(grep -m1 "^ROOT_CAUSE=" "/tmp/reproduce-findings-${ISSUE_NUMBER}.md" 2>/dev/null \
      | sed 's/^ROOT_CAUSE=//' || echo "")
    if [ -n "$ROOT_CAUSE" ] && [ "$ROOT_CAUSE" != "See findings on issue #${ISSUE_NUMBER}" ]; then
      # Obvious cause → add reproduced status label, create backlog issue for dev-agent
      LABEL_NAME="reproduced"
      LABEL_COLOR="#0075ca"
      COMMENT_HEADER="## ${AGENT_NAME}: **Reproduced with obvious cause** :white_check_mark: :zap:"
      CREATE_BACKLOG_ISSUE=true
    else
      # Cause unclear → in-triage → Triage-agent
      LABEL_NAME="in-triage"
      LABEL_COLOR="#d93f0b"
      COMMENT_HEADER="## ${AGENT_NAME}: **Reproduced, cause unclear** :white_check_mark: :mag:"
    fi
    ;;

  cannot-reproduce)
    # Cannot reproduce → rejected → Human review
    LABEL_NAME="rejected"
    LABEL_COLOR="#e4e669"
    COMMENT_HEADER="## ${AGENT_NAME}: **Cannot reproduce** :x:"
    ;;

  needs-triage)
    # Inconclusive (timeout, env issues) → blocked → Gardener/human
    LABEL_NAME="blocked"
    LABEL_COLOR="#e11d48"
    COMMENT_HEADER="## ${AGENT_NAME}: **Inconclusive, blocked** :construction:"
    ;;
esac

# Apply the outcome label
OUTCOME_LABEL_ID=$(_label_id "$LABEL_NAME" "$LABEL_COLOR")
_add_label "$ISSUE_NUMBER" "$OUTCOME_LABEL_ID"
log "Applied label '${LABEL_NAME}' to issue #${ISSUE_NUMBER}"

# If obvious cause, create backlog issue for dev-agent
if [ "$CREATE_BACKLOG_ISSUE" = true ]; then
  BACKLOG_BODY="## Summary
Bug reproduced from issue #${ISSUE_NUMBER}: ${ISSUE_TITLE}

Root cause (quick log analysis): ${ROOT_CAUSE}

## Dependencies
- #${ISSUE_NUMBER}

## Affected files
- (see findings on issue #${ISSUE_NUMBER})

## Acceptance criteria
- [ ] Root cause confirmed and fixed
- [ ] Issue #${ISSUE_NUMBER} no longer reproducible"

  log "Creating backlog issue for reproduced bug with obvious cause..."
  curl -sf -X POST \
    -H "Authorization: token ${FORGE_TOKEN}" \
    -H "Content-Type: application/json" \
    "${FORGE_API}/issues" \
    -d "$(jq -nc \
      --arg t "fix: $(echo "$ISSUE_TITLE" | sed 's/^bug:/fix:/' | sed 's/^feat:/fix:/')" \
      --arg b "$BACKLOG_BODY" \
      '{title:$t, body:$b, labels:[{"name":"backlog"}]}' 2>/dev/null)" >/dev/null 2>&1 || \
    log "WARNING: failed to create backlog issue"
fi

COMMENT_BODY="${COMMENT_HEADER}

${FINDINGS}${SCREENSHOT_LIST}

---
*${AGENT_NAME} run at $(date -u '+%Y-%m-%d %H:%M:%S UTC') — project: ${PROJECT_NAME}*"

_post_comment "$ISSUE_NUMBER" "$COMMENT_BODY"
log "Posted findings to issue #${ISSUE_NUMBER}"

log "${AGENT_NAME} done. Outcome: ${OUTCOME}"
