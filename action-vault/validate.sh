#!/usr/bin/env bash
# vault/validate.sh — Validate vault action TOML files
#
# Usage: ./vault/validate.sh <path-to-toml>
#
# Validates a vault action TOML file according to the schema defined in
# vault/SCHEMA.md. Checks:
# - Required fields are present
# - Secret names are in the allowlist
# - No unknown fields are present
# - Formula exists in formulas/

set -euo pipefail

# Get script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source vault environment
source "$SCRIPT_DIR/vault-env.sh"

# Get the TOML file to validate
TOML_FILE="${1:-}"

if [ -z "$TOML_FILE" ]; then
  echo "Usage: $0 <path-to-toml>" >&2
  echo "Example: $0 vault/examples/publish.toml" >&2
  exit 1
fi

# Resolve relative paths
if [[ "$TOML_FILE" != /* ]]; then
  TOML_FILE="$(cd "$(dirname "$TOML_FILE")" && pwd)/$(basename "$TOML_FILE")"
fi

# Run validation
if validate_vault_action "$TOML_FILE"; then
  echo "VALID: $TOML_FILE"
  echo "  ID: $VAULT_ACTION_ID"
  echo "  Formula: $VAULT_ACTION_FORMULA"
  echo "  Context: $VAULT_ACTION_CONTEXT"
  echo "  Secrets: $VAULT_ACTION_SECRETS"
  echo "  Mounts: ${VAULT_ACTION_MOUNTS:-none}"
  exit 0
else
  echo "INVALID: $TOML_FILE" >&2
  exit 1
fi
