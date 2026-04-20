#!/usr/bin/env bash
# =============================================================================
# lib/ports.sh — Port allocator for edge control plane
#
# Manages port allocation in the range 20000-29999.
# Uses flock-based concurrency control over registry.json.
#
# Functions:
#   allocate_port <project> <pubkey> <fqdn> → writes to registry, returns port
#   free_port <project> → removes project from registry
#   get_port <project> → returns assigned port or empty
#   list_ports → prints all projects with port/FQDN
# =============================================================================
set -euo pipefail

# Directory containing registry files
REGISTRY_DIR="${REGISTRY_DIR:-/var/lib/disinto}"
REGISTRY_FILE="${REGISTRY_DIR}/registry.json"
LOCK_FILE="${REGISTRY_DIR}/registry.lock"

# Port range
PORT_MIN=20000
PORT_MAX=29999

# Ensure registry directory exists
_ensure_registry_dir() {
  if [ ! -d "$REGISTRY_DIR" ]; then
    mkdir -p "$REGISTRY_DIR"
    chmod 0750 "$REGISTRY_DIR"
    chown root:disinto-register "$REGISTRY_DIR"
  fi
  if [ ! -f "$LOCK_FILE" ]; then
    touch "$LOCK_FILE"
    chmod 0644 "$LOCK_FILE"
  fi
}

# Read current registry, returns JSON or empty string
_registry_read() {
  if [ -f "$REGISTRY_FILE" ]; then
    cat "$REGISTRY_FILE"
  else
    echo '{"version":1,"projects":{}}'
  fi
}

# Write registry atomically (write to temp, then mv)
_registry_write() {
  local tmp_file
  tmp_file=$(mktemp "${REGISTRY_DIR}/registry.XXXXXX")
  echo "$1" > "$tmp_file"
  mv -f "$tmp_file" "$REGISTRY_FILE"
  chmod 0644 "$REGISTRY_FILE"
}

# Allocate a port for a project
# Usage: allocate_port <project> <pubkey> <fqdn> [<registered_by>]
# Returns: port number on stdout
# Writes: registry.json with project entry
allocate_port() {
  local project="$1"
  local pubkey="$2"
  local fqdn="$3"
  local registered_by="${4:-unknown}"

  _ensure_registry_dir

  # Use flock for concurrency control
  exec 200>"$LOCK_FILE"
  flock -x 200

  local registry
  registry=$(_registry_read)

  # Check if project already has a port assigned
  local existing_port
  existing_port=$(echo "$registry" | jq -r ".projects[\"$project\"].port // empty" 2>/dev/null) || existing_port=""

  if [ -n "$existing_port" ]; then
    # Project already registered, return existing port
    echo "$existing_port"
    return 0
  fi

  # Find an available port
  local port assigned=false
  local used_ports
  used_ports=$(echo "$registry" | jq -r '.projects | to_entries | map(.value.port) | .[]' 2>/dev/null) || used_ports=""

  for candidate in $(seq $PORT_MIN $PORT_MAX); do
    # Check if port is already used
    local in_use=false
    if echo "$used_ports" | grep -qx "$candidate"; then
      in_use=true
    fi

    if [ "$in_use" = false ]; then
      port=$candidate
      assigned=true
      break
    fi
  done

  if [ "$assigned" = false ]; then
    echo "Error: no available ports in range ${PORT_MIN}-${PORT_MAX}" >&2
    return 1
  fi

  # Get current timestamp
  local timestamp
  timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

  # Add project to registry
  local new_registry
  new_registry=$(echo "$registry" | jq --arg project "$project" \
    --argjson port "$port" \
    --arg pubkey "$pubkey" \
    --arg fqdn "$fqdn" \
    --arg timestamp "$timestamp" \
    --arg registered_by "$registered_by" \
    '.projects[$project] = {
      "port": $port,
      "fqdn": $fqdn,
      "pubkey": $pubkey,
      "registered_at": $timestamp,
      "registered_by": $registered_by
    }')

  _registry_write "$new_registry"

  echo "$port"
}

# Free a port (remove project from registry)
# Usage: free_port <project>
# Returns: 0 on success, 1 if project not found
free_port() {
  local project="$1"

  _ensure_registry_dir

  # Use flock for concurrency control
  exec 200>"$LOCK_FILE"
  flock -x 200

  local registry
  registry=$(_registry_read)

  # Check if project exists
  local existing_port
  existing_port=$(echo "$registry" | jq -r ".projects[\"$project\"].port // empty" 2>/dev/null) || existing_port=""

  if [ -z "$existing_port" ]; then
    echo "Error: project '$project' not found in registry" >&2
    return 1
  fi

  # Remove project from registry
  local new_registry
  new_registry=$(echo "$registry" | jq --arg project "$project" 'del(.projects[$project])')

  _registry_write "$new_registry"

  echo "$existing_port"
}

# Get the port for a project
# Usage: get_port <project>
# Returns: port number or empty string
get_port() {
  local project="$1"

  _ensure_registry_dir

  local registry
  registry=$(_registry_read)

  echo "$registry" | jq -r ".projects[\"$project\"].port // empty" 2>/dev/null || echo ""
}

# List all registered projects with their ports and FQDNs
# Usage: list_ports
# Returns: JSON array of projects
list_ports() {
  _ensure_registry_dir

  local registry
  registry=$(_registry_read)

  echo "$registry" | jq -r '.projects | to_entries | map({name: .key, port: .value.port, fqdn: .value.fqdn, registered_by: (.value.registered_by // "unknown")}) | .[] | @json' 2>/dev/null
}

# Get full project info from registry
# Usage: get_project_info <project>
# Returns: JSON object with project details
get_project_info() {
  local project="$1"

  _ensure_registry_dir

  local registry
  registry=$(_registry_read)

  echo "$registry" | jq -c ".projects[\"$project\"] // empty" 2>/dev/null || echo ""
}
