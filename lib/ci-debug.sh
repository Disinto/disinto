#!/usr/bin/env bash
# ci-debug.sh — Query Woodpecker CI (CLI for logs, API for structure)
#
# Usage:
#   ci-debug.sh status [pipeline]        — pipeline overview + step states
#   ci-debug.sh logs <pipeline> <step#>  — full logs for a step
#   ci-debug.sh failures [pipeline]      — all failed step logs
#   ci-debug.sh list [count]             — recent pipelines (default 10)

set -euo pipefail

# Load shared environment
source "$(dirname "$0")/../lib/env.sh"
# shellcheck source=ci-helpers.sh
source "$(dirname "$0")/../lib/ci-helpers.sh"

# WOODPECKER_TOKEN reaches the agent containers from Vault, rendered into
# secrets/bots.env by the jobspec template stanza (#1114). Name the missing
# piece: under `set -u` the bare unbound-variable abort told a reader nothing.
for _v in WOODPECKER_TOKEN WOODPECKER_SERVER WOODPECKER_REPO_ID; do
  if [ -z "${!_v:-}" ]; then
    echo "ERROR: ${_v} is not set — cannot query Woodpecker." >&2
    echo "       Agent containers get it from Vault (kv/disinto/shared/ci)." >&2
    exit 1
  fi
done
unset _v

API="${WOODPECKER_SERVER}/api/repos/${WOODPECKER_REPO_ID}"

api() {
  # Validate API URL to prevent URL injection
  if ! validate_url "$API"; then
    echo "ERROR: API URL validation failed - possible URL injection attempt" >&2
    return 1
  fi
  curl -sf -H "Authorization: Bearer ${WOODPECKER_TOKEN}" "${API}/$1"
}

get_latest() {
  api "pipelines?per_page=1" | jq -r '.[0].number'
}

# step_log <pipeline> <pid> — print one step's log.
#
# Fetches over the REST API rather than shelling out to `woodpecker-cli`: that
# binary is not installed in the agent container, and the SQLite path used by
# lib/ci-log-reader.py needs /woodpecker-data mounted, which it is not (#1114).
#
# The logs endpoint is keyed on the step's `id`, not the `pid` that `status`
# prints, so resolve that first and hand off to the shared helper.
step_log() {
  local pipeline="$1" pid="$2" step_id
  step_id=$(api "pipelines/${pipeline}" | \
    jq -r --arg pid "$pid" '.workflows[]?.children[]? | select(.pid == ($pid|tonumber)) | .id' | head -1)
  if [ -z "$step_id" ] || [ "$step_id" = "null" ]; then
    echo "ERROR: no step id for pid ${pid} in pipeline ${pipeline}" >&2
    return 1
  fi
  ci_get_step_logs "$pipeline" "$step_id"
}

case "${1:-help}" in
  list)
    COUNT="${2:-10}"
    api "pipelines?per_page=${COUNT}" | \
      jq -r '.[] | "#\(.number) \(.status) \(.event) \(.commit[:7]) \(.message | split("\n")[0][:60])"'
    ;;

  status)
    P="${2:-$(get_latest)}"
    echo "Pipeline #${P}:"
    api "pipelines/${P}" | \
      jq -r '"  Status: \(.status)  Event: \(.event)  Commit: \(.commit[:7])"'
    echo "Steps:"
    api "pipelines/${P}" | \
      jq -r '.workflows[]? | "  [\(.name)]", (.children[]? | "    [\(.pid)] \(.name) → \(.state) (exit \(.exit_code))")'
    ;;

  logs)
    P="${2:?Usage: ci-debug.sh logs <pipeline> <step#>}"
    S="${3:?Usage: ci-debug.sh logs <pipeline> <step#>}"
    step_log "$P" "$S"
    ;;

  failures)
    P="${2:-$(get_latest)}"
    FAILED=$(api "pipelines/${P}" | \
      jq -r '.workflows[]?.children[]? | select(.state=="failure") | "\(.pid)\t\(.name)"')

    if [ -z "$FAILED" ]; then
      echo "No failed steps in pipeline #${P}"
      exit 0
    fi

    while IFS=$'\t' read -r pid name; do
      echo "=== FAILED: ${name} (step ${pid}) ==="
      step_log "$P" "$pid" 2>/dev/null | tail -200
      echo ""
    done <<< "$FAILED"
    ;;

  help|*)
    cat <<'EOF'
ci-debug.sh — Query Woodpecker CI

Commands:
  list [count]              Recent pipelines (default 10)
  status [pipeline]         Pipeline overview + step states
  logs <pipeline> <step#>   Full step logs (step# = pid from status)
  failures [pipeline]       All failed step logs (last 200 lines each)
EOF
    ;;
esac
