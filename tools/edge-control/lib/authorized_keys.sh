#!/usr/bin/env bash
# =============================================================================
# lib/authorized_keys.sh — Rebuild authorized_keys from registry
#
# Rebuilds disinto-tunnel's authorized_keys file from the registry.
# Each entry has:
#   - restrict flag (no shell, no X11 forwarding, etc.)
#   - permitlisten for allowed reverse tunnel ports
#   - command="/bin/false" to prevent arbitrary command execution
#
# Functions:
#   rebuild_authorized_keys → rebuilds /home/disinto-tunnel/.ssh/authorized_keys
#   get_tunnel_authorized_keys → prints the generated authorized_keys content
# =============================================================================
set -euo pipefail

# Source ports library (SCRIPT_DIR is this file's directory, so lib/ports.sh is adjacent)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/ports.sh"

# Tunnel user home directory
TUNNEL_USER="disinto-tunnel"
TUNNEL_SSH_DIR="/home/${TUNNEL_USER}/.ssh"
TUNNEL_AUTH_KEYS="${TUNNEL_SSH_DIR}/authorized_keys"

# Ensure tunnel user exists
_ensure_tunnel_user() {
  if ! id "$TUNNEL_USER" &>/dev/null; then
    useradd -r -s /usr/sbin/nologin -M "$TUNNEL_USER" 2>/dev/null || true
    mkdir -p "$TUNNEL_SSH_DIR"
    chmod 700 "$TUNNEL_SSH_DIR"
  fi
}

# Generate the authorized_keys content from registry
# Output: one authorized_keys line per registered project
generate_authorized_keys_content() {
  local content=""
  local first=true

  # Get all projects from registry
  while IFS= read -r line; do
    [ -z "$line" ] && continue

    local project port pubkey
    # shellcheck disable=SC2034
    project=$(echo "$line" | jq -r '.name')
    port=$(echo "$line" | jq -r '.port')
    pubkey=$(echo "$line" | jq -r '.pubkey')

    # Skip if missing required fields
    [ -z "$port" ] || [ -z "$pubkey" ] && continue

    # Build the authorized_keys line
    # Format: restrict,port-forwarding,permitlisten="127.0.0.1:<port>",command="/bin/false" <key-type> <key>
    local auth_line="restrict,port-forwarding,permitlisten=\"127.0.0.1:${port}\",command=\"/bin/false\" ${pubkey}"

    if [ "$first" = true ]; then
      content="$auth_line"
      first=false
    else
      content="${content}
${auth_line}"
    fi
  done < <(list_ports)

  if [ -z "$content" ]; then
    # No projects registered, create empty file
    echo "# No tunnels registered"
  else
    echo "$content"
  fi
}

# Rebuild authorized_keys file
# Usage: rebuild_authorized_keys
rebuild_authorized_keys() {
  _ensure_tunnel_user

  local content
  content=$(generate_authorized_keys_content)

  # Write to file
  echo "$content" > "$TUNNEL_AUTH_KEYS"
  chmod 600 "$TUNNEL_AUTH_KEYS"
  chown -R "$TUNNEL_USER":"$TUNNEL_USER" "$TUNNEL_SSH_DIR"

  echo "Rebuilt authorized_keys for ${TUNNEL_USER} (entries: $(echo "$content" | grep -c 'ssh-' || echo 0))"
}

# Get the current authorized_keys content (for verification)
# Usage: get_tunnel_authorized_keys
get_tunnel_authorized_keys() {
  if [ -f "$TUNNEL_AUTH_KEYS" ]; then
    cat "$TUNNEL_AUTH_KEYS"
  else
    generate_authorized_keys_content
  fi
}
