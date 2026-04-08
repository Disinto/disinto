#!/usr/bin/env bash
# vault-env.sh — Shared vault environment: loads lib/env.sh and activates
# vault-bot's Forgejo identity (#747).
# Source this instead of lib/env.sh in vault scripts.

# shellcheck source=../lib/env.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/env.sh"
# Use vault-bot's own Forgejo identity
FORGE_TOKEN="${FORGE_VAULT_TOKEN:-${FORGE_TOKEN}}"
export FORGE_TOKEN

# Export FORGE_ADMIN_TOKEN for direct commits (low-tier bypass)
# This token is used to commit directly to ops main without PR workflow
export FORGE_ADMIN_TOKEN="${FORGE_ADMIN_TOKEN:-}"

# Vault redesign in progress (PR-based approval workflow)
# This file is kept for shared env setup; scripts being replaced by #73

# Blast-radius classification — set VAULT_TIER if a formula is known
# Callers may set VAULT_ACTION_FORMULA before sourcing, or pass it later.
if [ -n "${VAULT_ACTION_FORMULA:-}" ]; then
  VAULT_TIER=$("$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/classify.sh" \
    "$VAULT_ACTION_FORMULA" "${VAULT_BLAST_RADIUS_OVERRIDE:-}")
  export VAULT_TIER
fi

# =============================================================================
# VAULT ACTION VALIDATION
# =============================================================================

# Allowed secret names - must match keys in .env.vault.enc
VAULT_ALLOWED_SECRETS="CLAWHUB_TOKEN GITHUB_TOKEN DEPLOY_KEY NPM_TOKEN DOCKER_HUB_TOKEN"

# Validate a vault action TOML file
# Usage: validate_vault_action <path-to-toml>
# Returns: 0 if valid, 1 if invalid
# Sets: VAULT_ACTION_ID, VAULT_ACTION_FORMULA, VAULT_ACTION_CONTEXT on success
validate_vault_action() {
  local toml_file="$1"

  if [ -z "$toml_file" ]; then
    echo "ERROR: No TOML file specified" >&2
    return 1
  fi

  if [ ! -f "$toml_file" ]; then
    echo "ERROR: File not found: $toml_file" >&2
    return 1
  fi

  log "Validating vault action: $toml_file"

  # Get script directory for relative path resolution
  # FACTORY_ROOT is set by lib/env.sh which is sourced above
  local formulas_dir="${FACTORY_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}/formulas"

  # Extract TOML values using grep/sed (basic TOML parsing)
  local toml_content
  toml_content=$(cat "$toml_file")

  # Extract string values (id, formula, context)
  local id formula context
  id=$(echo "$toml_content" | grep -E '^id\s*=' | sed -E 's/^id\s*=\s*"(.*)"/\1/' | tr -d '\r')
  formula=$(echo "$toml_content" | grep -E '^formula\s*=' | sed -E 's/^formula\s*=\s*"(.*)"/\1/' | tr -d '\r')
  context=$(echo "$toml_content" | grep -E '^context\s*=' | sed -E 's/^context\s*=\s*"(.*)"/\1/' | tr -d '\r')

  # Extract secrets array
  local secrets_line secrets_array
  secrets_line=$(echo "$toml_content" | grep -E '^secrets\s*=' | tr -d '\r')
  secrets_array=$(echo "$secrets_line" | sed -E 's/^secrets\s*=\s*\[(.*)\]/\1/' | tr -d '[]"' | tr ',' ' ' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')

  # Check for unknown fields (any top-level key not in allowed list)
  local unknown_fields
  unknown_fields=$(echo "$toml_content" | grep -E '^[a-zA-Z_][a-zA-Z0-9_]*\s*=' | sed -E 's/^([a-zA-Z_][a-zA-Z0-9_]*)\s*=.*/\1/' | sort -u | while read -r field; do
    case "$field" in
      id|formula|context|secrets|model|tools|timeout_minutes|dispatch_mode) ;;
      *) echo "$field" ;;
    esac
  done)

  if [ -n "$unknown_fields" ]; then
    echo "ERROR: Unknown fields in TOML: $(echo "$unknown_fields" | tr '\n' ', ' | sed 's/,$//')" >&2
    return 1
  fi

  # Validate required fields
  if [ -z "$id" ]; then
    echo "ERROR: Missing required field: id" >&2
    return 1
  fi

  if [ -z "$formula" ]; then
    echo "ERROR: Missing required field: formula" >&2
    return 1
  fi

  if [ -z "$context" ]; then
    echo "ERROR: Missing required field: context" >&2
    return 1
  fi

  # Validate formula exists in formulas/
  if [ ! -f "$formulas_dir/${formula}.toml" ]; then
    echo "ERROR: Formula not found: $formula" >&2
    return 1
  fi

  # Validate secrets field exists and is not empty
  if [ -z "$secrets_line" ]; then
    echo "ERROR: Missing required field: secrets" >&2
    return 1
  fi

  # Validate each secret is in the allowlist
  for secret in $secrets_array; do
    secret=$(echo "$secret" | tr -d '"' | xargs)  # trim whitespace and quotes
    if [ -n "$secret" ]; then
      if ! echo " $VAULT_ALLOWED_SECRETS " | grep -q " $secret "; then
        echo "ERROR: Unknown secret (not in allowlist): $secret" >&2
        return 1
      fi
    fi
  done

  # Validate optional fields if present
  # model
  if echo "$toml_content" | grep -qE '^model\s*='; then
    local model_value
    model_value=$(echo "$toml_content" | grep -E '^model\s*=' | sed -E 's/^model\s*=\s*"(.*)"/\1/' | tr -d '\r')
    if [ -z "$model_value" ]; then
      echo "ERROR: 'model' must be a non-empty string" >&2
      return 1
    fi
  fi

  # tools
  if echo "$toml_content" | grep -qE '^tools\s*='; then
    local tools_line
    tools_line=$(echo "$toml_content" | grep -E '^tools\s*=' | tr -d '\r')
    if ! echo "$tools_line" | grep -q '\['; then
      echo "ERROR: 'tools' must be an array" >&2
      return 1
    fi
  fi

  # timeout_minutes
  if echo "$toml_content" | grep -qE '^timeout_minutes\s*='; then
    local timeout_value
    timeout_value=$(echo "$toml_content" | grep -E '^timeout_minutes\s*=' | sed -E 's/^timeout_minutes\s*=\s*([0-9]+)/\1/' | tr -d '\r')
    if [ -z "$timeout_value" ] || [ "$timeout_value" -le 0 ] 2>/dev/null; then
      echo "ERROR: 'timeout_minutes' must be a positive integer" >&2
      return 1
    fi
  fi

  # Export validated values (for use by caller script)
  export VAULT_ACTION_ID="$id"
  export VAULT_ACTION_FORMULA="$formula"
  export VAULT_ACTION_CONTEXT="$context"
  export VAULT_ACTION_SECRETS="$secrets_array"

  log "VAULT_ACTION_ID=$VAULT_ACTION_ID"
  log "VAULT_ACTION_FORMULA=$VAULT_ACTION_FORMULA"
  log "VAULT_ACTION_SECRETS=$VAULT_ACTION_SECRETS"

  return 0
}
