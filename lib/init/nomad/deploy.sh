#!/usr/bin/env bash
# =============================================================================
# lib/init/nomad/deploy.sh — Dependency-ordered Nomad job deploy + wait
#
# Runs a list of jobspecs in order, waiting for each to reach healthy state
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
#   JOB_READY_TIMEOUT_SECS — poll timeout in seconds (default: 360)
#   JOB_READY_TIMEOUT_<JOBNAME> — per-job timeout override (e.g.,
#                            JOB_READY_TIMEOUT_FORGEJO=300)
#                            Built-in: JOB_READY_TIMEOUT_CHAT=600
#
# Exit codes:
#   0  success (all jobs deployed and healthy, or dry-run completed)
#   1  failure (validation error, or one or more jobs unhealthy after all
#      jobs submitted — deploy does NOT cascade-skip on timeout)
#
# Idempotency:
#   Running twice back-to-back on a healthy cluster is a no-op. Jobs that are
#   already healthy print "[deploy] <name> already healthy" and continue.
# =============================================================================
set -euo pipefail

# ── Configuration ────────────────────────────────────────────────────────────
SCRIPT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${REPO_ROOT:-$(cd "${SCRIPT_ROOT}/../../.." && pwd)}"
JOB_READY_TIMEOUT_SECS="${JOB_READY_TIMEOUT_SECS:-360}"

# Per-job built-in defaults (override with JOB_READY_TIMEOUT_<JOBNAME> env var)
JOB_READY_TIMEOUT_CHAT="${JOB_READY_TIMEOUT_CHAT:-600}"

DRY_RUN=0
FAILED_JOBS=()  # jobs that timed out or failed deployment

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
# Polls `nomad deployment status -json <deployment-id>` until:
#   - Status == "successful"
#   - Status == "failed"
#
# On deployment failure: prints last 50 lines of stderr from allocations and exits 1.
# On timeout: prints last 50 lines of stderr from allocations and exits 1.
#
# This is a named, reusable helper for future init scripts.
_wait_job_running() {
  local job_name="$1"
  local timeout="$2"
  local elapsed=0

  log "waiting for job '${job_name}' to become healthy (timeout: ${timeout}s)..."

  # Get the latest deployment ID for this job (retry until available)
  local deployment_id=""
  local retry_count=0
  local max_retries=12

  while [ -z "$deployment_id" ] && [ "$retry_count" -lt "$max_retries" ]; do
    deployment_id=$(nomad job deployments -json "$job_name" 2>/dev/null | jq -r '.[0].ID' 2>/dev/null) || deployment_id=""
    if [ -z "$deployment_id" ]; then
      sleep 5
      retry_count=$((retry_count + 1))
    fi
  done

  if [ -z "$deployment_id" ]; then
    log "ERROR: no deployment found for job '${job_name}' after ${max_retries} attempts"
    return 1
  fi

  log "tracking deployment '${deployment_id}'..."

  while [ "$elapsed" -lt "$timeout" ]; do
    local deploy_status_json
    deploy_status_json=$(nomad deployment status -json "$deployment_id" 2>/dev/null) || {
      # Deployment may not exist yet — keep waiting
      sleep 5
      elapsed=$((elapsed + 5))
      continue
    }

    local status
    status=$(printf '%s' "$deploy_status_json" | jq -r '.Status' 2>/dev/null) || {
      sleep 5
      elapsed=$((elapsed + 5))
      continue
    }

    case "$status" in
      successful)
        log "${job_name} healthy after ${elapsed}s"
        return 0
        ;;
      failed)
        log "deployment '${deployment_id}' failed for job '${job_name}'"
        log "showing last 50 lines of allocation logs (stderr):"

        # Get allocation IDs from job status
        local alloc_ids
        alloc_ids=$(nomad job status -json "$job_name" 2>/dev/null \
          | jq -r '.Allocations[]?.ID // empty' 2>/dev/null) || alloc_ids=""

        if [ -n "$alloc_ids" ]; then
          for alloc_id in $alloc_ids; do
            log "--- Allocation ${alloc_id} logs (stderr) ---"
            nomad alloc logs -stderr -short "$alloc_id" 2>/dev/null | tail -50 || true
          done
        fi

        return 1
        ;;
      running|progressing)
        log "deployment '${deployment_id}' status: ${status} (waiting for ${job_name}...)"
        ;;
      *)
        log "deployment '${deployment_id}' status: ${status} (waiting for ${job_name}...)"
        ;;
    esac

    sleep 5
    elapsed=$((elapsed + 5))
  done

  # Timeout — print last 50 lines of alloc logs
  log "TIMEOUT: deployment '${deployment_id}' did not reach successful state within ${timeout}s"
  log "showing last 50 lines of allocation logs (stderr):"

  # Get allocation IDs from job status
  local alloc_ids
  alloc_ids=$(nomad job status -json "$job_name" 2>/dev/null \
    | jq -r '.Allocations[]?.ID // empty' 2>/dev/null) || alloc_ids=""

  if [ -n "$alloc_ids" ]; then
    for alloc_id in $alloc_ids; do
      log "--- Allocation ${alloc_id} logs (stderr) ---"
      nomad alloc logs -stderr -short "$alloc_id" 2>/dev/null | tail -50 || true
    done
  fi

  return 1
}

# ── Helper: _run_post_deploy <job_name> ─────────────────────────────────────
# Runs post-deploy scripts for a job after it becomes healthy.
# Currently supports: forgejo → run forgejo-bootstrap.sh
#
# Args:
#   job_name — name of the deployed job
#
# Returns:
#   0 on success (script ran or not applicable)
#   1 on failure
# ─────────────────────────────────────────────────────────────────────────────
_run_post_deploy() {
  local job_name="$1"
  local post_deploy_script

  case "$job_name" in
    forgejo)
      post_deploy_script="${SCRIPT_ROOT}/forgejo-bootstrap.sh"
      if [ -x "$post_deploy_script" ]; then
        log "running post-deploy script for ${job_name}"
        if ! "$post_deploy_script"; then
          log "ERROR: post-deploy script failed for ${job_name}"
          return 1
        fi
        log "post-deploy script completed for ${job_name}"
      else
        log "no post-deploy script found for ${job_name}, skipping"
      fi
      ;;
    *)
      log "no post-deploy script for ${job_name}, skipping"
      ;;
  esac

  return 0
}

# ── Main: deploy each job in order ───────────────────────────────────────────
for job_name in "${JOBS[@]}"; do
  jobspec_path="${REPO_ROOT}/nomad/jobs/${job_name}.hcl"

  if [ ! -f "$jobspec_path" ]; then
    die "Jobspec not found: ${jobspec_path}"
  fi

  # Per-job timeout override: JOB_READY_TIMEOUT_<UPPERCASE_JOBNAME>
  # Sanitize job name: replace hyphens with underscores (bash vars can't have hyphens)
  job_upper=$(printf '%s' "$job_name" | tr '[:lower:]-' '[:upper:]_' | tr ' ' '_')
  timeout_var="JOB_READY_TIMEOUT_${job_upper}"
  job_timeout="${!timeout_var:-$JOB_READY_TIMEOUT_SECS}"

  if [ "$DRY_RUN" -eq 1 ]; then
    log "[dry-run] nomad job validate ${jobspec_path}"
    log "[dry-run] nomad job run -detach ${jobspec_path}"
    log "[dry-run] (would wait for '${job_name}' to become healthy for ${job_timeout}s)"
    case "$job_name" in
      forgejo) log "[dry-run] [post-deploy] would run forgejo-bootstrap.sh" ;;
    esac
    continue
  fi

  log "processing job: ${job_name}"

  # 1. Validate the jobspec
  log "validating: ${jobspec_path}"
  if ! nomad job validate "$jobspec_path"; then
    die "validation failed for: ${jobspec_path}"
  fi

  # 2. Check if already healthy (idempotency)
  job_status_json=$(nomad job status -json "$job_name" 2>/dev/null || true)
  if [ -n "$job_status_json" ]; then
    current_status=$(printf '%s' "$job_status_json" | jq -r '.Status' 2>/dev/null || true)
    if [ "$current_status" = "running" ]; then
      log "${job_name} already healthy"
      continue
    fi
  fi

  # 3. Run the job (idempotent registration)
  log "running: ${jobspec_path}"
  if ! nomad job run -detach "$jobspec_path"; then
    die "failed to run job: ${job_name}"
  fi

  # 4. Wait for healthy state
  if ! _wait_job_running "$job_name" "$job_timeout"; then
    log "WARNING: deployment for job '${job_name}' did not reach successful state — continuing with remaining jobs"
    FAILED_JOBS+=("$job_name")
  fi

  # 5. Run post-deploy scripts
  if ! _run_post_deploy "$job_name"; then
    die "post-deploy script failed for job '${job_name}'"
  fi
done

if [ "$DRY_RUN" -eq 1 ]; then
  log "dry-run complete"
fi

# ── Final health summary ─────────────────────────────────────────────────────
if [ "${#FAILED_JOBS[@]}" -gt 0 ]; then
  log ""
  log "=== DEPLOY SUMMARY ==="
  log "The following jobs did NOT reach healthy state:"
  for failed in "${FAILED_JOBS[@]}"; do
    log "  - ${failed}"
  done
  log "All other jobs were submitted and healthy."
  log "======================"
  exit 1
fi

exit 0
