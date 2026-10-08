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
  local registered ids id spec declared missing allocs alloc now count=0
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
    if [ "$count" -ge "$HEALER_MAX_RESTARTS" ]; then
      log "restart cap reached — remaining jobs wait"
      break
    fi
    act_on "$id" "$alloc" "$missing" "$now"
    count=$((count + 1))
  done <<< "$ids"
  return 0
}

# healer_tick — one pass. Always returns 0: a query failure, a tape
# failure, or a restart failure must not stop the loop.
healer_tick() {
  local jobs services
  if ! agent_healthy; then
    log "WARNING: /v1/agent/health failed — no restart"
    return 0
  fi
  jobs="$(nomad_get /v1/jobs)"
  services="$(nomad_get /v1/services)"
  if ! json_array "$jobs" || ! json_array "$services"; then
    log "WARNING: nomad query failed — no restart"
    return 0
  fi
  close_open "$services" || log "WARNING: outcome pass failed"
  restart_unregistered "$jobs" "$services" || log "WARNING: restart pass failed"
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
