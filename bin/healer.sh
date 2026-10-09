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
# GET /v1/service/<name>, a JSON array of ServiceRegistration (Nomad 1.9):
# Address and Port are separate fields, joined here to host:port. [] is
# unregistered. The health check is curl on http://<address><health path>
# (2xx = healthy). An unregistered service is left to the service-reregister
# pass. Registered + unhealthy → that alloc is restarted; registered +
# healthy → the edge alloc is restarted.
# If the URL is still down after its own edge restart with a healthy backend,
# nothing is left to restart — the fault is outside the box (the Cloudflare
# tunnel): the URL is recorded under unfixable in state.json for #1955 and
# logged once. "Its own" is load-bearing: edge is a single job shared by all
# public endpoints, so the shared per-job cooldown alone must never declare a
# sibling URL that was never restarted to be outside the box (#1989). While
# that backend stays healthy, no further endpoint restart is attempted for
# that URL until it answers 2xx/3xx again (which resets the failure streak
# and clears the unfixable entry), so a bad tunnel does not drive a
# per-cooldown edge-restart loop. A later recheck that finds the backend
# unhealthy or unregistered drops the record (#1990) and the normal endpoint
# pass may restart that backend alloc, still subject to HEALER_COOLDOWN_SECS
# and the per-tick restart cap. A failed recheck keeps the record — a missed
# Nomad read is not "the backend died".
#
# Guards (a tick that cannot confirm Nomad is healthy does not restart,
# and does not close an open proposal — the next tick retries):
#   - a job named agents-* is skipped while `nomad alloc exec` finds a
#     process matching dev-agent.sh|review-pr.sh|gardener-run.sh|dsh ;
#     the next tick tries again (an exec failure also skips — do not kill
#     work the healer cannot see)
#   - at most one restart per job per HEALER_COOLDOWN_SECS (default 1800)
#   - at most 3 restarts per tick, shared by the service pass and every
#     public-endpoint restart (healthy or unhealthy backend). A URL past
#     the cap is still noted for escalation and is not restarted (#1988)
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
# Owner messages (#1955, the AD-006 exception #1970): the owner does not
# watch forge issues, the ops repo, or logs, and may take a day or more
# to answer. Operational faults are fixed here, best effort, without a
# human. The owner is told only when this healer's own fix did not work,
# and then by Telegram: each tick runs
#   ${HEALER_NOTIFY_CMD:-$FACTORY_ROOT/bin/notify-owner.sh} TEXT
# That command is the only sender. Nothing under lib/ sends it.
#
# An episode is one condition: service-unregistered:<job> or
# public-endpoint-down:<url>. It starts the first time the condition is
# seen and ends when the condition is gone. Episodes live in
# $HEALER_STATE_DIR/state.json (key "episodes") so a healer restart does
# not send a duplicate.
#
# The owner is messaged once per episode, when either:
#   - a remedy acted and the condition is still there
#     HEALER_ESCALATE_AFTER_SECS (default 1800) later, or
#   - #1952 recorded unfixable for the URL (that tick, no wait).
# The message is one plain-text paragraph naming the condition, since
# when, what the healer did and when, and the next step it cannot take.
#
# A reminder is sent every HEALER_REMIND_SECS (default 86400) while the
# episode lasts. A resolved line is sent only after this tick positively
# saw the condition gone: the job spec was read and the service is
# registered, or the URL was probed and answered 2xx/3xx. A skipped or
# failed check leaves the episode in place — it is not a clear. The line
# is "disinto: resolved: <condition> (down <duration>)", and only if a
# message was already sent for that episode. A condition that cleared
# before any message sends none.
#
# A failed send, or a send that reports the channel is not configured,
# logs a WARNING and is retried on a later tick, at most once per 10
# minutes. It never stops the loop. The episode stays in state, so a
# missed send is not forgotten and a healer restart does not duplicate
# one that landed.
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
#   HEALER_STATE_DIR        open proposals + cooldown + episodes
#                           (default /srv/disinto/healer)
#   HEALER_PUBLIC_URLS      whitespace-separated public endpoints to probe
#                           (default https://self.disinto.ai/forge/
#                           https://self.disinto.ai/ci/; empty = no probing)
#   HEALER_DRY_RUN          1 = log would restart, do not act
#   HEALER_ESCALATE_AFTER_SECS
#                           seconds after a remedy before the owner is told
#                           the condition is still there (default 1800)
#   HEALER_REMIND_SECS      seconds between reminders while an episode lasts
#                           (default 86400)
#   HEALER_NOTIFY_CMD       command that receives the message text (default
#                           $FACTORY_ROOT/bin/notify-owner.sh)
#   HEALER_NOW              optional epoch clock (tests); unset uses date
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
# `:-` would treat an explicit empty value as unset and restore the default,
# which would probe when the caller asked for none. Empty means no probing.
HEALER_PUBLIC_URLS="${HEALER_PUBLIC_URLS-https://self.disinto.ai/forge/ https://self.disinto.ai/ci/}"
# Health-check curl timeout for public endpoints (separate from NOMAD_TIMEOUT,
# which is for the Nomad API).
HEALER_PROBE_TIMEOUT_SECS="${HEALER_PROBE_TIMEOUT_SECS:-10}"
# Owner escalation (#1955). Not a restart knob: a message, after a remedy
# has already failed to clear the fault, or when nothing is left to restart.
HEALER_ESCALATE_AFTER_SECS="${HEALER_ESCALATE_AFTER_SECS:-1800}"
HEALER_REMIND_SECS="${HEALER_REMIND_SECS:-86400}"
# A failed or not-configured send is retried at most this often. Fixed:
# the issue says 10 minutes, not an operator knob.
HEALER_NOTIFY_RETRY_SECS=600
# Shared per-tick restart budget: capped by HEALER_MAX_RESTARTS, shared by
# the service-reregister pass and the public-endpoint pass.
RESTARTS=0
# Conditions observed this tick, and conditions positively seen gone.
# A missing note is not a clear: the check may have failed. Reset each tick.
TICK_NOTES='[]'
TICK_CLEARS='[]'
# 1 only after the service-unregistered scan read jobs and the registry.
TICK_SERVICE_SCAN_OK=0

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
case "$HEALER_ESCALATE_AFTER_SECS" in
  ''|*[!0-9]*) HEALER_ESCALATE_AFTER_SECS=1800 ;;
esac
case "$HEALER_REMIND_SECS" in
  ''|*[!0-9]*) HEALER_REMIND_SECS=86400 ;;
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
# Host-side loop: do not source lib/env.sh (it wants USER/HOME and can
# clobber NOMAD_ADDR). FACTORY_ROOT is only needed to find notify-owner.sh.
FACTORY_ROOT="${FACTORY_ROOT:-$(cd "$SCRIPT_DIR/.." && pwd)}"
HEALER_NOTIFY_CMD="${HEALER_NOTIFY_CMD:-$FACTORY_ROOT/bin/notify-owner.sh}"
# shellcheck source=../lib/tape.sh
source "${SCRIPT_DIR}/../lib/tape.sh"

log() {
  printf '[%s] healer: %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$*"
}

# healer_now — epoch seconds. HEALER_NOW lets a test advance the clock
# without sleeping; production leaves it unset.
healer_now() {
  case "${HEALER_NOW:-}" in
    ''|*[!0-9]*) date -u +%s ;;
    *) printf '%s' "$HEALER_NOW" ;;
  esac
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
  # Refuse a non-array. An empty capture must not reach --argjson (jq writes
  # a parse error to stderr and the tick would look like it failed the read).
  case "$1" in '['*) ;; *) return 1 ;; esac
  case "$2" in '['*) ;; *) return 1 ;; esac
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
  else
    episode_note_restart "service-unregistered:${job}" "$job" "$now" \
      || log "WARNING: failed to note episode restart for ${job}"
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
  now="$(healer_now)"
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
  local registered ids id spec declared missing allocs alloc now cap_logged=0
  RESTARTS=0
  TICK_SERVICE_SCAN_OK=0
  registered="$(registered_names "$services_json")" || {
    log "WARNING: could not read registered services — no restart"
    return 0
  }
  now="$(healer_now)"
  ids="$(running_service_job_ids "$jobs_json")" || {
    log "WARNING: could not read jobs — no restart"
    return 0
  }
  TICK_SERVICE_SCAN_OK=1
  while IFS= read -r id; do
    [ -n "$id" ] || continue
    if ! job_id_ok "$id"; then
      log "WARNING: skip unsafe job id"
      continue
    fi
    spec="$(nomad_get "/v1/job/${id}")"
    # A failed spec read is not a clear. Leave any open episode alone.
    json_object "$spec" || continue
    declared="$(declared_names "$spec")" || continue
    case "$declared" in
      '['*) ;;
      *) continue ;;
    esac
    missing="$(missing_names "$declared" "$registered")" || continue
    if [ "$missing" = "[]" ]; then
      tick_clear "service-unregistered:${id}"
      continue
    fi
    # Seen, whether or not this tick is allowed to restart it.
    tick_note "service-unregistered:${id}" "service still unregistered" "$id"
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
      if [ "$cap_logged" -eq 0 ]; then
        log "restart cap reached — remaining jobs wait"
        cap_logged=1
      fi
      continue
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

# service_address <svc-json> — host:port of the first Nomad 1.9
# ServiceRegistration in a GET /v1/service/:name body. That body is a JSON
# array; Address and Port are separate fields. [] (and an array with no
# usable registration) is unregistered: print nothing. A non-array is not a
# registration list; print nothing and let the caller decide whether that
# was a failed read.
service_address() {
  printf '%s' "$1" \
    | jq -r '
      if type != "array" then empty
      else
        [ .[] | select(type == "object"
            and (.Address | type) == "string" and .Address != ""
            and (.Port | type) == "number"
            and .Port > 0 and .Port < 65536)
          | if (.Address | contains(":")) then
              "[" + .Address + "]:" + (.Port | tostring)
            else
              .Address + ":" + (.Port | tostring)
            end
        ] | .[0] // empty
      end
    ' 2>/dev/null || true
}

# endpoint_alloc <jobs-json> <job> — the running allocation of <job>, else
# empty. <job> is looked up by ID, not service name: endpoint_backend()
# already knows the job that declares the service (which can differ, e.g.
# service woodpecker in job woodpecker-server), so a service-name search would
# miss it. The running-service-job guard keeps us away from jobs that are no
# longer running service jobs.
endpoint_alloc() {
  local jobs_json="$1" job="$2" ids alloc
  job_id_ok "$job" || return 1
  ids="$(running_service_job_ids "$jobs_json")" || return 1
  grep -Fxq -- "$job" <<<"$ids" || return 1
  alloc="$(running_alloc "$(nomad_get "/v1/job/${job}/allocations")")"
  [ -n "$alloc" ] && { printf '%s' "$alloc"; return 0; }
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
  else
    episode_note_restart "public-endpoint-down:${url}" "$job" "$now" \
      || log "WARNING: failed to note episode restart for ${url}"
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
      | ($s + {cooldown: (($s.cooldown // {}) + {($job): $now})})
      | if $pid == "" then .
        else .endpoint_open = ((.endpoint_open // {})
          + {($url): {proposal_id: $pid, restarted_at: $now, job: $job}})
        end
    ')" || return 1
  write_state "$new"
}

# clear_unfixable <url> — drop the unfixable record for <url>. Called when
# the URL answers 2xx/3xx, and when a recheck finds the backend unhealthy
# or unregistered (#1990) so the normal restart path can run.
clear_unfixable() {
  local url="$1" state new
  state="$(read_state)"
  if printf '%s' "$state" | jq -e --arg u "$url" '(.unfixable // {})
      | has($u)' >/dev/null 2>&1; then
    new="$(jq -nc --argjson state "$state" --arg u "$url" '
      ($state // {})
      | .unfixable = ((.unfixable // {}) | with_entries(
            select(.key != $u)))
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

# own_endpoint_restart <url> <now> — 0 when <url>'s own endpoint restart is
# still inside the cooldown window: its endpoint_open entry exists with a
# restarted_at within HEALER_COOLDOWN_SECS of <now>; 1 otherwise (never
# restarted, or its own window has elapsed).
#
# The per-job cooldown in in_cooldown() is shared across every public endpoint
# (edge is one job), so it cannot by itself say "this URL was restarted".
# #1989: recording unfixable off the shared cooldown declared a sibling URL
# that had never been restarted to be outside the box. endpoint_open[url] is
# set exactly when this URL's own restart acted, and close_endpoint_open keeps
# it only while the URL is down and its own window is open, so it is the
# per-URL signal the unfixable decision needs.
own_endpoint_restart() {
  local url="$1" now="$2" state at
  state="$(read_state)"
  at="$(printf '%s' "$state" | jq -r --arg u "$url" \
      '.endpoint_open[$u].restarted_at // empty' 2>/dev/null)" || return 1
  case "$at" in ''|*[!0-9]*) return 1 ;; esac
  [ $((now - at)) -lt "$HEALER_COOLDOWN_SECS" ]
}

# endpoint_down <url> <now> — the URL is still down with a healthy backend and
# its own edge restart still cooling (nothing left to restart for this URL):
# record unfixable and log once.
endpoint_down() {
  local url="$1" now="$2"
  if record_unfixable "$url" "$now"; then
    log "WARNING: ${url} down with healthy backend and edge in cooldown — nothing left to restart (unfixable)"
  fi
}

# unfixable_backend_dead URL — 0 when a recheck shows the backend is
# unhealthy or unregistered, so state.unfixable[url] must be dropped (#1990).
# 1 when the backend is still healthy, or the recheck failed (keep the
# record; do not guess from an empty Nomad read).
unfixable_backend_dead() {
  local url="$1" backend svc health addr raw
  backend="$(endpoint_backend "$url" 2>/dev/null || true)"
  [ -n "$backend" ] || return 1
  read -r svc _ health <<< "$backend"
  [ -n "$svc" ] || return 1
  raw="$(nomad_get "/v1/service/${svc}")"
  # Empty or non-array is a failed read, not "unregistered". A Nomad
  # 1.9 success is a JSON array ([] = no registrations). jq exits 0 on
  # empty input without running the filter, so the empty check is first.
  [ -n "$raw" ] || return 1
  if ! printf '%s' "$raw" | jq -e 'type == "array"' >/dev/null 2>&1; then
    return 1
  fi
  addr="$(service_address "$raw")"
  if [ -z "$addr" ]; then
    return 0
  fi
  if health_up "$addr" "$health"; then
    return 1
  fi
  return 0
}

# handle_public_endpoints <jobs-json> <now> — probe every configured URL, keep
# the failure streaks, and act when a streak reaches HEALER_PUBLIC_FAILURES.
# The shared HEALER_MAX_RESTARTS budget applies to every restart here, healthy
# or unhealthy backend. A URL past the cap is still noted (the tick_note above
# the check) and is not restarted. Never fails the tick.
handle_public_endpoints() {
  local jobs_json="$1" now="$2"
  local urls url svc job health alloc addr code count n backend
  local healthy=0 target_job="" word="" detail=""
  urls="${HEALER_PUBLIC_URLS}"
  if [ -z "$urls" ]; then
    return 0
  fi
  for url in $urls; do
    code="$(probe_url "$url")"
    if url_up "$code"; then
      set_failure_count "$url" 0 || log "WARNING: failed to reset probe count for ${url}"
      clear_unfixable "$url"
      tick_clear "public-endpoint-down:${url}"
      log "probe ${url} ${code} (up)"
      continue
    fi
    # Unfixable (see header): recorded while the backend was healthy and
    # the edge was in cooldown. Keep it only while a recheck still shows
    # that backend healthy. Unhealthy or unregistered means the fault is
    # back inside the box: drop the record and fall through so this pass
    # can restart the backend alloc (cooldown and the per-tick cap still
    # apply). A failed recheck keeps the record.
    if printf '%s' "$(read_state)" | jq -e --arg u "$url" \
      '.unfixable // {} | has($u)' >/dev/null 2>&1; then
      if ! unfixable_backend_dead "$url"; then
        note_unfixable_down "$url" "$code"
        log "probe ${url} ${code} (unfixable — no action)"
        continue
      fi
      if clear_unfixable "$url"; then
        log "probe ${url} ${code} (backend down — unfixable cleared)"
      else
        log "WARNING: failed to drop unfixable for ${url}"
      fi
    fi
    # Down. Note before any continue so a skip cannot look like a clear.
    tick_note "public-endpoint-down:${url}" "still ${code}" ""
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
    word="healthy"
    if ! health_up "$addr" "$health"; then
      healthy=0
      word="unhealthy"
      log "probe ${url}: backend ${svc} unhealthy"
    fi
    detail="$(endpoint_detail "$url" "$code" "$word")"
    if [ "$healthy" -eq 1 ]; then
      target_job="edge"
    else
      target_job="$job"
    fi
    tick_note "public-endpoint-down:${url}" "$detail" "$target_job"
    # Shared budget (#1950/#1952/#1988). Already noted above, so escalation
    # still sees this URL. Applies whether the backend is healthy or not.
    if [ "$RESTARTS" -ge "$HEALER_MAX_RESTARTS" ]; then
      log "restart cap reached — ${url} waits"
      continue
    fi
    # Cooldown for the job we would restart.  The unfixable record follows only
    # when this URL's own endpoint restart is what is cooling; the shared
    # per-job cooldown is set by whichever endpoint last restarted the job and
    # would alone falsely declare a sibling URL that was never restarted to be
    # outside the box (#1989).
    if in_cooldown "$target_job" "$now"; then
      if [ "$healthy" -eq 1 ] && own_endpoint_restart "$url" "$now"; then
        endpoint_down "$url" "$now"
      fi
      continue
    fi
    alloc="$(endpoint_alloc "$jobs_json" "$target_job")" || {
      tick_note "public-endpoint-down:${url}" "$detail" "$target_job"
      continue
    }
    if [ -z "$alloc" ]; then
      log "WARNING: no running alloc for job ${target_job}"
      continue
    fi
    if [ "$healthy" -eq 0 ]; then
      act_on_endpoint "$job" "$alloc" "$url" "$now"
    else
      act_on_endpoint "edge" "$alloc" "$url" "$now"
    fi
    tick_note "public-endpoint-down:${url}" "$detail" "$target_job"
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

# ── owner escalation (#1955) ────────────────────────────────────────────────
# The owner is messaged from here, never from lib/. A send failure is a
# WARNING and a later retry; it does not fail the tick.

# tick_note CONDITION DETAIL ACTED_JOB — one observation this tick.
# A later note for the same condition replaces this one in escalate_pass.
tick_note() {
  local condition="$1" detail="$2" acted_job="$3" new
  new="$(jq -nc \
    --argjson cur "$TICK_NOTES" \
    --arg c "$condition" \
    --arg detail "$detail" \
    --arg job "$acted_job" \
    '$cur + [{condition: $c, detail: $detail, acted_job: $job}]')" || {
    log "WARNING: failed to note condition ${condition}"
    return 0
  }
  TICK_NOTES="$new"
}

# tick_clear CONDITION — this tick positively saw the condition gone.
tick_clear() {
  local condition="$1" new
  new="$(jq -nc --argjson cur "$TICK_CLEARS" --arg c "$condition" \
    '$cur + [$c] | unique')" || {
    log "WARNING: failed to record clear for ${condition}"
    return 0
  }
  TICK_CLEARS="$new"
}

# note_unfixable_down URL CODE — the URL is still down and already
# unfixable. Recheck the backend. A failed check keeps the last real
# detail (empty detail does not overwrite it) and does not claim healthy.
note_unfixable_down() {
  local url="$1" code="$2" backend svc health addr word detail=""
  backend="$(endpoint_backend "$url" 2>/dev/null || true)"
  if [ -n "$backend" ]; then
    read -r svc _ health <<< "$backend"
    addr="$(service_address "$(nomad_get "/v1/service/${svc}")" 2>/dev/null || true)"
    if [ -n "$addr" ]; then
      word="healthy"
      if ! health_up "$addr" "$health"; then
        word="unhealthy"
      fi
      detail="$(endpoint_detail "$url" "$code" "$word")"
    fi
  fi
  tick_note "public-endpoint-down:${url}" "$detail" "edge"
}

# endpoint_detail URL CODE WORD — "still 502, forgejo healthy".
# WORD empty → "still <code>". Always returns 0.
endpoint_detail() {
  local url="$1" code="$2" word="$3" backend svc
  backend="$(endpoint_backend "$url" 2>/dev/null || true)"
  svc="${backend%% *}"
  if [ -n "$svc" ] && [ -n "$word" ]; then
    printf 'still %s, %s %s' "$code" "$svc" "$word"
  else
    printf 'still %s' "$code"
  fi
  return 0
}

# episode_note_restart CONDITION JOB NOW — remember the first remedy.
# A later restart must not push the escalation clock out forever.
episode_note_restart() {
  local condition="$1" job="$2" now="$3" state new
  state="$(read_state)"
  new="$(jq -nc \
    --argjson state "$state" \
    --arg c "$condition" \
    --arg job "$job" \
    --argjson now "$now" '
      ($state // {}) as $s
      | ($s.episodes // {}) as $eps
      | ($eps[$c] // {
          since: $now,
          acted_at: 0,
          acted_job: "",
          sent: 0,
          notified_at: 0,
          last_attempt_at: 0,
          detail: ""
        }) as $ep
      | (if ($ep.acted_at // 0) == 0 then
           $ep + {acted_at: $now, acted_job: $job}
         else $ep end) as $ep2
      | $s + {episodes: ($eps + {($c): $ep2})}
    ')" || return 1
  write_state "$new"
}

episode_put() {
  local cond="$1" ep="$2" state new
  state="$(read_state)"
  new="$(jq -nc --argjson state "$state" --arg c "$cond" --argjson ep "$ep" '
    ($state // {}) | .episodes = ((.episodes // {}) + {($c): $ep})
  ')" || return 1
  write_state "$new"
}

episode_drop() {
  local cond="$1" state new
  state="$(read_state)"
  new="$(jq -nc --argjson state "$state" --arg c "$cond" '
    ($state // {}) | .episodes = ((.episodes // {}) | del(.[$c]))
  ')" || return 1
  write_state "$new"
}

# episode_unfixable CONDITION — 0 when #1952 recorded unfixable for the URL.
episode_unfixable() {
  local cond="$1" url state
  case "$cond" in
    public-endpoint-down:*) url="${cond#public-endpoint-down:}" ;;
    *) return 1 ;;
  esac
  state="$(read_state)"
  printf '%s' "$state" | jq -e --arg u "$url" \
    '(.unfixable // {}) | has($u)' >/dev/null 2>&1
}

fmt_clock() {
  date -u -d "@$1" '+%H:%M UTC' 2>/dev/null || printf '%s' "$1"
}

fmt_down() {
  local s="$1" d h m
  case "$s" in
    ''|*[!0-9]*) s=0 ;;
  esac
  d=$((s / 86400))
  s=$((s % 86400))
  h=$((s / 3600))
  s=$((s % 3600))
  m=$((s / 60))
  s=$((s % 60))
  if [ "$d" -gt 0 ]; then
    printf '%dd%dh' "$d" "$h"
  elif [ "$h" -gt 0 ]; then
    printf '%dh%02dm' "$h" "$m"
  elif [ "$m" -gt 0 ]; then
    printf '%dm%02ds' "$m" "$s"
  else
    printf '%ds' "$s"
  fi
}

# build_owner_text KIND COND SINCE ACTED_JOB ACTED_AT DETAIL UNFIXABLE
# One paragraph. A reminder keeps the same facts with a reminder prefix.
build_owner_text() {
  local kind="$1" cond="$2" since="$3" acted_job="$4" acted_at="$5"
  local detail="$6" unfixable="$7"
  local since_hm acted_clause next body job
  case "$since" in ''|*[!0-9]*) since=0 ;; esac
  case "$acted_at" in ''|*[!0-9]*) acted_at=0 ;; esac
  since_hm="$(fmt_clock "$since")"
  if [ -n "$acted_job" ] && [ "$acted_at" -gt 0 ]; then
    acted_clause="Restarted ${acted_job} at $(fmt_clock "$acted_at")"
  else
    acted_clause="No restart recorded"
  fi
  case "$cond" in
    public-endpoint-down:*)
      if [ "$unfixable" -eq 1 ]; then
        next="Likely the Cloudflare tunnel on the host. Check: systemctl status cloudflared"
      else
        next="The healer cannot restart ${acted_job:-the alloc} again until cooldown ends. Check: nomad alloc status ${acted_job:-edge}"
      fi
      if [ -z "$detail" ]; then
        detail="still down"
      fi
      body="disinto: ${cond} down since ${since_hm}. ${acted_clause}; ${detail}. ${next}"
      ;;
    service-unregistered:*)
      job="${cond#service-unregistered:}"
      next="The healer cannot restart the Nomad agent. Check: nomad job status ${job}"
      body="disinto: ${cond} since ${since_hm}. ${acted_clause}; service still unregistered. ${next}"
      ;;
    *)
      body="disinto: ${cond} since ${since_hm}. ${acted_clause}. ${detail}"
      ;;
  esac
  if [ "$kind" = "reminder" ]; then
    body="disinto: reminder: ${body#disinto: }"
  fi
  printf '%s' "$body"
}

# healer_notify TEXT — 0 sent, 2 channel not configured, 1 any other failure.
# Never exits the healer. stderr is kept off the success path so a
# "not configured" line is visible and a token is not.
healer_notify() {
  local text="$1" cmd errf rc=0 err_line
  cmd="${HEALER_NOTIFY_CMD:-}"
  if [ -z "$cmd" ]; then
    log "WARNING: notify command is empty"
    return 1
  fi
  errf="$(mktemp)" || {
    log "WARNING: notify: cannot create temp file"
    return 1
  }
  # `cmd || rc=$?` — not `if ! cmd; then rc=$?`. The `!` inverts the status,
  # so $? inside that then-branch is 0 and a failed send looks like success.
  "$cmd" "$text" 2>"$errf" || rc=$?
  err_line="$(head -n 1 "$errf" 2>/dev/null || true)"
  rm -f "$errf"
  err_line="${err_line:0:200}"
  if [ "$rc" -eq 0 ]; then
    case "$err_line" in
      *'not configured'*) return 2 ;;
    esac
    return 0
  fi
  if [ -n "$err_line" ]; then
    log "WARNING: notify command failed (exit ${rc}): ${err_line}"
  else
    log "WARNING: notify command failed (exit ${rc})"
  fi
  return 1
}

# reconcile_episode COND DETAIL ACTED_JOB NOW — create or refresh one
# episode. acted_at stays at the first remedy. Cooldown / endpoint_open
# fill it in when the restart was recorded before this object existed.
reconcile_episode() {
  local cond="$1" detail="$2" note_job="$3" now="$4"
  local state ep at since url e_at e_job cur_at
  state="$(read_state)"
  ep="$(jq -c --arg c "$cond" --argjson now "$now" '
    .episodes[$c] // {
      since: $now, acted_at: 0, acted_job: "", sent: 0,
      notified_at: 0, last_attempt_at: 0, detail: ""
    }' <<<"$state")" || return 1
  if [ -n "$detail" ]; then
    ep="$(jq -c --arg d "$detail" '.detail = $d' <<<"$ep")" || return 1
  fi
  at="$(jq -r '.acted_at // 0' <<<"$ep")"
  case "$at" in ''|*[!0-9]*) at=0 ;; esac
  if [ "$at" -eq 0 ]; then
    if [ -z "$note_job" ]; then
      case "$cond" in
        service-unregistered:*) note_job="${cond#service-unregistered:}" ;;
      esac
    fi
    since="$(jq -r '.since // 0' <<<"$ep")"
    case "$since" in ''|*[!0-9]*) since=0 ;; esac
    if [ -n "$note_job" ]; then
      at="$(jq -r --arg j "$note_job" '.cooldown[$j] // 0' <<<"$state")"
      case "$at" in ''|*[!0-9]*) at=0 ;; esac
      if [ "$at" -gt 0 ] && [ "$at" -ge "$since" ]; then
        ep="$(jq -c --arg job "$note_job" --argjson at "$at" \
          '.acted_at = $at | .acted_job = $job' <<<"$ep")" || return 1
      fi
    fi
    case "$cond" in
      public-endpoint-down:*)
        url="${cond#public-endpoint-down:}"
        e_at="$(jq -r --arg u "$url" '.endpoint_open[$u].restarted_at // 0' <<<"$state")"
        e_job="$(jq -r --arg u "$url" '.endpoint_open[$u].job // ""' <<<"$state")"
        case "$e_at" in ''|*[!0-9]*) e_at=0 ;; esac
        cur_at="$(jq -r '.acted_at // 0' <<<"$ep")"
        case "$cur_at" in ''|*[!0-9]*) cur_at=0 ;; esac
        since="$(jq -r '.since // 0' <<<"$ep")"
        case "$since" in ''|*[!0-9]*) since=0 ;; esac
        if [ "$cur_at" -eq 0 ] && [ "$e_at" -gt 0 ] && [ "$e_at" -ge "$since" ] && [ -n "$e_job" ]; then
          ep="$(jq -c --arg job "$e_job" --argjson at "$e_at" \
            '.acted_at = $at | .acted_job = $job' <<<"$ep")" || return 1
        fi
        ;;
    esac
  fi
  episode_put "$cond" "$ep"
}

# owner_due EP NOW UNFIXABLE — prints "escalation" or "reminder", or nothing.
# A failed attempt is not retried until HEALER_NOTIFY_RETRY_SECS have passed.
owner_due() {
  local ep="$1" now="$2" unfixable="$3"
  local sent acted notified last kind=""
  sent="$(jq -r '.sent // 0' <<<"$ep")"
  acted="$(jq -r '.acted_at // 0' <<<"$ep")"
  notified="$(jq -r '.notified_at // 0' <<<"$ep")"
  last="$(jq -r '.last_attempt_at // 0' <<<"$ep")"
  case "$sent" in 1|true) sent=1 ;; *) sent=0 ;; esac
  case "$acted" in ''|*[!0-9]*) acted=0 ;; esac
  case "$notified" in ''|*[!0-9]*) notified=0 ;; esac
  case "$last" in ''|*[!0-9]*) last=0 ;; esac
  if [ "$sent" -eq 0 ]; then
    if [ "$unfixable" -eq 1 ]; then
      kind="escalation"
    elif [ "$acted" -gt 0 ] && [ $((now - acted)) -ge "$HEALER_ESCALATE_AFTER_SECS" ]; then
      kind="escalation"
    fi
  elif [ $((now - notified)) -ge "$HEALER_REMIND_SECS" ]; then
    kind="reminder"
  fi
  [ -n "$kind" ] || return 0
  if [ "$last" -gt 0 ] && [ "$now" -ge "$last" ] \
      && [ $((now - last)) -lt "$HEALER_NOTIFY_RETRY_SECS" ]; then
    if [ "$sent" -eq 0 ] || [ "$last" -gt "$notified" ]; then
      return 0
    fi
  fi
  printf '%s' "$kind"
}

# send_owner_message COND KIND NOW UNFIXABLE — one attempt. Records the
# attempt before the send so a crash cannot tight-loop, and records a
# success after. A failure leaves sent=0 (or the previous notified_at) so
# the episode is not lost.
send_owner_message() {
  local cond="$1" kind="$2" now="$3" unfixable="$4"
  local state ep text rc since acted_job acted_at detail
  state="$(read_state)"
  ep="$(jq -c --arg c "$cond" '.episodes[$c] // empty' <<<"$state")"
  [ -n "$ep" ] || return 0
  since="$(jq -r '.since // 0' <<<"$ep")"
  acted_job="$(jq -r '.acted_job // ""' <<<"$ep")"
  acted_at="$(jq -r '.acted_at // 0' <<<"$ep")"
  detail="$(jq -r '.detail // ""' <<<"$ep")"
  text="$(build_owner_text "$kind" "$cond" "$since" "$acted_job" "$acted_at" "$detail" "$unfixable")" \
    || return 0
  [ -n "$text" ] || return 0
  ep="$(jq -c --argjson now "$now" '.last_attempt_at = $now' <<<"$ep")" || return 0
  if ! episode_put "$cond" "$ep"; then
    log "WARNING: failed to record notify attempt for ${cond} — not sending this tick"
    return 0
  fi
  rc=0
  healer_notify "$text" || rc=$?
  if [ "$rc" -eq 0 ]; then
    state="$(read_state)"
    ep="$(jq -c --arg c "$cond" --argjson now "$now" \
      '.episodes[$c] | .sent = 1 | .notified_at = $now' <<<"$state")" || {
      log "WARNING: notify sent for ${cond} but could not read the episode back"
      return 0
    }
    episode_put "$cond" "$ep" || log "WARNING: notify sent for ${cond} but failed to record it"
    if [ "$kind" = "reminder" ]; then
      log "reminded owner: ${cond}"
    else
      log "notified owner: ${cond}"
    fi
    return 0
  fi
  if [ "$rc" -eq 2 ]; then
    log "WARNING: notify: not configured (${cond})"
  else
    log "WARNING: notify failed for ${cond}"
  fi
  return 0
}

# send_resolved COND NOW — one resolved line, only if a message was sent.
# Otherwise the episode is dropped with no send. A failed resolved send
# keeps the episode so the next tick can retry.
send_resolved() {
  local cond="$1" now="$2"
  local state ep sent last notified since dur text rc
  state="$(read_state)"
  ep="$(jq -c --arg c "$cond" '.episodes[$c] // empty' <<<"$state")"
  [ -n "$ep" ] || return 0
  sent="$(jq -r '.sent // 0' <<<"$ep")"
  case "$sent" in
    1|true) ;;
    *)
      episode_drop "$cond" || log "WARNING: failed to drop silent episode ${cond}"
      return 0
      ;;
  esac
  last="$(jq -r '.last_attempt_at // 0' <<<"$ep")"
  notified="$(jq -r '.notified_at // 0' <<<"$ep")"
  case "$last" in ''|*[!0-9]*) last=0 ;; esac
  case "$notified" in ''|*[!0-9]*) notified=0 ;; esac
  if [ "$last" -gt "$notified" ] && [ "$now" -ge "$last" ] \
      && [ $((now - last)) -lt "$HEALER_NOTIFY_RETRY_SECS" ]; then
    return 0
  fi
  since="$(jq -r '.since // 0' <<<"$ep")"
  case "$since" in ''|*[!0-9]*) since=0 ;; esac
  if [ "$now" -ge "$since" ]; then
    dur="$((now - since))"
  else
    dur=0
  fi
  text="disinto: resolved: ${cond} (down $(fmt_down "$dur"))"
  ep="$(jq -c --argjson now "$now" '.last_attempt_at = $now' <<<"$ep")" || return 0
  if ! episode_put "$cond" "$ep"; then
    log "WARNING: failed to record resolved attempt for ${cond}"
    return 0
  fi
  rc=0
  healer_notify "$text" || rc=$?
  if [ "$rc" -eq 0 ]; then
    episode_drop "$cond" || log "WARNING: resolved sent for ${cond} but failed to drop the episode"
    log "notified owner: resolved ${cond}"
    return 0
  fi
  if [ "$rc" -eq 2 ]; then
    log "WARNING: notify: not configured (${cond})"
  else
    log "WARNING: notify failed for resolved ${cond}"
  fi
  return 0
}

# escalate_pass NOW — message, remind, or resolve. Never fails the tick.
escalate_pass() {
  local now="$1" active cond detail job unfixable kind conds
  active="$(jq -c 'reduce .[] as $n ({}; .[$n.condition] = $n) | [.[]]' \
    <<<"$TICK_NOTES" 2>/dev/null)" || active='[]'
  conds="$(jq -r '.[].condition' <<<"$active" 2>/dev/null || true)"
  while IFS= read -r cond; do
    [ -n "$cond" ] || continue
    detail="$(jq -r --arg c "$cond" \
      '.[] | select(.condition == $c) | .detail' <<<"$active")" || detail=""
    job="$(jq -r --arg c "$cond" \
      '.[] | select(.condition == $c) | .acted_job' <<<"$active")" || job=""
    reconcile_episode "$cond" "$detail" "$job" "$now" \
      || log "WARNING: failed to update episode ${cond}"
    # Prefer the stored detail: an empty note means "keep the last real one".
    detail="$(jq -r --arg c "$cond" '.episodes[$c].detail // ""' <<<"$(read_state)")" \
      || detail=""
    unfixable=0
    if episode_unfixable "$cond"; then
      unfixable=1
    fi
    # Backend died after unfixable was recorded: do not tell the owner the
    # tunnel is the next step, and do not claim the backend is healthy.
    case "$detail" in
      *unhealthy*) unfixable=0 ;;
    esac
    kind="$(owner_due "$(jq -c --arg c "$cond" '.episodes[$c] // {}' <<<"$(read_state)")" \
      "$now" "$unfixable")" || kind=""
    [ -n "$kind" ] || continue
    send_owner_message "$cond" "$kind" "$now" "$unfixable" \
      || log "WARNING: escalate failed for ${cond}"
  done <<< "$conds"

  conds="$(jq -r '.episodes // {} | keys[]' <<<"$(read_state)" 2>/dev/null || true)"
  while IFS= read -r cond; do
    [ -n "$cond" ] || continue
    # Still observed down this tick.
    if jq -e --arg c "$cond" 'any(.[]; .condition == $c)' <<<"$active" >/dev/null 2>&1; then
      continue
    fi
    # Resolve only on a positive clear. A failed spec read, a jobs-list
    # failure, or a URL that was not probed must leave the episode in place.
    case "$cond" in
      service-unregistered:*)
        [ "$TICK_SERVICE_SCAN_OK" -eq 1 ] || continue
        ;;
    esac
    jq -e --arg c "$cond" 'index($c) != null' <<<"$TICK_CLEARS" >/dev/null 2>&1 \
      || continue
    send_resolved "$cond" "$now" || log "WARNING: resolved failed for ${cond}"
  done <<< "$conds"
  return 0
}

healer_tick() {
  local jobs services now
  if ! agent_healthy; then
    log "WARNING: /v1/agent/health failed — no restart"
    return 0
  fi
  now="$(healer_now)"
  TICK_NOTES='[]'
  TICK_CLEARS='[]'
  TICK_SERVICE_SCAN_OK=0
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
  escalate_pass "$now" || log "WARNING: escalate pass failed"
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
