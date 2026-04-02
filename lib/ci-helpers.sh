#!/usr/bin/env bash
set -euo pipefail
# ci-helpers.sh — Shared CI helper functions
#
# Source from any script: source "$(dirname "$0")/../lib/ci-helpers.sh"
# ci_passed() requires: WOODPECKER_REPO_ID (from env.sh / project config)
# ci_commit_status() / ci_pipeline_number() require: woodpecker_api(), forge_api() (from env.sh)
# classify_pipeline_failure() requires: woodpecker_api() (defined in env.sh)

# ensure_blocked_label_id — look up (or create) the "blocked" label, print its ID.
# Caches the result in _BLOCKED_LABEL_ID to avoid repeated API calls.
# Requires: FORGE_TOKEN, FORGE_API (from env.sh), forge_api()
ensure_blocked_label_id() {
  if [ -n "${_BLOCKED_LABEL_ID:-}" ]; then
    printf '%s' "$_BLOCKED_LABEL_ID"
    return 0
  fi
  _BLOCKED_LABEL_ID=$(forge_api GET "/labels" 2>/dev/null \
    | jq -r '.[] | select(.name == "blocked") | .id' 2>/dev/null || true)
  if [ -z "$_BLOCKED_LABEL_ID" ]; then
    _BLOCKED_LABEL_ID=$(curl -sf -X POST \
      -H "Authorization: token ${FORGE_TOKEN}" \
      -H "Content-Type: application/json" \
      "${FORGE_API}/labels" \
      -d '{"name":"blocked","color":"#e11d48"}' 2>/dev/null \
      | jq -r '.id // empty' 2>/dev/null || true)
  fi
  printf '%s' "$_BLOCKED_LABEL_ID"
}

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
# Queries Woodpecker API directly, falls back to forge commit status API.
ci_commit_status() {
  local sha="$1"
  local state=""

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
