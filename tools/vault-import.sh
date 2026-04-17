#!/usr/bin/env bash
# =============================================================================
# vault-import.sh — Import .env and sops-decrypted secrets into Vault KV
#
# Reads existing .env and sops-encrypted .env.vault.enc from the old docker stack
# and writes them to Vault KV paths matching the S2.1 policy layout.
#
# Usage:
#   vault-import.sh \
#     --env /path/to/.env \
#     [--sops /path/to/.env.vault.enc] \
#     [--age-key /path/to/age/keys.txt]
#
# Flag validation (S2.5, issue #883):
#   --import-sops without --age-key → error.
#   --age-key without --import-sops → error.
#   --env alone (no sops) → OK; imports only the plaintext half.
#
# Mapping:
#   From .env:
#     - FORGE_{ROLE}_TOKEN + FORGE_{ROLE}_PASS → kv/disinto/bots/<role>/{token,password}
#       (roles: review, dev, gardener, architect, planner, predictor, supervisor, vault)
#     - FORGE_TOKEN_LLAMA + FORGE_PASS_LLAMA → kv/disinto/bots/dev-qwen/{token,password}
#     - FORGE_TOKEN + FORGE_PASS → kv/disinto/shared/forge/{token,password}
#     - FORGE_ADMIN_TOKEN → kv/disinto/shared/forge/admin_token
#     - WOODPECKER_* → kv/disinto/shared/woodpecker/<lowercase_key>
#     - FORWARD_AUTH_SECRET, CHAT_OAUTH_* → kv/disinto/shared/chat/<lowercase_key>
#   From sops-decrypted .env.vault.enc:
#     - GITHUB_TOKEN, CODEBERG_TOKEN, CLAWHUB_TOKEN, DEPLOY_KEY, NPM_TOKEN, DOCKER_HUB_TOKEN
#       → kv/disinto/runner/<NAME>/value
#
# Security:
#   - Refuses to run if VAULT_ADDR is not localhost
#   - Writes to KV v2, not v1
#   - Validates sops age key file is mode 0400 before sourcing
#   - Never logs secret values — only key names
#
# Idempotency:
#   - Reports unchanged/updated/created per key via hvault_kv_get
#   - --dry-run prints the full import plan without writing
# =============================================================================

set -euo pipefail

# ── Internal helpers ──────────────────────────────────────────────────────────

# _log — emit a log message to stdout (never to stderr to avoid polluting diff)
_log() {
  printf '[vault-import] %s\n' "$*"
}

# _err — emit an error message to stderr
_err() {
  printf '[vault-import] ERROR: %s\n' "$*" >&2
}

# _die — log error and exit with status 1
_die() {
  _err "$@"
  exit 1
}

# _check_vault_addr — ensure VAULT_ADDR is localhost (security check)
_check_vault_addr() {
  local addr="${VAULT_ADDR:-}"
  if [[ ! "$addr" =~ ^https?://(localhost|127\.0\.0\.1)(:[0-9]+)?$ ]]; then
    _die "Security check failed: VAULT_ADDR must be localhost for safety. Got: $addr"
  fi
}

# _validate_age_key_perms — ensure age key file is mode 0400
_validate_age_key_perms() {
  local keyfile="$1"
  local perms
  perms="$(stat -c '%a' "$keyfile" 2>/dev/null)" || _die "Cannot stat age key file: $keyfile"
  if [ "$perms" != "400" ]; then
    _die "Age key file permissions are $perms, expected 400. Refusing to proceed for security."
  fi
}

# _decrypt_sops — decrypt sops-encrypted file using SOPS_AGE_KEY_FILE
_decrypt_sops() {
  local sops_file="$1"
  local age_key="$2"
  local output
  # sops outputs YAML format by default, extract KEY=VALUE lines
  output="$(SOPS_AGE_KEY_FILE="$age_key" sops -d "$sops_file" 2>/dev/null | \
    grep -E '^[A-Z_][A-Z0-9_]*=' | \
    sed 's/^\([^=]*\)=\(.*\)$/\1=\2/')" || \
    _die "Failed to decrypt sops file: $sops_file. Check age key and file integrity."
  printf '%s' "$output"
}

# _load_env_file — source an environment file (safety: only KEY=value lines)
_load_env_file() {
  local env_file="$1"
  local temp_env
  temp_env="$(mktemp)"
  # Extract only valid KEY=value lines (skip comments, blank lines, malformed)
  grep -E '^[A-Za-z_][A-Za-z0-9_]*=' "$env_file" 2>/dev/null > "$temp_env" || true
  # shellcheck source=/dev/null
  source "$temp_env"
  rm -f "$temp_env"
}

# _kv_path_exists — check if a KV path exists (returns 0 if exists, 1 if not)
_kv_path_exists() {
  local path="$1"
  # Use hvault_kv_get and check if it fails with "not found"
  if hvault_kv_get "$path" >/dev/null 2>&1; then
    return 0
  fi
  # Check if the error is specifically "not found"
  local err_output
  err_output="$(hvault_kv_get "$path" 2>&1)" || true
  if printf '%s' "$err_output" | grep -qi 'not found\|404'; then
    return 1
  fi
  # Some other error (e.g., auth failure) — treat as unknown
  return 1
}

# _kv_get_value — get a single key value from a KV path
_kv_get_value() {
  local path="$1"
  local key="$2"
  hvault_kv_get "$path" "$key"
}

# _kv_put_secret — write a secret to KV v2
_kv_put_secret() {
  local path="$1"
  shift
  local kv_pairs=("$@")

  # Build JSON payload with all key-value pairs
  local payload='{"data":{}}'
  for kv in "${kv_pairs[@]}"; do
    local k="${kv%%=*}"
    local v="${kv#*=}"
    # Use jq with --arg for safe string interpolation (handles quotes/backslashes)
    payload="$(printf '%s' "$payload" | jq --arg k "$k" --arg v "$v" '. * {"data": {($k): $v}}')"
  done

  # Use curl directly for KV v2 write with versioning
  local tmpfile http_code
  tmpfile="$(mktemp)"
  http_code="$(curl -s -w '%{http_code}' \
    -H "X-Vault-Token: ${VAULT_TOKEN}" \
    -H "Content-Type: application/json" \
    -X POST \
    -d "$payload" \
    -o "$tmpfile" \
    "${VAULT_ADDR}/v1/${VAULT_KV_MOUNT:-kv}/data/${path}")" || {
    rm -f "$tmpfile"
    _err "Failed to write to Vault at ${VAULT_KV_MOUNT:-kv}/data/${path}: curl error"
    return 1
  }
  rm -f "$tmpfile"

  # Check HTTP status — 2xx is success
  case "$http_code" in
    2[0-9][0-9])
      return 0
      ;;
    404)
      _err "KV path not found: ${VAULT_KV_MOUNT:-kv}/data/${path}"
      return 1
      ;;
    403)
      _err "Permission denied writing to ${VAULT_KV_MOUNT:-kv}/data/${path}"
      return 1
      ;;
    *)
      _err "Failed to write to Vault at ${VAULT_KV_MOUNT:-kv}/data/${path}: HTTP $http_code"
      return 1
      ;;
  esac
}

# _format_status — format the status string for a key
_format_status() {
  local status="$1"
  local path="$2"
  local key="$3"
  case "$status" in
    unchanged)
      printf '  %s: %s/%s (unchanged)' "$status" "$path" "$key"
      ;;
    updated)
      printf '  %s: %s/%s (updated)' "$status" "$path" "$key"
      ;;
    created)
      printf '  %s: %s/%s (created)' "$status" "$path" "$key"
      ;;
    *)
      printf '  %s: %s/%s (unknown)' "$status" "$path" "$key"
      ;;
  esac
}

# ── Mapping definitions ──────────────────────────────────────────────────────

# Bots mapping: FORGE_{ROLE}_TOKEN + FORGE_{ROLE}_PASS
declare -a BOT_ROLES=(review dev gardener architect planner predictor supervisor vault)

# Runner tokens from sops-decrypted file
declare -a RUNNER_TOKENS=(GITHUB_TOKEN CODEBERG_TOKEN CLAWHUB_TOKEN DEPLOY_KEY NPM_TOKEN DOCKER_HUB_TOKEN)

# ── Main logic ────────────────────────────────────────────────────────────────

main() {
  local env_file=""
  local sops_file=""
  local age_key_file=""
  local dry_run=false

  # Parse arguments
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --env)
        env_file="$2"
        shift 2
        ;;
      --sops)
        sops_file="$2"
        shift 2
        ;;
      --age-key)
        age_key_file="$2"
        shift 2
        ;;
      --dry-run)
        dry_run=true
        shift
        ;;
      --help|-h)
        cat <<'EOF'
vault-import.sh — Import .env and sops-decrypted secrets into Vault KV

Usage:
  vault-import.sh \
    --env /path/to/.env \
    [--sops /path/to/.env.vault.enc] \
    [--age-key /path/to/age/keys.txt] \
    [--dry-run]

Options:
  --env       Path to .env file (required)
  --sops      Path to sops-encrypted .env.vault.enc file (optional;
              requires --age-key when set)
  --age-key   Path to age keys file (required when --sops is set)
  --dry-run   Print import plan without writing to Vault (optional)
  --help      Show this help message

Mapping:
  From .env:
    - FORGE_{ROLE}_TOKEN + FORGE_{ROLE}_PASS → kv/disinto/bots/<role>/{token,password}
    - FORGE_TOKEN_LLAMA + FORGE_PASS_LLAMA → kv/disinto/bots/dev-qwen/{token,password}
    - FORGE_TOKEN + FORGE_PASS → kv/disinto/shared/forge/{token,password}
    - FORGE_ADMIN_TOKEN → kv/disinto/shared/forge/admin_token
    - WOODPECKER_* → kv/disinto/shared/woodpecker/<lowercase_key>
    - FORWARD_AUTH_SECRET, CHAT_OAUTH_* → kv/disinto/shared/chat/<lowercase_key>

  From sops-decrypted .env.vault.enc:
    - GITHUB_TOKEN, CODEBERG_TOKEN, CLAWHUB_TOKEN, DEPLOY_KEY, NPM_TOKEN, DOCKER_HUB_TOKEN
      → kv/disinto/runner/<NAME>/value

Examples:
  vault-import.sh --env .env --sops .env.vault.enc --age-key age-keys.txt
  vault-import.sh --env .env --sops .env.vault.enc --age-key age-keys.txt --dry-run
EOF
        exit 0
        ;;
      *)
        _die "Unknown option: $1. Use --help for usage."
        ;;
    esac
  done

  # Validate required arguments. --sops and --age-key are paired: if one
  # is set, the other must be too. --env alone (no sops half) is valid —
  # imports only the plaintext dotenv. Spec: S2.5 / issue #883 / #912.
  if [ -z "$env_file" ]; then
    _die "Missing required argument: --env"
  fi
  if [ -n "$sops_file" ] && [ -z "$age_key_file" ]; then
    _die "--sops requires --age-key"
  fi
  if [ -n "$age_key_file" ] && [ -z "$sops_file" ]; then
    _die "--age-key requires --sops"
  fi

  # Validate files exist
  if [ ! -f "$env_file" ]; then
    _die "Environment file not found: $env_file"
  fi
  if [ -n "$sops_file" ] && [ ! -f "$sops_file" ]; then
    _die "Sops file not found: $sops_file"
  fi
  if [ -n "$age_key_file" ] && [ ! -f "$age_key_file" ]; then
    _die "Age key file not found: $age_key_file"
  fi

  # Security check: age key permissions (only when an age key is provided —
  # --env-only imports never touch the age key).
  if [ -n "$age_key_file" ]; then
    _validate_age_key_perms "$age_key_file"
  fi

  # Source the Vault helpers and default the local-cluster VAULT_ADDR +
  # VAULT_TOKEN before the localhost safety check runs. `disinto init`
  # does not export these in the common fresh-LXC case (issue #912).
  source "$(dirname "$0")/../lib/hvault.sh"
  _hvault_default_env

  # Security check: VAULT_ADDR must be localhost
  _check_vault_addr

  # Load .env file
  _log "Loading environment from: $env_file"
  _load_env_file "$env_file"

  # Decrypt sops file when --sops was provided. On the --env-only path
  # (empty $sops_file) the sops_env stays empty and the per-token loop
  # below silently skips runner-token imports — exactly the "only
  # plaintext half" spec from S2.5.
  local sops_env=""
  if [ -n "$sops_file" ]; then
    _log "Decrypting sops file: $sops_file"
    sops_env="$(_decrypt_sops "$sops_file" "$age_key_file")"
    # shellcheck disable=SC2086
    eval "$sops_env"
  else
    _log "No --sops flag — skipping sops decryption (importing plaintext .env only)"
  fi

  # Collect all import operations
  declare -a operations=()

  # --- From .env ---

  # Bots: FORGE_{ROLE}_TOKEN + FORGE_{ROLE}_PASS
  for role in "${BOT_ROLES[@]}"; do
    local token_var="FORGE_${role^^}_TOKEN"
    local pass_var="FORGE_${role^^}_PASS"
    local token_val="${!token_var:-}"
    local pass_val="${!pass_var:-}"

    if [ -n "$token_val" ] && [ -n "$pass_val" ]; then
      operations+=("bots|$role|token|$env_file|$token_var")
      operations+=("bots|$role|pass|$env_file|$pass_var")
    elif [ -n "$token_val" ] || [ -n "$pass_val" ]; then
      _err "Warning: $role bot has token but no password (or vice versa), skipping"
    fi
  done

  # Llama bot: FORGE_TOKEN_LLAMA + FORGE_PASS_LLAMA
  local llama_token="${FORGE_TOKEN_LLAMA:-}"
  local llama_pass="${FORGE_PASS_LLAMA:-}"
  if [ -n "$llama_token" ] && [ -n "$llama_pass" ]; then
    operations+=("bots|dev-qwen|token|$env_file|FORGE_TOKEN_LLAMA")
    operations+=("bots|dev-qwen|pass|$env_file|FORGE_PASS_LLAMA")
  elif [ -n "$llama_token" ] || [ -n "$llama_pass" ]; then
    _err "Warning: dev-qwen bot has token but no password (or vice versa), skipping"
  fi

  # Generic forge creds: FORGE_TOKEN + FORGE_PASS
  local forge_token="${FORGE_TOKEN:-}"
  local forge_pass="${FORGE_PASS:-}"
  if [ -n "$forge_token" ] && [ -n "$forge_pass" ]; then
    operations+=("forge|token|$env_file|FORGE_TOKEN")
    operations+=("forge|pass|$env_file|FORGE_PASS")
  fi

  # Forge admin token: FORGE_ADMIN_TOKEN
  local forge_admin_token="${FORGE_ADMIN_TOKEN:-}"
  if [ -n "$forge_admin_token" ]; then
    operations+=("forge|admin_token|$env_file|FORGE_ADMIN_TOKEN")
  fi

  # Woodpecker secrets: WOODPECKER_*
  # Only read from the .env file, not shell environment
  local woodpecker_keys=()
  while IFS='=' read -r key _; do
    if [[ "$key" =~ ^WOODPECKER_ ]] || [[ "$key" =~ ^WP_[A-Z_]+$ ]]; then
      woodpecker_keys+=("$key")
    fi
  done < <(grep -E '^[A-Z_][A-Z0-9_]*=' "$env_file" 2>/dev/null || true)
  for key in "${woodpecker_keys[@]}"; do
    local val="${!key}"
    if [ -n "$val" ]; then
      local lowercase_key="${key,,}"
      operations+=("woodpecker|$lowercase_key|$env_file|$key")
    fi
  done

  # Chat secrets: FORWARD_AUTH_SECRET, CHAT_OAUTH_CLIENT_ID, CHAT_OAUTH_CLIENT_SECRET
  for key in FORWARD_AUTH_SECRET CHAT_OAUTH_CLIENT_ID CHAT_OAUTH_CLIENT_SECRET; do
    local val="${!key:-}"
    if [ -n "$val" ]; then
      local lowercase_key="${key,,}"
      operations+=("chat|$lowercase_key|$env_file|$key")
    fi
  done

  # --- From sops-decrypted .env.vault.enc ---

  # Runner tokens
  for token_name in "${RUNNER_TOKENS[@]}"; do
    local token_val="${!token_name:-}"
    if [ -n "$token_val" ]; then
      operations+=("runner|$token_name|$sops_file|$token_name")
    fi
  done

  # If dry-run, just print the plan
  if $dry_run; then
    _log "=== DRY-RUN: Import plan ==="
    _log "Environment file: $env_file"
    if [ -n "$sops_file" ]; then
      _log "Sops file: $sops_file"
      _log "Age key: $age_key_file"
    else
      _log "Sops file: (none — --env-only import)"
    fi
    _log ""
    _log "Planned operations:"
    for op in "${operations[@]}"; do
      _log "  $op"
    done
    _log ""
    _log "Total: ${#operations[@]} operations"
    exit 0
  fi

  # --- Actual import with idempotency check ---

  _log "=== Starting Vault import ==="
  _log "Environment file: $env_file"
  if [ -n "$sops_file" ]; then
    _log "Sops file: $sops_file"
    _log "Age key: $age_key_file"
  else
    _log "Sops file: (none — --env-only import)"
  fi
  _log ""

  local created=0
  local updated=0
  local unchanged=0

  # First pass: collect all operations with their parsed values.
  # Store value and status in separate associative arrays keyed by
  # "vault_path:kv_key". Secret values may contain any character, so we
  # never pack them into a delimited string — the previous `value|status`
  # encoding silently truncated values containing '|' (see issue #898).
  declare -A ops_value
  declare -A ops_status
  declare -A path_seen

  for op in "${operations[@]}"; do
    # Parse operation: category|field|subkey|file|envvar (5 fields for bots/runner)
    # or category|field|file|envvar (4 fields for forge/woodpecker/chat).
    # These metadata strings are built from safe identifiers (role names,
    # env-var names, file paths) and do not carry secret values, so '|' is
    # still fine as a separator here.
    local category field subkey file envvar=""
    local field_count
    field_count="$(printf '%s' "$op" | awk -F'|' '{print NF}')"

    if [ "$field_count" -eq 5 ]; then
      # 5 fields: category|role|subkey|file|envvar
      IFS='|' read -r category field subkey file envvar <<< "$op"
    else
      # 4 fields: category|field|file|envvar
      IFS='|' read -r category field file envvar <<< "$op"
      subkey="$field"  # For 4-field ops, field is the vault key
    fi

    # Determine Vault path and key based on category
    local vault_path=""
    local vault_key="$subkey"
    local source_value=""

    if [ "$file" = "$env_file" ]; then
      # Source from environment file (envvar contains the variable name)
      source_value="${!envvar:-}"
    else
      # Source from sops-decrypted env (envvar contains the variable name)
      source_value="$(printf '%s' "$sops_env" | grep "^${envvar}=" | sed "s/^${envvar}=//" || true)"
    fi

    case "$category" in
      bots)
        vault_path="disinto/bots/${field}"
        vault_key="$subkey"
        ;;
      forge)
        vault_path="disinto/shared/forge"
        vault_key="$field"
        ;;
      woodpecker)
        vault_path="disinto/shared/woodpecker"
        vault_key="$field"
        ;;
      chat)
        vault_path="disinto/shared/chat"
        vault_key="$field"
        ;;
      runner)
        vault_path="disinto/runner/${field}"
        vault_key="value"
        ;;
      *)
        _err "Unknown category: $category"
        continue
        ;;
    esac

    # Determine status for this key
    local status="created"
    if _kv_path_exists "$vault_path"; then
      local existing_value
      if existing_value="$(_kv_get_value "$vault_path" "$vault_key")" 2>/dev/null; then
        if [ "$existing_value" = "$source_value" ]; then
          status="unchanged"
        else
          status="updated"
        fi
      fi
    fi

    # vault_path and vault_key are identifier-safe (no ':' in either), so
    # the composite key round-trips cleanly via ${ck%:*} / ${ck#*:}.
    local ck="${vault_path}:${vault_key}"
    ops_value["$ck"]="$source_value"
    ops_status["$ck"]="$status"
    path_seen["$vault_path"]=1
  done

  # Second pass: group by vault_path and write.
  # IMPORTANT: Always write ALL keys for a path, not just changed ones.
  # KV v2 POST replaces the entire document, so we must include unchanged keys
  # to avoid dropping them. The idempotency guarantee comes from KV v2 versioning.
  for vault_path in "${!path_seen[@]}"; do
    # Collect this path's "vault_key=source_value" pairs into a bash
    # indexed array. Each element is one kv pair; '=' inside the value is
    # preserved because _kv_put_secret splits on the *first* '=' only.
    local pairs_array=()
    local path_has_changes=0

    for ck in "${!ops_value[@]}"; do
      [ "${ck%:*}" = "$vault_path" ] || continue
      local vault_key="${ck#*:}"
      pairs_array+=("${vault_key}=${ops_value[$ck]}")
      if [ "${ops_status[$ck]}" != "unchanged" ]; then
        path_has_changes=1
      fi
    done

    # Determine effective status for this path (updated if any key changed)
    local effective_status="unchanged"
    if [ "$path_has_changes" = 1 ]; then
      effective_status="updated"
    fi

    if ! _kv_put_secret "$vault_path" "${pairs_array[@]}"; then
      _err "Failed to write to $vault_path"
      exit 1
    fi

    # Output status for each key in this path
    for kv in "${pairs_array[@]}"; do
      local kv_key="${kv%%=*}"
      _format_status "$effective_status" "$vault_path" "$kv_key"
      printf '\n'
    done

    # Count only if path has changes
    if [ "$effective_status" = "updated" ]; then
      ((updated++)) || true
    fi
  done

  _log ""
  _log "=== Import complete ==="
  _log "Created: $created"
  _log "Updated: $updated"
  _log "Unchanged: $unchanged"
}

main "$@"
