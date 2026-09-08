#!/usr/bin/env bash
# =============================================================================
# factory-walk.sh — factory-walk gates:
#   1. agent alloc restart rate (#1277)
#   2. Nomad service registration presence (#1278)
#
# 2026-09-08 outage: both agent allocs (agents-dev-qwen, agents-review-qwen)
# crash-looped for ~26h (exit 1 every 30m, Forgejo undiscoverable) while the
# factory walk reported OK every 40 minutes — the logs were still fresh
# (entrypoint "waiting for ..." messages), so the log-freshness gates saw
# nothing wrong. Freshness says nothing about the *rate of death*, so this
# gate tracks the Nomad per-alloc "Total Restarts" counter instead: when an
# alloc gains >= FACTORY_WALK_RESTART_THRESHOLD restarts between two
# consecutive walks, the walk queue is paged.
#
# Per walk, for each job in FACTORY_WALK_JOBS:
#   1. latest alloc id  — `nomad alloc list -latest <job>` (first row)
#   2. total restarts   — "Total Restarts" line of `nomad alloc status <id>`
#                          (max over all task rows)
#   3. diff vs previous walk — state in $WALK_STATE_DIR/<job>.restarts
#   4. delta >= threshold   — page $WALK_QUEUE_DIR (one item file per alloc)
#
# Service registration gate (#1278):
#
# Same outage, second half: the `forgejo` service vanished from Nomad's
# service registry while the forgejo alloc stayed running — the task-level
# health checks read success and the registry was the only source that knew.
# Nomad service discovery (nomadService "forgejo") then resolved nothing,
# clients rendered an empty FORGE_URL and crash-looped. For each service
# the job templates discover via nomadService, the gate queries the Nomad
# HTTP API (GET /v1/service/<name>) and pages when the service has zero
# registrations while its owning job still has a running alloc (GET
# /v1/job/<job>/allocations?prefix=running). All services present pages
# nothing; a service with zero registrations AND no running alloc (job
# stopped on purpose) pages nothing either.
#
# Placement: the supervisor loop (supervisor/preflight.sh) does not shell
# out to Nomad — it reads Docker labels, phase files, and the Forge API from
# inside the agents container. Per issue #1278 the check therefore lives in
# the walk script's Nomad section, next to the restart gate.
#
# The remedy stays manual: a paged item tells the operator to run
# `nomad alloc restart <alloc>` on the owning alloc. The gate never
# auto-restarts anything.
#
# Re-baselining: restart counters are per-alloc. A *replaced* alloc (new
# alloc id — redeploy, node migration) starts at 0 and must NOT be paged
# against the old alloc's counter, so a changed alloc id re-baselines
# silently. A counter that decreases on the same alloc (should be
# impossible) also re-baselines with a WALK-WARN.
#
# Integration: invoked by the existing factory walk — no new cron. Restart
# gate deps: nomad CLI + coreutils; service gate deps: curl + jq (both
# degrade to WALK-WARN when missing — the gate never takes the walk down).
# If the live walk's queue lives elsewhere, point WALK_QUEUE_DIR at it.
#
# Contract:
#   - Always exits 0. Degraded runs (nomad missing, curl/jq missing, API
#     unreachable, parse failure) print WALK-WARN and page nothing — a gate
#     must not take the walk down.
#   - Paging = one item file per alerted alloc/service in $WALK_QUEUE_DIR
#     plus a WALK-ALERT line on stdout for the walk log:
#       WALK-ALERT job=<job> alloc=<id> restarts=<n> prev=<p> delta=+<d>
#       WALK-ALERT service=<svc> job=<job> registrations=0 \
#                    running_allocs=<n> alloc=<id>
#       WALK-WARN  job=<job>: <reason> | service=<svc>: <reason>
#       WALK-OK    job=<job> ... | service=<svc> ...
#
# Environment (all optional):
#   FACTORY_WALK_JOBS               space-separated job ids
#                                   (default: "agents-dev-qwen agents-review-qwen")
#   FACTORY_WALK_RESTART_THRESHOLD  page when an alloc gains >= N restarts
#                                   between walks (default: 2)
#   WALK_STATE_DIR                  previous-walk state dir
#                                   (default: $HOME/memory/factory-walk-state)
#   WALK_QUEUE_DIR                  walk queue dir that receives page items
#                                   (default: $HOME/memory/factory-walk-queue)
#   NOMAD_BIN                       nomad binary (default: "nomad")
#   FACTORY_WALK_SERVICES           space-separated "service:job" pairs to
#                                   watch — the services our templates
#                                   discover via nomadService and the job
#                                   that owns each registration
#                                   (default: "forgejo:forgejo woodpecker:woodpecker-server")
#   NOMAD_ADDR                      Nomad HTTP API base URL
#                                   (default: http://127.0.0.1:4646)
#   NOMAD_TOKEN                     Nomad ACL token (default: none)
#   NOMAD_TIMEOUT                   per-API-call timeout in seconds
#                                   (default: 5)
# =============================================================================
set -euo pipefail

FACTORY_WALK_JOBS="${FACTORY_WALK_JOBS:-agents-dev-qwen agents-review-qwen}"
FACTORY_WALK_RESTART_THRESHOLD="${FACTORY_WALK_RESTART_THRESHOLD:-2}"
WALK_STATE_DIR="${WALK_STATE_DIR:-${HOME}/memory/factory-walk-state}"
WALK_QUEUE_DIR="${WALK_QUEUE_DIR:-${HOME}/memory/factory-walk-queue}"
NOMAD_BIN="${NOMAD_BIN:-nomad}"
# Service-registration gate (#1278): "service:job" pairs — the services our
# templates discover via nomadService, and the job that owns each.
FACTORY_WALK_SERVICES="${FACTORY_WALK_SERVICES:-forgejo:forgejo woodpecker:woodpecker-server}"
NOMAD_ADDR="${NOMAD_ADDR:-http://127.0.0.1:4646}"
NOMAD_TIMEOUT="${NOMAD_TIMEOUT:-5}"

ALERTS=0
SERVICE_ALERTS=0
API_BODY=""
API_CODE=""
API_BODY_FILE=""

log() { printf '%s\n' "$*"; }
warn() { log "WALK-WARN $*"; }

# page <job> <alloc> <prev> <cur> <delta> — append one walk-queue item.
page() {
  local job="$1" alloc="$2" prev="$3" cur="$4" delta="$5"
  local ts item
  ts="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
  mkdir -p "$WALK_QUEUE_DIR"
  # Filename ends in -at-<cur>: cur strictly increases between pages for a
  # given alloc, so back-to-back pages never overwrite each other even in
  # the same second.
  item="$WALK_QUEUE_DIR/$(date -u '+%Y%m%dT%H%M%SZ')-${job}-restarts-+${delta}-at-${cur}.txt"
  {
    echo "factory-walk restart gate — ${ts}"
    echo "job:      ${job}"
    echo "alloc:    ${alloc}"
    echo "restarts: ${cur} (previous walk: ${prev}, delta +${delta}, threshold ${FACTORY_WALK_RESTART_THRESHOLD})"
    echo ""
    echo "The alloc is restarting faster than normal (>= ${FACTORY_WALK_RESTART_THRESHOLD} between"
    echo "walks) — likely crash-looping. Inspect with:"
    echo "  ${NOMAD_BIN} alloc status ${alloc}"
    echo "  ${NOMAD_BIN} alloc logs ${alloc}"
  } > "$item"
  log "WALK-ALERT job=${job} alloc=${alloc} restarts=${cur} prev=${prev} delta=+${delta} (paged: ${item})"
}

# read_state <job> — load previous-walk state into RESTART_STATE_ALLOC /
# RESTART_STATE_COUNT (empty if absent or unparseable).
read_state() {
  local job="$1"
  local f="$WALK_STATE_DIR/${job}.restarts"
  local k v
  RESTART_STATE_ALLOC=""
  RESTART_STATE_COUNT=""
  [ -f "$f" ] || return 0
  while IFS='=' read -r k v || [ -n "$k" ]; do
    case "$k" in
      alloc) RESTART_STATE_ALLOC="$v" ;;
      restarts)
        case "$v" in
          ''|*[!0-9]*) : ;;
          *) RESTART_STATE_COUNT="$v" ;;
        esac
        ;;
    esac
  done < "$f"
}

# write_state <job> <alloc> <count> — persist this walk's values (atomic).
write_state() {
  local job="$1" alloc="$2" count="$3"
  local f="$WALK_STATE_DIR/${job}.restarts"
  local tmp
  mkdir -p "$WALK_STATE_DIR"
  tmp="$(mktemp "${f}.XXXXXX")"
  {
    echo "alloc=${alloc}"
    echo "restarts=${count}"
    echo "updated=$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
  } > "$tmp"
  mv "$tmp" "$f"
}

# latest_alloc <job> — id of the job's latest alloc; returns 1 if the job
# has none (stopped) or nomad fails.
latest_alloc() {
  local job="$1" out
  if ! out="$("$NOMAD_BIN" alloc list -latest "$job" 2>/dev/null)"; then
    warn "job=${job}: nomad alloc list failed — skipping"
    return 1
  fi
  printf '%s\n' "$out" | awk 'NR==2 && NF { print $1; exit }'
}

# total_restarts <alloc> — "Total Restarts" from `nomad alloc status`, max
# over all task rows; returns 1 if nomad fails or the line is absent.
total_restarts() {
  local alloc="$1" out
  if ! out="$("$NOMAD_BIN" alloc status "$alloc" 2>/dev/null)"; then
    warn "alloc=${alloc}: nomad alloc status failed — skipping"
    return 1
  fi
  printf '%s\n' "$out" \
    | grep -iE 'total[[:space:]]+restarts' \
    | grep -oE '[0-9]+' \
    | sort -n \
    | tail -n 1
}

# check_job <job> — one gate pass for one job.
check_job() {
  local job="$1"
  local alloc cur prev delta
  if ! alloc="$(latest_alloc "$job")" || [ -z "$alloc" ]; then
    warn "job=${job}: no alloc found (job stopped?) — skipping"
    return 0
  fi
  if ! cur="$(total_restarts "$alloc")" || [ -z "$cur" ]; then
    warn "job=${job}: no 'Total Restarts' line in alloc status — skipping"
    return 0
  fi

  read_state "$job"
  if [ "$RESTART_STATE_ALLOC" != "$alloc" ]; then
    write_state "$job" "$alloc" "$cur"
    log "WALK-OK job=${job} alloc=${alloc} restarts=${cur} (new alloc — baseline set)"
    return 0
  fi
  if [ -z "$RESTART_STATE_COUNT" ]; then
    write_state "$job" "$alloc" "$cur"
    log "WALK-OK job=${job} alloc=${alloc} restarts=${cur} (baseline set)"
    return 0
  fi

  prev="$RESTART_STATE_COUNT"
  delta=$((cur - prev))
  if [ "$delta" -lt 0 ]; then
    warn "job=${job}: restart counter decreased (${prev} -> ${cur}) — re-baselining"
    write_state "$job" "$alloc" "$cur"
    return 0
  fi
  if [ "$delta" -ge "$FACTORY_WALK_RESTART_THRESHOLD" ]; then
    page "$job" "$alloc" "$prev" "$cur" "$delta"
    ALERTS=$((ALERTS + 1))
  else
    log "WALK-OK job=${job} alloc=${alloc} restarts=${cur} (prev ${prev}, +${delta})"
  fi
  write_state "$job" "$alloc" "$cur"
}

# restart_gate — one pass of the restart-rate gate over every configured job.
restart_gate() {
  local job
  if ! command -v "$NOMAD_BIN" >/dev/null 2>&1; then
    warn "nomad binary '${NOMAD_BIN}' not found — restart gate skipped (degraded)"
    return 0
  fi
  local jobs=()
  read -r -a jobs <<< "$FACTORY_WALK_JOBS"
  for job in "${jobs[@]}"; do
    [ -n "$job" ] || continue
    check_job "$job"
  done
  if [ "$ALERTS" -gt 0 ]; then
    log "factory-walk: ${ALERTS} restart alert(s) paged to ${WALK_QUEUE_DIR}"
  else
    log "factory-walk: restart gate OK (no alloc gained >= ${FACTORY_WALK_RESTART_THRESHOLD} restarts since last walk)"
  fi
}

# ── Service registration gate (#1278) ─────────────────────────────────────────
# Queries the Nomad HTTP API (not the CLI) — the CLI has no per-service
# registration query, and bin/ Nomad access uses the HTTP API by convention.

# api_get <path> — GET ${NOMAD_ADDR}<path>. Sets API_CODE (HTTP status) and
# API_BODY (response body). Returns 1 on transport failure (curl missing,
# timeout, connection refused).
api_get() {
  local path="$1"
  local -a headers=()
  [ -n "${NOMAD_TOKEN:-}" ] && headers+=(-H "X-Nomad-Token: ${NOMAD_TOKEN}")
  local code
  code="$(curl -sS --max-time "$NOMAD_TIMEOUT" \
    ${headers[@]+"${headers[@]}"} \
    -o "$API_BODY_FILE" -w '%{http_code}' \
    "${NOMAD_ADDR%/}${path}" 2>/dev/null)" || return 1
  API_CODE="$code"
  API_BODY="$(cat "$API_BODY_FILE")"
  return 0
}

# json_array_len <body> — element count of a JSON array body; prints
# "not-an-array" for anything else.
json_array_len() {
  printf '%s' "$1" | jq -r 'if type == "array" then length else "not-an-array" end' 2>/dev/null
}

# page_service <svc> <job> <running> <alloc> — append one walk-queue item.
# Back-to-back pages for the same service (condition persisting across
# walks, same second) must not overwrite each other, so a per-service page
# counter in $WALK_STATE_DIR suffixes the filename (the condition is an
# absolute, not a monotonically increasing counter).
page_service() {
  local svc="$1" job="$2" running="$3" alloc="$4"
  local ts item pages
  ts="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
  mkdir -p "$WALK_QUEUE_DIR" "$WALK_STATE_DIR"
  local pages_file="$WALK_STATE_DIR/${svc}.service-pages"
  pages="$(cat "$pages_file" 2>/dev/null)" || pages=""
  case "$pages" in ''|*[!0-9]*) pages=0 ;; esac
  pages=$((pages + 1))
  printf '%s\n' "$pages" > "$pages_file"
  item="$WALK_QUEUE_DIR/$(date -u '+%Y%m%dT%H%M%SZ')-${svc}-no-registrations-page-${pages}.txt"
  {
    echo "factory-walk service-registration gate — ${ts}"
    echo "service:      ${svc}"
    echo "job:          ${job}"
    echo "registrations: 0"
    echo "running allocs: ${running}"
    if [ -n "$alloc" ]; then
      echo "first alloc:    ${alloc}"
    fi
    echo ""
    echo "The service has zero Nomad registrations while its job has running"
    echo "alloc(s). Nomad service discovery (nomadService \"${svc}\") resolves"
    echo "nothing, so clients that render URLs from it (e.g. FORGE_URL) get"
    echo "empty values and crash-loop while task health reads success."
    echo ""
    echo "Remedy (manual — this gate does not auto-restart):"
    if [ -n "$alloc" ]; then
      echo "  ${NOMAD_BIN} alloc restart ${alloc}"
    fi
    echo "  ${NOMAD_BIN} alloc list ${job}   # find the owning alloc"
  } > "$item"
  log "WALK-ALERT service=${svc} job=${job} registrations=0 running_allocs=${running} alloc=${alloc:-?} (paged: ${item})"
}

# check_service <svc> <job> — page when the service has zero registrations
# while its owning job still has a running alloc.
check_service() {
  local svc="$1" job="$2"
  local n alloc

  # 1. Registrations for the service. A 404 means the service is absent from
  #    the registry entirely — also zero registrations.
  if ! api_get "/v1/service/${svc}"; then
    warn "service=${svc}: Nomad API unreachable — skipping (degraded)"
    return 0
  fi
  case "$API_CODE" in
    200) ;;
    404) n=0 ;;
    *)
      warn "service=${svc}: Nomad API returned HTTP ${API_CODE} — skipping"
      return 0
      ;;
  esac
  if [ "$API_CODE" = "200" ]; then
    n="$(json_array_len "$API_BODY")" || true
    case "$n" in
      ''|*[!0-9]*)
        warn "service=${svc}: unparseable /v1/service response — skipping"
        return 0
        ;;
    esac
  fi

  # 2. All present (or registrations exist) — nothing to do.
  if [ "$n" -gt 0 ]; then
    log "WALK-OK service=${svc} registrations=${n}"
    return 0
  fi

  # 3. Zero registrations: is the owning job still running? No running alloc
  #    means the job was stopped on purpose — not a registration loss.
  if ! api_get "/v1/job/${job}/allocations?prefix=running"; then
    warn "service=${svc}: allocations query failed — skipping (degraded)"
    return 0
  fi
  case "$API_CODE" in
    404)
      log "WALK-OK service=${svc} registrations=0 (job ${job} not found — not deployed)"
      return 0
      ;;
    200) ;;
    *)
      warn "service=${svc}: allocations query returned HTTP ${API_CODE} — skipping"
      return 0
      ;;
  esac
  n="$(json_array_len "$API_BODY")" || true
  case "$n" in
    ''|*[!0-9]*)
      warn "service=${svc}: unparseable allocations response — skipping"
      return 0
      ;;
  esac
  if [ "$n" -eq 0 ]; then
    log "WALK-OK service=${svc} registrations=0 (job ${job} has no running allocs)"
    return 0
  fi

  alloc="$(printf '%s' "$API_BODY" | jq -r '.[0].ID // empty' 2>/dev/null)" || alloc=""
  page_service "$svc" "$job" "$n" "$alloc"
  SERVICE_ALERTS=$((SERVICE_ALERTS + 1))
}

# service_gate — one pass over every "service:job" pair in FACTORY_WALK_SERVICES.
service_gate() {
  local pair svc job
  if ! command -v curl >/dev/null 2>&1 || ! command -v jq >/dev/null 2>&1; then
    warn "curl or jq not found — service-registration gate skipped (degraded)"
    return 0
  fi
  API_BODY_FILE="$(mktemp)"
  local pairs=()
  read -r -a pairs <<< "$FACTORY_WALK_SERVICES"
  for pair in "${pairs[@]}"; do
    [ -n "$pair" ] || continue
    svc="${pair%%:*}"
    job="${pair#*:}"
    if [ -z "$svc" ] || [ -z "$job" ] || [ "$svc" = "$pair" ]; then
      warn "service=${pair}: expected a 'service:job' pair — skipping"
      continue
    fi
    check_service "$svc" "$job"
  done
  rm -f "$API_BODY_FILE"
  if [ "$SERVICE_ALERTS" -gt 0 ]; then
    log "factory-walk: ${SERVICE_ALERTS} service-registration alert(s) paged to ${WALK_QUEUE_DIR}"
  else
    log "factory-walk: service-registration gate OK (all watched services have registrations or no running allocs)"
  fi
}

# main — run every gate.
main() {
  restart_gate
  service_gate
}

main "$@"
