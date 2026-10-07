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
#   {"nomad":{"ts":"...","jobs":[...],"alerts":[...]}}
#
# ts is UTC (%Y-%m-%dT%H:%M:%SZ) on the collector object. The daemon
# rewrites the top-level ts every tick, including when it keeps a
# previous "nomad" key, so that top-level ts cannot show that these
# alerts are stale.
#
# Alerts (strings), appended in this order:
#   "job <ID> <status>"                         — pending/dead for >5 min
#   "alloc <ID> restarted <N> times (last 1h)"  — restart count > 3
#   "service <name> of job <ID> not registered" — a running job
#     (Type != "batch") declares <name> in TaskGroups[].Services or
#     TaskGroups[].Tasks[].Services, and /v1/services does not list it.
#     A failed /v1/services call adds none of these.
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
# Shared TMPFILES / mktemp_safe / cleanup (lib/snapshot-tmp.sh).

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
FACTORY_ROOT="${FACTORY_ROOT:-$(cd "${SCRIPT_DIR}/.." && pwd)}"
source "${FACTORY_ROOT}/lib/snapshot-tmp.sh"
trap cleanup EXIT

# ── Fetch Nomad data with timeout ─────────────────────────────────────────────
# Every call uses the same curl options and NOMAD_TIMEOUT. A failed call
# prints nothing (callers treat an empty body as a failure).

nomad_get() {
  local path="$1"
  local -a headers=()
  [ -n "${NOMAD_TOKEN:-}" ] && headers+=(-H "X-Nomad-Token: ${NOMAD_TOKEN}")
  curl -fsS --max-time "${NOMAD_TIMEOUT}" "${headers[@]}" \
    "${NOMAD_ADDR%/}${path}" 2>/dev/null || true
}

fetch_jobs() { nomad_get "/v1/jobs"; }
fetch_allocs() { nomad_get "/v1/allocations"; }
fetch_services() { nomad_get "/v1/services"; }
fetch_job() { nomad_get "/v1/job/$1"; }

# ── Service registration alerts ───────────────────────────────────────────────
# Declared names: running, non-batch jobs, from /v1/job/<ID>
#   .TaskGroups[].Services[].Name and .TaskGroups[].Tasks[].Services[].Name
# Registered names: every ServiceName in /v1/services
#   [{Namespace, Services: [{ServiceName, Tags}]}]
# A failed /v1/services call (empty/non-array body) adds no service alerts.
# A failed /v1/job/<ID> call skips that job rather than inventing an alert.

collect_service_alerts() {
  local jobs_json="$1"
  local services_json specs id spec

  services_json="$(fetch_services)"
  if ! printf '%s' "$services_json" | jq -e 'type == "array"' >/dev/null 2>&1; then
    printf '[]'
    return 0
  fi

  specs='[]'
  while IFS= read -r id; do
    [ -n "$id" ] || continue
    spec="$(fetch_job "$id")"
    if printf '%s' "$spec" | jq -e 'type == "object"' >/dev/null 2>&1; then
      specs="$(jq -c --arg id "$id" --argjson spec "$spec" \
        '. + [{id: $id, spec: $spec}]' <<<"$specs")" || specs='[]'
    fi
  done < <(printf '%s' "$jobs_json" | jq -r '
    .[] | select(. != null and .Status == "running" and .Type != "batch")
    | .ID // .Name // empty
  ' 2>/dev/null || true)

  jq -nc --argjson services "$services_json" --argjson specs "$specs" '
    ([ $services[]?.Services[]?.ServiceName
       | select(type == "string" and . != "") ] | unique) as $registered |
    [
      $specs[]
      | .id as $jid
      | (
          [
            (if (.spec.TaskGroups | type) == "array" then .spec.TaskGroups[] else empty end)
            | (
                (if (.Services | type) == "array" then .Services[].Name else empty end),
                (if (.Tasks | type) == "array" then
                   .Tasks[]
                   | if (.Services | type) == "array" then .Services[].Name else empty end
                 else empty end)
              )
          ]
          | map(select(type == "string" and . != ""))
          | unique[]
        ) as $name
      | select(($registered | index($name)) == null)
      | "service \($name) of job \($jid) not registered"
    ]
  ' 2>/dev/null || printf '[]'
}

# ── Build jobs array and alerts ───────────────────────────────────────────────

build_nomad_data() {
  local jobs_json allocs_json ts base service_alerts

  ts="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"

  jobs_json="$(fetch_jobs)" || true
  allocs_json="$(fetch_allocs)" || true
  allocs_json="${allocs_json:-[]}"

  # If jobs call returned nothing, Nomad is unreachable.
  if [[ -z "$jobs_json" || "$jobs_json" == "[]" || "$jobs_json" == "null" ]]; then
    jq -cn --arg ts "$ts" \
      '{ts: $ts, jobs: [], alerts: ["nomad unreachable: no jobs returned"]}'
    return
  fi

  # Build the merged output with jq.
  # nomad job list  -json → flat array of job objects (no embedded Allocations)
  # nomad alloc list -json → flat array of alloc objects (with JobID, ClientStatus)
  base="$(printf '%s' "$jobs_json" | jq -c --argjson allocs "$allocs_json" --arg ts "$ts" '
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
      ts: $ts,
      jobs: $jobs,
      alerts: ($time_alerts + $restart_alerts)
    }
  ' 2>/dev/null)" || base=""

  if [[ -z "$base" ]]; then
    jq -cn --arg ts "$ts" '{ts: $ts, jobs: [], alerts: ["nomad data parse failed"]}'
    return
  fi

  # Append after the existing alerts. A failed /v1/services call yields []
  # and leaves the job/alloc alerts unchanged.
  service_alerts="$(collect_service_alerts "$jobs_json")" || service_alerts='[]'
  if ! printf '%s' "$service_alerts" | jq -e 'type == "array"' >/dev/null 2>&1; then
    service_alerts='[]'
  fi
  jq -c --argjson extra "$service_alerts" '.alerts += $extra' <<<"$base" \
    || printf '%s' "$base"
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
  mktemp_safe "${SNAPSHOT_PATH}.nomad.XXXXXX"
  tmpfile="$_TMPFILE"

  # Read previous snapshot, merge nomad key under .collectors.nomad, write atomically.
  jq -c --argjson nomad "$nomad_data" '.collectors.nomad = $nomad' "$SNAPSHOT_PATH" > "$tmpfile" 2>/dev/null
  chmod 644 "$tmpfile"
  mv -f "$tmpfile" "$SNAPSHOT_PATH"

  local alert_count
  alert_count=$(printf '%s' "$nomad_data" | jq -r '.alerts | length')
  log "nomad snapshot merged — ${#nomad_data} bytes, ${alert_count} alert(s)"
}

main "$@"
