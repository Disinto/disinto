#!/usr/bin/env bash
# =============================================================================
# lib/init/nomad/vault-nomad-auth.sh — Idempotent Vault JWT auth + Nomad wiring
#
# Part of the Nomad+Vault migration (S2.3, issue #881). Enables Vault's JWT
# auth method at path `jwt-nomad`, points it at Nomad's workload-identity
# JWKS endpoint, writes one role per policy (via tools/vault-apply-roles.sh),
# updates /etc/nomad.d/server.hcl with the vault stanza, and signals nomad
# to reload so jobs can exchange short-lived workload-identity tokens for
# Vault tokens — no shared VAULT_TOKEN in job env.
#
# Steps:
#   1. Enable auth method           (sys/auth/jwt-nomad, type=jwt)
#   2. Configure JWKS + algs        (auth/jwt-nomad/config)
#   3. Upsert roles from vault/roles.yaml (delegates to vault-apply-roles.sh)
#   4. Install /etc/nomad.d/server.hcl from repo + SIGHUP nomad if changed
#
# Idempotency contract:
#   - Auth path already enabled → skip create, log "jwt-nomad already enabled".
#   - Config identical to desired → skip write, log "jwt-nomad config unchanged".
#   - Roles: see tools/vault-apply-roles.sh header for per-role diffing.
#   - server.hcl on disk byte-identical to repo copy → skip write, skip SIGHUP.
#   - Second run on a fully-configured box is a silent no-op end-to-end.
#
# Preconditions:
#   - S0 complete (empty cluster up: nomad + vault reachable, vault unsealed).
#   - S2.1 complete: vault/policies/*.hcl applied via tools/vault-apply-policies.sh
#     (otherwise the roles we write will reference policies Vault does not
#     know about — the write succeeds, but token minting will fail later).
#   - Running as root (writes /etc/nomad.d/server.hcl + signals nomad).
#
# Environment:
#   VAULT_ADDR  — default http://127.0.0.1:8200 (matches nomad/vault.hcl).
#   VAULT_TOKEN — env OR /etc/vault.d/root.token (resolved by lib/hvault.sh).
#
# Usage:
#   sudo lib/init/nomad/vault-nomad-auth.sh
#
# Exit codes:
#   0  success (configured, or already so)
#   1  precondition / API / nomad-reload failure
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"

APPLY_ROLES_SH="${REPO_ROOT}/tools/vault-apply-roles.sh"
SERVER_HCL_SRC="${REPO_ROOT}/nomad/server.hcl"
SERVER_HCL_DST="/etc/nomad.d/server.hcl"

VAULT_ADDR="${VAULT_ADDR:-http://127.0.0.1:8200}"
export VAULT_ADDR

# shellcheck source=../../hvault.sh
source "${REPO_ROOT}/lib/hvault.sh"

log() { printf '[vault-auth] %s\n' "$*"; }
die() { printf '[vault-auth] ERROR: %s\n' "$*" >&2; exit 1; }

# ── Preconditions ────────────────────────────────────────────────────────────
if [ "$(id -u)" -ne 0 ]; then
  die "must run as root (writes ${SERVER_HCL_DST} + signals nomad)"
fi

# curl + jq are used directly; hvault.sh's helpers are also curl-based, so
# the `vault` CLI is NOT required here — don't add it to this list, or a
# Vault-server-present / vault-CLI-absent box (e.g. a Nomad-client-only
# node) would die spuriously. systemctl is required for SIGHUPing nomad.
for bin in curl jq systemctl; do
  command -v "$bin" >/dev/null 2>&1 \
    || die "required binary not found: ${bin}"
done

[ -f "$SERVER_HCL_SRC" ] \
  || die "source config not found: ${SERVER_HCL_SRC}"
[ -x "$APPLY_ROLES_SH" ] \
  || die "companion script missing or not executable: ${APPLY_ROLES_SH}"

hvault_token_lookup >/dev/null \
  || die "Vault auth probe failed — check VAULT_ADDR + VAULT_TOKEN"

# ── Desired config (Nomad workload-identity JWKS on localhost:4646) ──────────
# Nomad's default workload-identity signer publishes the public JWKS at
# /.well-known/jwks.json on the nomad HTTP API port (4646). Vault validates
# JWTs against it. RS256 is the signer's default algorithm. `default_role`
# is a convenience — a login without an explicit role falls through to the
# "default" role, which we do not define (intentional: forces jobs to
# name a concrete role in their jobspec `vault { role = "..." }`).
JWKS_URL="http://127.0.0.1:4646/.well-known/jwks.json"

# ── Step 1/4: enable auth method jwt-nomad ───────────────────────────────────
log "── Step 1/4: enable auth method path=jwt-nomad type=jwt ──"
# sys/auth returns an object keyed by "<path>/" for every enabled method.
# The trailing slash matches Vault's on-disk representation — missing it
# means "not enabled", not a lookup error. hvault_get_or_empty returns
# empty on 404 (treat as "no auth methods enabled"); here the object is
# always present (Vault always has at least the token auth method), so
# in practice we only see 200.
auth_list="$(hvault_get_or_empty "sys/auth")" \
  || die "failed to list auth methods"
if printf '%s' "$auth_list" | jq -e '.["jwt-nomad/"]' >/dev/null 2>&1; then
  log "auth path jwt-nomad already enabled"
else
  enable_payload="$(jq -n '{type:"jwt",description:"Nomad workload identity (S2.3)"}')"
  _hvault_request POST "sys/auth/jwt-nomad" "$enable_payload" >/dev/null \
    || die "failed to enable auth method jwt-nomad"
  log "auth path jwt-nomad enabled"
fi

# ── Step 2/4: configure auth/jwt-nomad/config ────────────────────────────────
log "── Step 2/4: configure auth/jwt-nomad/config ──"
desired_cfg="$(jq -n --arg jwks "$JWKS_URL" '{
  jwks_url: $jwks,
  jwt_supported_algs: ["RS256"],
  default_role: "default"
}')"

current_cfg_raw="$(hvault_get_or_empty "auth/jwt-nomad/config")" \
  || die "failed to read current jwt-nomad config"
if [ -n "$current_cfg_raw" ]; then
  cur_jwks="$(printf '%s' "$current_cfg_raw" | jq -r '.data.jwks_url // ""')"
  cur_algs="$(printf '%s' "$current_cfg_raw" | jq -cS '.data.jwt_supported_algs // []')"
  cur_default="$(printf '%s' "$current_cfg_raw" | jq -r '.data.default_role // ""')"
else
  cur_jwks=""; cur_algs="[]"; cur_default=""
fi

if [ "$cur_jwks" = "$JWKS_URL" ] \
   && [ "$cur_algs" = '["RS256"]' ] \
   && [ "$cur_default" = "default" ]; then
  log "jwt-nomad config unchanged"
else
  _hvault_request POST "auth/jwt-nomad/config" "$desired_cfg" >/dev/null \
    || die "failed to write jwt-nomad config"
  log "jwt-nomad config written"
fi

# ── Step 3/4: apply roles from vault/roles.yaml ──────────────────────────────
log "── Step 3/4: apply roles from vault/roles.yaml ──"
# Delegates to tools/vault-apply-roles.sh — one source of truth for the
# parser and per-role idempotency contract. Its header documents the
# created/updated/unchanged wiring.
"$APPLY_ROLES_SH"

# ── Step 4/4: install server.hcl + SIGHUP nomad if changed ───────────────────
log "── Step 4/4: install ${SERVER_HCL_DST} + reload nomad if changed ──"
# cluster-up.sh (S0.4) is the normal path for installing server.hcl — but
# this script is run AFTER S0.4, so we also install here. Writing only on
# content-diff keeps re-runs a true no-op (no spurious SIGHUP). `install`
# preserves perms at 0644 root:root on every write.
needs_reload=0
if [ -f "$SERVER_HCL_DST" ] && cmp -s "$SERVER_HCL_SRC" "$SERVER_HCL_DST"; then
  log "unchanged: ${SERVER_HCL_DST}"
else
  log "writing: ${SERVER_HCL_DST}"
  install -m 0644 -o root -g root "$SERVER_HCL_SRC" "$SERVER_HCL_DST"
  needs_reload=1
fi

if [ "$needs_reload" -eq 1 ]; then
  # SIGHUP triggers Nomad's config reload (see ExecReload in
  # lib/init/nomad/systemd-nomad.sh — /bin/kill -HUP $MAINPID). Using
  # `systemctl kill -s SIGHUP` instead of `systemctl reload` sends the
  # signal even when the unit doesn't declare ExecReload (defensive —
  # future unit edits can't silently break this script).
  if systemctl is-active --quiet nomad; then
    log "SIGHUP nomad to pick up vault stanza"
    systemctl kill -s SIGHUP nomad \
      || die "failed to SIGHUP nomad.service"
  else
    # Fresh box: nomad not started yet. The updated server.hcl will be
    # picked up at first start. Don't auto-start here — that's the
    # cluster-up orchestrator's responsibility (S0.4).
    log "nomad.service not active — skipping SIGHUP (next start loads vault stanza)"
  fi
else
  log "server.hcl unchanged — nomad SIGHUP not needed"
fi

log "── done — jwt-nomad auth + config + roles + nomad vault stanza in place ──"
