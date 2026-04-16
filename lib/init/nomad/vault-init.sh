#!/usr/bin/env bash
# =============================================================================
# lib/init/nomad/vault-init.sh — Idempotent Vault first-run initializer
#
# Part of the Nomad+Vault migration (S0.3, issue #823). Initializes Vault
# in dev-persisted-seal mode (single unseal key on disk) and unseals once.
# On re-run, becomes a no-op — never re-initializes or rotates the key.
#
# What it does (first run):
#   1. Ensures Vault is reachable at ${VAULT_ADDR} — spawns a temporary
#      `vault server -config=/etc/vault.d/vault.hcl` if not already up.
#   2. Runs `vault operator init -key-shares=1 -key-threshold=1` and
#      captures the resulting unseal key + root token.
#   3. Writes /etc/vault.d/unseal.key   (0400 root, no trailing newline).
#   4. Writes /etc/vault.d/root.token   (0400 root, no trailing newline).
#   5. Unseals Vault once in the current process.
#   6. Shuts down the temporary server if we started one (so a subsequent
#      `systemctl start vault` doesn't conflict on port 8200).
#
# Idempotency contract:
#   - /etc/vault.d/unseal.key exists AND `vault status` reports
#     initialized=true → exit 0, no mutation, no re-init.
#   - Initialized-but-unseal.key-missing is a hard failure (can't recover
#     the key without the existing storage; user must restore from backup).
#
# Bootstrap order:
#   lib/init/nomad/install.sh          (installs vault binary)
#   lib/init/nomad/systemd-vault.sh    (lands unit + config + dirs; enables)
#   lib/init/nomad/vault-init.sh       (this script — init + unseal once)
#   systemctl start vault              (ExecStartPost auto-unseals henceforth)
#
# Seal model:
#   Single unseal key persisted on disk at /etc/vault.d/unseal.key. Seal-key
#   theft == vault theft. Factory-dev-box-acceptable tradeoff — we avoid
#   running a second Vault to auto-unseal the first.
#
# Environment:
#   VAULT_ADDR  — Vault API address (default: http://127.0.0.1:8200).
#
# Usage:
#   sudo lib/init/nomad/vault-init.sh
#
# Exit codes:
#   0  success (initialized + unsealed + keys persisted; or already done)
#   1  precondition / operational failure
# =============================================================================
set -euo pipefail

VAULT_CONFIG_FILE="/etc/vault.d/vault.hcl"
UNSEAL_KEY_FILE="/etc/vault.d/unseal.key"
ROOT_TOKEN_FILE="/etc/vault.d/root.token"
VAULT_ADDR="${VAULT_ADDR:-http://127.0.0.1:8200}"
export VAULT_ADDR

# Track whether we spawned a temporary vault (for cleanup).
spawned_pid=""
spawned_log=""

log() { printf '[vault-init] %s\n' "$*"; }
die() { printf '[vault-init] ERROR: %s\n' "$*" >&2; exit 1; }

# ── Cleanup: stop the temporary server (if we started one) on any exit ───────
# EXIT trap fires on success AND failure AND signals — so we never leak a
# background vault process holding port 8200 after this script returns.
cleanup() {
  if [ -n "$spawned_pid" ] && kill -0 "$spawned_pid" 2>/dev/null; then
    log "stopping temporary vault (pid=${spawned_pid})"
    kill "$spawned_pid" 2>/dev/null || true
    wait "$spawned_pid" 2>/dev/null || true
  fi
  if [ -n "$spawned_log" ] && [ -f "$spawned_log" ]; then
    rm -f "$spawned_log"
  fi
}
trap cleanup EXIT

# ── Preconditions ────────────────────────────────────────────────────────────
if [ "$(id -u)" -ne 0 ]; then
  die "must run as root (needs to write 0400 files under /etc/vault.d)"
fi

for bin in vault jq; do
  command -v "$bin" >/dev/null 2>&1 \
    || die "required binary not found: ${bin}"
done

[ -f "$VAULT_CONFIG_FILE" ] \
  || die "config not found: ${VAULT_CONFIG_FILE} — run systemd-vault.sh first"

# ── Helpers ──────────────────────────────────────────────────────────────────

# vault_reachable — true iff `vault status` can reach the server.
#   Exit codes from `vault status`:
#     0 = reachable, initialized, unsealed
#     2 = reachable, sealed (or uninitialized)
#     1 = unreachable / other error
#   We treat 0 and 2 as "reachable". `|| status=$?` avoids set -e tripping
#   on the expected sealed-is-also-fine case.
vault_reachable() {
  local status=0
  vault status -format=json >/dev/null 2>&1 || status=$?
  [ "$status" -eq 0 ] || [ "$status" -eq 2 ]
}

# vault_initialized — echoes "true" / "false" / "" (empty on parse failure
# or unreachable vault). Always returns 0 so that `x="$(vault_initialized)"`
# is safe under `set -euo pipefail`.
#
# Key subtlety: `vault status` exits 2 when Vault is sealed OR uninitialized
# — the exact state we need to *observe* on first run. Without the
# `|| true` guard, pipefail + set -e inside a standalone assignment would
# propagate that exit 2 to the outer script and abort before we ever call
# `vault operator init`. We capture `vault status`'s output to a variable
# first (pipefail-safe), then feed it to jq separately.
vault_initialized() {
  local out=""
  out="$(vault status -format=json 2>/dev/null || true)"
  [ -n "$out" ] || { printf ''; return 0; }
  printf '%s' "$out" | jq -r '.initialized' 2>/dev/null || printf ''
}

# write_secret_file PATH CONTENT
#   Write CONTENT to PATH atomically with 0400 root:root and no trailing
#   newline. mktemp+install keeps perms tight for the whole lifetime of
#   the file on disk — no 0644-then-chmod window.
write_secret_file() {
  local path="$1" content="$2"
  local tmp
  tmp="$(mktemp)"
  printf '%s' "$content" > "$tmp"
  install -m 0400 -o root -g root "$tmp" "$path"
  rm -f "$tmp"
}

# ── Ensure vault is reachable ────────────────────────────────────────────────
if ! vault_reachable; then
  log "vault not reachable at ${VAULT_ADDR} — starting temporary server"
  spawned_log="$(mktemp)"
  vault server -config="$VAULT_CONFIG_FILE" >"$spawned_log" 2>&1 &
  spawned_pid=$!

  # Poll for readiness. Vault's API listener comes up before notify-ready
  # in Type=notify mode, but well inside a few seconds even on cold boots.
  ready=0
  for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15; do
    if vault_reachable; then
      ready=1
      break
    fi
    sleep 1
  done
  if [ "$ready" -ne 1 ]; then
    log "vault did not become reachable within 15s — server log follows:"
    if [ -f "$spawned_log" ]; then
      sed 's/^/[vault-server] /' "$spawned_log" >&2 || true
    fi
    die "failed to start temporary vault server"
  fi
  log "temporary vault ready (pid=${spawned_pid})"
fi

# ── Idempotency gate ─────────────────────────────────────────────────────────
initialized="$(vault_initialized)"

if [ "$initialized" = "true" ] && [ -f "$UNSEAL_KEY_FILE" ]; then
  log "vault already initialized and unseal.key present — no-op"
  exit 0
fi

if [ "$initialized" = "true" ] && [ ! -f "$UNSEAL_KEY_FILE" ]; then
  die "vault is initialized but ${UNSEAL_KEY_FILE} is missing — cannot recover the unseal key; restore from backup or wipe ${VAULT_CONFIG_FILE%/*}/data and re-run"
fi

if [ "$initialized" != "false" ]; then
  die "unexpected initialized state: '${initialized}' (expected 'true' or 'false')"
fi

# ── Initialize ───────────────────────────────────────────────────────────────
log "initializing vault (key-shares=1, key-threshold=1)"
init_json="$(vault operator init \
  -key-shares=1 \
  -key-threshold=1 \
  -format=json)" \
  || die "vault operator init failed"

unseal_key="$(printf '%s' "$init_json" | jq -er '.unseal_keys_b64[0]')" \
  || die "failed to extract unseal key from init response"
root_token="$(printf '%s' "$init_json" | jq -er '.root_token')" \
  || die "failed to extract root token from init response"

# Best-effort scrub of init_json from the env (the captured key+token still
# sit in the local vars above — there's no clean way to wipe bash memory).
unset init_json

# ── Persist keys ─────────────────────────────────────────────────────────────
log "writing ${UNSEAL_KEY_FILE} (0400 root)"
write_secret_file "$UNSEAL_KEY_FILE" "$unseal_key"
log "writing ${ROOT_TOKEN_FILE} (0400 root)"
write_secret_file "$ROOT_TOKEN_FILE" "$root_token"

# ── Unseal in the current process ────────────────────────────────────────────
log "unsealing vault"
vault operator unseal "$unseal_key" >/dev/null \
  || die "vault operator unseal failed"

log "done — vault initialized + unsealed + keys persisted"
