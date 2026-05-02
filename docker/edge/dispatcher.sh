#!/usr/bin/env bash
# dispatcher.sh — Edge task dispatcher
#
# Polls the ops repo for vault actions that arrived via admin-merged PRs.
#
# Flow:
# 1. Poll loop: git pull the ops repo every 60s
# 2. Scan vault/actions/ for TOML files without .result.json
# 3. Verify TOML arrived via merged PR with admin merger (Forgejo API)
# 4. Validate TOML using vault-env.sh validator
# 5. Decrypt declared secrets via load_secret (lib/env.sh)
# 6. Launch: delegate to _launch_runner_{docker,nomad} backend
# 7. Write <action-id>.result.json with exit code, timestamp, logs summary
#
# Part of #76.

set -euo pipefail

# Resolve script root (parent of lib/)
SCRIPT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Source shared environment (provides load_secret, log helpers, etc.)
source "${SCRIPT_ROOT}/../lib/env.sh"

# Project TOML location: prefer mounted path, fall back to cloned path
# Edge container mounts ./projects to /opt/disinto-projects;
# the shallow clone only has .toml.example files.
PROJECTS_DIR="${PROJECTS_DIR:-${FACTORY_ROOT:-/opt/disinto}-projects}"

# -----------------------------------------------------------------------------
# Backend selection: DISPATCHER_BACKEND={docker,nomad}
# Default: docker.  nomad lands as a pure addition during migration Step 5.
# -----------------------------------------------------------------------------
DISPATCHER_BACKEND="${DISPATCHER_BACKEND:-docker}"

# Ops repo location (vault/actions directory)
OPS_REPO_ROOT="${OPS_REPO_ROOT:-/home/agent/repos/disinto-ops}"
VAULT_ACTIONS_DIR="${OPS_REPO_ROOT}/vault/actions"

# Vault action validation
VAULT_ENV="${SCRIPT_ROOT}/../action-vault/vault-env.sh"

# Admin users who can merge vault PRs (from issue #77)
# Comma-separated list of Forgejo usernames with admin role
ADMIN_USERS="${FORGE_ADMIN_USERS:-vault-bot,admin}"

# Persistent log file for dispatcher
DISPATCHER_LOG_FILE="${DISINTO_LOG_DIR:-/tmp}/dispatcher/dispatcher.log"
mkdir -p "$(dirname "$DISPATCHER_LOG_FILE")"

# Log function with standardized format
log() {
  local agent="${LOG_AGENT:-dispatcher}"
  printf '[%s] %s: %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$agent" "$*" >> "$DISPATCHER_LOG_FILE"
}

# -----------------------------------------------------------------------------
# Forge API helpers for admin verification
# -----------------------------------------------------------------------------

# Check if a user has admin role
# Usage: is_user_admin <username>
# Returns: 0=yes, 1=no
is_user_admin() {
  local username="$1"
  local user_json

  # Use admin token for API check (Forgejo only exposes is_admin: true
  # when the requesting user is also a site admin)
  local admin_token="${FORGE_ADMIN_TOKEN:-${FORGE_TOKEN}}"

  # Fetch user info from Forgejo API
  user_json=$(curl -sf -H "Authorization: token ${admin_token}" \
    "${FORGE_URL}/api/v1/users/${username}" 2>/dev/null) || return 1

  # Forgejo uses .is_admin for site-wide admin users
  local is_admin
  is_admin=$(echo "$user_json" | jq -r '.is_admin // false' 2>/dev/null) || return 1

  if [[ "$is_admin" == "true" ]]; then
    return 0
  fi

  return 1
}

# Check if a user is in the allowed admin list
# Usage: is_allowed_admin <username>
# Returns: 0=yes, 1=no
is_allowed_admin() {
  local username="$1"
  local admin_list
  admin_list=$(echo "$ADMIN_USERS" | tr ',' '\n')

  while IFS= read -r admin; do
    admin=$(echo "$admin" | xargs)  # trim whitespace
    if [[ "$username" == "$admin" ]]; then
      return 0
    fi
  done <<< "$admin_list"

  # Also check via API if not in static list
  if is_user_admin "$username"; then
    return 0
  fi

  return 1
}

# Get the PR that introduced a specific file to vault/actions
# Usage: get_pr_for_file <file_path>
# Returns: PR number or empty if not found via PR
get_pr_for_file() {
  local file_path="$1"
  local file_name
  file_name=$(basename "$file_path")

  # Step 1: find the commit that added the file
  local add_commit
  add_commit=$(git -C "$OPS_REPO_ROOT" log --diff-filter=A --format="%H" \
    -- "vault/actions/${file_name}" 2>/dev/null | head -1)

  if [ -z "$add_commit" ]; then
    return 1
  fi

  # Step 2: find the merge commit that contains it via ancestry path
  local merge_line
  # Use --reverse to get the oldest (direct PR merge) first, not the newest
  merge_line=$(git -C "$OPS_REPO_ROOT" log --merges --ancestry-path \
    --reverse "${add_commit}..HEAD" --oneline 2>/dev/null | head -1)

  if [ -z "$merge_line" ]; then
    return 1
  fi

  # Step 3: extract PR number from merge commit message
  # Forgejo format: "Merge pull request 'title' (#N) from branch into main"
  local pr_num
  pr_num=$(echo "$merge_line" | grep -oE '#[0-9]+' | head -1 | tr -d '#')

  if [ -n "$pr_num" ]; then
    echo "$pr_num"
    return 0
  fi

  return 1
}

# Get PR merger info
# Usage: get_pr_merger <pr_number>
# Returns: JSON with merger username and merged timestamp
get_pr_merger() {
  local pr_number="$1"

  # Use ops repo API URL for PR lookups (not disinto repo)
  local ops_api="${FORGE_URL}/api/v1/repos/${FORGE_OPS_REPO}"

  curl -sf -H "Authorization: token ${FORGE_TOKEN}" \
    "${ops_api}/pulls/${pr_number}" 2>/dev/null | jq -r '{
      username: .merge_user?.login // .user?.login,
      merged: .merged,
      merged_at: .merged_at // empty
    }'
}

# Get PR reviews
# Usage: get_pr_reviews <pr_number>
# Returns: JSON array of reviews with reviewer login and state
get_pr_reviews() {
  local pr_number="$1"

  # Use ops repo API URL for PR lookups (not disinto repo)
  local ops_api="${FORGE_URL}/api/v1/repos/${FORGE_OPS_REPO}"

  curl -sf -H "Authorization: token ${FORGE_TOKEN}" \
    "${ops_api}/pulls/${pr_number}/reviews" 2>/dev/null
}

# Verify vault action was approved by an admin via PR review
# Usage: verify_admin_approver <pr_number> <action_id>
# Returns: 0=verified, 1=not verified
verify_admin_approver() {
  local pr_number="$1"
  local action_id="$2"

  # Fetch reviews for this PR
  local reviews_json
  reviews_json=$(get_pr_reviews "$pr_number") || {
    log "WARNING: Could not fetch reviews for PR #${pr_number} — skipping"
    return 1
  }

  # Check if there are any reviews
  local review_count
  review_count=$(echo "$reviews_json" | jq 'length // 0')
  if [ "$review_count" -eq 0 ]; then
    log "WARNING: No reviews found for PR #${pr_number} — rejecting"
    return 1
  fi

  # Check each review for admin approval
  local review
  while IFS= read -r review; do
    local reviewer state
    reviewer=$(echo "$review" | jq -r '.user?.login // empty')
    state=$(echo "$review" | jq -r '.state // empty')

    # Skip non-APPROVED reviews
    if [ "$state" != "APPROVED" ]; then
      continue
    fi

    # Skip if no reviewer
    if [ -z "$reviewer" ]; then
      continue
    fi

    # Check if reviewer is admin
    if is_allowed_admin "$reviewer"; then
      log "Verified: PR #${pr_number} approved by admin '${reviewer}'"
      return 0
    fi
  done < <(echo "$reviews_json" | jq -c '.[]')

  log "WARNING: No admin approval found for PR #${pr_number} — rejecting"
  return 1
}

# Verify vault action arrived via admin-merged PR
# Usage: verify_admin_merged <toml_file>
# Returns: 0=verified, 1=not verified
#
# Verification order (for auto-merge workflow):
# 1. Check PR reviews for admin APPROVED state (primary check for auto-merge)
# 2. Fallback: Check if merger is admin (backwards compat for manual merges)
#
# This handles the case where auto-merge is performed by a bot (dev-bot)
# but the actual approval came from an admin reviewer.
verify_admin_merged() {
  local toml_file="$1"
  local action_id
  action_id=$(basename "$toml_file" .toml)

  # Get the PR that introduced this file
  local pr_num
  pr_num=$(get_pr_for_file "$toml_file") || {
    log "WARNING: No PR found for action ${action_id} — skipping (possible direct push)"
    return 1
  }

  log "Action ${action_id} arrived via PR #${pr_num}"

  # First, try admin approver check (for auto-merge workflow)
  if verify_admin_approver "$pr_num" "$action_id"; then
    return 0
  fi

  # Fallback: Check merger (backwards compatibility for manual merges)
  local merger_json
  merger_json=$(get_pr_merger "$pr_num") || {
    log "WARNING: Could not fetch PR #${pr_num} details — skipping"
    return 1
  }

  local merged merger_username
  merged=$(echo "$merger_json" | jq -r '.merged // false')
  merger_username=$(echo "$merger_json" | jq -r '.username // empty')

  # Check if PR is merged
  if [[ "$merged" != "true" ]]; then
    log "WARNING: PR #${pr_num} is not merged — skipping"
    return 1
  fi

  # Check if merger is admin
  if [ -z "$merger_username" ]; then
    log "WARNING: Could not determine PR #${pr_num} merger — skipping"
    return 1
  fi

  if ! is_allowed_admin "$merger_username"; then
    log "WARNING: PR #${pr_num} merged by non-admin user '${merger_username}' — skipping"
    return 1
  fi

  log "Verified: PR #${pr_num} merged by admin '${merger_username}' (fallback check)"
  return 0
}

# -----------------------------------------------------------------------------
# Vault action processing
# -----------------------------------------------------------------------------

# Check if an action has already been completed
is_action_completed() {
  local id="$1"
  [ -f "${VAULT_ACTIONS_DIR}/${id}.result.json" ]
}

# Validate a vault action TOML file
# Usage: validate_action <toml_file>
# Sets: VAULT_ACTION_ID, VAULT_ACTION_FORMULA, VAULT_ACTION_CONTEXT, VAULT_ACTION_SECRETS, VAULT_DISPATCH_MODE
validate_action() {
  local toml_file="$1"

  # Source vault-env.sh for validate_vault_action function
  if [ ! -f "$VAULT_ENV" ]; then
    echo "ERROR: vault-env.sh not found at ${VAULT_ENV}" >&2
    return 1
  fi

  if ! source "$VAULT_ENV"; then
    echo "ERROR: failed to source vault-env.sh" >&2
    return 1
  fi

  if ! validate_vault_action "$toml_file"; then
    return 1
  fi

  return 0
}

# Extract dispatch_mode from TOML file
# Usage: get_dispatch_mode <toml_file>
# Returns: "direct" for direct-commit, "pr" for PR-merged, or empty if not specified
get_dispatch_mode() {
  local toml_file="$1"
  local toml_content dispatch_mode

  toml_content=$(cat "$toml_file")

  # Extract dispatch_mode field if present
  dispatch_mode=$(echo "$toml_content" | grep -E '^dispatch_mode\s*=' | sed -E 's/^dispatch_mode\s*=\s*"(.*)"/\1/' | tr -d '\r')

  if [ -n "$dispatch_mode" ]; then
    echo "$dispatch_mode"
  else
    # Default to "pr" for backward compatibility (PR-based workflow)
    echo "pr"
  fi
}

# Commit result.json to the ops repo via git push (portable, no bind-mount).
#
# Clones the ops repo into a scratch directory, writes the result file,
# commits as vault-bot, and pushes to the primary branch.
# Idempotent: skips if result.json already exists upstream.
# Retries on push conflict with rebase-and-push (handles concurrent merges).
#
# Usage: commit_result_via_git <action_id> <exit_code> <logs>
commit_result_via_git() {
  local action_id="$1"
  local exit_code="$2"
  local logs="$3"

  local result_relpath="vault/actions/${action_id}.result.json"
  local ops_clone_url="${FORGE_URL}/${FORGE_OPS_REPO}.git"
  local branch="${PRIMARY_BRANCH:-main}"
  local scratch_dir
  scratch_dir=$(mktemp -d /tmp/dispatcher-result-XXXXXX)
  # shellcheck disable=SC2064
  trap "rm -rf '${scratch_dir}'" RETURN

  # Shallow clone of the ops repo — only the primary branch
  if ! git clone --depth 1 --branch "$branch" \
    "$ops_clone_url" "$scratch_dir" 2>/dev/null; then
    log "ERROR: Failed to clone ops repo for result commit (action ${action_id})"
    return 1
  fi

  # Idempotency: skip if result.json already exists upstream
  if [ -f "${scratch_dir}/${result_relpath}" ]; then
    log "Result already exists upstream for ${action_id} — skipping commit"
    return 0
  fi

  # Configure git identity as vault-bot
  git -C "$scratch_dir" config user.name "vault-bot"
  git -C "$scratch_dir" config user.email "vault-bot@disinto.local"

  # Truncate logs if too long (keep last 1000 chars)
  if [ ${#logs} -gt 1000 ]; then
    logs="${logs: -1000}"
  fi

  # Write result JSON via jq (never string-interpolate into JSON)
  mkdir -p "$(dirname "${scratch_dir}/${result_relpath}")"
  jq -n \
    --arg id "$action_id" \
    --argjson exit_code "$exit_code" \
    --arg timestamp "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" \
    --arg logs "$logs" \
    '{id: $id, exit_code: $exit_code, timestamp: $timestamp, logs: $logs}' \
    > "${scratch_dir}/${result_relpath}"

  git -C "$scratch_dir" add "$result_relpath"
  git -C "$scratch_dir" commit -q -m "vault: result for ${action_id}"

  # Push with retry on conflict (rebase-and-push pattern).
  # Common case: admin merges another action PR between our clone and push.
  local attempt
  for attempt in 1 2 3; do
    if git -C "$scratch_dir" push origin "$branch" 2>/dev/null; then
      log "Result committed and pushed for ${action_id} (attempt ${attempt})"
      return 0
    fi

    log "Push conflict for ${action_id} (attempt ${attempt}/3) — rebasing"

    if ! git -C "$scratch_dir" pull --rebase origin "$branch" 2>/dev/null; then
      # Rebase conflict — check if result was pushed by another process
      git -C "$scratch_dir" rebase --abort 2>/dev/null || true
      if git -C "$scratch_dir" fetch origin "$branch" 2>/dev/null && \
         git -C "$scratch_dir" show "origin/${branch}:${result_relpath}" >/dev/null 2>&1; then
        log "Result already exists upstream for ${action_id} (pushed by another process)"
        return 0
      fi
    fi
  done

  log "ERROR: Failed to push result for ${action_id} after 3 attempts"
  return 1
}

# Write result file for an action via git push to the ops repo.
# Usage: write_result <action_id> <exit_code> <logs>
write_result() {
  local action_id="$1"
  local exit_code="$2"
  local logs="$3"

  commit_result_via_git "$action_id" "$exit_code" "$logs"
}

# -----------------------------------------------------------------------------
# Pluggable launcher backends
# -----------------------------------------------------------------------------

# _launch_runner_docker ACTION_ID SECRETS_CSV MOUNTS_CSV
#
# Builds and executes a `docker run` command for the vault runner.
# Secrets are resolved via load_secret (lib/env.sh).
# Returns: exit code of the docker run.  Stdout/stderr are captured to a temp
#          log file whose path is printed to stdout (caller reads it).
_launch_runner_docker() {
  local action_id="$1"
  local secrets_csv="$2"
  local mounts_csv="$3"

  local -a cmd=(docker run --rm
    --name "vault-runner-${action_id}"
    --network host
    --entrypoint bash
    -e DISINTO_CONTAINER=1
    -e "FORGE_URL=${FORGE_URL}"
    -e "FORGE_TOKEN=${FORGE_TOKEN}"
    -e "FORGE_REPO=${FORGE_REPO:-disinto-admin/disinto}"
    -e "FORGE_OPS_REPO=${FORGE_OPS_REPO:-}"
    -e "PRIMARY_BRANCH=${PRIMARY_BRANCH:-main}"
  )

  # Pass through optional env vars if set
  if [ -n "${ANTHROPIC_API_KEY:-}" ]; then
    cmd+=(-e "ANTHROPIC_API_KEY=${ANTHROPIC_API_KEY}")
  fi
  if [ -n "${CLAUDE_MODEL:-}" ]; then
    cmd+=(-e "CLAUDE_MODEL=${CLAUDE_MODEL}")
  fi

  # Mount docker socket, claude binary, and claude config
  cmd+=(-v /var/run/docker.sock:/var/run/docker.sock)
  if [ -f /usr/local/bin/claude ]; then
    cmd+=(-v /usr/local/bin/claude:/usr/local/bin/claude:ro)
  fi
  local runtime_home="${HOME:-/home/debian}"
  if [ -d "${CLAUDE_SHARED_DIR:-/var/lib/disinto/claude-shared}" ]; then
    cmd+=(-v "${CLAUDE_SHARED_DIR:-/var/lib/disinto/claude-shared}:${CLAUDE_SHARED_DIR:-/var/lib/disinto/claude-shared}")
    cmd+=(-e "CLAUDE_CONFIG_DIR=${CLAUDE_CONFIG_DIR:-/var/lib/disinto/claude-shared/config}")
  fi
  if [ -f "${runtime_home}/.claude.json" ]; then
    cmd+=(-v "${runtime_home}/.claude.json:/home/agent/.claude.json:ro")
  fi

  # Add environment variables for secrets (resolved via load_secret)
  if [ -n "$secrets_csv" ]; then
    local secret
    for secret in $(echo "$secrets_csv" | tr ',' ' '); do
      secret=$(echo "$secret" | xargs)
      [ -n "$secret" ] || continue
      local secret_val
      secret_val=$(load_secret "$secret") || true
      if [ -z "$secret_val" ]; then
        log "ERROR: Secret '${secret}' could not be resolved for action ${action_id}"
        write_result "$action_id" 1 "Secret not found: ${secret}"
        return 1
      fi
      cmd+=(-e "${secret}=${secret_val}")
    done
  fi

  # Add volume mounts for file-based credentials
  if [ -n "$mounts_csv" ]; then
    local mount_alias
    for mount_alias in $(echo "$mounts_csv" | tr ',' ' '); do
      mount_alias=$(echo "$mount_alias" | xargs)
      [ -n "$mount_alias" ] || continue
      case "$mount_alias" in
        ssh)
          cmd+=(-v "${runtime_home}/.ssh:/home/agent/.ssh:ro")
          ;;
        gpg)
          cmd+=(-v "${runtime_home}/.gnupg:/home/agent/.gnupg:ro")
          ;;
        sops)
          cmd+=(-v "${runtime_home}/.config/sops/age:/home/agent/.config/sops/age:ro")
          ;;
        *)
          log "ERROR: Unknown mount alias '${mount_alias}' for action ${action_id}"
          write_result "$action_id" 1 "Unknown mount alias: ${mount_alias}"
          return 1
          ;;
      esac
    done
  fi

  # Mount the ops repo so the runner entrypoint can read the action TOML
  cmd+=(-v "${OPS_REPO_ROOT}:/home/agent/ops:ro")

  # Image and entrypoint arguments: runner entrypoint + action-id
  cmd+=(disinto/agents:latest /home/agent/disinto/docker/runner/entrypoint-runner.sh "$action_id")

  log "Running: docker run --rm vault-runner-${action_id} (secrets: ${secrets_csv:-none}, mounts: ${mounts_csv:-none})"

  # Create temp file for logs
  local log_file
  log_file=$(mktemp /tmp/dispatcher-logs-XXXXXX)
  trap 'rm -f "$log_file"' RETURN

  # Execute with array expansion (safe from shell injection)
  "${cmd[@]}" > "$log_file" 2>&1
  local exit_code=$?

  # Read logs summary
  local logs
  logs=$(cat "$log_file")

  # Write result file
  write_result "$action_id" "$exit_code" "$logs"

  if [ $exit_code -eq 0 ]; then
    log "Runner completed successfully for action: ${action_id}"
  else
    log "Runner failed for action: ${action_id} (exit code: ${exit_code})"
  fi

  return $exit_code
}

# _launch_runner_nomad ACTION_ID SECRETS_CSV MOUNTS_CSV
#
# Dispatches a vault-runner batch job via `nomad job dispatch`.
# Polls `nomad job status` until terminal state (completed/failed).
# Reads exit code from allocation and writes <action-id>.result.json.
#
# Usage: _launch_runner_nomad <action_id> <secrets_csv> <mounts_csv>
# Returns: exit code of the nomad job (0=success, non-zero=failure)
_launch_runner_nomad() {
  local action_id="$1"
  local secrets_csv="$2"
  local mounts_csv="$3"

  log "Dispatching vault-runner batch job via Nomad for action: ${action_id}"

  # Dispatch the parameterized batch job
  # The vault-runner job expects meta: action_id, secrets_csv
  # Note: mounts_csv is not passed as meta (not declared in vault-runner.hcl)
  local dispatch_output
  dispatch_output=$(nomad job dispatch \
    -detach \
    -meta action_id="$action_id" \
    -meta secrets_csv="$secrets_csv" \
    vault-runner 2>&1) || {
    log "ERROR: Failed to dispatch vault-runner job for ${action_id}"
    log "Dispatch output: ${dispatch_output}"
    write_result "$action_id" 1 "Nomad dispatch failed: ${dispatch_output}"
    return 1
  }

  # Extract dispatched job ID from output (format: "vault-runner/dispatch-<timestamp>-<uuid>")
  local dispatched_job_id
  dispatched_job_id=$(echo "$dispatch_output" | grep -oP '(?<=Dispatched Job ID = ).+' || true)

  if [ -z "$dispatched_job_id" ]; then
    log "ERROR: Could not extract dispatched job ID from nomad output"
    log "Dispatch output: ${dispatch_output}"
    write_result "$action_id" 1 "Could not extract dispatched job ID from nomad output"
    return 1
  fi

  log "Dispatched vault-runner with job ID: ${dispatched_job_id}"

  # Poll job status until terminal state
  # Batch jobs transition: running -> completed/failed
  local max_wait=300  # 5 minutes max wait
  local elapsed=0
  local poll_interval=5
  local alloc_id=""

  log "Polling nomad job status for ${dispatched_job_id}..."

  while [ "$elapsed" -lt "$max_wait" ]; do
    # Get job status with JSON output for the dispatched child job
    local job_status_json
    job_status_json=$(nomad job status -json "$dispatched_job_id" 2>/dev/null) || {
      log "ERROR: Failed to get job status for ${dispatched_job_id}"
      write_result "$action_id" 1 "Failed to get job status for ${dispatched_job_id}"
      return 1
    }

    # Check job status field (transitions to "dead" on completion)
    local job_state
    job_state=$(echo "$job_status_json" | jq -r '.Status // empty' 2>/dev/null) || job_state=""

    # Check allocation state directly
    alloc_id=$(echo "$job_status_json" | jq -r '.Allocations[0]?.ID // empty' 2>/dev/null) || alloc_id=""

    if [ -n "$alloc_id" ]; then
      local alloc_state
      alloc_state=$(nomad alloc status -short "$alloc_id" 2>/dev/null || true)

      case "$alloc_state" in
        *completed*|*success*|*dead*)
          log "Allocation ${alloc_id} reached terminal state: ${alloc_state}"
          break
          ;;
        *running*|*pending*|*starting*)
          log "Allocation ${alloc_id} still running (state: ${alloc_state})..."
          ;;
        *failed*|*crashed*)
          log "Allocation ${alloc_id} failed (state: ${alloc_state})"
          break
          ;;
      esac
    fi

    # Also check job-level state
    case "$job_state" in
      dead)
        log "Job ${dispatched_job_id} reached terminal state: ${job_state}"
        break
        ;;
      failed)
        log "Job ${dispatched_job_id} failed"
        break
        ;;
    esac

    sleep "$poll_interval"
    elapsed=$((elapsed + poll_interval))
  done

  if [ "$elapsed" -ge "$max_wait" ]; then
    log "ERROR: Timeout waiting for vault-runner job to complete"
    write_result "$action_id" 1 "Timeout waiting for nomad job to complete"
    return 1
  fi

  # Get final job status and exit code
  local final_status_json
  final_status_json=$(nomad job status -json "$dispatched_job_id" 2>/dev/null) || {
    log "ERROR: Failed to get final job status"
    write_result "$action_id" 1 "Failed to get final job status"
    return 1
  }

  # Get allocation exit code
  local exit_code=0
  local logs=""

  if [ -n "$alloc_id" ]; then
    # Get allocation logs
    logs=$(nomad alloc logs -short "$alloc_id" 2>/dev/null || true)

    # Try to get exit code from alloc status JSON
    # Nomad alloc status -json has .TaskStates["<task_name>"].Events[].ExitCode
    local alloc_exit_code
    alloc_exit_code=$(nomad alloc status -json "$alloc_id" 2>/dev/null | jq -r '.TaskStates["runner"].Events[-1].ExitCode // empty' 2>/dev/null) || alloc_exit_code=""

    if [ -n "$alloc_exit_code" ] && [ "$alloc_exit_code" != "null" ]; then
      exit_code="$alloc_exit_code"
    fi
  fi

  # If we couldn't get exit code from alloc, check job state as fallback
  # Note: "dead" = terminal state for batch jobs (includes successful completion)
  # Only "failed" indicates actual failure
  if [ "$exit_code" -eq 0 ]; then
    local final_state
    final_state=$(echo "$final_status_json" | jq -r '.Status // empty' 2>/dev/null) || final_state=""

    case "$final_state" in
      failed)
        exit_code=1
        ;;
    esac
  fi

  # Truncate logs if too long
  if [ ${#logs} -gt 1000 ]; then
    logs="${logs: -1000}"
  fi

  # Write result file
  write_result "$action_id" "$exit_code" "$logs"

  if [ "$exit_code" -eq 0 ]; then
    log "Vault-runner job completed successfully for action: ${action_id}"
  else
    log "Vault-runner job failed for action: ${action_id} (exit code: ${exit_code})"
  fi

  return "$exit_code"
}

# Launch runner for the given action (backend-agnostic orchestrator)
# Usage: launch_runner <toml_file>
launch_runner() {
  local toml_file="$1"
  local action_id
  action_id=$(basename "$toml_file" .toml)

  log "Launching runner for action: ${action_id}"

  # Validate TOML
  if ! validate_action "$toml_file"; then
    log "ERROR: Action validation failed for ${action_id}"
    write_result "$action_id" 1 "Validation failed: see logs above"
    return 1
  fi

  # Check dispatch mode to determine if admin verification is needed
  local dispatch_mode
  dispatch_mode=$(get_dispatch_mode "$toml_file")

  if [ "$dispatch_mode" = "direct" ]; then
    log "Action ${action_id}: tier=${VAULT_TIER:-unknown}, dispatch_mode=${dispatch_mode} — skipping admin merge verification (direct commit)"
  else
    # Verify admin merge for PR-based actions
    log "Action ${action_id}: tier=${VAULT_TIER:-unknown}, dispatch_mode=${dispatch_mode} — verifying admin merge"
    if ! verify_admin_merged "$toml_file"; then
      log "ERROR: Admin merge verification failed for ${action_id}"
      write_result "$action_id" 1 "Admin merge verification failed: see logs above"
      return 1
    fi
    log "Action ${action_id}: admin merge verified"
  fi

  # Build CSV lists from validated action metadata
  local secrets_csv=""
  if [ -n "${VAULT_ACTION_SECRETS:-}" ]; then
    # Convert space-separated to comma-separated
    secrets_csv=$(echo "${VAULT_ACTION_SECRETS}" | xargs | tr ' ' ',')
  fi

  local mounts_csv=""
  if [ -n "${VAULT_ACTION_MOUNTS:-}" ]; then
    mounts_csv=$(echo "${VAULT_ACTION_MOUNTS}" | xargs | tr ' ' ',')
  fi

  # Delegate to the selected backend
  "_launch_runner_${DISPATCHER_BACKEND}" "$action_id" "$secrets_csv" "$mounts_csv"
}

# -----------------------------------------------------------------------------
# Pluggable sidecar launcher (reproduce / triage / verify)
# -----------------------------------------------------------------------------

# _dispatch_sidecar_docker CONTAINER_NAME ISSUE_NUM PROJECT_TOML IMAGE [FORMULA]
#
# Launches a sidecar container via docker run (background, pid-tracked).
# Prints the background PID to stdout.
_dispatch_sidecar_docker() {
  local container_name="$1"
  local issue_number="$2"
  local project_toml="$3"
  local image="$4"
  local formula="${5:-}"

  local -a cmd=(docker run --rm
    --name "${container_name}"
    --network host
    --security-opt apparmor=unconfined
    -v /var/run/docker.sock:/var/run/docker.sock
    -v agent-data:/home/agent/data
    -v project-repos:/home/agent/repos
    -e "FORGE_URL=${FORGE_URL}"
    -e "FORGE_TOKEN=${FORGE_TOKEN}"
    -e "FORGE_REPO=${FORGE_REPO}"
    -e "PRIMARY_BRANCH=${PRIMARY_BRANCH:-main}"
    -e DISINTO_CONTAINER=1
  )

  # Set formula if provided
  if [ -n "$formula" ]; then
    cmd+=(-e "DISINTO_FORMULA=${formula}")
  fi

  # Pass through ANTHROPIC_API_KEY if set
  if [ -n "${ANTHROPIC_API_KEY:-}" ]; then
    cmd+=(-e "ANTHROPIC_API_KEY=${ANTHROPIC_API_KEY}")
  fi

  # Mount shared Claude config dir and ~/.ssh from the runtime user's home
  local runtime_home="${HOME:-/home/debian}"
  if [ -d "${CLAUDE_SHARED_DIR:-/var/lib/disinto/claude-shared}" ]; then
    cmd+=(-v "${CLAUDE_SHARED_DIR:-/var/lib/disinto/claude-shared}:${CLAUDE_SHARED_DIR:-/var/lib/disinto/claude-shared}")
    cmd+=(-e "CLAUDE_CONFIG_DIR=${CLAUDE_CONFIG_DIR:-/var/lib/disinto/claude-shared/config}")
  fi
  if [ -f "${runtime_home}/.claude.json" ]; then
    cmd+=(-v "${runtime_home}/.claude.json:/home/agent/.claude.json:ro")
  fi
  if [ -d "${runtime_home}/.ssh" ]; then
    cmd+=(-v "${runtime_home}/.ssh:/home/agent/.ssh:ro")
  fi
  if [ -f /usr/local/bin/claude ]; then
    cmd+=(-v /usr/local/bin/claude:/usr/local/bin/claude:ro)
  fi

  # Mount the project TOML into the container at a stable path
  local container_toml="/home/agent/project.toml"
  cmd+=(-v "${project_toml}:${container_toml}:ro")

  cmd+=("${image}" "$container_toml" "$issue_number")

  # Launch in background
  "${cmd[@]}" &
  echo $!
}

# _dispatch_sidecar_nomad CONTAINER_NAME ISSUE_NUM PROJECT_TOML IMAGE [FORMULA]
#
# Nomad sidecar backend stub — will be implemented in migration Step 5.
_dispatch_sidecar_nomad() {
  echo "nomad backend not yet implemented" >&2
  return 1
}

# -----------------------------------------------------------------------------
# Reproduce dispatch — launch sidecar for bug-report issues
# -----------------------------------------------------------------------------

# Check if a reproduce run is already in-flight for a given issue.
# Uses a simple pid-file in /tmp so we don't double-launch per dispatcher cycle.
_reproduce_lockfile() {
  local issue="$1"
  echo "/tmp/reproduce-inflight-${issue}.pid"
}

is_reproduce_running() {
  local issue="$1"
  local pidfile
  pidfile=$(_reproduce_lockfile "$issue")
  [ -f "$pidfile" ] || return 1
  local pid
  pid=$(cat "$pidfile" 2>/dev/null || echo "")
  [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null
}

# Fetch open issues labelled bug-report that have no outcome label yet.
# Returns a newline-separated list of "issue_number:project_toml" pairs.
fetch_reproduce_candidates() {
  # Require FORGE_TOKEN, FORGE_URL, FORGE_REPO
  [ -n "${FORGE_TOKEN:-}" ] || return 0
  [ -n "${FORGE_URL:-}" ]   || return 0
  [ -n "${FORGE_REPO:-}" ]  || return 0

  local api="${FORGE_URL}/api/v1/repos/${FORGE_REPO}"

  local issues_json
  issues_json=$(curl -sf \
    -H "Authorization: token ${FORGE_TOKEN}" \
    "${api}/issues?type=issues&state=open&labels=bug-report&limit=20" 2>/dev/null) || return 0

  # Filter out issues that already carry an outcome label.
  # Write JSON to a temp file so python3 can read from stdin (heredoc) and
  # still receive the JSON as an argument (avoids SC2259: pipe vs heredoc).
  local tmpjson
  tmpjson=$(mktemp)
  echo "$issues_json" > "$tmpjson"
  python3 - "$tmpjson" <<'PYEOF'
import sys, json
data = json.load(open(sys.argv[1]))
skip = {"in-progress", "in-triage", "rejected", "blocked"}
for issue in data:
    labels = {l["name"] for l in (issue.get("labels") or [])}
    if labels & skip:
        continue
    print(issue["number"])
PYEOF
  rm -f "$tmpjson"
}

# Launch one reproduce container per candidate issue.
# project_toml is resolved from FACTORY_ROOT/projects/*.toml (first match).
dispatch_reproduce() {
  local issue_number="$1"

  if is_reproduce_running "$issue_number"; then
    log "Reproduce already running for issue #${issue_number}, skipping"
    return 0
  fi

  # Find first project TOML available (same convention as dev-poll)
  local project_toml=""
  for toml in "$PROJECTS_DIR"/*.toml; do
    [ -f "$toml" ] && { project_toml="$toml"; break; }
  done

  if [ -z "$project_toml" ]; then
    log "WARNING: no project TOML found under ${PROJECTS_DIR}/ — skipping reproduce for #${issue_number}"
    return 0
  fi

  log "Dispatching reproduce-agent for issue #${issue_number} (project: ${project_toml})"

  local bg_pid
  bg_pid=$("_dispatch_sidecar_${DISPATCHER_BACKEND}" \
    "disinto-reproduce-${issue_number}" \
    "$issue_number" \
    "$project_toml" \
    "disinto-reproduce:latest")

  echo "$bg_pid" > "$(_reproduce_lockfile "$issue_number")"
  log "Reproduce container launched (pid ${bg_pid}) for issue #${issue_number}"
}

# -----------------------------------------------------------------------------
# Triage dispatch — launch sidecar for bug-report + in-triage issues
# -----------------------------------------------------------------------------

# Check if a triage run is already in-flight for a given issue.
_triage_lockfile() {
  local issue="$1"
  echo "/tmp/triage-inflight-${issue}.pid"
}

is_triage_running() {
  local issue="$1"
  local pidfile
  pidfile=$(_triage_lockfile "$issue")
  [ -f "$pidfile" ] || return 1
  local pid
  pid=$(cat "$pidfile" 2>/dev/null || echo "")
  [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null
}

# Fetch open issues labelled both bug-report and in-triage.
# Returns a newline-separated list of issue numbers.
fetch_triage_candidates() {
  # Require FORGE_TOKEN, FORGE_URL, FORGE_REPO
  [ -n "${FORGE_TOKEN:-}" ] || return 0
  [ -n "${FORGE_URL:-}" ]   || return 0
  [ -n "${FORGE_REPO:-}" ]  || return 0

  local api="${FORGE_URL}/api/v1/repos/${FORGE_REPO}"

  local issues_json
  issues_json=$(curl -sf \
    -H "Authorization: token ${FORGE_TOKEN}" \
    "${api}/issues?type=issues&state=open&labels=bug-report&limit=20" 2>/dev/null) || return 0

  # Filter to issues that carry BOTH bug-report AND in-triage labels.
  local tmpjson
  tmpjson=$(mktemp)
  echo "$issues_json" > "$tmpjson"
  python3 - "$tmpjson" <<'PYEOF'
import sys, json
data = json.load(open(sys.argv[1]))
for issue in data:
    labels = {l["name"] for l in (issue.get("labels") or [])}
    if "bug-report" in labels and "in-triage" in labels:
        print(issue["number"])
PYEOF
  rm -f "$tmpjson"
}

# Launch one triage container per candidate issue.
# Uses the same disinto-reproduce:latest image as the reproduce-agent,
# selecting the triage formula via DISINTO_FORMULA env var.
# Stack lock is held for the full run (no timeout).
dispatch_triage() {
  local issue_number="$1"

  if is_triage_running "$issue_number"; then
    log "Triage already running for issue #${issue_number}, skipping"
    return 0
  fi

  # Find first project TOML available (same convention as dev-poll)
  local project_toml=""
  for toml in "$PROJECTS_DIR"/*.toml; do
    [ -f "$toml" ] && { project_toml="$toml"; break; }
  done

  if [ -z "$project_toml" ]; then
    log "WARNING: no project TOML found under ${PROJECTS_DIR}/ — skipping triage for #${issue_number}"
    return 0
  fi

  log "Dispatching triage-agent for issue #${issue_number} (project: ${project_toml})"

  local bg_pid
  bg_pid=$("_dispatch_sidecar_${DISPATCHER_BACKEND}" \
    "disinto-triage-${issue_number}" \
    "$issue_number" \
    "$project_toml" \
    "disinto-reproduce:latest" \
    "triage")

  echo "$bg_pid" > "$(_triage_lockfile "$issue_number")"
  log "Triage container launched (pid ${bg_pid}) for issue #${issue_number}"
}

# -----------------------------------------------------------------------------
# Verification dispatch — launch sidecar for bug-report parents with all deps closed
# -----------------------------------------------------------------------------

# Check if a verification run is already in-flight for a given issue.
_verify_lockfile() {
  local issue="$1"
  echo "/tmp/verify-inflight-${issue}.pid"
}

is_verify_running() {
  local issue="$1"
  local pidfile
  pidfile=$(_verify_lockfile "$issue")
  [ -f "$pidfile" ] || return 1
  local pid
  pid=$(cat "$pidfile" 2>/dev/null || echo "")
  [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null
}

# Check if an issue is a parent with sub-issues (identified by sub-issues
# whose body contains "Decomposed from #N" where N is the parent's number).
# Returns: 0 if parent with sub-issues found, 1 otherwise
_is_parent_issue() {
  local parent_num="$1"

  # Fetch all issues (open and closed) to find sub-issues
  local api="${FORGE_URL}/api/v1/repos/${FORGE_REPO}"
  local all_issues_json
  all_issues_json=$(curl -sf \
    -H "Authorization: token ${FORGE_TOKEN}" \
    "${api}/issues?type=issues&state=all&limit=50" 2>/dev/null) || return 1

  # Find issues whose body contains "Decomposed from #<parent_num>"
  local sub_issues
  sub_issues=$(python3 -c '
import sys, json
parent_num = sys.argv[1]
data = json.load(open("/dev/stdin"))
sub_issues = []
for issue in data:
    body = issue.get("body") or ""
    if f"Decomposed from #{parent_num}" in body:
        sub_issues.append(str(issue["number"]))
print(" ".join(sub_issues))
' "$parent_num" < <(echo "$all_issues_json")) || return 1

  [ -n "$sub_issues" ]
}

# Check if all sub-issues of a parent are closed.
# Returns: 0 if all closed, 1 if any still open
_are_all_sub_issues_closed() {
  local parent_num="$1"

  # Fetch all issues (open and closed) to find sub-issues
  local api="${FORGE_URL}/api/v1/repos/${FORGE_REPO}"
  local all_issues_json
  all_issues_json=$(curl -sf \
    -H "Authorization: token ${FORGE_TOKEN}" \
    "${api}/issues?type=issues&state=all&limit=50" 2>/dev/null) || return 1

  # Find issues whose body contains "Decomposed from #<parent_num>"
  local sub_issues
  sub_issues=$(python3 -c '
import sys, json
parent_num = sys.argv[1]
data = json.load(open("/dev/stdin"))
sub_issues = []
for issue in data:
    body = issue.get("body") or ""
    if f"Decomposed from #{parent_num}" in body:
        sub_issues.append(str(issue["number"]))
print(" ".join(sub_issues))
' "$parent_num" < <(echo "$all_issues_json")) || return 1

  [ -z "$sub_issues" ] && return 1

  # Check if all sub-issues are closed
  for sub_num in $sub_issues; do
    local sub_state
    sub_state=$(curl -sf \
      -H "Authorization: token ${FORGE_TOKEN}" \
      "${api}/issues/${sub_num}" 2>/dev/null | jq -r '.state // "unknown"') || return 1
    if [ "$sub_state" != "closed" ]; then
      return 1
    fi
  done
  return 0
}

# Fetch open bug-report + in-progress issues whose sub-issues are all closed.
# Returns a newline-separated list of issue numbers ready for verification.
fetch_verification_candidates() {
  # Require FORGE_TOKEN, FORGE_URL, FORGE_REPO
  [ -n "${FORGE_TOKEN:-}" ] || return 0
  [ -n "${FORGE_URL:-}" ]   || return 0
  [ -n "${FORGE_REPO:-}" ]  || return 0

  local api="${FORGE_URL}/api/v1/repos/${FORGE_REPO}"

  # Fetch open bug-report + in-progress issues
  local issues_json
  issues_json=$(curl -sf \
    -H "Authorization: token ${FORGE_TOKEN}" \
    "${api}/issues?type=issues&state=open&labels=bug-report&limit=20" 2>/dev/null) || return 0

  # Filter to issues that also have in-progress label and have all sub-issues closed
  local tmpjson
  tmpjson=$(mktemp)
  echo "$issues_json" > "$tmpjson"
  python3 - "$tmpjson" "$api" "${FORGE_TOKEN}" <<'PYEOF'
import sys, json
api_base = sys.argv[2]
token = sys.argv[3]
data = json.load(open(sys.argv[1]))

for issue in data:
    labels = {l["name"] for l in (issue.get("labels") or [])}
    # Must have BOTH bug-report AND in-progress labels
    if "bug-report" not in labels or "in-progress" not in labels:
        continue
    print(issue["number"])
PYEOF
  rm -f "$tmpjson"
}

# Launch one verification container per candidate issue.
# Uses the same disinto-reproduce:latest image as the reproduce-agent,
# selecting the verify formula via DISINTO_FORMULA env var.
dispatch_verify() {
  local issue_number="$1"

  if is_verify_running "$issue_number"; then
    log "Verification already running for issue #${issue_number}, skipping"
    return 0
  fi

  # Find first project TOML available (same convention as dev-poll)
  local project_toml=""
  for toml in "$PROJECTS_DIR"/*.toml; do
    [ -f "$toml" ] && { project_toml="$toml"; break; }
  done

  if [ -z "$project_toml" ]; then
    log "WARNING: no project TOML found under ${PROJECTS_DIR}/ — skipping verification for #${issue_number}"
    return 0
  fi

  log "Dispatching verification-agent for issue #${issue_number} (project: ${project_toml})"

  local bg_pid
  bg_pid=$("_dispatch_sidecar_${DISPATCHER_BACKEND}" \
    "disinto-verify-${issue_number}" \
    "$issue_number" \
    "$project_toml" \
    "disinto-reproduce:latest" \
    "verify")

  echo "$bg_pid" > "$(_verify_lockfile "$issue_number")"
  log "Verification container launched (pid ${bg_pid}) for issue #${issue_number}"
}

# -----------------------------------------------------------------------------
# Main dispatcher loop
# -----------------------------------------------------------------------------

# Clone or pull the ops repo
ensure_ops_repo() {
  if [ ! -d "${OPS_REPO_ROOT}/.git" ]; then
    log "Cloning ops repo from ${FORGE_URL}/${FORGE_OPS_REPO}..."
    git clone "${FORGE_URL}/${FORGE_OPS_REPO}" "${OPS_REPO_ROOT}"
  else
    log "Pulling latest ops repo changes..."
    (cd "${OPS_REPO_ROOT}" && git pull --rebase)
  fi
}

# Main dispatcher loop
main() {
  log "Starting dispatcher (backend=${DISPATCHER_BACKEND})..."
  log "Polling ops repo: ${VAULT_ACTIONS_DIR}"
  log "Admin users: ${ADMIN_USERS}"

  # Validate backend selection at startup
  case "$DISPATCHER_BACKEND" in
    docker|nomad)
      log "Using ${DISPATCHER_BACKEND} backend for vault-runner dispatch"
      ;;
    *)
      log "ERROR: unknown DISPATCHER_BACKEND=${DISPATCHER_BACKEND}"
      echo "unknown DISPATCHER_BACKEND=${DISPATCHER_BACKEND} (expected: docker, nomad)" >&2
      exit 1
      ;;
  esac

  while true; do
    # Refresh ops repo at the start of each poll cycle
    ensure_ops_repo

    # Check if actions directory exists
    if [ ! -d "${VAULT_ACTIONS_DIR}" ]; then
      log "Actions directory not found: ${VAULT_ACTIONS_DIR}"
      sleep 60
      continue
    fi

    # Process each action file
    for toml_file in "${VAULT_ACTIONS_DIR}"/*.toml; do
      # Handle case where no .toml files exist
      [ -e "$toml_file" ] || continue

      local action_id
      action_id=$(basename "$toml_file" .toml)

      # Skip if already completed
      if is_action_completed "$action_id"; then
        log "Action ${action_id} already completed, skipping"
        continue
      fi

      # Launch runner for this action
      launch_runner "$toml_file" || true
    done

    # Reproduce dispatch: check for bug-report issues needing reproduction
    local candidate_issues
    candidate_issues=$(fetch_reproduce_candidates) || true
    if [ -n "$candidate_issues" ]; then
      while IFS= read -r issue_num; do
        [ -n "$issue_num" ] || continue
        dispatch_reproduce "$issue_num" || true
      done <<< "$candidate_issues"
    fi

    # Triage dispatch: check for bug-report + in-triage issues needing deep analysis
    local triage_issues
    triage_issues=$(fetch_triage_candidates) || true
    if [ -n "$triage_issues" ]; then
      while IFS= read -r issue_num; do
        [ -n "$issue_num" ] || continue
        dispatch_triage "$issue_num" || true
      done <<< "$triage_issues"
    fi

    # Verification dispatch: check for bug-report + in-progress issues whose sub-issues are all closed
    # These are parents whose fixes have merged and need verification
    local verify_issues
    verify_issues=$(fetch_verification_candidates) || true
    if [ -n "$verify_issues" ]; then
      while IFS= read -r issue_num; do
        [ -n "$issue_num" ] || continue
        # Double-check: this issue must have all sub-issues closed before dispatching
        if _are_all_sub_issues_closed "$issue_num"; then
          dispatch_verify "$issue_num" || true
        else
          log "Issue #${issue_num} has open sub-issues — skipping verification"
        fi
      done <<< "$verify_issues"
    fi

    # Wait before next poll
    sleep 60
  done
}

# Run main
main "$@"
