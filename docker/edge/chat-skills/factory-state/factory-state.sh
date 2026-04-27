#!/usr/bin/env bash
# =============================================================================
# factory-state.sh — read snapshot.json, return text summary + JSON
#
# Part of the chat-Claude operator surface (#727). Reads the on-box snapshot
# written by the snapshot daemon at /var/lib/disinto/snapshot/state.json and
# returns a concise plain-text summary suitable for voice/chat, plus the full
# JSON blob for deeper inspection.
#
# Usage:
#   factory-state.sh [section]
#
# Sections: nomad, forge, agents, inbox
# No section = full summary.
#
# Output:
#   Plain-text summary (~10 lines)
#   <blank line>
#   Full JSON (or sub-section)
# =============================================================================
set -euo pipefail

SNAPSHOT_PATH="${SNAPSHOT_PATH:-/var/lib/disinto/snapshot/state.json}"
STALE_THRESHOLD="${STALE_THRESHOLD_SECS:-30}"

usage() {
  printf 'usage: factory-state.sh [nomad|forge|agents|inbox]\n'
}

# ── Parse arguments ──────────────────────────────────────────────────────────

section=""
while [ $# -gt 0 ]; do
  case "$1" in
    nomad|forge|agents|inbox)
      section="$1"; shift ;;
    -h|--help)
      usage; exit 0 ;;
    *)
      printf 'factory-state: unknown arg: %s\n' "$1" >&2
      usage >&2
      exit 2 ;;
  esac
done

# ── Check snapshot file ──────────────────────────────────────────────────────

if [ ! -f "$SNAPSHOT_PATH" ]; then
  printf '(snapshot daemon not running — check '\''nomad job status snapshot'\'')\n'
  exit 0
fi

# ── Read snapshot ────────────────────────────────────────────────────────────

snapshot=$(cat "$SNAPSHOT_PATH")

# Validate JSON
if ! printf '%s' "$snapshot" | jq empty 2>/dev/null; then
  printf '(snapshot file is not valid JSON — daemon may be corrupted)\n'
  exit 1
fi

# ── Compute staleness ────────────────────────────────────────────────────────

now_epoch=$(date +%s)
ts_raw=$(printf '%s' "$snapshot" | jq -r '.ts // ""')

stale_warn=""
if [ -n "$ts_raw" ] && [ "$ts_raw" != "null" ] && [ "$ts_raw" != "" ]; then
  # Parse ISO 8601 timestamp to epoch
  snap_epoch=$(date -d "$ts_raw" +%s 2>/dev/null) || snap_epoch=0
  if [ "$snap_epoch" -gt 0 ]; then
    age=$(( now_epoch - snap_epoch ))
    if [ "$age" -gt "$STALE_THRESHOLD" ]; then
      stale_warn="[stale ${age}s] "
    fi
  fi
fi

# ── Build text summary ───────────────────────────────────────────────────────

human_age() {
  # Convert seconds to a human-readable age string.
  local secs="$1"
  if [ "$secs" -lt 60 ]; then
    printf '%ss' "$secs"
  elif [ "$secs" -lt 3600 ]; then
    printf '%sm' $(( secs / 60 ))
  elif [ "$secs" -lt 86400 ]; then
    printf '%sh' $(( secs / 3600 ))
  else
    printf '%sd' $(( secs / 86400 ))
  fi
}

build_text_summary() {
  local data="$1"
  local ts snap_epoch age age_str

  ts=$(printf '%s' "$data" | jq -r '.ts // ""')
  age_str="unknown"

  if [ -n "$ts" ] && [ "$ts" != "null" ]; then
    snap_epoch=$(date -d "$ts" +%s 2>/dev/null) || snap_epoch=0
    if [ "$snap_epoch" -gt 0 ]; then
      age=$(( now_epoch - snap_epoch ))
      age_str="$(human_age "$age")"
    fi
  fi

  printf 'Factory state (snapshot %s old):\n' "$age_str"

  # ── Forge summary ──
  local has_forge
  has_forge=$(printf '%s' "$data" | jq '.collectors | has("forge")')
  if [ "$has_forge" = "true" ]; then
    local backlog in_progress blocked prs_open prs_blocked
    backlog=$(printf '%s' "$data" | jq -r '.collectors.forge.backlog_count // 0')
    in_progress=$(printf '%s' "$data" | jq -r '.collectors.forge.in_progress_count // 0')
    blocked=$(printf '%s' "$data" | jq -r '.collectors.forge.blocked_count // 0')
    prs_open=$(printf '%s' "$data" | jq -r '.collectors.forge.prs_open // [] | length')
    prs_blocked=$(printf '%s' "$data" | jq -r '.collectors.forge.prs_blocked // [] | length')

    printf -- '- Tracker: %s backlog, %s in-progress' "$backlog" "$in_progress"
    if [ "$blocked" -gt 0 ] 2>/dev/null; then
      printf ', %s blocked' "$blocked"
    fi
    printf '\n'

    if [ "$prs_open" -gt 0 ] 2>/dev/null || [ "$prs_blocked" -gt 0 ] 2>/dev/null; then
      # Build PR detail string
      local pr_details
      pr_details=$(printf '%s' "$data" | jq -r '
        [.collectors.forge.prs_open // [] | .[] |
          "#\(.number) \(.status)"
        ] +
        [.collectors.forge.prs_blocked // [] | .[] |
          "#\(.number) \(.status) (CI failing)"
        ] | join(", ")
      ' 2>/dev/null) || pr_details=""
      if [ -n "$pr_details" ]; then
        # Truncate long PR lists for voice
        local pr_count=$(( prs_open + prs_blocked ))
        printf -- '- PRs: %s open (%s)\n' "$pr_count" "$(printf '%s' "$pr_details" | cut -c1-80)"
      fi
    fi
  fi

  # ── Agents summary ──
  local has_agents
  has_agents=$(printf '%s' "$data" | jq '.collectors | has("agents")')
  if [ "$has_agents" = "true" ]; then
    local agent_count
    agent_count=$(printf '%s' "$data" | jq -r '.collectors.agents | length')
    if [ "$agent_count" -gt 0 ] 2>/dev/null; then
      local agent_lines
      agent_lines=$(printf '%s' "$data" | jq -r '
        .collectors.agents | to_entries[] |
        if .value.issue then
          "\(.key) working \(.value.issue)"
        elif .value.state == "working" then
          "\(.key) working"
        elif .value.last_pr then
          "\(.key) idle (last PR \(.value.last_pr))"
        else
          "\(.key) \(.value.state)"
        end
      ' 2>/dev/null | head -5) || agent_lines=""
      if [ -n "$agent_lines" ]; then
        printf -- '- Agents: %s\n' "$(printf '%s\n' "$agent_lines" | tr '\n' ',' | sed 's/,$//' | sed 's/,/, /g')"
      fi
    else
      printf -- '- Agents: none active\n'
    fi
  fi

  # ── Nomad summary ──
  local has_nomad
  has_nomad=$(printf '%s' "$data" | jq '.collectors | has("nomad")')
  if [ "$has_nomad" = "true" ]; then
    local job_count alert_count
    job_count=$(printf '%s' "$data" | jq -r '.collectors.nomad.jobs // [] | length')
    alert_count=$(printf '%s' "$data" | jq -r '.collectors.nomad.alerts // [] | length')
    local running_count
    running_count=$(printf '%s' "$data" | jq -r '[.collectors.nomad.jobs[]?.allocs_running // 0] | add // 0')

    printf -- '- Nomad: %s jobs, %s running' "$job_count" "$running_count"
    if [ "$alert_count" -gt 0 ] 2>/dev/null; then
      printf ', %s alert(s)' "$alert_count"
    fi
    printf '\n'
  fi

  # ── Inbox summary ──
  local has_inbox
  has_inbox=$(printf '%s' "$data" | jq '.collectors | has("inbox")')
  if [ "$has_inbox" = "true" ]; then
    local unread_count
    unread_count=$(printf '%s' "$data" | jq -r '.collectors.inbox.unread_count // 0')
    printf -- '- Inbox: %s unread item(s)\n' "$unread_count"
  fi
}

# ── Get data slice (full or section) ─────────────────────────────────────────

get_data_slice() {
  local data="$1"
  local sec="$2"

  if [ -n "$sec" ]; then
    # Return just the section under .collectors
    local has_key
    has_key=$(printf '%s' "$data" | jq --arg sec "$sec" '.collectors | has($sec)')
    if [ "$has_key" = "true" ]; then
      printf '%s' "$data" | jq -c --arg sec "$sec" '.collectors[$sec]'
    else
      printf '{"error":"no data for section '\''%s'\''"}' "$sec"
    fi
  else
    # Return full snapshot
    printf '%s' "$data"
  fi
}

# ── Build summary for section ────────────────────────────────────────────────

build_section_summary() {
  local data="$1"
  local sec="$2"

  case "$sec" in
    nomad)
      local jobs alerts running
      jobs=$(printf '%s' "$data" | jq -r '.jobs // [] | length')
      running=$(printf '%s' "$data" | jq -r '[.jobs[]?.allocs_running // 0] | add // 0')
      alerts=$(printf '%s' "$data" | jq -r '.alerts // [] | length')
      printf 'Nomad: %s jobs, %s running' "$jobs" "$running"
      if [ "$alerts" -gt 0 ] 2>/dev/null; then
        printf ', %s alert(s):' "$alerts"
        printf '%s' "$data" | jq -r '.alerts[] | "  - \(.)"'
      fi
      printf '\n'
      ;;
    forge)
      local backlog in_progress blocked
      backlog=$(printf '%s' "$data" | jq -r '.backlog_count // 0')
      in_progress=$(printf '%s' "$data" | jq -r '.in_progress_count // 0')
      blocked=$(printf '%s' "$data" | jq -r '.blocked_count // 0')
      printf 'Forge tracker: %s backlog, %s in-progress' "$backlog" "$in_progress"
      if [ "$blocked" -gt 0 ] 2>/dev/null; then
        printf ', %s blocked' "$blocked"
      fi
      printf '\n'
      local prs_open prs_blocked
      prs_open=$(printf '%s' "$data" | jq -r '.prs_open // [] | length')
      prs_blocked=$(printf '%s' "$data" | jq -r '.prs_blocked // [] | length')
      if [ "$prs_open" -gt 0 ] 2>/dev/null; then
        printf 'PRs open: %s\n' "$prs_open"
        printf '%s' "$data" | jq -r '.prs_open[] | "  - #\(.number) \(.status) (\(.age_hours)h old)"'
      fi
      if [ "$prs_blocked" -gt 0 ] 2>/dev/null; then
        printf 'PRs blocked (CI): %s\n' "$prs_blocked"
        printf '%s' "$data" | jq -r '.prs_blocked[] | "  - #\(.number) \(.status)"'
      fi
      ;;
    agents)
      local count
      count=$(printf '%s' "$data" | jq -r 'length')
      if [ "$count" -eq 0 ] 2>/dev/null; then
        printf 'No agents active.\n'
      else
        printf 'Agent status (%s agent(s)):\n' "$count"
        printf '%s' "$data" | jq -r 'to_entries[] | "  - \(.key): \(.value.state)" + (if .value.issue then " (on \(.value.issue))" else "" end)'
      fi
      ;;
    inbox)
      local unread
      unread=$(printf '%s' "$data" | jq -r '.unread_count // 0')
      printf 'Inbox: %s unread item(s)\n' "$unread"
      printf '%s' "$data" | jq -r '.items[] | "  - [\(.kind)] \(.title) (by \(.author // "unknown"), \(.ts))"' | head -10
      ;;
  esac
}

# ── Emit output ──────────────────────────────────────────────────────────────

if [ -n "$section" ]; then
  # Section mode: return just that sub-section
  section_data=$(get_data_slice "$snapshot" "$section")
  summary=$(build_section_summary "$section_data" "$section")
  printf '%s%s\n' "$stale_warn" "$summary"
  printf '\n%s\n' "$section_data"
else
  # Full summary mode
  summary=$(build_text_summary "$snapshot")
  printf '%s%s\n' "$stale_warn" "$summary"
  printf '\n%s\n' "$(get_data_slice "$snapshot" "")"
fi
