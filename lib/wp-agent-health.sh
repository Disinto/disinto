#!/usr/bin/env bash
# wp-agent-health.sh — newest Woodpecker agent contact (#1698)
#
# The supervisor cannot inspect the Nomad-named agent container. The
# Woodpecker server lists every registered agent, with last_contact in
# epoch seconds. Stale registrations from restarts sit beside the live
# one, so the age is now minus the largest last_contact across every page.
#
# Requires: woodpecker_api() (lib/env.sh), jq, date.
#
# wp_agent_last_contact_age
#   GET /api/agents?page=N&perPage=50 for N = 1, 2, … until a page has
#   fewer than 50 entries, at most 10 pages. Prints seconds since the
#   newest last_contact and returns 0. A failed request, or no agent at
#   all: print nothing, return 1.

set -euo pipefail

# wp_agent_last_contact_age — see the file header.
wp_agent_last_contact_age() {
  local page=1 body count contact newest="" now
  while [ "$page" -le 10 ]; do
    body="$(woodpecker_api "/agents?page=${page}&perPage=50")" || return 1
    count="$(printf '%s' "$body" | jq -r 'if type == "array" then length else empty end')" || return 1
    [[ "$count" =~ ^[0-9]+$ ]] || return 1
    contact="$(printf '%s' "$body" | jq -r '[.[] | .last_contact | select(type == "number") | floor] | if length == 0 then empty else max end')" || return 1
    if [ -n "$contact" ]; then
      [[ "$contact" =~ ^-?[0-9]+$ ]] || return 1
      if [ -z "$newest" ] || [ "$contact" -gt "$newest" ]; then
        newest="$contact"
      fi
    fi
    # A short page is the last page. A full page continues, up to 10.
    if [ "$count" -lt 50 ]; then
      break
    fi
    page=$((page + 1))
  done
  [ -n "$newest" ] || return 1
  now="$(date +%s)"
  printf '%s\n' "$((now - newest))"
}
