#!/usr/bin/env bash
# =============================================================================
# factory-walk.sh — factory-walk gate: agent alloc restart rate (#1277)
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
# Re-baselining: restart counters are per-alloc. A *replaced* alloc (new
# alloc id — redeploy, node migration) starts at 0 and must NOT be paged
# against the old alloc's counter, so a changed alloc id re-baselines
# silently. A counter that decreases on the same alloc (should be
# impossible) also re-baselines with a WALK-WARN.
#
# Integration: invoked by the existing factory walk — no new cron, no new
# deps (bash + nomad + coreutils only). If the live walk's queue lives
# elsewhere, point WALK_QUEUE_DIR at it.
#
# Contract:
#   - Always exits 0. Degraded runs (nomad missing, job stopped, parse
#     failure) print WALK-WARN and page nothing — a gate must not take the
#     walk down.
#   - Paging = one item file per alerted alloc in $WALK_QUEUE_DIR plus a
#     WALK-ALERT line on stdout for the walk log:
#       WALK-ALERT job=<job> alloc=<id> restarts=<n> prev=<p> delta=+<d>
#       WALK-WARN  job=<job>: <reason>
#       WALK-OK    job=<job> ...
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
# =============================================================================
set -euo pipefail

FACTORY_WALK_JOBS="${FACTORY_WALK_JOBS:-agents-dev-qwen agents-review-qwen}"
FACTORY_WALK_RESTART_THRESHOLD="${FACTORY_WALK_RESTART_THRESHOLD:-2}"
WALK_STATE_DIR="${WALK_STATE_DIR:-${HOME}/memory/factory-walk-state}"
WALK_QUEUE_DIR="${WALK_QUEUE_DIR:-${HOME}/memory/factory-walk-queue}"
NOMAD_BIN="${NOMAD_BIN:-nomad}"

ALERTS=0

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

# main — run the gate for every configured job.
main() {
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

main "$@"
