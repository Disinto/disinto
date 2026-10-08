#!/usr/bin/env bash
# =============================================================================
# healer.sh — host-side re-registration of lost Nomad services (#1950)
#
# Fixes the 2026-10-07 outage: a Nomad agent restart dropped service
# registrations, the edge then crash-looped, and self.disinto.ai returned
# 502 for two hours. The fix was `nomad alloc restart` on the running
# allocation. Nothing else in disinto can take that step. Nomad's API
# listens on 127.0.0.1:4646 only, so a container cannot reach it; this
# script runs on the host (a raw_exec task, same placement as the snapshot
# task in nomad/jobs/edge.hcl). Nomad ACLs are disabled, so no token is
# required. This is the only disinto process allowed to restart allocations.
#
# It does not read the snapshot. The snapshot task lives in the edge job,
# which may be the thing that is down. Each tick queries Nomad directly,
# the same way the service-unregistered alert in bin/snapshot-nomad.sh does:
#   declared names  — running non-batch jobs (/v1/jobs), then /v1/job/<ID>,
#                     .TaskGroups[].Services[].Name and
#                     .TaskGroups[].Tasks[].Services[].Name
#   registered names — /v1/services (ServiceName)
# A declared name absent from the registry is unregistered. The remedy is
# one `nomad alloc restart` of that job's running allocation.
#
# Second check (public endpoints, #1952): the owner does not watch this box,
# so a 502 on a public endpoint must be fixed here, not in the ops repo.
# Each tick, every URL in $HEALER_PUBLIC_URLS is probed with curl (10 s);
# 2xx/3xx = up (the streak resets to 0), anything else is a failing tick.
# After 3 consecutive failing ticks the endpoint's backend is picked from its
# path (/forge/ → service forgejo, health /api/healthz; /ci/ → service
# woodpecker, health /ci/healthz — a bare /healthz answers 200 from the web
# UI's catch-all, so it is never used). The address comes from
# /v1/service/<name> (.Services[].Address = "host:port"); the health check is
# curl on http://<address><health path> (2xx = healthy). An unregistered
# service is left to the service-reregister pass. Registered + unhealthy →
# that alloc is restarted; registered + healthy → the edge alloc is restarted.
# If the URL is still down after an edge restart with a healthy backend,
# nothing is left to restart — the fault is outside the box (the Cloudflare
# tunnel): the URL is recorded under unfixable in state.json for #1955 and
# logged once. Once recorded, no further endpoint restart is attempted for
# that URL until it answers 2xx/3xx again (which resets the failure streak
# and clears the unfixable entry), so a bad tunnel does not drive a
# per-cooldown edge-restart loop.
#
# Guards (a tick that cannot confirm Nomad is healthy does not restart,
# and does not close an open proposal — the next tick retries):
#   - a job named agents-* is skipped while `nomad alloc exec` finds a
#     process matching dev-agent.sh|review-pr.sh|gardener-run.sh|dsh ;
#     the next tick tries again (an exec failure also skips — do not kill
#     work the healer cannot see)
#   - at most one restart per job per HEALER_COOLDOWN_SECS (default 1800)
#   - at most 3 restarts per tick
#   - no restart when /v1/agent/health fails
#   - HEALER_DRY_RUN=1 logs "would restart <job>" instead of acting
#
# Tape (lib/tape.sh, same shape as the supervisor's direct remedies):
#   before each restart,
#     tape_proposal <id> repair service-reregister "" "" \
#       '{"signature":"service-unregistered:<job>","organ":"healer"}' \
#       "" auto "job:<job>"
#   once that service is registered again, or after the cooldown has passed,
#     tape_outcome <id> '{"acted":1,"cleared":1|0}' '{}' '{}' '[]'
#   open proposals live in $HEALER_STATE_DIR/state.json. A tape failure
#   logs a WARNING and never stops the loop.
#
# Loop: every HEALER_INTERVAL_SECS (default 60). --once runs one tick and
# exits (tests). One line per action on stdout: [<iso>] healer: <message>.
#
# Environment:
#   NOMAD_ADDR              Nomad API (default http://localhost:4646)
#   NOMAD_TOKEN             optional; ACLs are disabled, so usually unset
#   NOMAD_TIMEOUT           per-call curl timeout, seconds (default 5)
#   HEALER_INTERVAL_SECS    loop sleep (default 60)
#   HEALER_COOLDOWN_SECS    min seconds between restarts of one job (default 1800)
#   HEALER_STATE_DIR        open proposals + cooldown (default /srv/disinto/healer)
#   HEALER_PUBLIC_URLS      whitespace-separated public endpoints to probe
#                           (default https://self.disinto.ai/forge/
#                           https://self.disinto.ai/ci/; empty = no probing)
#   HEALER_DRY_RUN          1 = log would restart, do not act
#   TAPE_DIR                tape store (lib/tape.sh; default /srv/disinto/tape)
#
# Does not source lib/env.sh: this is a host-side loop, not an agent, and
# sourcing env.sh would require USER/HOME and could clobber NOMAD_ADDR.
# =============================================================================
set -euo pipefail

HEALER_INTERVAL_SECS="${HEALER_INTERVAL_SECS:-60}"
HEALER_COOLDOWN_SECS="${HEALER_COOLDOWN_SECS:-1800}"
HEALER_STATE_DIR="${HEALER_STATE_DIR:-/srv/disinto/healer}"
NOMAD_ADDR="${NOMAD_ADDR:-http://localhost:4646}"
NOMAD_TIMEOUT="${NOMAD_TIMEOUT:-5}"
# Hard cap from the issue: at most 3 restarts per tick. Not an env knob.
HEALER_MAX_RESTARTS=3
# alloc exec must not hang the loop. A timeout is treated as "cannot see
# the alloc" and the agents-* job is skipped, not restarted.
HEALER_EXEC_TIMEOUT_SECS=15
# Public endpoint probing (#1952): after this many consecutive failing ticks
# a restart attempt is made; empty means no endpoint probing.
HEALER_PUBLIC_FAILURES=3
HEALER_PUBLIC_URLS="${HEALER_PUBLIC_URLS:-https://self.disinto.ai/forge/ https://self.disinto.ai/ci/}"
# Health-check curl timeout for public endpoints (separate from NOMAD_TIMEOUT,
# which is for the Nomad API).
HEALER_PROBE_TIMEOUT_SECS="${HEALER_PROBE_TIMEOUT_SECS:-10}"
# Shared per-tick restart budget: capped by HEALER_MAX_RESTARTS, shared by
# the service-reregister pass and the public-endpoint pass.
RESTARTS=0

export NOMAD_ADDR

case "$HEALER_INTERVAL_SECS" in
  ''|*[!0-9]*) HEALER_INTERVAL_SECS=60 ;;
esac
case "$HEALER_COOLDOWN_SECS" in
  ''|*[!0-9]*) HEALER_COOLDOWN_SECS=1800 ;;
esac
case "$NOMAD_TIMEOUT" in
  ''|*[!0-9]*) NOMAD_TIMEOUT=5 ;;
esac

ONCE=0
usage() {
  printf '%s\n' "usage: healer.sh [--once]"
}

while [ $# -gt 0 ]; do
  case "$1" in
    --once) ONCE=1 ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      usage >&2
      exit 2
      ;;
  esac
  shift
done

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/tape.sh
source "${SCRIPT_DIR}/../lib/tape.sh"

log() {
  printf '[%s] healer: %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$*"
}

# nomad_get PATH — body of a Nomad GET, or empty on any failure. Callers
# that must tell "failed" from "empty" use curl themselves (health).
nomad_get() {
  local path="$1"
  local url="${NOMAD_ADDR%/}${path}"
  if [ -n "${NOMAD_TOKEN:-}" ]; then
    curl -fsS --max-time "$NOMAD_TIMEOUT" \
      -H "X-Nomad-Token: ${NOMAD_TOKEN}" "$url" 2>/dev/null || true
  else
    curl -fsS --max-time "$NOMAD_TIMEOUT" "$url" 2>/dev/null || true
  fi
}

json_array() {
  printf '%s' "$1" | jq -e 'type == "array"' >/dev/null 2>&1
}

json_object() {
  printf '%s' "$1" | jq -e 'type == "object"' >/dev/null 2>&1
}

agent_healthy() {
  curl -fsS --max-time "$NOMAD_TIMEOUT" \
    "${NOMAD_ADDR%/}/v1/agent/health" >/dev/null 2>&1
}

# Job ids are interpolated into URL paths. Refuse anything that is not a
# single path segment.
job_id_ok() {
  case "$1" in
    ''|*[!A-Za-z0-9._-]*) return 1 ;;
  esac
  return 0
}

state_path() {
  printf '%s/state.json' "$HEALER_STATE_DIR"
}

read_state() {
  local dest
  dest="$(state_path)"
  if [ -f "$dest" ] && jq -e 'type == "object"' "$dest" >/dev/null 2>&1; then
    cat "$dest"
  else
    printf '%s\n' '{}'
  fi
}

write_state() {
  local json="$1" dest tmp
  printf '%s' "$json" | jq -e 'type == "object"' >/dev/null 2>&1 || return 1
  mkdir -p "$HEALER_STATE_DIR" || return 1
  dest="$(state_path)"
  tmp="$(mktemp "${HEALER_STATE_DIR}/state.XXXXXX")" || return 1
  printf '%s\n' "$json" > "$tmp"
  mv -f "$tmp" "$dest"
}

healer_proposal_id() {
  local raw=""
  if [ -r /proc/sys/kernel/random/uuid ]; then
    raw="$(cat /proc/sys/kernel/random/uuid)"
  elif command -v uuidgen >/dev/null 2>&1; then
    raw="$(uuidgen)"
  else
    raw="$(od -An -N16 -tx1 /dev/urandom 2>/dev/null | tr -d ' \n')"
  fi
  printf 'healer-%s' "${raw:-$$}"
}

# registered_names SERVICES_JSON — JSON array of ServiceName values.
registered_names() {
  printf '%s' "$1" | jq -c '
    [ .[]?.Services[]?.ServiceName
      | select(type == "string" and length > 0) ]
    | unique
  '
}

# declared_names JOB_SPEC — group-level and task-level service names.
declared_names() {
  printf '%s' "$1" | jq -c '
    [ (.TaskGroups // [])[]
      | (.Services // [])[].Name,
        ((.Tasks // [])[] | (.Services // [])[].Name) ]
    | map(select(type == "string" and length > 0))
    | unique
  '
}

# missing_names DECLARED_JSON REGISTERED_JSON — declared names not registered.
missing_names() {
  # $name, not `.`: inside `$registered | index(.)` the dot is the array.
  jq -nc --argjson declared "$1" --argjson registered "$2" '
    [ $declared[] as $name | select(($registered | index($name)) == null) | $name ]
  '
}

running_service_job_ids() {
  printf '%s' "$1" | jq -r '
    [ .[]?
      | select(.Status == "running" and .Type != "batch")
      | (.ID // .Name // empty)
      | select(type == "string" and length > 0) ]
    | unique
    | .[]
  ' | sort
}

running_alloc() {
  printf '%s' "$1" | jq -r '
    [ .[]?
      | select(.ClientStatus == "running")
      | .ID
      | select(type == "string" and length > 0) ][0] // empty
  ' 2>/dev/null || true
}

in_cooldown() {
  local job="$1" now="$2" state at elapsed
  state="$(read_state)"
  at="$(printf '%s' "$state" | jq -r --arg j "$job" '.cooldown[$j] // empty')" || return 1
  case "$at" in
    ''|*[!0-9]*) return 1 ;;
  esac
  elapsed=$((now - at))
  [ "$elapsed" -lt "$HEALER_COOLDOWN_SECS" ]
}

# alloc_ps ALLOC — command lines inside the allocation, one per line.
# Matching happens here, not in the alloc: a remote grep whose argv
# contained the pattern would look like work in flight.
alloc_ps() {
  local alloc="$1"
  # Single quotes on purpose: this string runs inside the allocation, so
  # $f must not expand on the host.
  # shellcheck disable=SC2016
  local cmd='for f in /proc/[0-9]*/cmdline; do tr "\0" " " < "$f"; printf "\n"; done'
  if command -v timeout >/dev/null 2>&1; then
    timeout "$HEALER_EXEC_TIMEOUT_SECS" \
      nomad alloc exec -i=false "$alloc" sh -c "$cmd"
  else
    nomad alloc exec -i=false "$alloc" sh -c "$cmd"
  fi
}

# alloc_is_idle JOB ALLOC — 0 when an agents-* alloc has no work in flight.
# 1 (skip) when a matching process is running, or when exec fails.
alloc_is_idle() {
  local job="$1" alloc="$2" ps rc=0
  ps="$(alloc_ps "$alloc" 2>/dev/null)" || rc=$?
  if [ "$rc" -ne 0 ]; then
    log "WARNING: alloc exec failed for ${job} — skip restart"
    return 1
  fi
  if printf '%s\n' "$ps" | grep -E -q 'dev-agent\.sh|review-pr\.sh|gardener-run\.sh|dsh '; then
    log "skip ${job}: work in flight"
    return 1
  fi
  return 0
}

record_restart() {
  local job="$1" pid="$2" missing="$3" now="$4" state new
  state="$(read_state)"
  new="$(jq -nc \
    --argjson state "$state" \
    --arg job "$job" \
    --arg pid "$pid" \
    --argjson services "$missing" \
    --argjson now "$now" '
      ($state // {}) as $s
      | ($s + {cooldown: (($s.cooldown // {}) + {($job): $now})})
      | if $pid == "" then .
        else . + {open: ((.open // {}) + {($job): {proposal_id: $pid, restarted_at: $now, services: $services}})}
        end
    ')" || return 1
  write_state "$new"
}

# act_on JOB ALLOC MISSING_JSON NOW — one restart, or a dry-run log line.
# Tape failure warns and does not stop the restart. A failed restart is
# not cooled down, so the next tick can try again.
act_on() {
  local job="$1" alloc="$2" missing="$3" now="$4" pid="" ctx=""
  if [ "${HEALER_DRY_RUN:-}" = "1" ]; then
    log "would restart ${job}"
    return 0
  fi
  pid="$(healer_proposal_id)"
  ctx="$(jq -nc --arg sig "service-unregistered:${job}" \
    '{signature: $sig, organ: "healer"}')" || ctx=""
  if [ -z "$ctx" ] || ! tape_proposal "$pid" repair service-reregister "" "" \
      "$ctx" "" auto "job:${job}"; then
    log "WARNING: tape: failed to append repair proposal for ${job}"
    pid=""
  fi
  if ! nomad alloc restart "$alloc"; then
    log "WARNING: alloc restart failed for ${job} (${alloc})"
    return 0
  fi
  log "restarted alloc ${alloc} for job ${job}"
  if ! record_restart "$job" "$pid" "$missing" "$now"; then
    log "WARNING: failed to record restart state for ${job}"
  fi
  return 0
}

# close_open SERVICES_JSON — outcome for each open proposal whose services
# are registered again (cleared 1) or whose cooldown has passed (cleared 0).
# A failed outcome append leaves the entry for the next tick.
close_open() {
  local services_json="$1"
  local state registered now jobs job pid restarted svcs all_back elapsed
  local cleared bits new
  state="$(read_state)"
  registered="$(registered_names "$services_json")" || return 0
  now="$(date -u +%s)"
  jobs="$(printf '%s' "$state" | jq -r '.open // {} | keys[]')" || return 0
  while IFS= read -r job; do
    [ -n "$job" ] || continue
    pid="$(printf '%s' "$state" | jq -r --arg j "$job" '.open[$j].proposal_id // empty')" || continue
    restarted="$(printf '%s' "$state" | jq -r --arg j "$job" '.open[$j].restarted_at // empty')" || continue
    svcs="$(printf '%s' "$state" | jq -c --arg j "$job" '.open[$j].services // []')" || continue
    case "$restarted" in
      ''|*[!0-9]*) restarted=0 ;;
    esac
    all_back="$(jq -nr --argjson svcs "$svcs" --argjson reg "$registered" '
      if ($svcs | length) == 0 then false
      else [ $svcs[] as $name | select(($reg | index($name)) == null) ] | length == 0
      end
    ')" || all_back="false"
    elapsed=$((now - restarted))
    if [ "$all_back" = "true" ]; then
      cleared=1
    elif [ "$elapsed" -ge "$HEALER_COOLDOWN_SECS" ]; then
      cleared=0
    else
      continue
    fi
    if [ -z "$pid" ]; then
      log "WARNING: no proposal id for ${job} — dropping open entry"
    else
      bits="$(jq -nc --argjson cleared "$cleared" '{acted: 1, cleared: $cleared}')" || bits=""
      if [ -z "$bits" ] || ! tape_outcome "$pid" "$bits" '{}' '{}' '[]'; then
        log "WARNING: tape: failed to append outcome for ${job} (${pid})"
        continue
      fi
      log "outcome recorded for ${job} cleared=${cleared}"
    fi
    new="$(printf '%s' "$state" | jq -c --arg j "$job" 'del(.open[$j])')" || continue
    if ! write_state "$new"; then
      log "WARNING: failed to drop open proposal for ${job}"
      continue
    fi
    state="$new"
  done <<< "$jobs"
  return 0
}

restart_unregistered() {
  local jobs_json="$1" services_json="$2"
  local registered ids id spec declared missing allocs alloc now
  RESTARTS=0
  registered="$(registered_names "$services_json")" || {
    log "WARNING: could not read registered services — no restart"
    return 0
  }
  now="$(date -u +%s)"
  ids="$(running_service_job_ids "$jobs_json")" || {
    log "WARNING: could not read jobs — no restart"
    return 0
  }
  while IFS= read -r id; do
    [ -n "$id" ] || continue
    if ! job_id_ok "$id"; then
      log "WARNING: skip unsafe job id"
      continue
    fi
    spec="$(nomad_get "/v1/job/${id}")"
    json_object "$spec" || continue
    declared="$(declared_names "$spec")" || continue
    missing="$(missing_names "$declared" "$registered")" || continue
    [ "$missing" = "[]" ] && continue
    allocs="$(nomad_get "/v1/job/${id}/allocations")"
    alloc="$(running_alloc "$allocs")"
    if [ -z "$alloc" ]; then
      log "WARNING: job ${id} has unregistered services but no running alloc"
      continue
    fi
    if in_cooldown "$id" "$now"; then
      log "skip ${id}: cooldown"
      continue
    fi
    case "$id" in
      agents-*)
        alloc_is_idle "$id" "$alloc" || continue
        ;;
    esac
    if [ "$RESTARTS" -ge "$HEALER_MAX_RESTARTS" ]; then
      log "restart cap reached — remaining jobs wait"
      break
    fi
    act_on "$id" "$alloc" "$missing" "$now"
    RESTARTS=$((RESTARTS + 1))
  done <<< "$ids"
  return 0
}

# ── public endpoints (#1952) ────────────────────────────────────────────────
# endpoint_backend <url> — "service job health-path" (whitespace-separated)
# for the public endpoint <url>; print nothing and return 1 when <url> is
# not a known endpoint.  The service name is what Nomad registers (service
# "woodpecker" belongs to job woodpecker-server), so both names are returned.
endpoint_backend() {
  local url host path seg
  url="$1"
  [ -n "$url" ] || return 1
  url="${url#*://}"
  host="${url%%/*}"
  path="${url#"$host"/}"
  seg="${path%%/*}"
  case "$seg" in
    forge) printf 'forgejo forgejo /api/healthz' ;;
    ci) printf 'woodpecker woodpecker-server /ci/healthz' ;;
    *) return 1 ;;
  esac
}

# probe_url <url> — HTTP status of one probe. 0 = curl itself failed
# (unreachable / timeout), which is down, not up.
probe_url() {
  local code
  code="$(curl -s -o /dev/null -w '%{http_code}' -m "$HEALER_PROBE_TIMEOUT_SECS" \
    "$1" 2>/dev/null)" || true
  case "$code" in
    ''|*[!0-9]*) printf '0' ;;
    *) printf '%s' "$code" ;;
  esac
}

# url_up <code> — 0 when 2xx or 3xx (a redirect is up); 1 otherwise, including
# 0 (curl itself failed).
url_up() {
  case "$1" in
    2*|3*) return 0 ;;
    *) return 1 ;;
  esac
}

# health_up <address> <health-path> — 0 when the backend health endpoint
# (http://<address><health-path>) answers 2xx.
health_up() {
  local code
  code="$(curl -s -o /dev/null -w '%{http_code}' -m "$HEALER_PROBE_TIMEOUT_SECS" \
    "http://${1}${2}" 2>/dev/null)" || true
  url_up "$code"
}

# state accessors for the per-URL failure streak.
get_failure_count() {
  printf '%s' "$(read_state)" \
    | jq -r --arg u "$1" '(.failures // {})[($u)] // 0'
}

set_failure_count() {
  local url="$1" n="$2" state new
  state="$(read_state)"
  new="$(jq -nc \
    --argjson state "$state" --arg u "$url" --argjson n "$n" '
      ($state // {})
      | .failures = ((.failures // {}) + {($u): $n})
    ')" || return 1
  write_state "$new"
}

# service_address <svc-json> — first non-empty .Services[].Address (host:port);
# empty when the service has no registered address (unregistered).
service_address() {
  printf '%s' "$1" \
    | jq -r '
      ([ .Services[]? | select(type == "object"
          and (.Address | type) == "string" and (.Address != "")) | .Address ]
        | map(select(length > 0)) | unique | (.[0] // empty))'
}

# endpoint_alloc <jobs-json> <svc> — running allocation of the job that declares
# service <svc>, else empty.
endpoint_alloc() {
  local jobs_json="$1" svc="$2" ids id spec declared alloc
  ids="$(running_service_job_ids "$jobs_json")" || return 1
  while IFS= read -r id; do
    [ -n "$id" ] || continue
    job_id_ok "$id" || continue
    spec="$(nomad_get "/v1/job/${id}")"
    json_object "$spec" || continue
    declared="$(declared_names "$spec")" || continue
    printf '%s' "$declared" | jq -e --arg s "$svc" 'index($s) != null' >/dev/null 2>&1 || continue
    alloc="$(running_alloc "$(nomad_get "/v1/job/${id}/allocations")")"
    [ -n "$alloc" ] && { printf '%s' "$alloc"; return 0; }
  done <<< "$ids"
  return 1
}

# act_on_endpoint <job> <alloc> <url> <now> — one endpoint restart (or a dry-run
# line), with its tape proposal. A failed restart is not cooled down so the
# next tick may retry.
act_on_endpoint() {
  local job="$1" alloc="$2" url="$3" now="$4" pid="" ctx=""
  if [ "${HEALER_DRY_RUN:-}" = "1" ]; then
    log "would restart ${job}"
    return 0
  fi
  pid="$(healer_proposal_id)"
  ctx="$(jq -nc --arg sig "public-endpoint-down:${job}" \
    '{signature: $sig, organ: "healer"}')" || ctx=""
  if [ -z "$ctx" ] || ! tape_proposal "$pid" repair endpoint-restart "" "" \
      "$ctx" "" auto "url:${url}"; then
    log "WARNING: tape: failed to append endpoint proposal for ${job}"
    pid=""
  fi
  if ! nomad alloc restart "$alloc"; then
    log "WARNING: alloc restart failed for ${job} (${alloc})"
    return 0
  fi
  log "restarted alloc ${alloc} for job ${job} (public endpoint ${url})"
  if ! record_endpoint_restart "$job" "$pid" "$url" "$now"; then
    log "WARNING: failed to record endpoint restart state for ${url}"
  fi
  return 0
}

# record_endpoint_restart <job> <pid> <url> <now> — cooldown + endpoint_open
# (keyed by url) for a public-endpoint restart.
record_endpoint_restart() {
  local job="$1" pid="$2" url="$3" now="$4" state new
  state="$(read_state)"
  new="$(jq -nc \
    --argjson state "$state" --arg job "$job" --arg pid "$pid" \
    --arg url "$url" --argjson now "$now" '
      ($state // {}) as $s
      | .cooldown = (($s.cooldown // {}) + {($job): $now})
      | if $pid == "" then .
        else .endpoint_open = ((.endpoint_open // {})
          + {($url): {proposal_id: $pid, restarted_at: $now, job: $job}})
        end
    ')" || return 1
  write_state "$new"
}

# clear_unfixable <url> — drop the unfixable record for <url> when it is back
# up, so it is only reported while it actually needs a human.
clear_unfixable() {
  local url="$1" state new
  state="$(read_state)"
  if printf '%s' "$state" | jq -e --arg u "$url" '(.unfixable // {})
      | has($u)' >/dev/null 2>&1; then
    new="$(jq -nc --argjson state "$state" --arg u "$url" '
      ($state // {})
      | .unfixable = ((.unfixable // {}) | with_entries(
            select(.key != $u))
    ')" || return
    write_state "$new" || return
  fi
  return 0
}

# record_unfixable <url> <epoch> — set state.unfixable[url] = epoch only when
# it is not already recorded (once per incident). Return 0 when a new record
# was written, 1 when it was already recorded (nothing to do), 2 on failure.
record_unfixable() {
  local url="$1" now="$2" state new
  state="$(read_state)"
  if printf '%s' "$state" | jq -e --arg u "$url" '(.unfixable // {}) | has($u)' \
      >/dev/null 2>&1; then
    return 1
  fi
  new="$(jq -nc --argjson state "$state" --arg u "$url" --argjson now "$now" '
      ($state // {})
      | .unfixable = ((.unfixable // {}) + {($u): $now})')" || return 2
  write_state "$new" || return 2
  return 0
}

# endpoint_down <url> <now> — the URL is still down with nothing left to
# restart (healthy backend + edge in cooldown): record unfixable and log once.
endpoint_down() {
  local url="$1" now="$2"
  if record_unfixable "$url" "$now"; then
    log "WARNING: ${url} down with healthy backend and edge in cooldown — nothing left to restart (unfixable)"
  fi
}

# handle_public_endpoints <jobs-json> <now> — probe every configured URL, keep
# the failure streaks, and act when a streak reaches HEALER_PUBLIC_FAILURES.
# Never fails the tick.
handle_public_endpoints() {
  local jobs_json="$1" now="$2"
  local urls url svc job health alloc addr code count n backend
  urls="${HEALER_PUBLIC_URLS}"
  if [ -z "$urls" ]; then
    return 0
  fi
  for url in $urls; do
    code="$(probe_url "$url")"
    if url_up "$code"; then
      set_failure_count "$url" 0 || log "WARNING: failed to reset probe count for ${url}"
      clear_unfixable "$url"
      log "probe ${url} ${code} (up)"
      continue
    fi
    # Unfixable (see header): the fault is outside the box; do not restart
    # again until this URL answers 2xx/3xx again.
    if printf '%s' "$(read_state)" | jq -e --arg u "$url" \
      '.unfixable // {} | has($u)' >/dev/null 2>&1; then
      log "probe ${url} ${code} (unfixable — no action)"
      continue
    fi
    n="$(get_failure_count "$url")" || n=0
    count=$((n + 1))
    set_failure_count "$url" "$count" || log "WARNING: failed to set probe count for ${url}"
    log "probe ${url} ${code} (failing ticks: ${count})"
    if [ "$count" -lt "$HEALER_PUBLIC_FAILURES" ]; then
      continue
    fi
    backend="$(endpoint_backend "$url" || true)"
    if [ -z "$backend" ]; then
      log "WARNING: no backend for public endpoint ${url}"
      continue
    fi
    read -r svc job health <<< "$backend"
    addr="$(service_address "$(nomad_get "/v1/service/${svc}")" 2>/dev/null || true)"
    if [ -z "$addr" ]; then
      # Unregistered service — #1950's service-reregister pass owns it.
      log "skip ${url}: service ${svc} unregistered"
      continue
    fi
    healthy=1
    if ! health_up "$addr" "$health"; then
      healthy=0
      log "probe ${url}: backend ${svc} unhealthy"
    fi
    if [ "$healthy" -eq 1 ] && [ "$RESTARTS" -ge "$HEALER_MAX_RESTARTS" ]; then
      continue
    fi
    if [ "$healthy" -eq 1 ]; then
      target_job="edge"
    else
      target_job="$job"
    fi
    # Cooldown for the job we would restart.
    if in_cooldown "$target_job" "$now"; then
      if [ "$healthy" -eq 1 ]; then
        endpoint_down "$url" "$now"
      fi
      continue
    fi
    alloc="$(endpoint_alloc "$jobs_json" "$target_job")" || continue
    if [ -z "$alloc" ]; then
      log "WARNING: no running alloc for job ${target_job}"
      continue
    fi
    if [ "$healthy" -eq 0 ]; then
      act_on_endpoint "$job" "$alloc" "$url" "$now"
    else
      act_on_endpoint "edge" "$alloc" "$url" "$now"
    fi
    RESTARTS=$((RESTARTS + 1))
  done
  return 0
}

# close_endpoint_open <now> — close an open endpoint-restart proposal:
# cleared=1 when the URL answers 2xx/3xx, else cleared=0 when the job's
# restart cooldown has passed. The entry is dropped either way; a missing or
# malformed entry is skipped. Never fails the tick.
close_endpoint_open() {
  local now="$1" state urls url pid restarted job code cleared bits
  state="$(read_state)"
  urls="$(jq -r '.endpoint_open // {} | keys[]' <<<"$state")"
  while IFS= read -r url; do
    [ -n "$url" ] || continue
    pid="$(jq -r --arg u "$url" '.endpoint_open[$u].proposal_id // empty' <<<"$state")"
    restarted="$(jq -r --arg u "$url" '.endpoint_open[$u].restarted_at // empty' <<<"$state")"
    job="$(jq -r --arg u "$url" '.endpoint_open[$u].job // empty' <<<"$state")"
    if [ -z "$pid" ] || [ -z "$restarted" ] || [ "$restarted" = "null" ]; then
      continue
    fi
    code="$(probe_url "$url")"
    if url_up "$code"; then
      cleared=1
    elif [ "$((now - restarted))" -ge "$HEALER_COOLDOWN_SECS" ]; then
      cleared=0
    else
      continue
    fi
    bits="$(jq -nc --argjson cleared "$cleared" '{acted: 1, cleared: $cleared}')" \
      || bits=""
    if [ -z "$bits" ] || ! tape_outcome "$pid" "$bits" '{}' '{}' '[]'; then
      log "WARNING: tape: failed to append endpoint outcome for ${url} (${pid})"
      continue
    fi
    log "outcome recorded for ${job} cleared=${cleared}"
    if ! state="$(printf '%s' "$state" | jq -c --arg u "$url" 'del(.endpoint_open[$u])')"; then
      log "WARNING: failed to drop endpoint_open entry for ${url}"
      continue
    fi
    write_state "$state" || log "WARNING: failed to write state after dropping ${url}"
  done <<< "$urls"
  return 0
}
healer_tick() {
  local jobs services now
  if ! agent_healthy; then
    log "WARNING: /v1/agent/health failed — no restart"
    return 0
  fi
  now="$(date -u +%s)"
  jobs="$(nomad_get /v1/jobs)"
  services="$(nomad_get /v1/services)"
  if ! json_array "$jobs" || ! json_array "$services"; then
    log "WARNING: nomad query failed — no restart"
    return 0
  fi
  close_open "$services" || log "WARNING: outcome pass failed"
  restart_unregistered "$jobs" "$services" || log "WARNING: restart pass failed"
  close_endpoint_open "$now" || log "WARNING: endpoint outcome pass failed"
  handle_public_endpoints "$jobs" "$now" || log "WARNING: endpoint pass failed"
  return 0
}

main() {
  command -v curl >/dev/null 2>&1 || { log "missing curl"; exit 1; }
  command -v jq >/dev/null 2>&1 || { log "missing jq"; exit 1; }
  command -v nomad >/dev/null 2>&1 || { log "missing nomad"; exit 1; }
  mkdir -p "$HEALER_STATE_DIR" || log "WARNING: cannot create ${HEALER_STATE_DIR}"
  while true; do
    healer_tick || log "WARNING: tick failed"
    if [ "$ONCE" -eq 1 ]; then
      return 0
    fi
    sleep "$HEALER_INTERVAL_SECS"
  done
}

main
