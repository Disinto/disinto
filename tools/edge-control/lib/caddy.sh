#!/usr/bin/env bash
# =============================================================================
# lib/caddy.sh — Caddy admin API route helper
#
# Interacts with the Caddy admin API on 127.0.0.1:2019 to manage ONE route
# per project:
#   - add_route <project> <port>
#       POSTs exactly one new route whose `match.host` is exactly
#       [<project>.${DOMAIN_SUFFIX}] as a reverse_proxy to
#       127.0.0.1:<port>. Never PUTs /config/, never replaces a server.
#       No wildcard hosts, no wildcard proxy sites.
#   - add_webhook_route
#       POSTs exactly one new route whose `match.uri` is exactly
#       /stripe/webhook as a reverse_proxy to 127.0.0.1:9088 — the port the
#       operator's per-request invoker listens on (stripe-webhook.sh). No
#       host match (path only), no wildcard, no catch-all. Never PUTs /config/,
#       never replaces a server, never touches any other route (site blocks,
#       other project routes, a self.disinto.ai stub, etc.). If a route with
#       that path already exists, it is a no-op (returns 0, does not POST).
#       Returns 0 on success (added or already present), 1 on any failure.
#   - remove_route <project>
#       GETs the server's routes, finds the single route index whose host
#       list is EXACTLY [<project>.${DOMAIN_SUFFIX}], and DELETEs only that
#       index. If no such route exists, returns 0 (idempotent) and deletes
#       nothing — every other route in the list is left untouched.
#   - reload_caddy
#       POST /reload on the admin API.
#
# Sourced by lib/apply-name.sh (EDGE_APPLY=1 only). Not a standalone entry
# point — it has no main().
# =============================================================================
set -euo pipefail

# Caddy admin API endpoint
CADDY_ADMIN_URL="${CADDY_ADMIN_URL:-http://127.0.0.1:2019}"

# Domain suffix for projects
DOMAIN_SUFFIX="${DOMAIN_SUFFIX:-disinto.ai}"

# Discover the Caddy server name that listens on :80/:443.
# GETs only — never PUTs /config/ or replaces any server.
_discover_server_name() {
  local server_name
  server_name=$(curl -sS "${CADDY_ADMIN_URL}/config/apps/http/servers" \
    | jq -r 'to_entries
            | map(select(.value.listen[]? | test(":(80|443)$")))
            | .[0].key // empty') || {
    echo "Error: could not query Caddy admin API for servers" >&2
    return 1
  }

  if [ -z "$server_name" ]; then
    echo "Error: could not find a Caddy server listening on :80/:443" >&2
    return 1
  fi

  echo "$server_name"
}

# ── add_route: POST exactly one route, exact host only ───────────────────────
# add_route <project> <port>
# Returns 0 on success, 1 on any failure.
add_route() {
  local project="$1"
  local port="$2"
  local fqdn="${project}.${DOMAIN_SUFFIX}"

  local server_name
  server_name=$(_discover_server_name) || return 1

  # The route: one match on exactly <project>.<DOMAIN_SUFFIX>, proxied to
  # 127.0.0.1:<port>. No wildcards, no catch-all.
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
      "handler": "reverse_proxy",
      "upstreams": [
        {
          "dial": "127.0.0.1:${port}"
        }
      ]
    }
  ]
}
EOF
  )

  # POST appends the single route to the server's routes array.
  # Never PUT /config/, never replace a server.
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

  echo "Added route: ${fqdn} -> 127.0.0.1:${port}" >&2
}

# ── remove_route: DELETE only the exact-host index ───────────────────────────
# remove_route <project>
# Finds the route index whose flattened host list is EXACTLY
# [<project>.<DOMAIN_SUFFIX>] and deletes only that index.
# If no such route exists, returns 0 without deleting anything (idempotent).
# Every other route in the list is left untouched.
remove_route() {
  local project="$1"
  local fqdn="${project}.${DOMAIN_SUFFIX}"

  local server_name
  server_name=$(_discover_server_name) || return 1

  # Current routes for the server.
  local response status body
  response=$(curl -sS -w '\n%{http_code}' \
    "${CADDY_ADMIN_URL}/config/apps/http/servers/${server_name}/routes" \
    -H "Content-Type: application/json") || {
    echo "Error: failed to get current routes" >&2
    return 1
  }
  status=$(echo "$response" | tail -n1)
  body=$(echo "$response" | sed '$d')
  if [ "$status" -ge 400 ]; then
    echo "Error: Caddy admin API returned ${status}: ${body}" >&2
    return 1
  fi

  # The route index whose host list is exactly [fqdn]. A route that shares
  # fqdn with other hosts (e.g. ["acme.disinto.ai","www.disinto.ai"]) does
  # NOT match — deleting it would take other hosts with it.
  local route_index
  route_index=$(echo "$body" | jq -r --arg h "$fqdn" \
    'to_entries[]
     | select((.value.match // [] | map(.host // []) | add // []) == [$h])
     | .key' 2>/dev/null | head -n1)

  if [ -z "$route_index" ] || [ "$route_index" = "null" ]; then
    echo "Route for ${fqdn} not present; nothing to remove" >&2
    return 0
  fi

  # DELETE only that index.
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

# ── add_webhook_route: POST exactly one path route for /stripe/webhook ──────
# add_webhook_route
# No arguments: the contract is fixed to the exact path /stripe/webhook
# reverse-proxied to 127.0.0.1:9088 (the port the operator runs the
# per-request invoker that pipes stdin + STRIPE_SIGNATURE into
# stripe-webhook.sh). No host is chosen, no wildcard, no catch-all.
#
# Idempotent: GETs the current routes first; if any route already matches
# the exact path /stripe/webhook (match[].uri), it returns 0 and does not
# POST again. Otherwise it POSTs exactly one route, leaving every other
# route untouched (no PUT /config/, no DELETE of any existing route).
#
# Returns 0 on success (added, or already present), 1 on any failure.
add_webhook_route() {
  local WEBHOOK_PATH="/stripe/webhook"
  local WEBHOOK_PORT=9088

  local server_name
  server_name=$(_discover_server_name) || return 1

  # Current routes for the server.
  local response status body
  response=$(curl -sS -w '\n%{http_code}' \
    "${CADDY_ADMIN_URL}/config/apps/http/servers/${server_name}/routes" \
    -H "Content-Type: application/json") || {
    echo "Error: failed to get current routes for add_webhook_route" >&2
    return 1
  }
  status=$(echo "$response" | tail -n1)
  body=$(echo "$response" | sed '$d')
  if [ "$status" -ge 400 ]; then
    echo "Error: Caddy admin API returned ${status}: ${body}" >&2
    return 1
  fi

  # Idempotency: find any route whose match array contains an entry whose
  # `uri` is EXACTLY /stripe/webhook. A host-only route (e.g.
  # self.disinto.ai) does NOT match and is left untouched. If one exists,
  # do nothing and return 0.
  local route_index
  route_index=$(echo "$body" | jq -r --arg p "$WEBHOOK_PATH" \
    'to_entries[]
     | select((.value.match // []) | map(.uri // "") | any(. == $p))
     | .key' 2>/dev/null | head -n1)

  if [ -n "$route_index" ] && [ "$route_index" != "null" ]; then
    echo "Route for ${WEBHOOK_PATH} already present; nothing to add" >&2
    return 0
  fi

  # The route: one match on the exact path /stripe/webhook (uri, not host),
  # proxied to 127.0.0.1:9088. No host, no wildcard, no catch-all.
  local route_config
  route_config=$(cat <<EOF
{
  "match": [
    {
      "uri": "${WEBHOOK_PATH}"
    }
  ],
  "handle": [
    {
      "handler": "reverse_proxy",
      "upstreams": [
        {
          "dial": "127.0.0.1:${WEBHOOK_PORT}"
        }
      ]
    }
  ]
}
EOF
  )

  # POST appends the single route to the server's routes array.
  # Never PUT /config/, never replace a server.
  response=$(curl -sS -w '\n%{http_code}' -X POST \
    "${CADDY_ADMIN_URL}/config/apps/http/servers/${server_name}/routes" \
    -H "Content-Type: application/json" \
    -d "$route_config") || {
    echo "Error: failed to add webhook route for ${WEBHOOK_PATH}" >&2
    return 1
  }
  status=$(echo "$response" | tail -n1)
  body=$(echo "$response" | sed '$d')
  if [ "$status" -ge 400 ]; then
    echo "Error: Caddy admin API returned ${status}: ${body}" >&2
    return 1
  fi

  echo "Added webhook route: ${WEBHOOK_PATH} -> 127.0.0.1:${WEBHOOK_PORT}" >&2
}

# ── reload_caddy: POST /reload on the admin API ───────────────────────────────
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
