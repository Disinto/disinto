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

# ── Fetch Nomad data with timeout ─────────────────────────────────────────────

fetch_jobs() {
  nomad job list -json -address="$NOMAD_ADDR" \
    -token="$NOMAD_TOKEN" \
    -timeout="${NOMAD_TIMEOUT}s" 2>/dev/null || true
}

fetch_allocs() {
  nomad alloc list -json -address="$NOMAD_ADDR" \
    -token="$NOMAD_TOKEN" \
    -timeout="${NOMAD_TIMEOUT}s" 2>/dev/null || true
}

# ── Build jobs array and alerts ───────────────────────────────────────────────

build_nomad_data() {
  local jobs_json allocs_json

  jobs_json="$(fetch_jobs)" || true
  allocs_json="$(fetch_allocs)" || true
  allocs_json="${allocs_json:-[]}"

  # If jobs call returned nothing, Nomad is unreachable.
  if [[ -z "$jobs_json" || "$jobs_json" == "[]" || "$jobs_json" == "null" ]]; then
    printf '{"jobs":[],"alerts":["nomad unreachable: no jobs returned"]}'
    return
  fi

  # Build the merged output with jq.
  # nomad job list  -json → flat array of job objects (no embedded Allocations)
  # nomad alloc list -json → flat array of alloc objects (with JobID, ClientStatus)
  printf '%s' "$jobs_json" | jq -c --argjson allocs "$allocs_json" '
    # ── alloc_id → restart_count map ──
    ([$allocs[] | select(. != null and .ID != null)]
     | map({key: .ID, value: (.RestartCount // 0)})
     | from_entries) as $alloc_restarts |

    # ── job_id → list-of-allocs map ──
    ([$allocs[] | select(. != null and .JobID != null)]
     | group_by(.JobID)
     | map({key: .[0].JobID, value: .})
     | from_entries) as $allocs_by_job |

    # ── jobs summary ──
    (map(select(. != null)) | map(
      . as $j |
      ($allocs_by_job[$j.ID // ""] // []) as $job_allocs |
      {
        id:           ($j.ID // $j.Name // "unknown"),
        status:       ($j.Status // "unknown"),
        allocs_running: ([$job_allocs[] | select(.ClientStatus == "running")] | length),
        allocs_failed:  ([$job_allocs[] | select(.ClientStatus == "failed" or .ClientStatus == "lost")] | length)
      }
    )) as $jobs |

    # ── Alert 1: pending/dead jobs older than 5 min ──
    # nomad job list -json exposes SubmitTime (nanoseconds since epoch) rather
    # than StatusTime — fall back to either when present.
    (
      [
        (map(select(. != null)) | .[]) |
        select(.Status == "pending" or .Status == "dead") |
        ((
          if .StatusTime != null and (.StatusTime | type) == "string" then
            (.StatusTime | gsub("\\.[0-9]+Z$"; "Z") | strptime("%Y-%m-%dT%H:%M:%SZ") | mktime)
          elif .SubmitTime != null and (.SubmitTime | type) == "number" then
            (.SubmitTime / 1000000000 | floor)
          else
            null
          end
        )) as $t |
        select($t != null and (now - $t) > 300) |
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
  tmpfile="$(mktemp_safe "${SNAPSHOT_PATH}.nomad.XXXXXX")"

  # Read previous snapshot, merge nomad key under .collectors.nomad, write atomically.
  jq -c --argjson nomad "$nomad_data" '.collectors.nomad = $nomad' "$SNAPSHOT_PATH" > "$tmpfile" 2>/dev/null
  mv -f "$tmpfile" "$SNAPSHOT_PATH"

  local alert_count
  alert_count=$(printf '%s' "$nomad_data" | jq -r '.alerts | length')
  log "nomad snapshot merged — ${#nomad_data} bytes, ${alert_count} alert(s)"
}

main "$@"
