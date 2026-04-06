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
REPRODUCE_FORMULA="${DISINTO_DIR}/formulas/reproduce.toml"
REPRODUCE_TIMEOUT="${REPRODUCE_TIMEOUT_MINUTES:-15}"
LOGFILE="/home/agent/data/logs/reproduce.log"
SCREENSHOT_DIR="/home/agent/data/screenshots"

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------
log() {
  printf '[%s] reproduce: %s\n' "$(date -u '+%Y-%m-%d %H:%M:%S UTC')" "$*" | tee -a "$LOGFILE"
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

log "Starting reproduce-agent for issue #${ISSUE_NUMBER} (project: ${PROJECT_NAME})"

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

if [ -f "$REPRODUCE_FORMULA" ]; then
  FORMULA_STACK_SCRIPT=$(python3 -c "
import sys, tomllib
with open(sys.argv[1], 'rb') as f:
    d = tomllib.load(f)
print(d.get('stack_script', ''))
" "$REPRODUCE_FORMULA" 2>/dev/null || echo "")

  _tm=$(python3 -c "
import sys, tomllib
with open(sys.argv[1], 'rb') as f:
    d = tomllib.load(f)
print(d.get('timeout_minutes', '${REPRODUCE_TIMEOUT}'))
" "$REPRODUCE_FORMULA" 2>/dev/null || echo "${REPRODUCE_TIMEOUT}")
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
trap 'stack_lock_release "$PROJECT_NAME" "$LOCK_HOLDER"; log "Stack lock released (trap)"' EXIT
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
trap 'kill "$HEARTBEAT_PID" 2>/dev/null; stack_lock_release "$PROJECT_NAME" "$LOCK_HOLDER"; log "Stack lock released (trap)"' EXIT

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
# Build Claude prompt for reproduction
# ---------------------------------------------------------------------------
TIMESTAMP=$(date -u '+%Y%m%d-%H%M%S')
SCREENSHOT_PREFIX="${SCREENSHOT_DIR}/issue-${ISSUE_NUMBER}-${TIMESTAMP}"

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

# ---------------------------------------------------------------------------
# Run Claude with Playwright MCP
# ---------------------------------------------------------------------------
log "Starting Claude reproduction session (timeout: ${FORMULA_TIMEOUT_MINUTES}m)..."

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
  FINDINGS="Reproduce-agent completed but did not write a findings report. Claude output:\n\`\`\`\n$(tail -100 "/tmp/reproduce-claude-output-${ISSUE_NUMBER}.txt" 2>/dev/null || echo '(no output)')\n\`\`\`"
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
      COMMENT_HEADER="## Reproduce-agent: **Reproduced with obvious cause** :white_check_mark: :zap:"
      CREATE_BACKLOG_ISSUE=true
    else
      # Cause unclear → in-triage → Triage-agent
      LABEL_NAME="in-triage"
      LABEL_COLOR="#d93f0b"
      COMMENT_HEADER="## Reproduce-agent: **Reproduced, cause unclear** :white_check_mark: :mag:"
    fi
    ;;

  cannot-reproduce)
    # Cannot reproduce → rejected → Human review
    LABEL_NAME="rejected"
    LABEL_COLOR="#e4e669"
    COMMENT_HEADER="## Reproduce-agent: **Cannot reproduce** :x:"
    ;;

  needs-triage)
    # Inconclusive (timeout, env issues) → blocked → Gardener/human
    LABEL_NAME="blocked"
    LABEL_COLOR="#e11d48"
    COMMENT_HEADER="## Reproduce-agent: **Inconclusive, blocked** :construction:"
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
*Reproduce-agent run at $(date -u '+%Y-%m-%d %H:%M:%S UTC') — project: ${PROJECT_NAME}*"

_post_comment "$ISSUE_NUMBER" "$COMMENT_BODY"
log "Posted findings to issue #${ISSUE_NUMBER}"

log "Reproduce-agent done. Outcome: ${OUTCOME}"
