#!/usr/bin/env bash
# =============================================================================
# snapshot-agents.sh — agent-activity collector for snapshot daemon
#
# Queries Nomad for opus agent allocations, reads recent logs to detect
# idle/working/stalled state, and merges into state.json under key "agents".
# Invoked by the snapshot-daemon loop each tick.
#
# Environment:
#   NOMAD_ADDR    — Nomad API URL (required)
#   NOMAD_TOKEN   — Nomad ACL token (required)
#   SNAPSHOT_PATH — path to state.json (default /var/lib/disinto/snapshot/state.json)
#   NOMAD_TIMEOUT — per-call timeout in seconds (default 5)
#   LOG_TAIL      — lines to tail per alloc (default 50)
#
# Output shape:
#   {"agents":{"dev-opus":{"state":"working","issue":"#891","since":"...","alloc":"..."},...}}
#
# Detection logic (applied per agent):
#   1. Structured "STATE <state> ts=..." lines take priority if present.
#   2. Otherwise grep natural output:
#      - idle: "no claimable issues" / "sleeping" / "polling"
#      - working: "claimed" / "opened worktree" / "opening PR" / "building"
#      - stalled: no log output in 10+ min
# Cheap: parallelize log reads with background subshells.
# =============================================================================
set -euo pipefail

NOMAD_ADDR="${NOMAD_ADDR:?NOMAD_ADDR is required}"
NOMAD_TOKEN="${NOMAD_TOKEN:?NOMAD_TOKEN is required}"
SNAPSHOT_PATH="${SNAPSHOT_PATH:-/var/lib/disinto/snapshot/state.json}"
NOMAD_TIMEOUT="${NOMAD_TIMEOUT:-5}"
LOG_TAIL="${LOG_TAIL:-50}"

log() {
  printf '[%s] snapshot-agents: %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$*" >&2
}

# ── Temp file tracking ───────────────────────────────────────────────────────

TMPFILES=()

mktemp_safe() {
  local tmp
  tmp="$(mktemp "$@")"
  TMPFILES+=("$tmp")
  printf '%s' "$tmp"
}

cleanup() {
  rm -f "${TMPFILES[@]}" 2>/dev/null || true
}
trap cleanup EXIT

# ── Discover opus agent allocations ──────────────────────────────────────────

# Returns JSON array of {name, alloc_id} objects for opus agent allocations.
# Matches nomad alloc list output for jobs ending in "-opus" (e.g.
# agents-dev-opus, agents-review-opus, agents-supervisor-opus).
discover_opus_allocs() {
  local -a headers=()
  [ -n "${NOMAD_TOKEN:-}" ] && headers+=(-H "X-Nomad-Token: ${NOMAD_TOKEN}")

  local allocs_json
  allocs_json="$(curl -fsS --max-time "${NOMAD_TIMEOUT}" "${headers[@]}" \
    "${NOMAD_ADDR%/}/v1/allocations" 2>/dev/null)" || true

  [ -z "$allocs_json" ] && printf '[]' && return

  # Filter on JobID (alloc Name is "<job>.<group>[<index>]" — never ends in
  # "-opus"); status filter moves into jq so we don't depend on a flag that
  # `nomad alloc list` doesn't accept.
  #
  # Task name is needed for the HTTP logs endpoint. AllocListStub exposes
  # TaskStates (map keyed by task name); fall back to TaskGroup if TaskStates
  # is unavailable for any reason.
  printf '%s' "$allocs_json" | jq -c '
    [ .[]
      | select(. != null)
      | select(.JobID != null and .ID != null)
      | select(.ClientStatus == "running")
      | select(.JobID | test("-opus$"))
      | {
          name: (.JobID | sub("^agents-"; "")),
          alloc_id: .ID,
          task: ((.TaskStates // {} | keys | .[0]) // .TaskGroup // "")
        }
    ]
  ' 2>/dev/null || printf '[]'
}

# ── Fetch recent logs for a single allocation ────────────────────────────────

# Writes stdout log to the given file (stderr discarded).
#
# Uses the Nomad HTTP logs endpoint (/v1/client/fs/logs/<alloc_id>) directly
# rather than the `nomad alloc logs` CLI: PR #845 demonstrated that the
# deployed Nomad 1.9.5 has dropped the legacy -token/-address/-timeout flag
# format on the matching list commands, so we avoid the CLI surface entirely.
#
# The HTTP endpoint is byte-oriented; we over-read a window from the tail and
# then trim to LOG_TAIL lines locally. 512 bytes/line is a conservative upper
# bound for these agents' log format.
fetch_alloc_logs() {
  local alloc_id="$1" task="$2" dest="$3"
  : > "$dest"

  # Without a task name we can't query logs — leave the dest empty so
  # detect_state() falls through to the "stalled" branch.
  [ -z "$task" ] && return 0

  local -a headers=()
  [ -n "${NOMAD_TOKEN:-}" ] && headers+=(-H "X-Nomad-Token: ${NOMAD_TOKEN}")

  local bytes=$((LOG_TAIL * 512))
  [ "$bytes" -lt 8192 ] && bytes=8192

  curl -fsS --max-time "${NOMAD_TIMEOUT}" "${headers[@]}" \
    --get \
    --data-urlencode "task=${task}" \
    --data-urlencode "type=stdout" \
    --data-urlencode "plain=true" \
    --data-urlencode "origin=end" \
    --data-urlencode "offset=${bytes}" \
    "${NOMAD_ADDR%/}/v1/client/fs/logs/${alloc_id}" 2>/dev/null \
    | tail -n "$LOG_TAIL" > "$dest" || true
}

# ── Detect agent state from log content ──────────────────────────────────────

# Reads a log file and returns a JSON object with state info.
detect_state() {
  local logfile="$1" agent_name="$2" alloc_id="$3" now_epoch="$4"

  # Handle empty / unreadable logs
  if [ ! -s "$logfile" ]; then
    printf '{"state":"stalled","since":null,"alloc":"%s"}' "$alloc_id"
    return
  fi

  # ── Check for structured STATE lines first ──────────────────────────────
  local structured_state structured_ts structured_issue structured_output structured_last_pr
  structured_state="$(grep -oiP '^\s*STATE\s+(idle|working|stalled)\b' "$logfile" 2>/dev/null | tail -1 | awk '{print tolower($2)}')" || true
  structured_ts="$(grep -oiP '^\s*STATE\s+(idle|working|stalled)\b.*?ts=\K[^ ]+' "$logfile" 2>/dev/null | tail -1)" || true
  structured_issue="$(grep -oiP '^\s*STATE\s+(idle|working|stalled)\b.*?issue=\K#[0-9]+' "$logfile" 2>/dev/null | tail -1)" || true
  structured_output="$(grep -oiP '^\s*STATE\s+(idle|working|stalled)\b.*?output=\K\S+' "$logfile" 2>/dev/null | tail -1)" || true
  structured_last_pr="$(grep -oiP '^\s*STATE\s+(idle|working|stalled)\b.*?last_pr=\K#[0-9]+' "$logfile" 2>/dev/null | tail -1)" || true

  if [ -n "$structured_state" ]; then
    local entry
    entry=$(jq -n -c --arg state "$structured_state" --arg alloc "$alloc_id" \
      '{state: $state, alloc: $alloc}')
    if [ -n "$structured_ts" ]; then
      entry=$(printf '%s' "$entry" | jq -c --arg ts "$structured_ts" '.since = $ts')
    fi
    if [ -n "$structured_issue" ]; then
      entry=$(printf '%s' "$entry" | jq -c --arg issue "$structured_issue" '.issue = $issue')
    fi
    if [ -n "$structured_output" ]; then
      entry=$(printf '%s' "$entry" | jq -c --arg output "$structured_output" '.output = $output')
    fi
    if [ -n "$structured_last_pr" ]; then
      entry=$(printf '%s' "$entry" | jq -c --arg pr "$structured_last_pr" '.last_pr = $pr')
    fi
    printf '%s' "$entry"
    return
  fi

  # ── Fallback: pattern-match natural log output ──────────────────────────

  # Get the last non-empty line to check for recency
  local last_line
  last_line="$(grep -v '^\s*$' "$logfile" 2>/dev/null | tail -1)" || true

  # Check staleness: if last line is older than 10 minutes, mark stalled.
  # We try to extract a timestamp from the last line.
  local last_ts_epoch
  last_ts_epoch="$(printf '%s' "$last_line" | grep -oP '^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}' 2>/dev/null | head -1)" || true

  if [ -n "$last_ts_epoch" ]; then
    local line_epoch
    line_epoch="$(date -d "$last_ts_epoch" +%s 2>/dev/null)" || true
    if [ -n "${line_epoch:-}" ]; then
      local age=$((now_epoch - line_epoch))
      if [ "$age" -gt 600 ]; then
        printf '{"state":"stalled","since":null,"alloc":"%s"}' "$alloc_id"
        return
      fi
    fi
  fi

  # Check for idle patterns
  local is_idle=0
  if grep -qiP '(no claimable issues|sleeping|no work|idle|polling.*nothing)' "$logfile" 2>/dev/null; then
    is_idle=1
  fi

  # Check for working patterns
  local is_working=0
  local issue_num=""
  if grep -qiP '(claimed|opened worktree|opening PR|opening pull request|building|processing|working on|checking out)' "$logfile" 2>/dev/null; then
    is_working=1
  fi

  # Extract issue number from working logs
  if [ "$is_working" -eq 1 ]; then
    issue_num="$(grep -oiP '(claimed|working on|processing)\s+#[0-9]+' "$logfile" 2>/dev/null | tail -1 | grep -oP '#[0-9]+')" || true
  fi

  # Extract last PR from idle logs
  local last_pr=""
  if [ "$is_idle" -eq 1 ]; then
    last_pr="$(grep -oiP '(last|latest)\s+PR?\s+#[0-9]+' "$logfile" 2>/dev/null | tail -1 | grep -oP '#[0-9]+')" || true
    if [ -z "$last_pr" ]; then
      last_pr="$(grep -oiP 'PR?\s+#[0-9]+' "$logfile" 2>/dev/null | tail -1 | grep -oP '#[0-9]+')" || true
    fi
  fi

  # Build the result
  local entry
  entry=$(jq -n -c --arg state "$([ "$is_working" -eq 1 ] && echo 'working' || echo 'idle')" \
    --arg alloc "$alloc_id" \
    '{state: $state, alloc: $alloc}')

  if [ -n "$issue_num" ]; then
    entry=$(printf '%s' "$entry" | jq -c --arg issue "$issue_num" '.issue = $issue')
  fi
  if [ -n "$last_pr" ]; then
    entry=$(printf '%s' "$entry" | jq -c --arg pr "$last_pr" '.last_pr = $pr')
  fi

  printf '%s' "$entry"
}

# ── Build agents data ────────────────────────────────────────────────────────

build_agents_data() {
  local allocs_json
  allocs_json="$(discover_opus_allocs)"

  local now_epoch
  now_epoch="$(date +%s)"

  # If no opus allocs found, return empty agents map.
  local alloc_count
  alloc_count="$(printf '%s' "$allocs_json" | jq 'length')" || alloc_count=0

  if [ "$alloc_count" -eq 0 ]; then
    printf '{}'
    return
  fi

  # ── Parallelize: fetch logs for all allocs in background ────────────────
  local -a logfiles=()
  local i

  for ((i = 0; i < alloc_count; i++)); do
    local agent_name alloc_id task
    agent_name="$(printf '%s' "$allocs_json" | jq -r ".[$i].name")"
    alloc_id="$(printf '%s' "$allocs_json" | jq -r ".[$i].alloc_id")"
    task="$(printf '%s' "$allocs_json" | jq -r ".[$i].task")"

    local lf
    lf="$(mktemp_safe "/tmp/snapshot-agents-log.XXXXXX")"
    logfiles+=("$lf")

    # Run log fetch in background
    fetch_alloc_logs "$alloc_id" "$task" "$lf" &
  done

  # Wait for all log fetches to complete
  wait

  # ── Detect state for each agent ─────────────────────────────────────────
  local agents_json="{}"

  for ((i = 0; i < alloc_count; i++)); do
    local agent_name alloc_id
    agent_name="$(printf '%s' "$allocs_json" | jq -r ".[$i].name")"
    alloc_id="$(printf '%s' "$allocs_json" | jq -r ".[$i].alloc_id")"

    local state_json
    state_json="$(detect_state "${logfiles[$i]}" "$agent_name" "$alloc_id" "$now_epoch")"

    # Merge into agents map
    agents_json="$(printf '%s' "$agents_json" | jq -c --arg name "$agent_name" --argjson info "$state_json" '. + {($name): $info}')"
  done

  printf '%s' "$agents_json"
}

# ── Merge into state.json ─────────────────────────────────────────────────────

main() {
  if [ ! -f "$SNAPSHOT_PATH" ]; then
    log "no state.json found — skipping (daemon not yet initialized)"
    return 0
  fi

  local agents_data
  agents_data="$(build_agents_data)"

  local tmpfile
  tmpfile="$(mktemp_safe "${SNAPSHOT_PATH}.agents.XXXXXX")"

  # Read previous snapshot, merge agents key under .collectors.agents, write atomically.
  jq -c --argjson agents "$agents_data" '.collectors.agents = $agents' "$SNAPSHOT_PATH" > "$tmpfile" 2>/dev/null
  mv -f "$tmpfile" "$SNAPSHOT_PATH"

  local agent_count
  agent_count=$(printf '%s' "$agents_data" | jq -r 'length')
  log "agents snapshot merged — ${agent_count} agent(s)"
}

main "$@"
