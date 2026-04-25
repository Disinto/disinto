#!/usr/bin/env bash
# =============================================================================
# snapshot-nomad.sh — nomad-collector for snapshot daemon
#
# Queries Nomad for job/alloc status and merges into state.json under key
# "nomad". Invoked by the snapshot-daemon loop each tick.
#
# Environment:
#   NOMAD_ADDR    — Nomad API URL (required)
#   NOMAD_TOKEN   — Nomad ACL token (required)
#   SNAPSHOT_PATH — path to state.json (default /var/lib/disinto/snapshot/state.json)
#   NOMAD_TIMEOUT — per-call timeout in seconds (default 2)
#
# Output shape:
#   {"nomad":{"jobs":[...],"alerts":[...]}}
#
# Read-only. Skips silently if Nomad is unreachable; leaves previous
# "nomad" key in place rather than blanking it.
# =============================================================================
set -euo pipefail

NOMAD_ADDR="${NOMAD_ADDR:?NOMAD_ADDR is required}"
NOMAD_TOKEN="${NOMAD_TOKEN:?NOMAD_TOKEN is required}"
SNAPSHOT_PATH="${SNAPSHOT_PATH:-/var/lib/disinto/snapshot/state.json}"
NOMAD_TIMEOUT="${NOMAD_TIMEOUT:-2}"

log() {
  printf '[%s] snapshot-nomad: %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$*" >&2
}

# ── Fetch Nomad data with timeout ─────────────────────────────────────────────

fetch_jobs() {
  nomad job status -json -address="$NOMAD_ADDR" \
    -token="$NOMAD_TOKEN" \
    -timeout="${NOMAD_TIMEOUT}s" 2>/dev/null || true
}

fetch_allocs() {
  nomad alloc status -json -address="$NOMAD_ADDR" \
    -token="$NOMAD_TOKEN" \
    -timeout="${NOMAD_TIMEOUT}s" 2>/dev/null || true
}

# ── Build jobs array and alerts ───────────────────────────────────────────────

build_nomad_data() {
  local jobs_json allocs_json

  jobs_json="$(fetch_jobs)" || true
  allocs_json="$(fetch_allocs)" || true

  # If jobs call returned nothing, Nomad is unreachable.
  if [[ -z "$jobs_json" || "$jobs_json" == "[]" || "$jobs_json" == "null" ]]; then
    printf '{"jobs":[],"alerts":["nomad unreachable: no jobs returned"]}'
    return
  fi

  # Build the merged output with jq.
  # nomad job status -json → flat array of job objects
  # nomad alloc status -json → flat array of alloc objects
  printf '%s' "$jobs_json" | jq -c --argjson allocs "$allocs_json" '
    # ── alloc_id → restart_count map ──
    ([$allocs[] | select(. != null and .ID != null)]
     | map({key: .ID, value: (.RestartCount // 0)})
     | from_entries) as $alloc_restarts |

    # ── jobs summary ──
    (map(select(. != null)) | map(
      {
        id:           (.ID // .Name // "unknown"),
        status:       (.Status // "unknown"),
        allocs_running: ([.Allocations // [] | .[] | select(.Status == "running")] | length),
        allocs_failed:  ([.Allocations // [] | .[] | select(.Status == "dead" or .Status == "failed")] | length)
      }
    )) as $jobs |

    # ── Alert 1: pending/dead/failed jobs older than 5 min ──
    # Parse ISO 8601 StatusTime via strptime/mktime; compare with jq now().
    (
      [
        (map(select(. != null)) | .[]) |
        select(
          (.Status == "pending" or .Status == "dead" or .Status == "failed")
          and (.StatusTime != null)
        ) |
        # Strip fractional seconds and Z for strptime compatibility
        (.StatusTime | gsub("\\.[0-9]+Z$"; "Z") | strptime("%Y-%m-%dT%H:%M:%SZ") | mktime) as $t |
        select((now - $t) > 300) |
        "job \(.ID // .Name) \(.Status)"
      ]
    ) as $time_alerts |

    # ── Alert 2: alloc restart count > 3 ──
    ([$alloc_restarts | to_entries[]
      | select(.value > 3)
      | "alloc \(.key) restarted \(.value) times (last 1h)"]) as $restart_alerts |

    {
      jobs: $jobs,
      alerts: ($time_alerts + $restart_alerts)
    }
  ' 2>/dev/null || printf '{"jobs":[],"alerts":["nomad data parse failed"]}'
}

# ── Merge into state.json ─────────────────────────────────────────────────────

main() {
  if [ ! -f "$SNAPSHOT_PATH" ]; then
    log "no state.json found — skipping (daemon not yet initialized)"
    return 0
  fi

  local nomad_data
  nomad_data="$(build_nomad_data)"

  local tmpfile
  tmpfile="$(mktemp "${SNAPSHOT_PATH}.nomad.XXXXXX")"

  # Read previous snapshot, merge nomad key, write atomically.
  jq -c --argjson nomad "$nomad_data" '.nomad = $nomad' "$SNAPSHOT_PATH" > "$tmpfile" 2>/dev/null
  mv -f "$tmpfile" "$SNAPSHOT_PATH"

  local alert_count
  alert_count=$(printf '%s' "$nomad_data" | jq -r '.alerts | length')
  log "nomad snapshot merged — ${#nomad_data} bytes, ${alert_count} alert(s)"
}

main "$@"
