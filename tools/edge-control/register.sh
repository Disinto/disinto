#!/usr/bin/env bash
# =============================================================================
# register.sh — SSH forced-command handler for edge control plane
#
# This script runs as a forced command for the disinto-register SSH user.
# It parses SSH_ORIGINAL_COMMAND and dispatches to register|deregister|list.
#
# Usage (via SSH):
#   ssh disinto-register@edge "register <project> <pubkey>"
#   ssh disinto-register@edge "deregister <project>"
#   ssh disinto-register@edge "list"
#
# Output: JSON on stdout
# =============================================================================
set -euo pipefail

# Script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source libraries
source "${SCRIPT_DIR}/lib/ports.sh"
source "${SCRIPT_DIR}/lib/caddy.sh"
source "${SCRIPT_DIR}/lib/authorized_keys.sh"

# Domain suffix
DOMAIN_SUFFIX="${DOMAIN_SUFFIX:-disinto.ai}"

# Reserved project names — operator-adjacent, internal roles, and subdomain-mode prefixes
RESERVED_NAMES=(www api admin root mail chat forge ci edge caddy disinto register tunnel)

# Print usage
usage() {
  cat <<EOF
Usage:
  register <project> <pubkey>       Register a new tunnel
  deregister <project>              Remove a tunnel
  list                              List all registered tunnels

Example:
  ssh disinto-register@edge "register myproject ssh-ed25519 AAAAC3..."
EOF
  exit 1
}

# Register a new tunnel
# Usage: do_register <project> <pubkey>
# When EDGE_ROUTING_MODE=subdomain, also registers forge.<project>, ci.<project>,
# and chat.<project> subdomain routes (see docs/edge-routing-fallback.md).
do_register() {
  local project="$1"
  local pubkey="$2"

  # Validate project name — strict DNS label: lowercase alphanumeric, inner hyphens,
  # 3-63 chars, no leading/trailing hyphen, no underscore (RFC 1035)
  if ! [[ "$project" =~ ^[a-z0-9][a-z0-9-]{1,61}[a-z0-9]$ ]]; then
    echo '{"error":"invalid project name"}'
    exit 1
  fi

  # Check against reserved names
  local reserved
  for reserved in "${RESERVED_NAMES[@]}"; do
    if [[ "$project" = "$reserved" ]]; then
      echo '{"error":"name reserved"}'
      exit 1
    fi
  done

  # Extract key type and key from pubkey (format: "ssh-ed25519 AAAAC3...")
  local key_type key
  key_type=$(echo "$pubkey" | awk '{print $1}')
  key=$(echo "$pubkey" | awk '{print $2}')

  if [ -z "$key_type" ] || [ -z "$key" ]; then
    echo '{"error":"invalid pubkey format"}'
    exit 1
  fi

  # Validate key type
  if ! [[ "$key_type" =~ ^(ssh-ed25519|ssh-rsa|ecdsa-sha2-nistp256|ecdsa-sha2-nistp384|ecdsa-sha2-nistp521)$ ]]; then
    echo '{"error":"unsupported key type"}'
    exit 1
  fi

  # Full pubkey for registry
  local full_pubkey="${key_type} ${key}"

  # Allocate port (idempotent - returns existing if already registered)
  local port
  port=$(allocate_port "$project" "$full_pubkey" "${project}.${DOMAIN_SUFFIX}")

  # Add Caddy route for main project domain
  add_route "$project" "$port"

  # Subdomain mode: register additional routes for per-service subdomains
  local routing_mode="${EDGE_ROUTING_MODE:-subpath}"
  if [ "$routing_mode" = "subdomain" ]; then
    local subdomain
    for subdomain in forge ci chat; do
      add_route "${subdomain}.${project}" "$port"
    done
  fi

  # Rebuild authorized_keys for tunnel user
  rebuild_authorized_keys

  # Reload Caddy
  reload_caddy

  # Build JSON response
  local response="{\"port\":${port},\"fqdn\":\"${project}.${DOMAIN_SUFFIX}\""
  if [ "$routing_mode" = "subdomain" ]; then
    response="${response},\"routing_mode\":\"subdomain\""
    response="${response},\"subdomains\":{\"forge\":\"forge.${project}.${DOMAIN_SUFFIX}\",\"ci\":\"ci.${project}.${DOMAIN_SUFFIX}\",\"chat\":\"chat.${project}.${DOMAIN_SUFFIX}\"}"
  fi
  response="${response}}"
  echo "$response"
}

# Deregister a tunnel
# Usage: do_deregister <project>
do_deregister() {
  local project="$1"

  # Get current port before removing
  local port
  port=$(get_port "$project")

  if [ -z "$port" ]; then
    echo '{"error":"project not found"}'
    exit 1
  fi

  # Remove from registry
  free_port "$project" >/dev/null

  # Remove Caddy route for main project domain
  remove_route "$project"

  # Subdomain mode: also remove per-service subdomain routes
  local routing_mode="${EDGE_ROUTING_MODE:-subpath}"
  if [ "$routing_mode" = "subdomain" ]; then
    local subdomain
    for subdomain in forge ci chat; do
      remove_route "${subdomain}.${project}"
    done
  fi

  # Rebuild authorized_keys for tunnel user
  rebuild_authorized_keys

  # Reload Caddy
  reload_caddy

  # Return JSON response
  echo "{\"removed\":true,\"port\":${port},\"fqdn\":\"${project}.${DOMAIN_SUFFIX}\"}"
}

# List all registered tunnels
# Usage: do_list
do_list() {
  local result='{"tunnels":['
  local first=true

  while IFS= read -r line; do
    [ -z "$line" ] && continue

    if [ "$first" = true ]; then
      first=false
    else
      result="${result},"
    fi

    result="${result}${line}"
  done < <(list_ports)

  result="${result}]}"
  echo "$result"
}

# Main dispatch
main() {
  # Get the SSH_ORIGINAL_COMMAND
  local command="${SSH_ORIGINAL_COMMAND:-}"

  if [ -z "$command" ]; then
    echo '{"error":"no command provided"}'
    exit 1
  fi

  # Parse command
  local cmd="${command%% *}"
  local args="${command#* }"

  # Handle commands
  case "$cmd" in
    register)
      # register <project> <pubkey>
      local project="${args%% *}"
      local pubkey="${args#* }"
      # Handle case where pubkey might have spaces (rare but possible with some formats)
      if [ "$pubkey" = "$args" ]; then
        pubkey=""
      fi
      if [ -z "$project" ] || [ -z "$pubkey" ]; then
        echo '{"error":"register requires <project> <pubkey>"}'
        exit 1
      fi
      do_register "$project" "$pubkey"
      ;;
    deregister)
      # deregister <project>
      local project="$args"
      if [ -z "$project" ]; then
        echo '{"error":"deregister requires <project>"}'
        exit 1
      fi
      do_deregister "$project"
      ;;
    list)
      do_list
      ;;
    *)
      echo '{"error":"unknown command: '"$cmd"'" }'
      usage
      ;;
  esac
}

main "$@"
