#!/usr/bin/env bash
# =============================================================================
# prediction-agent.sh — Per-project LLM prediction agent
#
# Reads structured evidence from the project's evidence/ directory plus
# secondary Codeberg signals, then asks Claude to identify patterns and
# file up to 5 prediction/unreviewed issues for the planner to triage.
#
# The predictor is the goblin — it sees patterns and shouts about them.
# The planner is the adult — it triages every prediction before acting.
# The predictor MUST NOT emit feature work directly.
#
# Signal sources:
#   evidence/red-team/    — attack results, floor status, vulnerability trends
#   evidence/evolution/   — fitness scores, champion improvements
#   evidence/user-test/   — persona journey completion, friction points
#   evidence/holdout/     — scenario pass rates, quality gate history
#   evidence/resources/   — CPU, RAM, disk, container utilization
#   evidence/protocol/    — on-chain metrics from Ponder
#
# Secondary:
#   Codeberg activity (new issues, merged PRs), system resource snapshot
#
# Usage: prediction-agent.sh [project-toml]
# Called by: prediction-poll.sh
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
FACTORY_ROOT="$(dirname "$SCRIPT_DIR")"

export PROJECT_TOML="${1:-}"
# shellcheck source=../lib/env.sh
source "$FACTORY_ROOT/lib/env.sh"

LOG_FILE="$SCRIPT_DIR/prediction.log"
# env.sh already exports CLAUDE_TIMEOUT="${CLAUDE_TIMEOUT:-7200}"; inherit that default
EVIDENCE_DIR="${PROJECT_REPO_ROOT}/evidence"

log() { echo "[$(date -u +%Y-%m-%dT%H:%M:%S)Z] $*" >> "$LOG_FILE"; }

log "--- prediction-agent start (project: ${PROJECT_NAME}) ---"

# ── Helpers ───────────────────────────────────────────────────────────────

# Find the most recent JSON file in a directory (files named YYYY-MM-DD.json
# sort correctly in alphabetical order).
latest_json() { find "$1" -maxdepth 1 -name '*.json' 2>/dev/null | sort | tail -1; }
prev_json()   { find "$1" -maxdepth 1 -name '*.json' 2>/dev/null | sort | tail -2 | head -1; }

# ── Scan evidence/ directory ──────────────────────────────────────────────
EVIDENCE_SUMMARY=""
for subdir in red-team evolution user-test holdout resources protocol; do
  subdir_path="${EVIDENCE_DIR}/${subdir}"

  if [ ! -d "$subdir_path" ]; then
    EVIDENCE_SUMMARY="${EVIDENCE_SUMMARY}
=== evidence/${subdir} ===
(no data — directory not yet created)"
    continue
  fi

  latest=$(latest_json "$subdir_path")
  if [ -z "$latest" ]; then
    EVIDENCE_SUMMARY="${EVIDENCE_SUMMARY}
=== evidence/${subdir} ===
(no data — no JSON files found)"
    continue
  fi

  latest_name=$(basename "$latest")
  # Derive age from the date in the filename (YYYY-MM-DD.json) — more reliable
  # than mtime, which changes when files are copied or synced.
  file_date=$(basename "$latest" .json)
  file_ts=$(date -d "$file_date" +%s 2>/dev/null || date -r "$latest" +%s)
  now_ts=$(date +%s)
  age_hours=$(( (now_ts - file_ts) / 3600 ))
  content=$(head -c 3000 "$latest" 2>/dev/null || echo "{}")

  prev=$(prev_json "$subdir_path")
  prev_section=""
  if [ -n "$prev" ] && [ "$prev" != "$latest" ]; then
    prev_name=$(basename "$prev")
    prev_content=$(head -c 2000 "$prev" 2>/dev/null || echo "{}")
    prev_section="
  previous: ${prev_name}
  previous_content: ${prev_content}"
  fi

  EVIDENCE_SUMMARY="${EVIDENCE_SUMMARY}
=== evidence/${subdir} ===
  latest: ${latest_name} (age: ${age_hours}h, path: ${latest})
  content: ${content}${prev_section}"
done

# ── Secondary signals — Codeberg activity (last 24h) ─────────────────────
SINCE_ISO=$(date -u -d '24 hours ago' +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || true)
if [ -z "$SINCE_ISO" ]; then
  log "WARN: date -d '24 hours ago' failed (non-GNU date?) — skipping Codeberg activity"
fi
RECENT_ISSUES=""
RECENT_PRS=""
if [ -n "$SINCE_ISO" ]; then
  RECENT_ISSUES=$(codeberg_api GET "/issues?state=open&type=issues&limit=20&sort=newest" 2>/dev/null | \
    jq -r --arg since "$SINCE_ISO" \
    '.[] | select(.created_at >= $since) | "  #\(.number) [\(.labels | map(.name) | join(","))] \(.title)"' \
    2>/dev/null || true)
  # Use state=closed to capture recently-merged PRs — merged activity is the
  # key signal (e.g. new red-team PR merged since last evolution run).
  RECENT_PRS=$(codeberg_api GET "/pulls?state=closed&limit=20&sort=newest" 2>/dev/null | \
    jq -r --arg since "$SINCE_ISO" \
    '.[] | select(.merged_at != null and .merged_at >= $since) | "  #\(.number) \(.title) (merged \(.merged_at[:10]))"' \
    2>/dev/null || true)
fi

# ── Already-open predictions (avoid duplicates) ───────────────────────────
OPEN_PREDICTIONS=$(codeberg_api GET "/issues?state=open&type=issues&labels=prediction%2Funreviewed&limit=50" 2>/dev/null | \
  jq -r '.[] | "  #\(.number) \(.title)"' 2>/dev/null || true)

# ── System resource snapshot ──────────────────────────────────────────────
AVAIL_MB=$(free -m | awk '/Mem:/{print $7}' 2>/dev/null || echo "unknown")
DISK_PCT=$(df -h / | awk 'NR==2{print $5}' | tr -d '%' 2>/dev/null || echo "unknown")
LOAD_AVG=$(cut -d' ' -f1-3 /proc/loadavg 2>/dev/null || echo "unknown")
ACTIVE_SESSIONS=$(tmux list-sessions 2>/dev/null | \
  grep -cE "^(dev|action|gardener|review)-" || echo "0")

# ── Build prompt ──────────────────────────────────────────────────────────
PROMPT="You are the prediction agent (goblin) for ${CODEBERG_REPO}.

Your role: spot patterns in evidence and signal them as prediction issues.
The planner (adult) will triage every prediction before acting.
You MUST NOT emit feature work or implementation issues — only predictions
about evidence state, metric trends, and system conditions.

## Evidence from evidence/ directory
${EVIDENCE_SUMMARY}

## System resource snapshot (right now)
Available RAM: ${AVAIL_MB}MB
Disk used: ${DISK_PCT}%
Load avg (1/5/15 min): ${LOAD_AVG}
Active agent sessions (tmux): ${ACTIVE_SESSIONS}

## Recent Codeberg activity (last 24h)
New issues:
${RECENT_ISSUES:-  (none)}

Recently merged PRs (last 24h):
${RECENT_PRS:-  (none)}

## Already-open predictions (do NOT duplicate these)
${OPEN_PREDICTIONS:-  (none)}

## What to look for

**Staleness** — Evidence older than its expected refresh interval:
- red-team: stale after 7 days
- evolution: stale after 7 days
- user-test: stale after 14 days
- holdout: stale after 7 days
- resources: stale after 1 day
- protocol: stale after 1 day
- any directory missing entirely: flag as critical gap

**Regression** — Metrics worse in latest vs previous run:
- Decreased: fitness score, pass rate, conversion, floor price
- Increased: error count, risk score, ETH extracted by attacker
- Only flag if change is meaningful (>5% relative, or clearly significant)

**Opportunity** — Conditions that make a process worth running now:
- Box is relatively idle (RAM>2000MB, load<2.0, no active agent sessions)
  AND evidence is stale — good time to run evolution or red-team
- New attack vectors in red-team since last evolution run → evolution scores stale

**Risk** — Conditions that suggest deferring expensive work:
- RAM<1500MB or disk>85% or load>3.0 → defer evolution/red-team
- Active dev session in progress on related work

## Output format

For each prediction, output a JSON object on its own line (no array wrapper,
no markdown fences):

{\"title\": \"...\", \"signal_source\": \"...\", \"confidence\": \"high|medium|low\", \"suggested_action\": \"...\", \"body\": \"...\"}

Fields:
- title: Short declarative statement of what you observed. Not an action.
- signal_source: Which evidence file or signal triggered this
  (e.g. \"evidence/evolution/2024-01-15.json\", \"system resources\",
  \"evidence/red-team/ missing\")
- confidence: high (clear numerical evidence), medium (trend/pattern),
  low (inferred or absent data but important to flag)
- suggested_action: Concrete next step for the planner —
  \"run formula X\", \"file issue for Y\", \"escalate to human\",
  \"monitor for N days\", \"run process X\"
- body: 2-4 sentences. What changed or is missing, why it matters,
  what the planner should consider doing. Be specific: name the file,
  metric, and value.

## Rules
- Max 5 predictions total
- Do NOT predict feature work — only evidence/metric/system observations
- Do NOT duplicate existing open predictions (listed above)
- Do NOT predict things you cannot support with the evidence provided
- Prefer high-confidence predictions; emit low-confidence only when the
  signal is important (e.g. missing critical evidence)
- Be specific: name the file, the metric, the value

If you see no meaningful patterns, output exactly: NO_PREDICTIONS

Output ONLY the JSON lines (or NO_PREDICTIONS) — no preamble, no markdown."

# ── Invoke Claude (one-shot) ──────────────────────────────────────────────
log "invoking claude -p for ${PROJECT_NAME} predictions"
CLAUDE_OUTPUT=$(timeout "$CLAUDE_TIMEOUT" claude -p "$PROMPT" \
  --model sonnet \
  2>/dev/null) || {
  EXIT_CODE=$?
  log "ERROR: claude exited with code $EXIT_CODE"
  exit 1
}

log "claude finished ($(printf '%s' "$CLAUDE_OUTPUT" | wc -c) bytes)"

if printf '%s' "$CLAUDE_OUTPUT" | grep -qxF "NO_PREDICTIONS"; then
  log "no predictions — evidence looks healthy for ${PROJECT_NAME}"
  log "--- prediction-agent done ---"
  exit 0
fi

# ── Look up prediction/unreviewed label ───────────────────────────────────
PREDICTION_LABEL_ID=$(codeberg_api GET "/labels" 2>/dev/null | \
  jq -r '.[] | select(.name == "prediction/unreviewed") | .id' 2>/dev/null || true)
if [ -z "$PREDICTION_LABEL_ID" ]; then
  log "WARN: 'prediction/unreviewed' label not found — issues created without label (see #141)"
fi

# ── Create prediction issues ──────────────────────────────────────────────
CREATED=0
while IFS= read -r line; do
  [ -z "$line" ] && continue
  # Skip non-JSON lines
  printf '%s' "$line" | jq -e . >/dev/null 2>&1 || continue

  TITLE=$(printf '%s' "$line"  | jq -r '.title')
  SIGNAL=$(printf '%s' "$line" | jq -r '.signal_source // "unknown"')
  CONFIDENCE=$(printf '%s' "$line" | jq -r '.confidence // "medium"')
  ACTION=$(printf '%s' "$line" | jq -r '.suggested_action // ""')
  BODY_TEXT=$(printf '%s' "$line" | jq -r '.body')

  FULL_BODY="${BODY_TEXT}

---
**Signal source:** ${SIGNAL}
**Confidence:** ${CONFIDENCE}
**Suggested action:** ${ACTION}"

  CREATE_PAYLOAD=$(jq -nc --arg t "$TITLE" --arg b "$FULL_BODY" \
    '{title: $t, body: $b}')

  if [ -n "$PREDICTION_LABEL_ID" ]; then
    CREATE_PAYLOAD=$(printf '%s' "$CREATE_PAYLOAD" | \
      jq --argjson lid "$PREDICTION_LABEL_ID" '.labels = [$lid]')
  fi

  RESULT=$(codeberg_api POST "/issues" -d "$CREATE_PAYLOAD" 2>/dev/null || true)
  ISSUE_NUM=$(printf '%s' "$RESULT" | jq -r '.number // "?"' 2>/dev/null || echo "?")

  log "Created prediction #${ISSUE_NUM} [${CONFIDENCE}]: ${TITLE}"
  matrix_send "predictor" "🔮 Prediction #${ISSUE_NUM} [${CONFIDENCE}]: ${TITLE} — ${ACTION}" \
    2>/dev/null || true

  CREATED=$((CREATED + 1))
  [ "$CREATED" -ge 5 ] && break
done <<< "$CLAUDE_OUTPUT"

log "--- prediction-agent done (created ${CREATED} predictions for ${PROJECT_NAME}) ---"
