#!/usr/bin/env bash
# ci-helpers.sh — Shared CI helper functions
#
# Source from any script: source "$(dirname "$0")/../lib/ci-helpers.sh"
# ci_passed() requires: WOODPECKER_REPO_ID (from env.sh / project config)
# classify_pipeline_failure() requires: woodpecker_api() (defined in env.sh)

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
  all_json=$(codeberg_api_all "/pulls/${pr_num}/files") || return 0
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

# classify_pipeline_failure <repo_id> <pipeline_num>
# Classifies a pipeline's failure type by inspecting all failed steps.
# Outputs "infra" if every failed step is a git step with exit code 128 or 137.
# Outputs "code" otherwise (including when steps cannot be determined).
# Returns 0 for infra, 1 for code or unclassifiable.
classify_pipeline_failure() {
  local repo_id="$1" pip_num="$2"
  local pip_json failed_steps all_infra _sname _ecode

  pip_json=$(woodpecker_api "/repos/${repo_id}/pipelines/${pip_num}" 2>/dev/null) || {
    echo "code"; return 1
  }

  failed_steps=$(printf '%s' "$pip_json" | jq -r '
    .workflows[]?.children[]? |
    select(.state == "failure" or .state == "error" or .state == "killed") |
    "\(.name)\t\(.exit_code)"' 2>/dev/null)

  if [ -z "$failed_steps" ]; then
    echo "code"; return 1
  fi

  all_infra=true
  _infra_count=0
  while IFS=$'\t' read -r _sname _ecode; do
    [ -z "$_sname" ] && continue
    # git step with exit 128 (connection/rate-limit) or 137 (OOM) → infra
    if [[ "$_sname" == git* ]] && { [ "$_ecode" = "128" ] || [ "$_ecode" = "137" ]; }; then
      _infra_count=$(( _infra_count + 1 ))
    else
      all_infra=false
      break
    fi
  done <<< "$failed_steps"

  # Require at least one confirmed infra step (guards against all-empty-name steps)
  if [ "$all_infra" = true ] && [ "$_infra_count" -gt 0 ]; then
    echo "infra"
    return 0
  fi
  echo "code"
  return 1
}
