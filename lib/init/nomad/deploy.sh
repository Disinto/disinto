#!/usr/bin/env bash
# =============================================================================
# lib/init/nomad/deploy.sh — Dependency-ordered Nomad job deploy + wait
#
# Runs a list of jobspecs in order, waiting for each to reach "running" state
# before starting the next. Step-1 uses it for forgejo-only; Steps 3–6 extend
# the job list.
#
# Usage:
#   lib/init/nomad/deploy.sh <jobname> [jobname2 ...] [--dry-run]
#
# Arguments:
#   jobname  — basename of jobspec (without .hcl), resolved to
#              ${REPO_ROOT}/nomad/jobs/<jobname>.hcl
#
# Environment:
#   REPO_ROOT              — absolute path to repo root (defaults to parent of
#                            this script's parent directory)
#   JOB_READY_TIMEOUT_SECS — poll timeout in seconds (default: 120)
#
# Exit codes:
#   0  success (all jobs deployed and running, or dry-run completed)
#   1  failure (validation error, timeout, or nomad command failure)
#
# Idempotency:
#   Running twice back-to-back on a healthy cluster is a no-op. Jobs that are
#   already running print "[deploy] <name> already running" and continue.
# =============================================================================
set -euo pipefail

# ── Configuration ────────────────────────────────────────────────────────────
SCRIPT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${REPO_ROOT:-$(cd "${SCRIPT_ROOT}/../../.." && pwd)}"
JOB_READY_TIMEOUT_SECS="${JOB_READY_TIMEOUT_SECS:-120}"

DRY_RUN=0

log() { printf '[deploy] %s\n' "$*" >&2; }
die() { printf '[deploy] ERROR: %s\n' "$*" >&2; exit 1; }

# ── Parse arguments ───────────────────────────────────────────────────────────
JOBS=()
while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run)
      DRY_RUN=1
      shift
      ;;
    -*)
      die "Unknown option: $1"
      ;;
    *)
      JOBS+=("$1")
      shift
      ;;
  esac
done

if [ "${#JOBS[@]}" -eq 0 ]; then
  die "Usage: $0 <jobname> [jobname2 ...] [--dry-run]"
fi

# ── Helper: _wait_job_running <name> <timeout> ───────────────────────────────
# Polls `nomad job status -json <name>` until:
#   - Status == "running", OR
#   - All allocations are in "running" state
#
# On timeout: prints last 50 lines of stderr from all allocations and exits 1.
#
# This is a named, reusable helper for future init scripts.
_wait_job_running() {
  local job_name="$1"
  local timeout="$2"
  local elapsed=0

  log "waiting for job '${job_name}' to become running (timeout: ${timeout}s)..."

  while [ "$elapsed" -lt "$timeout" ]; do
    local status_json
    status_json=$(nomad job status -json "$job_name" 2>/dev/null) || {
      # Job may not exist yet — keep waiting
      sleep 5
      elapsed=$((elapsed + 5))
      continue
    }

    local status
    status=$(printf '%s' "$status_json" | jq -r '.Status' 2>/dev/null) || {
      sleep 5
      elapsed=$((elapsed + 5))
      continue
    }

    case "$status" in
      running)
        log "job '${job_name}' is now running"
        return 0
        ;;
      complete)
        log "job '${job_name}' reached terminal state: ${status}"
        return 0
        ;;
      dead|failed)
        log "job '${job_name}' reached terminal state: ${status}"
        return 1
        ;;
      *)
        log "job '${job_name}' status: ${status} (waiting...)"
        ;;
    esac

    sleep 5
    elapsed=$((elapsed + 5))
  done

  # Timeout — print last 50 lines of alloc logs
  log "TIMEOUT: job '${job_name}' did not reach running state within ${timeout}s"
  log "showing last 50 lines of allocation logs (stderr):"

  # Get allocation IDs
  local alloc_ids
  alloc_ids=$(nomad job status -json "$job_name" 2>/dev/null \
    | jq -r '.Evaluations[].Allocations[]?.ID // empty' 2>/dev/null) || alloc_ids=""

  if [ -n "$alloc_ids" ]; then
    for alloc_id in $alloc_ids; do
      log "--- Allocation ${alloc_id} logs (stderr) ---"
      nomad alloc logs -stderr -short "$alloc_id" 2>/dev/null | tail -50 || true
    done
  fi

  return 1
}

# ── Main: deploy each job in order ───────────────────────────────────────────
for job_name in "${JOBS[@]}"; do
  jobspec_path="${REPO_ROOT}/nomad/jobs/${job_name}.hcl"

  if [ ! -f "$jobspec_path" ]; then
    die "Jobspec not found: ${jobspec_path}"
  fi

  if [ "$DRY_RUN" -eq 1 ]; then
    log "[dry-run] nomad job validate ${jobspec_path}"
    log "[dry-run] nomad job run -detach ${jobspec_path}"
    log "[dry-run] (would wait for '${job_name}' to become running for ${JOB_READY_TIMEOUT_SECS}s)"
    continue
  fi

  log "processing job: ${job_name}"

  # 1. Validate the jobspec
  log "validating: ${jobspec_path}"
  if ! nomad job validate "$jobspec_path"; then
    die "validation failed for: ${jobspec_path}"
  fi

  # 2. Check if already running (idempotency)
  job_status_json=$(nomad job status -json "$job_name" 2>/dev/null || true)
  if [ -n "$job_status_json" ]; then
    current_status=$(printf '%s' "$job_status_json" | jq -r '.Status' 2>/dev/null || true)
    if [ "$current_status" = "running" ]; then
      log "${job_name} already running"
      continue
    fi
  fi

  # 3. Run the job (idempotent registration)
  log "running: ${jobspec_path}"
  if ! nomad job run -detach "$jobspec_path"; then
    die "failed to run job: ${job_name}"
  fi

  # 4. Wait for running state
  if ! _wait_job_running "$job_name" "$JOB_READY_TIMEOUT_SECS"; then
    die "timeout waiting for job '${job_name}' to become running"
  fi
done

if [ "$DRY_RUN" -eq 1 ]; then
  log "dry-run complete"
fi

exit 0
