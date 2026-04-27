#!/usr/bin/env bash
# =============================================================================
# lib/forge-paginate.sh — Paginated Forge API helper
#
# Provides forge_api_all() for paginating Forge API GET endpoints.
# Source this from any script that needs to fetch all pages of results.
#
# Usage:
#   source "$(dirname "${BASH_SOURCE[0]}")/forge-paginate.sh"
#   all_items=$(forge_api_all "/issues?state=open")
#   all_items=$(forge_api_all "/issues?state=open" "$CUSTOM_TOKEN")
# =============================================================================

# Paginate a Forge API GET endpoint and return all items as a merged JSON array.
# Usage: forge_api_all /path             (no existing query params)
#        forge_api_all /path?a=b         (with existing params — appends &limit=50&page=N)
#        forge_api_all /path TOKEN       (optional second arg: token; defaults to $FORGE_TOKEN)
forge_api_all() {
  local path_prefix="$1"
  local FORGE_TOKEN="${2:-${FORGE_TOKEN}}"
  local sep page page_items count all_items="[]"
  case "$path_prefix" in
    *"?"*) sep="&" ;;
    *) sep="?" ;;
  esac
  page=1
  while true; do
    page_items=$(forge_api GET "${path_prefix}${sep}limit=50&page=${page}" 2>/dev/null) || {
      echo "ERROR: forge unreachable" >&2
      return 1
    }
    count=$(printf '%s' "$page_items" | jq 'length' 2>/dev/null) || count=0
    [ -z "$count" ] && count=0
    [ "$count" -eq 0 ] && break
    all_items=$(printf '%s\n%s' "$all_items" "$page_items" | jq -s 'add')
    [ "$count" -lt 50 ] && break
    page=$((page + 1))
  done
  printf '%s' "$all_items"
}
