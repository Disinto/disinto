#!/usr/bin/env bash
# =============================================================================
# register.sh — SSH forced-command handler for edge control plane
#
# This script runs as a forced command for the disinto-register SSH user.
# It parses SSH_ORIGINAL_COMMAND and dispatches to register|deregister|list.
#
# Per-caller attribution: each admin key's forced-command passes --as <tag>,
# which is stored as registered_by in the registry. Missing --as defaults to
# "unknown" for backwards compatibility.
#
# Usage (via SSH):
#   ssh disinto-register@edge "register <project> <pubkey>"
#   ssh disinto-register@edge "deregister <project> <pubkey>"
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

# Allowlist path (root-owned, never mutated by this script)
ALLOWLIST_FILE="${ALLOWLIST_FILE:-/var/lib/disinto/allowlist.json}"

# Audit log path
AUDIT_LOG="${AUDIT_LOG:-/var/log/disinto/edge-register.log}"

# Captured error from check_allowlist (used for JSON response)
_ALLOWLIST_ERROR=""

# Caller tag (set via --as <tag> in forced command)
CALLER="unknown"

# Parse script arguments (from forced command, not SSH_ORIGINAL_COMMAND)
while [[ $# -gt 0 ]]; do
  case $1 in
    --as)
      CALLER="$2"
      shift 2
      ;;
    *)
      shift
      ;;
  esac
done

# Append one line to the audit log.
# Usage: audit_log <action> <project> <port> <pubkey_fp>
# Fails silently — write errors are warned but never abort.
audit_log() {
  local action="$1" project="$2" port="$3" pubkey_fp="$4"
  local timestamp
  timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

  local line="${timestamp} ${action} project=${project} port=${port} pubkey_fp=${pubkey_fp} caller=${CALLER}"

  # Ensure log directory exists
  local log_dir
  log_dir=$(dirname "$AUDIT_LOG")
  if [ ! -d "$log_dir" ]; then
    mkdir -p "$log_dir" 2>/dev/null || {
      echo "[WARN] audit log: cannot create ${log_dir}" >&2
      return 0
    }
    chown root:disinto-register "$log_dir" 2>/dev/null || true
    chmod 0750 "$log_dir"
  fi

  # Append — write failure is non-fatal
  if ! printf '%s\n' "$line" >> "$AUDIT_LOG" 2>/dev/null; then
    echo "[WARN] audit log: failed to write to ${AUDIT_LOG}" >&2
  fi
}

# Print usage
usage() {
  cat <<EOF
Usage:
  register <project> <pubkey>       Register a new tunnel
  deregister <project> <pubkey>     Remove a tunnel (requires owner pubkey)
  list                              List all registered tunnels

Example:
  ssh disinto-register@edge "register myproject ssh-ed25519 AAAAC3..."
EOF
  exit 1
}

# Check whether the project/pubkey pair is allowed by the allowlist.
# Usage: check_allowlist <project> <pubkey>
# Returns: 0 if allowed, 1 if denied (prints error JSON to stderr)
check_allowlist() {
  local project="$1"
  local pubkey="$2"

  # If allowlist file does not exist, allow all (opt-in policy)
  if [ ! -f "$ALLOWLIST_FILE" ]; then
    return 0
  fi

  # Look up the project in the allowlist
  local entry
  entry=$(jq -c --arg p "$project" '.allowed[$p] // empty' "$ALLOWLIST_FILE" 2>/dev/null) || entry=""

  if [ -z "$entry" ]; then
    # Project not in allowlist at all
    _ALLOWLIST_ERROR="name not approved"
    return 1
  fi

  # Project found — check pubkey fingerprint binding
  local bound_fingerprint
  bound_fingerprint=$(echo "$entry" | jq -r '.pubkey_fingerprint // ""' 2>/dev/null)

  if [ -n "$bound_fingerprint" ]; then
    # Fingerprint is bound — verify caller's pubkey matches
    local caller_fingerprint
    caller_fingerprint=$(ssh-keygen -lf /dev/stdin <<<"$pubkey" 2>/dev/null | awk '{print $2}') || caller_fingerprint=""

    if [ -z "$caller_fingerprint" ]; then
      _ALLOWLIST_ERROR="invalid pubkey for fingerprint check"
      return 1
    fi

    if [ "$caller_fingerprint" != "$bound_fingerprint" ]; then
      _ALLOWLIST_ERROR="pubkey does not match allowed key for this project"
      return 1
    fi
  fi

  return 0
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

  # Check allowlist (opt-in: no file = allow all)
  if ! check_allowlist "$project" "$full_pubkey"; then
    echo "{\"error\":\"${_ALLOWLIST_ERROR}\"}"
    exit 1
  fi

  # Allocate port (idempotent - returns existing if already registered)
  local port
  port=$(allocate_port "$project" "$full_pubkey" "${project}.${DOMAIN_SUFFIX}" "$CALLER")

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

  # Audit log
  local pubkey_fp
  pubkey_fp=$(ssh-keygen -lf /dev/stdin <<<"$full_pubkey" 2>/dev/null | awk '{print $2}') || pubkey_fp="unknown"
  audit_log "register" "$project" "$port" "$pubkey_fp"

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
# Usage: do_deregister <project> <pubkey>
do_deregister() {
  local project="$1"
  local caller_pubkey="$2"

  if [ -z "$caller_pubkey" ]; then
    echo '{"error":"deregister requires <project> <pubkey>"}'
    exit 1
  fi

  # Record who is deregistering before removal
  local deregistered_by="$CALLER"

  # Get current port and pubkey before removing
  local port pubkey_fp
  port=$(get_port "$project")

  if [ -z "$port" ]; then
    echo '{"error":"project not found"}'
    exit 1
  fi

  # Verify caller owns this project — pubkey must match stored value
  local stored_pubkey
  stored_pubkey=$(get_project_info "$project" | jq -r '.pubkey // empty' 2>/dev/null) || stored_pubkey=""
  if [ "$caller_pubkey" != "$stored_pubkey" ]; then
    echo '{"error":"pubkey mismatch"}'
    exit 1
  fi

  pubkey_fp=$(ssh-keygen -lf /dev/stdin <<<"$stored_pubkey" 2>/dev/null | awk '{print $2}') || pubkey_fp="unknown"

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

  # Audit log
  audit_log "deregister" "$project" "$port" "$pubkey_fp"

  # Return JSON response
  echo "{\"removed\":true,\"port\":${port},\"fqdn\":\"${project}.${DOMAIN_SUFFIX}\",\"deregistered_by\":\"${deregistered_by}\"}"
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
      # deregister <project> <pubkey>
      local project="${args%% *}"
      local pubkey="${args#* }"
      if [ "$pubkey" = "$args" ]; then
        pubkey=""
      fi
      if [ -z "$project" ] || [ -z "$pubkey" ]; then
        echo '{"error":"deregister requires <project> <pubkey>"}'
        exit 1
      fi
      do_deregister "$project" "$pubkey"
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
