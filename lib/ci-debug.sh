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

# WOODPECKER_TOKEN loaded from .env via env.sh
REPO="${FORGE_REPO}"
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
    woodpecker-cli pipeline log show "$REPO" "$P" "$S"
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
      woodpecker-cli pipeline log show "$REPO" "$P" "$pid" 2>/dev/null | tail -200
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
