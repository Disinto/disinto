#!/usr/bin/env bash
# =============================================================================
# lib/caddy.sh — Caddy admin API wrapper
#
# Interacts with Caddy admin API on 127.0.0.1:2019 to:
# - Add site blocks for <project>.disinto.ai → reverse_proxy 127.0.0.1:<port>
# - Remove site blocks when deregistering
#
# Functions:
#   add_route <project> <port> → adds Caddy site block
#   remove_route <project> → removes Caddy site block
#   reload_caddy → sends POST /reload to apply changes
# =============================================================================
set -euo pipefail

# Caddy admin API endpoint
CADDY_ADMIN_URL="${CADDY_ADMIN_URL:-http://127.0.0.1:2019}"

# Domain suffix for projects
DOMAIN_SUFFIX="${DOMAIN_SUFFIX:-disinto.ai}"

# Discover the Caddy server name that listens on :80/:443
# Usage: _discover_server_name
_discover_server_name() {
  local server_name
  server_name=$(curl -sS "${CADDY_ADMIN_URL}/config/apps/http/servers" \
    | jq -r 'to_entries | map(select(.value.listen[]? | test(":(80|443)$"))) | .[0].key // empty') || {
    echo "Error: could not query Caddy admin API for servers" >&2
    return 1
  }

  if [ -z "$server_name" ]; then
    echo "Error: could not find a Caddy server listening on :80/:443" >&2
    return 1
  fi

  echo "$server_name"
}

# Add a route for a project
# Usage: add_route <project> <port>
add_route() {
  local project="$1"
  local port="$2"
  local fqdn="${project}.${DOMAIN_SUFFIX}"

  local server_name
  server_name=$(_discover_server_name) || return 1

  # Build the route configuration (partial config)
  local route_config
  route_config=$(cat <<EOF
{
  "match": [
    {
      "host": ["${fqdn}"]
    }
  ],
  "handle": [
    {
      "handler": "subroute",
      "routes": [
        {
          "handle": [
            {
              "handler": "reverse_proxy",
              "upstreams": [
                {
                  "dial": "127.0.0.1:${port}"
                }
              ]
            }
          ]
        }
      ]
    }
  ]
}
EOF
)

  # Append route via admin API, checking HTTP status
  local response status body
  response=$(curl -sS -w '\n%{http_code}' -X POST \
    "${CADDY_ADMIN_URL}/config/apps/http/servers/${server_name}/routes" \
    -H "Content-Type: application/json" \
    -d "$route_config") || {
    echo "Error: failed to add route for ${fqdn}" >&2
    return 1
  }
  status=$(echo "$response" | tail -n1)
  body=$(echo "$response" | sed '$d')
  if [ "$status" -ge 400 ]; then
    echo "Error: Caddy admin API returned ${status}: ${body}" >&2
    return 1
  fi

  echo "Added route: ${fqdn} → 127.0.0.1:${port}" >&2
}

# Remove a route for a project
# Usage: remove_route <project>
remove_route() {
  local project="$1"
  local fqdn="${project}.${DOMAIN_SUFFIX}"

  local server_name
  server_name=$(_discover_server_name) || return 1

  # First, get current routes, checking HTTP status
  local response status body
  response=$(curl -sS -w '\n%{http_code}' \
    "${CADDY_ADMIN_URL}/config/apps/http/servers/${server_name}/routes") || {
    echo "Error: failed to get current routes" >&2
    return 1
  }
  status=$(echo "$response" | tail -n1)
  body=$(echo "$response" | sed '$d')
  if [ "$status" -ge 400 ]; then
    echo "Error: Caddy admin API returned ${status}: ${body}" >&2
    return 1
  fi

  # Find the route index that matches our fqdn using jq
  local route_index
  route_index=$(echo "$body" | jq -r "to_entries[] | select(.value.match[]?.host[]? == \"${fqdn}\") | .key" 2>/dev/null | head -1)

  if [ -z "$route_index" ] || [ "$route_index" = "null" ]; then
    echo "Warning: route for ${fqdn} not found" >&2
    return 0
  fi

  # Delete the route at the found index, checking HTTP status
  response=$(curl -sS -w '\n%{http_code}' -X DELETE \
    "${CADDY_ADMIN_URL}/config/apps/http/servers/${server_name}/routes/${route_index}" \
    -H "Content-Type: application/json") || {
    echo "Error: failed to remove route for ${fqdn}" >&2
    return 1
  }
  status=$(echo "$response" | tail -n1)
  body=$(echo "$response" | sed '$d')
  if [ "$status" -ge 400 ]; then
    echo "Error: Caddy admin API returned ${status}: ${body}" >&2
    return 1
  fi

  echo "Removed route: ${fqdn}" >&2
}

# Reload Caddy to apply configuration changes
# Usage: reload_caddy
reload_caddy() {
  local response status body
  response=$(curl -sS -w '\n%{http_code}' -X POST \
    "${CADDY_ADMIN_URL}/reload") || {
    echo "Error: failed to reload Caddy" >&2
    return 1
  }
  status=$(echo "$response" | tail -n1)
  body=$(echo "$response" | sed '$d')
  if [ "$status" -ge 400 ]; then
    echo "Error: Caddy reload returned ${status}: ${body}" >&2
    return 1
  fi

  echo "Caddy reloaded" >&2
}

# Get Caddy config for debugging
# Usage: get_caddy_config
get_caddy_config() {
  curl -s "${CADDY_ADMIN_URL}/config"
}

# Check if Caddy admin API is reachable
# Usage: check_caddy_health
check_caddy_health() {
  local response
  response=$(curl -s -o /dev/null -w "%{http_code}" \
    "${CADDY_ADMIN_URL}/" 2>/dev/null) || response="000"

  if [ "$response" = "200" ]; then
    return 0
  else
    echo "Caddy admin API not reachable (HTTP ${response})" >&2
    return 1
  fi
}
