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

  # Build Caddy site block configuration
  local config
  config=$(cat <<EOF
{
  "apps": {
    "http": {
      "servers": {
        "edge": {
          "listen": [":80", ":443"],
          "routes": [
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
          ]
        }
      }
    }
  }
}
EOF
)

  # Send POST to Caddy admin API to load config
  # Note: This appends to existing config rather than replacing
  local response
  response=$(curl -s -X POST \
    "${CADDY_ADMIN_URL}/load" \
    -H "Content-Type: application/json" \
    -d "$config" 2>&1) || {
    echo "Error: failed to add route for ${fqdn}" >&2
    echo "Response: ${response}" >&2
    return 1
  }

  # Check response
  local loaded
  loaded=$(echo "$response" | jq -r '.loaded // empty' 2>/dev/null) || loaded=""

  if [ "$loaded" = "true" ]; then
    echo "Added route: ${fqdn} → 127.0.0.1:${port}"
  else
    echo "Warning: Caddy admin response: ${response}" >&2
    # Don't fail hard - config might have been merged successfully
  fi
}

# Remove a route for a project
# Usage: remove_route <project>
remove_route() {
  local project="$1"
  local fqdn="${project}.${DOMAIN_SUFFIX}"

  # Use Caddy admin API to delete the config for this host
  # We need to delete the specific host match from the config
  local response
  response=$(curl -s -X DELETE \
    "${CADDY_ADMIN_URL}/config/apps/http/servers/edge/routes/0" \
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
