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

# Add a route for a project
# Usage: add_route <project> <port>
add_route() {
  local project="$1"
  local port="$2"
  local fqdn="${project}.${DOMAIN_SUFFIX}"

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

  # Append route using POST /config/apps/http/servers/edge/routes
  local response
  response=$(curl -s -X POST \
    "${CADDY_ADMIN_URL}/config/apps/http/servers/edge/routes" \
    -H "Content-Type: application/json" \
    -d "$route_config" 2>&1) || {
    echo "Error: failed to add route for ${fqdn}" >&2
    echo "Response: ${response}" >&2
    return 1
  }

  echo "Added route: ${fqdn} → 127.0.0.1:${port}"
}

# Remove a route for a project
# Usage: remove_route <project>
remove_route() {
  local project="$1"
  local fqdn="${project}.${DOMAIN_SUFFIX}"

  # First, get current routes
  local routes_json
  routes_json=$(curl -s "${CADDY_ADMIN_URL}/config/apps/http/servers/edge/routes" 2>&1) || {
    echo "Error: failed to get current routes" >&2
    return 1
  }

  # Find the route index that matches our fqdn
  local route_index=-1
  local idx=0
  while IFS= read -r host; do
    if [ "$host" = "$fqdn" ]; then
      route_index=$idx
      break
    fi
    idx=$((idx + 1))
  done < <(echo "$routes_json" | jq -r '.[].match[].host[]' 2>/dev/null)

  if [ "$route_index" -lt 0 ]; then
    echo "Warning: route for ${fqdn} not found" >&2
    return 0
  fi

  # Delete the route at the found index
  local response
  response=$(curl -s -X DELETE \
    "${CADDY_ADMIN_URL}/config/apps/http/servers/edge/routes/${route_index}" \
    -H "Content-Type: application/json" 2>&1) || {
    echo "Error: failed to remove route for ${fqdn}" >&2
    echo "Response: ${response}" >&2
    return 1
  }

  echo "Removed route: ${fqdn}"
}

# Reload Caddy to apply configuration changes
# Usage: reload_caddy
reload_caddy() {
  local response
  response=$(curl -s -X POST \
    "${CADDY_ADMIN_URL}/reload" 2>&1) || {
    echo "Error: failed to reload Caddy" >&2
    echo "Response: ${response}" >&2
    return 1
  }

  echo "Caddy reloaded"
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
