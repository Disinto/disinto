#!/usr/bin/env bash
set -euo pipefail
# ci-helpers.sh — Shared CI helper functions
#
# Source from any script: source "$(dirname "$0")/../lib/ci-helpers.sh"
# ci_passed() requires: WOODPECKER_REPO_ID (from env.sh / project config)
# ci_commit_status() / ci_pipeline_number() require: woodpecker_api(), forge_api() (from env.sh)
# classify_pipeline_failure() requires: woodpecker_api() (defined in env.sh)

# ensure_priority_label — look up (or create) the "priority" label, print its ID.
# Caches the result in _PRIORITY_LABEL_ID to avoid repeated API calls.
# Requires: FORGE_TOKEN, FORGE_API (from env.sh), forge_api()
ensure_priority_label() {
  if [ -n "${_PRIORITY_LABEL_ID:-}" ]; then
    printf '%s' "$_PRIORITY_LABEL_ID"
    return 0
  fi
  _PRIORITY_LABEL_ID=$(forge_api GET "/labels" 2>/dev/null \
    | jq -r '.[] | select(.name == "priority") | .id' 2>/dev/null || true)
  if [ -z "$_PRIORITY_LABEL_ID" ]; then
    _PRIORITY_LABEL_ID=$(curl -sf -X POST \
      -H "Authorization: token ${FORGE_TOKEN}" \
      -H "Content-Type: application/json" \
      "${FORGE_API}/labels" \
      -d '{"name":"priority","color":"#f59e0b"}' 2>/dev/null \
      | jq -r '.id // empty' 2>/dev/null || true)
  fi
  printf '%s' "$_PRIORITY_LABEL_ID"
}

# diff_has_code_files — check if file list (stdin, one per line) contains code files
# Non-code paths: docs/*, formulas/*, evidence/*, *.md
# Returns 0 if any code file found, 1 if all files are non-code.
diff_has_code_files() {
  while IFS= read -r f; do
    [ -z "$f" ] && continue
    case "$f" in
      docs/*|formulas/*|evidence/*) continue ;;
      *.md) continue ;;
      *) return 0 ;;
    esac
  done
  return 1
}

# ci_required_for_pr <pr_number> — check if CI is needed for this PR
# Returns 0 if PR has code files (CI required), 1 if non-code only (CI not required).
ci_required_for_pr() {
  local pr_num="$1"
  local files all_json
  all_json=$(forge_api_all "/pulls/${pr_num}/files") || return 0
  files=$(printf '%s' "$all_json" | jq -r '.[].filename' 2>/dev/null) || return 0
  if [ -z "$files" ]; then
    return 0  # empty file list — require CI as safety default
  fi
  echo "$files" | diff_has_code_files
}

# ci_required_contexts [branch] — get required status check contexts from branch protection.
# Cached per poll cycle (module-level variable) to avoid repeated API calls.
# Stdout: newline-separated list of required context names, or empty if none configured.
# shellcheck disable=SC2120  # branch arg is optional, callers may omit it
ci_required_contexts() {
  if [ -n "${_CI_REQUIRED_CONTEXTS+set}" ]; then
    printf '%s' "$_CI_REQUIRED_CONTEXTS"
    return
  fi
  local branch="${1:-${PRIMARY_BRANCH:-main}}"
  local bp_json
  bp_json=$(forge_api GET "/branch_protections/${branch}" 2>/dev/null) || bp_json=""

  if [ -z "$bp_json" ] || [ "$bp_json" = "null" ]; then
    _CI_REQUIRED_CONTEXTS=""
    printf '%s' "$_CI_REQUIRED_CONTEXTS"
    return
  fi

  local enabled
  enabled=$(printf '%s' "$bp_json" | jq -r '.enable_status_check // false' 2>/dev/null) || enabled="false"

  if [ "$enabled" != "true" ]; then
    _CI_REQUIRED_CONTEXTS=""
    printf '%s' "$_CI_REQUIRED_CONTEXTS"
    return
  fi

  _CI_REQUIRED_CONTEXTS=$(printf '%s' "$bp_json" \
    | jq -r '.status_check_contexts // [] | .[]' 2>/dev/null) || _CI_REQUIRED_CONTEXTS=""
  printf '%s' "$_CI_REQUIRED_CONTEXTS"
}

# _ci_reduce_required_contexts <sha> <required_contexts>
# Reduce commit statuses to required contexts only.
# Fetches per-context statuses from the forge combined endpoint and filters.
# Stdout: success | failure | pending
_ci_reduce_required_contexts() {
  local sha="$1" required="$2"
  local status_json
  status_json=$(forge_api GET "/commits/${sha}/status" 2>/dev/null) || { echo "pending"; return; }

  printf '%s' "$status_json" | jq -r --arg req "$required" '
    ($req | split("\n") | map(select(. != ""))) as $contexts |
    .statuses as $all |
    if ($contexts | length) == 0 then "pending"
    else
      [ $contexts[] as $ctx |
        [$all[] | select(.context == $ctx)] | sort_by(.id) | last | .status // "pending"
      ] |
      if any(. == "failure" or . == "error") then "failure"
      elif all(. == "success") then "success"
      else "pending"
      end
    end
  ' 2>/dev/null || echo "pending"
}

# ci_required_passed <sha> — check if all required pipelines have passed.
# Used by the reviewer agent: gate only on required pipelines (#920).
#
# Returns 0 if:
#   - branch protection declares required status check contexts AND all of
#     those contexts are "success"; OR
#   - no required contexts are configured (nothing to gate on).
# Returns 1 if any required context is failure/pending/missing.
ci_required_passed() {
  local sha="$1"
  local required
  # shellcheck disable=SC2119  # branch arg defaults to PRIMARY_BRANCH
  required=$(ci_required_contexts) || true
  if [ -z "$required" ]; then
    return 0
  fi
  local state
  state=$(_ci_reduce_required_contexts "$sha" "$required")
  [ "$state" = "success" ]
}

# ci_passed <state> — check if CI is passing (or no CI configured)
#   Returns 0 if state is "success", or if no CI is configured and
#   state is empty/pending/unknown.
ci_passed() {
  local state="$1"
  if [ "$state" = "success" ]; then return 0; fi
  if [ "${WOODPECKER_REPO_ID:-2}" = "0" ] && { [ -z "$state" ] || [ "$state" = "pending" ] || [ "$state" = "unknown" ]; }; then
    return 0  # no CI configured
  fi
  return 1
}

# ci_failed <state> — check if CI has definitively failed
#   Returns 0 if state indicates a real failure (not success, not pending,
#   not unknown, not empty).
ci_failed() {
  local state="$1"
  if [ -z "$state" ] || [ "$state" = "pending" ] || [ "$state" = "unknown" ]; then
    return 1
  fi
  if ci_passed "$state"; then
    return 1
  fi
  return 0
}

# ci_commit_status <sha> — get CI state for a commit
# When branch protection declares required status check contexts, reduces over
# just those — optional workflows that are stuck/failed do not block decisions.
# Otherwise queries Woodpecker API directly, falls back to forge combined status.
ci_commit_status() {
  local sha="$1"
  local state=""

  # When required contexts are configured, reduce over just those
  local required
  # shellcheck disable=SC2119  # branch arg defaults to PRIMARY_BRANCH
  required=$(ci_required_contexts) || true
  if [ -n "$required" ]; then
    _ci_reduce_required_contexts "$sha" "$required"
    return
  fi

  # No required-context filtering — original behavior
  # Primary: ask Woodpecker directly
  if [ -n "${WOODPECKER_REPO_ID:-}" ] && [ "${WOODPECKER_REPO_ID}" != "0" ]; then
    state=$(woodpecker_api "/repos/${WOODPECKER_REPO_ID}/pipelines" \
      | jq -r --arg sha "$sha" \
        '[.[] | select(.commit == $sha)] | sort_by(.number) | last | .status // empty' \
      2>/dev/null) || true
    # Map Woodpecker status to Gitea/Forgejo status names
    case "$state" in
      success)  echo "success"; return ;;
      failure|error|killed) echo "failure"; return ;;
      running|pending|blocked) echo "pending"; return ;;
    esac
  fi

  # Fallback: forge commit status API (works with any Gitea/Forgejo)
  forge_api GET "/commits/${sha}/status" 2>/dev/null \
    | jq -r '.state // "unknown"'
}

# ci_pipeline_number <sha> — get Woodpecker pipeline number for a commit
# Queries Woodpecker API directly, falls back to forge status target_url parsing.
ci_pipeline_number() {
  local sha="$1"

  # Primary: ask Woodpecker directly
  if [ -n "${WOODPECKER_REPO_ID:-}" ] && [ "${WOODPECKER_REPO_ID}" != "0" ]; then
    local num
    num=$(woodpecker_api "/repos/${WOODPECKER_REPO_ID}/pipelines" \
      | jq -r --arg sha "$sha" \
        '[.[] | select(.commit == $sha)] | sort_by(.number) | last | .number // empty' \
      2>/dev/null) || true
    if [ -n "$num" ]; then
      echo "$num"
      return
    fi
  fi

  # Fallback: extract from forge status target_url
  forge_api GET "/commits/${sha}/status" 2>/dev/null \
    | jq -r '.statuses[0].target_url // ""' \
    | grep -oP 'pipeline/\K[0-9]+' | head -1 || true
}

# is_infra_step <step_name> <exit_code> [log_data]
# Checks whether a single CI step failure matches infra heuristics.
# Returns 0 (infra) with reason on stdout, or 1 (not infra).
#
# Heuristics (union of P2e and classify_pipeline_failure patterns):
#   - Clone/git step with exit 128 → connection failure / rate limit
#   - Any step with exit 137 → OOM / killed by signal 9
#   - Log patterns: connection timeout, docker pull timeout, TLS handshake timeout
is_infra_step() {
  local sname="$1" ecode="$2" log_data="${3:-}"

  # Clone/git step exit 128 → forge connection failure / rate limit
  if { [[ "$sname" == *clone* ]] || [[ "$sname" == git* ]]; } && [ "$ecode" = "128" ]; then
    echo "${sname} exit 128 (connection failure)"
    return 0
  fi

  # Exit 137 → OOM / killed by signal 9
  if [ "$ecode" = "137" ]; then
    echo "${sname} exit 137 (OOM/signal 9)"
    return 0
  fi

  # Log-pattern matching for infra issues
  if [ -n "$log_data" ] && \
     printf '%s' "$log_data" | grep -qiE 'Failed to connect|connection timed out|docker pull.*timeout|TLS handshake timeout'; then
    echo "${sname}: log matches infra pattern (timeout/connection)"
    return 0
  fi

  return 1
}

# classify_pipeline_failure <repo_id> <pipeline_num>
# Classifies a pipeline's failure type by inspecting failed steps.
# Uses is_infra_step() for per-step classification (exit codes + log patterns).
# Outputs "infra <reason>" if any failed step matches infra heuristics.
# Outputs "code" otherwise (including when steps cannot be determined).
# Returns 0 for infra, 1 for code or unclassifiable.
classify_pipeline_failure() {
  local repo_id="$1" pip_num="$2"
  local pip_json failed_steps _sname _ecode _spid _reason _log_data

  pip_json=$(woodpecker_api "/repos/${repo_id}/pipelines/${pip_num}" 2>/dev/null) || {
    echo "code"; return 1
  }

  # Extract failed steps: name, exit_code, pid
  failed_steps=$(printf '%s' "$pip_json" | jq -r '
    .workflows[]?.children[]? |
    select(.state == "failure" or .state == "error" or .state == "killed") |
    "\(.name)\t\(.exit_code)\t\(.pid)"' 2>/dev/null)

  if [ -z "$failed_steps" ]; then
    echo "code"; return 1
  fi

  while IFS=$'\t' read -r _sname _ecode _spid; do
    [ -z "$_sname" ] && continue

    # Check name+exit_code patterns (no log fetch needed)
    if _reason=$(is_infra_step "$_sname" "$_ecode"); then
      echo "infra ${_reason}"
      return 0
    fi

    # Fetch step logs and check log patterns
    if [ -n "$_spid" ] && [ "$_spid" != "null" ]; then
      _log_data=$(woodpecker_api "/repos/${repo_id}/logs/${pip_num}/${_spid}" \
        --max-time 15 2>/dev/null \
        | jq -r '.[].data // empty' 2>/dev/null | tail -200 || true)
      if [ -n "$_log_data" ]; then
        if _reason=$(is_infra_step "$_sname" "$_ecode" "$_log_data"); then
          echo "infra ${_reason}"
          return 0
        fi
      fi
    fi
  done <<< "$failed_steps"

  echo "code"
  return 1
}

# ci_promote <repo_id> <pipeline_number> <environment>
# Calls the Woodpecker promote API to trigger a deployment pipeline.
# The promote endpoint creates a new pipeline with event=deployment and
# deploy_to=<environment>, which fires pipelines filtered on that environment.
# Requires: WOODPECKER_TOKEN, WOODPECKER_SERVER (from env.sh)
# Returns 0 on success, 1 on failure. Prints the new pipeline number on success.
ci_promote() {
  local repo_id="$1" pipeline_num="$2" environment="$3"

  if [ -z "$repo_id" ] || [ -z "$pipeline_num" ] || [ -z "$environment" ]; then
    echo "Usage: ci_promote <repo_id> <pipeline_number> <environment>" >&2
    return 1
  fi

  local resp new_num
  resp=$(woodpecker_api "/repos/${repo_id}/pipelines/${pipeline_num}" \
    -X POST \
    -H "Content-Type: application/x-www-form-urlencoded" \
    -d "event=deployment&deploy_to=${environment}" 2>/dev/null) || {
    echo "ERROR: promote API call failed" >&2
    return 1
  }

  new_num=$(printf '%s' "$resp" | jq -r '.number // empty' 2>/dev/null)
  if [ -z "$new_num" ]; then
    echo "ERROR: promote returned no pipeline number" >&2
    return 1
  fi

  echo "$new_num"
}

# ci_get_step_logs <pipeline_num> <step_id>
# Fetches logs for a single CI step via the Woodpecker API.
# Requires: WOODPECKER_REPO_ID, woodpecker_api() (from env.sh)
# Returns: 0 on success, 1 on failure. Outputs log text to stdout.
#
# Usage:
#   ci_get_step_logs 1423 5    # Get logs for step ID 5 in pipeline 1423
ci_get_step_logs() {
  local pipeline_num="$1" step_id="$2"

  if [ -z "$pipeline_num" ] || [ -z "$step_id" ]; then
    echo "Usage: ci_get_step_logs <pipeline_num> <step_id>" >&2
    return 1
  fi

  if [ -z "${WOODPECKER_REPO_ID:-}" ] || [ "${WOODPECKER_REPO_ID}" = "0" ]; then
    echo "ERROR: WOODPECKER_REPO_ID not set or zero" >&2
    return 1
  fi

  woodpecker_api "/repos/${WOODPECKER_REPO_ID}/logs/${pipeline_num}/${step_id}" \
    --max-time 15 2>/dev/null \
    | jq -r '.[].data // empty' 2>/dev/null
}

# ci_get_logs <pipeline_number> [--step <step_name>]
# Reads CI logs from the Woodpecker SQLite database.
# Requires: WOODPECKER_DATA_DIR env var or mounted volume at /woodpecker-data
# Returns: 0 on success, 1 on failure. Outputs log text to stdout.
#
# Usage:
#   ci_get_logs 346                  # Get all failed step logs
#   ci_get_logs 346 --step smoke-init # Get logs for specific step
ci_get_logs() {
  local pipeline_number="$1"
  shift || true

  local step_name=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --step|-s)
        step_name="$2"
        shift 2
        ;;
      *)
        echo "Unknown option: $1" >&2
        return 1
        ;;
    esac
  done

  local log_reader="${FACTORY_ROOT:-/home/agent/disinto}/lib/ci-log-reader.py"
  if [ -f "$log_reader" ]; then
    if [ -n "$step_name" ]; then
      python3 "$log_reader" "$pipeline_number" --step "$step_name"
    else
      python3 "$log_reader" "$pipeline_number"
    fi
  else
    echo "ERROR: ci-log-reader.py not found at $log_reader" >&2
    return 1
  fi
}

# =============================================================================
# CI CIRCUIT BREAKER (issue #557)
# =============================================================================
# Detects CI measurement failures and creates incident PRs in the ops repo.
# Requires: WOODPECKER_REPO_ID, woodpecker_api(), FORGE_API_BASE, FORGE_TOKEN,
#           FORGE_URL, FORGE_OPS_REPO, FORGE_REPO, PRIMARY_BRANCH

# ci_main_canary — check if CI is untrusted (2 consecutive failed pipelines on main)
#
# Queries Woodpecker for the last 20 pipelines on PRIMARY_BRANCH, finds the
# first two that have finished statuses, and checks if both are failures.
#
# Returns: 0 if CI is untrusted (both recent main pipelines failed), 1 otherwise.
# Stdout (when untrusted): "untrusted <pip1_number>:<status1> <pip2_number>:<status2>"
ci_main_canary() {
  if [ -z "${WOODPECKER_REPO_ID:-}" ] || [ "${WOODPECKER_REPO_ID}" = "0" ]; then
    return 1
  fi

  local pipelines_json
  pipelines_json=$(woodpecker_api "/repos/${WOODPECKER_REPO_ID}/pipelines?perPage=20" 2>/dev/null) || return 1

  # Find the last two finished pipelines on main, sorted by number descending
  # Note: skipped/blocked/declined are included in the finished pool so they can
  # appear in the top-2, but the untrusted trigger only fires on failure/error/killed.
  # A skipped pipeline between two failures (e.g. [failure, skipped, failure]) will
  # prevent detection — skipped pipelines do NOT reset the consecutive-failure counter.
  local result
  result=$(printf '%s' "$pipelines_json" | jq -r --arg branch "${PRIMARY_BRANCH:-main}" '
    [.[] | select(.branch == $branch)] |
    [.[] | select(.status == "failure" or .status == "error" or .status == "killed" or
                  .status == "declined" or .status == "skipped" or .status == "blocked")] |
    sort_by(-.number) | .[0:2] |
    if length < 2 then "ok"
    else
      if (.[0].status == "failure" or .[0].status == "error" or .[0].status == "killed") and
         (.[1].status == "failure" or .[1].status == "error" or .[1].status == "killed")
      then "untrusted \(.[0].number):\(.[0].status) \(.[1].number):\(.[1].status)"
      else "ok"
      end
    end
  ' 2>/dev/null) || return 1

  case "$result" in
    untrusted*)
      echo "$result"
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

# ci_get_main_pipelines — list recent finished pipelines on main
#
# Returns JSON array of pipeline objects for the last 20 finished pipelines
# on PRIMARY_BRANCH, sorted by number descending.
ci_get_main_pipelines() {
  if [ -z "${WOODPECKER_REPO_ID:-}" ] || [ "${WOODPECKER_REPO_ID}" = "0" ]; then
    echo "[]"
    return
  fi

  woodpecker_api "/repos/${WOODPECKER_REPO_ID}/pipelines?perPage=20" 2>/dev/null | \
    jq --arg branch "${PRIMARY_BRANCH:-main}" '
      [.[] | select(.branch == $branch)] |
      [.[] | select(.status == "failure" or .status == "error" or .status == "success" or
                    .status == "killed" or .status == "pending" or .status == "running" or
                    .status == "declined" or .status == "skipped" or .status == "blocked")] |
      sort_by(-.number)
    ' 2>/dev/null || echo "[]"
}

# ── Incident PR helpers (Forgejo API) ──────────────────────────────────────
# These functions create and manage incident PRs in the ops repo.
# The open PR IS the state — no JSON, no flag file.

# _ci_incident_pr_exists — check if an open incident PR exists in ops repo
# Returns: 0 if open incident PR exists, 1 otherwise.
# Stdout: PR number if found.
_ci_incident_pr_exists() {
  local response
  response=$(curl -sf -H "Authorization: token ${FORGE_TOKEN}" \
    "${FORGE_API_BASE}/repos/${FORGE_OPS_REPO}/pulls?state=open&limit=100" 2>/dev/null) || return 1

  local pr_number
  pr_number=$(printf '%s' "$response" | jq -r '.[] | select(.title | contains("incident: ci-untrusted")) | .number' 2>/dev/null | head -1) || return 1

  if [ -n "$pr_number" ]; then
    echo "$pr_number"
    return 0
  fi
  return 1
}

# create_incident_pr <signal> <pipelines_json>
# Creates an incident PR in the ops repo with detection signal and pipeline details.
# Signal format: "untrusted <pip1>:<status1> <pip2>:<status2>"
# Returns: PR number on success, empty on failure.
create_incident_pr() {
  local signal="$1"
  local pipelines_json="$2"

  if [ -z "$signal" ] || [ -z "$pipelines_json" ]; then
    echo "Usage: create_incident_pr <signal> <pipelines_json>" >&2
    return 1
  fi

  # Check if an incident PR already exists (idempotency)
  local existing_pr
  existing_pr=$(_ci_incident_pr_exists 2>/dev/null) || true
  if [ -n "$existing_pr" ]; then
    log "Incident PR #${existing_pr} already exists — not creating duplicate"
    echo "$existing_pr"
    return 0
  fi

  # Extract pipeline details for the PR body
  : # signal format: "untrusted <pip1>:<status1> <pip2>:<status2>"

  # Build pipeline details for PR body
  local pipeline_details
  local jq_filter2
  jq_filter2='[.[] | select(.status == "failure" or .status == "error" or .status == "killed") | "# Pipeline \(.number) (\(.status)) — commit \(.commit[0:7]) — \(.duration)s"] | .[0:5] | join("\n")'
  pipeline_details=$(printf '%s' "$pipelines_json" | jq -r "$jq_filter2") || pipeline_details="(no failure details available)"

  # Build PR body
  local timestamp
  timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
  local pr_body
  pr_body=$(cat <<EOF
## CI Circuit Breaker — Untrusted

**Detection**: main canary red — 2 consecutive failed pipelines on \`${PRIMARY_BRANCH:-main}\`

### Signal
\`ci_main_canary\` returned: \`${signal}\`

### Affected Pipelines
${pipeline_details}

### Timestamp
${timestamp}

---
Auto-filed by supervisor circuit breaker (issue #557).
EOF
)

  # Create incident branch on ops repo
  local branch_name
  branch_name="incidents/ci-untrusted-$(date -u "+%Y%m%d-%H%M")"
  if ! curl -sf -X POST \
    -H "Authorization: token ${FORGE_TOKEN}" \
    -H "Content-Type: application/json" \
    "${FORGE_API_BASE}/repos/${FORGE_OPS_REPO}/branches" \
    -d "{\"new_branch_name\": \"${branch_name}\", \"old_branch_name\": \"${PRIMARY_BRANCH:-main}\"}" >/dev/null 2>&1; then
    log "WARNING: failed to create incident branch ${branch_name}"
    return 1
  fi

  # Build incident file content
  local incident_filename
  incident_filename="${branch_name#incidents/}"
  local incident_file="# CI Circuit Breaker — Untrusted

**Detection**: main canary red — 2 consecutive failed pipelines on \`${PRIMARY_BRANCH:-main}\`

### Signal
\`ci_main_canary\` returned: \`${signal}\`

### Affected Pipelines
${pipeline_details}

### Timestamp
${timestamp}

---
Auto-filed by supervisor circuit breaker (issue #557).
"

  # Write incident file to branch (base64 encoded)
  local file_content_b64
  file_content_b64=$(printf '%s' "$incident_file" | base64 -w 0)

  local incidents_dir="incidents"
  # Ensure directory exists on the branch first
  # (Forgejo contents API requires parent directories to exist for file creation)
  if ! curl -sf -X PUT \
    -H "Authorization: token ${FORGE_TOKEN}" \
    -H "Content-Type: application/json" \
    "${FORGE_API_BASE}/repos/${FORGE_OPS_REPO}/contents/${incidents_dir}/.gitkeep" \
    -d "{\"message\": \"incidents: ensure directory\", \"content\": \"cGxhY2Vob2xkZXI=\", \"branch\": \"${branch_name}\"}" >/dev/null 2>&1; then
    : # Directory may already exist or will be created with the file
  fi

  local incident_path="incidents/${incident_filename}.md"
  if ! curl -sf -X PUT \
    -H "Authorization: token ${FORGE_TOKEN}" \
    -H "Content-Type: application/json" \
    "${FORGE_API_BASE}/repos/${FORGE_OPS_REPO}/contents/${incident_path}" \
    -d "{\"message\": \"incident: add ${incident_filename}.md\", \"content\": \"${file_content_b64}\", \"branch\": \"${branch_name}\"}" >/dev/null 2>&1; then
    log "WARNING: failed to write incident file ${incident_path}"
    return 1
  fi

  # Create PR — use jq to build JSON payload safely
  local pr_payload
  local pr_title
  pr_title="incident: ci-untrusted ($(date -u "+%Y-%m-%d %H:%M UTC"))"
  local jq_filter
  # shellcheck disable=SC2016  # jq variables — passed via --arg, not shell expansion
  jq_filter='{"title": $title, "body": $body, "head": $head, "base": $base}'
  pr_payload=$(jq -n \
    --arg title "$pr_title" \
    --arg body "$pr_body" \
    --arg head "$branch_name" \
    --arg base "${PRIMARY_BRANCH:-main}" \
    "$jq_filter")

  local pr_response
  pr_response=$(curl -sf -X POST \
    -H "Authorization: token ${FORGE_TOKEN}" \
    -H "Content-Type: application/json" \
    "${FORGE_API_BASE}/repos/${FORGE_OPS_REPO}/pulls" \
    -d "$pr_payload" 2>/dev/null) || return 1

  # Extract PR number
  local pr_number
  pr_number=$(printf '%s' "$pr_response" | jq -r '.number // empty')

  # Add "incident" label to the PR
  if [ -n "$pr_number" ]; then
    curl -sf -X POST \
      -H "Authorization: token ${FORGE_TOKEN}" \
      -H "Content-Type: application/json" \
      "${FORGE_API_BASE}/repos/${FORGE_OPS_REPO}/issues/${pr_number}/labels" \
      -d '{"labels":["incident"]}' >/dev/null 2>&1 || true

    log "Created incident PR #${pr_number}: ${pr_title}"
    printf '%s' "$pr_number"
  fi
}

# _ci_recover_incident_pr — close open incident PRs when main pipeline is green
#
# Called during recovery: when main canary is green, close any remaining
# open incident PRs to signal recovery.
_ci_recover_incident_pr() {
  # Verify main is actually green before closing
  local canary_result
  canary_result=$(ci_main_canary 2>/dev/null) || true
  if [ -n "$canary_result" ]; then
    log "CI circuit breaker: main still has failures — not closing incidents"
    return 1
  fi

  # Find open incident PRs
  local response
  response=$(curl -sf -H "Authorization: token ${FORGE_TOKEN}" \
    "${FORGE_API_BASE}/repos/${FORGE_OPS_REPO}/pulls?state=open&limit=100" 2>/dev/null) || return 1

  local pr_numbers
  pr_numbers=$(printf '%s' "$response" | jq -r '.[] | select(.title | contains("incident: ci-untrusted")) | .number' 2>/dev/null) || return 1

  if [ -z "$pr_numbers" ]; then
    return 0
  fi

  while IFS= read -r pr_num; do
    [ -z "$pr_num" ] && continue
    # Close the incident PR via the issues API (Forgejo treats PRs as issues)
    if curl -sf -X PATCH \
      -H "Authorization: token ${FORGE_TOKEN}" \
      -H "Content-Type: application/json" \
      "${FORGE_API_BASE}/repos/${FORGE_OPS_REPO}/issues/${pr_num}" \
      -d '{"state":"closed"}' >/dev/null 2>&1; then
      log "CI circuit breaker: closed incident PR #${pr_num} (recovery)"
    else
      log "WARNING: failed to close incident PR #${pr_num}"
    fi
  done <<< "$pr_numbers"
}
