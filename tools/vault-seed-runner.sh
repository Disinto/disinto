#!/usr/bin/env bash
# =============================================================================
# tools/vault-seed-runner.sh — Seed runner secrets from .env into Vault KV
#
# Part of issue #604. Reads runner tokens from .env and writes them to
# kv/disinto/runner/<NAME>/value paths so that nomad/jobs/vault-runner.hcl
# can render them via template stanzas.
#
# Also seeds kv/disinto/shared/ops-repo with remote URL and deploy key
# (may resolve the dispatcher-blocked bug mentioned in #601).
#
# Runner tokens (written to kv/disinto/runner/<NAME>/value):
#   GITHUB_TOKEN, CODEBERG_TOKEN, CLAWHUB_TOKEN, NPM_TOKEN, DOCKER_HUB_TOKEN,
#   DEPLOY_KEY
#
# Ops-repo (written to kv/disinto/shared/ops-repo):
#   remote   — "${FORGE_URL}/${FORGE_OPS_REPO}.git" (if both vars set)
#   deploy_key — contents of file at DEPLOY_KEY_PATH (if set)
#
# Idempotency contract:
#   - Overwrites existing values (no version explosion).
#   - Skips keys absent from .env (warns, does not fail).
#
# Usage:
#   tools/vault-seed-runner.sh
#   tools/vault-seed-runner.sh --dry-run
#
# Requires:
#   - VAULT_ADDR  (e.g. http://127.0.0.1:8200)
#   - VAULT_TOKEN (env OR /etc/vault.d/root.token)
#   - curl, jq, openssl
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# shellcheck source=../lib/hvault.sh
source "${REPO_ROOT}/lib/hvault.sh"

# KV paths
RUNNER_PATH_PREFIX="disinto/runner"
OPS_REPO_PATH="disinto/shared/ops-repo"

# Runner tokens that vault-runner.hcl expects
declare -a RUNNER_TOKENS=(GITHUB_TOKEN CODEBERG_TOKEN CLAWHUB_TOKEN NPM_TOKEN DOCKER_HUB_TOKEN DEPLOY_KEY)

log() { printf '[vault-seed-runner] %s\n' "$*"; }
die() { printf '[vault-seed-runner] ERROR: %s\n' "$*" >&2; exit 1; }

# Strip surrounding single/double quotes from a value (e.g. "abc123" -> abc123)
_strip_quote() {
  local v="$1"
  case "$v" in
    \'*\'|\"*\") v="${v:1:${#v}-2}" ;;
  esac
  printf '%s' "$v"
}

# ── Flag parsing ─────────────────────────────────────────────────────────────
DRY_RUN=0
case "$#:${1-}" in
  0:)
    ;;
  1:--dry-run)
    DRY_RUN=1
    ;;
  1:-h|1:--help)
    printf 'Usage: %s [--dry-run]\n\n' "$(basename "$0")"
    printf 'Seed runner secrets from .env into Vault KV.\n\n'
    printf 'Writes kv/disinto/runner/<NAME>/value for each token\n'
    printf 'present in .env. Also seeds ops-repo remote + deploy_key.\n\n'
    printf '  --dry-run   Print planned actions without writing.\n'
    exit 0
    ;;
  *)
    die "invalid arguments: $*  (try --help)"
    ;;
esac

# ── Preconditions ────────────────────────────────────────────────────────────
for bin in curl jq openssl; do
  command -v "$bin" >/dev/null 2>&1 \
    || die "required binary not found: ${bin}"
done

_hvault_default_env

[ -n "${VAULT_ADDR:-}" ] \
  || die "VAULT_ADDR unset — e.g. export VAULT_ADDR=http://127.0.0.1:8200"
hvault_token_lookup >/dev/null \
  || die "Vault auth probe failed — check VAULT_ADDR + VAULT_TOKEN"

# ── Step 1/3: ensure kv/ mount exists and is KV v2 ──────────────────────────
export DRY_RUN
hvault_ensure_kv_v2 "kv" "[vault-seed-runner]" \
  || die "KV mount check failed"

# ── Step 2/3: seed runner tokens ─────────────────────────────────────────────
log "── Step 2/3: seed runner tokens ──"

env_file="${REPO_ROOT}/.env"
seeds_written=0
seeds_skipped=0

if [ ! -f "$env_file" ]; then
  log "warning: ${env_file} not found — skipping runner token seed"
  seeds_skipped=${#RUNNER_TOKENS[@]}
else
  # Parse .env into an associative array (safe: only reads KEY=value lines)
  declare -A env_vals
  while IFS='=' read -r key val; do
    # Skip comments and blank lines
    [[ "$key" =~ ^[[:space:]]*# ]] && continue
    [[ -z "$key" ]] && continue
    # Trim leading/trailing whitespace from key
    key="$(printf '%s' "$key" | xargs)"
    # Strip surrounding quotes from value
    val="$(_strip_quote "$val")"
    env_vals["$key"]="$val"
  done < <(grep -E '^[A-Za-z_][A-Za-z0-9_]*=' "$env_file" 2>/dev/null || true)

  for token_name in "${RUNNER_TOKENS[@]}"; do
    val="${env_vals[$token_name]:-}"
    if [ -z "$val" ]; then
      log "skip ${token_name} (not in .env)"
      ((seeds_skipped++)) || true
      continue
    fi

    kv_path="${RUNNER_PATH_PREFIX}/${token_name}"
    if [ "$DRY_RUN" -eq 1 ]; then
      log "[dry-run] ${kv_path}: would write value"
      ((seeds_written++)) || true
      continue
    fi

    # Write to KV v2 — idempotent (POST replaces the document)
    payload="$(jq -n --arg v "$val" '{data: {value: $v}}')"
    if ! _hvault_request POST "kv/data/${kv_path}" "$payload" >/dev/null; then
      log "error: failed to write ${kv_path}"
      continue
    fi
    log "${kv_path}: written"
    ((seeds_written++)) || true
  done
fi

# ── Step 3/3: seed ops-repo ──────────────────────────────────────────────────
log "── Step 3/3: seed ops-repo ──"

ops_remote=""
ops_deploy_key=""

if [ -f "$env_file" ]; then
  # Re-parse env_vals (already populated above, but guard for dry-run path)
  declare -A env_vals
  while IFS='=' read -r key val; do
    [[ "$key" =~ ^[[:space:]]*# ]] && continue
    [[ -z "$key" ]] && continue
    key="$(printf '%s' "$key" | xargs)"
    val="$(_strip_quote "$val")"
    env_vals["$key"]="$val"
  done < <(grep -E '^[A-Za-z_][A-Za-z0-9_]*=' "$env_file" 2>/dev/null || true)

  forge_url="${env_vals[FORGE_URL]:-}"
  ops_repo="${env_vals[FORGE_OPS_REPO]:-}"
  if [ -n "$forge_url" ] && [ -n "$ops_repo" ]; then
    ops_remote="${forge_url}/${ops_repo}.git"
  else
    log "skip ops-repo remote (FORGE_URL or FORGE_OPS_REPO not in .env)"
  fi

  deploy_key_path="${env_vals[DEPLOY_KEY_PATH]:-}"
  if [ -n "$deploy_key_path" ] && [ -f "$deploy_key_path" ]; then
    ops_deploy_key="$(cat "$deploy_key_path")"
  elif [ -n "$deploy_key_path" ]; then
    log "warning: DEPLOY_KEY_PATH set but file not found: ${deploy_key_path}"
  else
    log "skip ops-repo deploy_key (DEPLOY_KEY_PATH not in .env)"
  fi
else
  log "warning: ${env_file} not found — skipping ops-repo seed"
fi

# Only write ops-repo if at least one field is set
if [ -n "$ops_remote" ] || [ -n "$ops_deploy_key" ]; then
  if [ "$DRY_RUN" -eq 1 ]; then
    log "[dry-run] ${OPS_REPO_PATH}: would write remote=${ops_remote:+set}${ops_remote:+,} deploy_key=${ops_deploy_key:+set}"
  else
    # Read existing ops-repo document and merge (POST replaces the full KV v2
    # data document, so we must preserve sibling keys like 'token').
    existing_raw="$(hvault_get_or_empty "kv/data/${OPS_REPO_PATH}")" || true
    existing_data="{}"
    [ -n "$existing_raw" ] && existing_data="$(printf '%s' "$existing_raw" | jq '.data.data // {}')"

    payload="$(printf '%s' "$existing_data" | jq -c '
      if .remote == null and .deploy_key == null then .
      else
        (. + (
          (if .remote != null then {remote: .remote} else {} end) +
          (if .deploy_key != null then {deploy_key: .deploy_key} else {} end)
        ))
      end
    ')"
    # Now overlay the new values
    if [ -n "$ops_remote" ]; then
      payload="$(printf '%s' "$payload" | jq --arg v "$ops_remote" '.remote = $v')"
    fi
    if [ -n "$ops_deploy_key" ]; then
      payload="$(printf '%s' "$payload" | jq --arg v "$ops_deploy_key" '.deploy_key = $v')"
    fi
    payload="$(printf '%s' "$payload" | jq '{data: .}')"

    if ! _hvault_request POST "kv/data/${OPS_REPO_PATH}" "$payload" >/dev/null; then
      log "error: failed to write ${OPS_REPO_PATH}"
    else
      log "${OPS_REPO_PATH}: written (remote=${ops_remote:+set}, deploy_key=${ops_deploy_key:+set})"
    fi
  fi
else
  log "ops-repo: no fields to write (skipped)"
fi

log "done — ${seeds_written} runner tokens written, ${seeds_skipped} skipped"
