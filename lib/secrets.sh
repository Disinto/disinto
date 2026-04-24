#!/usr/bin/env bash
# =============================================================================
# secrets.sh — Secret resolution for disinto agents.
#
# Public surface:
#   load_dotenv [FILE]       — load a plaintext .env into the environment;
#                              defaults to $FACTORY_ROOT/.env. Preserves
#                              FORGE_URL across the re-source.
#   load_dotenv_enc [FILE]   — SOPS-decrypt FILE, validate as dotenv (eval-
#                              injection-safe), load into environment;
#                              defaults to $FACTORY_ROOT/.env.enc. No-op if
#                              FILE absent or sops not on PATH. Exits 1 on
#                              decrypt or format-validation failure.
#   load_secret NAME [DEFAULT]
#                            — resolve a secret value by precedence:
#                                (1) /secrets/<NAME>.env     (Nomad template)
#                                (2) current environment
#                                (3) secrets/<NAME>.enc      (age-encrypted)
#                                (4) DEFAULT (or empty)
#                              Prints the resolved value to stdout; caches
#                              age-decrypted values in the process env.
#
# Sourcing this file does NOT auto-run anything; callers invoke explicitly.
# =============================================================================

# Resolve factory root if the caller has not set it. Callers that source
# lib/env.sh get FACTORY_ROOT from there; direct callers get the same answer
# by resolving relative to this file's location.
: "${FACTORY_ROOT:=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"

# =============================================================================
# load_dotenv [FILE]
# -----------------------------------------------------------------------------
# Load a plaintext .env file into the environment (`set -a` so assignments are
# exported). Preserves any pre-existing FORGE_URL (compose/container may have
# injected a different value than what .env ships — see #364).
# No-op if FILE is absent.
# =============================================================================
load_dotenv() {
  local env_file="${1:-$FACTORY_ROOT/.env}"
  [ -f "$env_file" ] || return 0

  local _saved_forge_url="${FORGE_URL:-}"
  set -a
  # shellcheck source=/dev/null
  source "$env_file"
  set +a
  [ -n "$_saved_forge_url" ] && export FORGE_URL="$_saved_forge_url"
  return 0
}

# =============================================================================
# load_dotenv_enc [FILE]
# -----------------------------------------------------------------------------
# SOPS-decrypt FILE, validate the decrypted output as dotenv format (to prevent
# eval-injection via crafted .env.enc contents), then source it with `set -a`.
# Defaults FILE to $FACTORY_ROOT/.env.enc. No-op if FILE is absent or `sops` is
# not on PATH. Exits 1 on decryption or validation failure — matching the prior
# eager-load behavior in lib/env.sh.
# =============================================================================
load_dotenv_enc() {
  local env_file="${1:-$FACTORY_ROOT/.env.enc}"
  [ -f "$env_file" ] || return 0
  command -v sops &>/dev/null || return 0

  local _saved_forge_url="${FORGE_URL:-}"
  local _tmpenv _validated _validated_env

  set -a
  # Use temp file + validate dotenv format before sourcing (avoids eval injection)
  # SOPS -d automatically verifies MAC/GCM authentication tag during decryption
  _tmpenv=$(mktemp) || { echo "Error: failed to create temp file for $env_file" >&2; exit 1; }
  if ! sops -d --output-type dotenv "$env_file" > "$_tmpenv" 2>/dev/null; then
    echo "Error: failed to decrypt $env_file — decryption failed, possible corruption" >&2
    rm -f "$_tmpenv"
    exit 1
  fi
  # Validate: non-empty, non-comment lines must match KEY=value pattern
  # Filter out blank lines and comments before validation
  _validated=$(grep -E '^[A-Za-z_][A-Za-z0-9_]*=' "$_tmpenv" 2>/dev/null || true)
  if [ -n "$_validated" ]; then
    _validated_env=$(mktemp)
    printf '%s\n' "$_validated" > "$_validated_env"
    # shellcheck source=/dev/null
    source "$_validated_env"
    rm -f "$_validated_env"
  else
    echo "Error: $env_file decryption output failed format validation" >&2
    rm -f "$_tmpenv"
    exit 1
  fi
  rm -f "$_tmpenv"
  set +a
  [ -n "$_saved_forge_url" ] && export FORGE_URL="$_saved_forge_url"
  return 0
}

# =============================================================================
# load_secret NAME [DEFAULT]
# -----------------------------------------------------------------------------
# Resolves a secret value using the following precedence:
#   1. /secrets/<NAME>.env  — Nomad-rendered template
#   2. Current environment  — already set by .env.enc, compose, etc.
#   3. secrets/<NAME>.enc   — age-encrypted per-key file (decrypted on demand)
#   4. DEFAULT (or empty)
#
# Prints the resolved value to stdout. Caches age-decrypted values in the
# process environment so subsequent calls are free.
# =============================================================================
load_secret() {
  local name="$1"
  local default="${2:-}"

  # 1. Nomad-rendered template (Nomad writes /secrets/<NAME>.env)
  local nomad_path="/secrets/${name}.env"
  if [ -f "$nomad_path" ]; then
    # Source into a subshell to extract just the value
    local _nomad_val
    _nomad_val=$(
      set -a
      # shellcheck source=/dev/null
      source "$nomad_path"
      set +a
      printf '%s' "${!name:-}"
    )
    if [ -n "$_nomad_val" ]; then
      export "$name=$_nomad_val"
      printf '%s' "$_nomad_val"
      return 0
    fi
  fi

  # 2. Already in environment (set by .env.enc, compose injection, etc.)
  if [ -n "${!name:-}" ]; then
    printf '%s' "${!name}"
    return 0
  fi

  # 3. Age-encrypted per-key file: secrets/<NAME>.enc (#777)
  local _age_key="${HOME}/.config/sops/age/keys.txt"
  local _enc_path="${FACTORY_ROOT}/secrets/${name}.enc"
  if [ -f "$_enc_path" ] && [ -f "$_age_key" ] && command -v age &>/dev/null; then
    local _dec_val
    if _dec_val=$(age -d -i "$_age_key" "$_enc_path" 2>/dev/null) && [ -n "$_dec_val" ]; then
      export "$name=$_dec_val"
      printf '%s' "$_dec_val"
      return 0
    fi
  fi

  # 4. Default (or empty)
  if [ -n "$default" ]; then
    printf '%s' "$default"
  fi
  return 0
}
