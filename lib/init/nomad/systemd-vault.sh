#!/usr/bin/env bash
# =============================================================================
# lib/init/nomad/systemd-vault.sh — Idempotent systemd unit installer for Vault
#
# Part of the Nomad+Vault migration (S0.3, issue #823). Lands three things:
#   1. /etc/vault.d/               (0755 root:root)
#   2. /etc/vault.d/vault.hcl      (copy of nomad/vault.hcl, 0644 root:root)
#   3. /var/lib/vault/data/        (0700 root:root, Vault file-storage backend)
#   4. /etc/systemd/system/vault.service  (0644 root:root)
#
# Then `systemctl enable vault` WITHOUT starting the service. Bootstrap
# order is:
#   lib/init/nomad/install.sh         (nomad + vault binaries)
#   lib/init/nomad/systemd-vault.sh   (this script — unit + config + dirs)
#   lib/init/nomad/vault-init.sh      (init + write unseal.key + unseal once)
#   systemctl start vault             (ExecStartPost auto-unseals from file)
#
# The systemd unit's ExecStartPost reads /etc/vault.d/unseal.key and calls
# `vault operator unseal`. That file is written by vault-init.sh on first
# run; until it exists, `systemctl start vault` will leave Vault sealed
# (ExecStartPost fails, unit goes into failed state — intentional, visible).
#
# Seal model:
#   The single unseal key lives at /etc/vault.d/unseal.key (0400 root).
#   Seal-key theft == vault theft. Factory-dev-box-acceptable tradeoff —
#   we avoid running a second Vault to auto-unseal the first.
#
# Idempotency contract:
#   - Unit file NOT rewritten when on-disk content already matches desired.
#   - vault.hcl NOT rewritten when on-disk content matches the repo copy.
#   - `systemctl enable` on an already-enabled unit is a no-op.
#   - Safe to run unconditionally before every factory boot.
#
# Preconditions:
#   - vault binary installed (lib/init/nomad/install.sh)
#   - nomad/vault.hcl present in the repo (relative to this script)
#
# Usage:
#   sudo lib/init/nomad/systemd-vault.sh
#
# Exit codes:
#   0  success (unit+config installed + enabled, or already so)
#   1  precondition failure (not root, no systemctl, no vault binary,
#      missing source config)
# =============================================================================
set -euo pipefail

UNIT_PATH="/etc/systemd/system/vault.service"
VAULT_CONFIG_DIR="/etc/vault.d"
VAULT_CONFIG_FILE="${VAULT_CONFIG_DIR}/vault.hcl"
VAULT_DATA_DIR="/var/lib/vault/data"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"
VAULT_HCL_SRC="${REPO_ROOT}/nomad/vault.hcl"

log() { printf '[systemd-vault] %s\n' "$*"; }
die() { printf '[systemd-vault] ERROR: %s\n' "$*" >&2; exit 1; }

# shellcheck source=lib-systemd.sh
. "${SCRIPT_DIR}/lib-systemd.sh"

# ── Preconditions ────────────────────────────────────────────────────────────
systemd_require_preconditions "$UNIT_PATH"

VAULT_BIN="$(command -v vault 2>/dev/null || true)"
[ -n "$VAULT_BIN" ] \
  || die "vault binary not found — run lib/init/nomad/install.sh first"

[ -f "$VAULT_HCL_SRC" ] \
  || die "source config not found: ${VAULT_HCL_SRC}"

# ── Desired unit content ─────────────────────────────────────────────────────
# Adapted from HashiCorp's recommended vault.service template
# (https://developer.hashicorp.com/vault/tutorials/getting-started-deploy/deploy)
# for a single-node factory dev box:
#   - User=root keeps the seal-key read path simple (unseal.key is 0400 root).
#   - CAP_IPC_LOCK lets mlock() succeed so disable_mlock=false is honoured.
#     Harmless when running as root; required if this is ever flipped to a
#     dedicated `vault` user.
#   - ExecStartPost auto-unseals on every boot using the persisted key.
#     This is the dev-persisted-seal tradeoff — seal-key theft == vault
#     theft, but no second Vault to babysit.
#   - ConditionFileNotEmpty guards against starting without config — makes
#     a missing vault.hcl visible in systemctl status, not a crash loop.
#   - Type=notify so systemd waits for Vault's listener-ready notification
#     before running ExecStartPost (ExecStartPost also has `sleep 2` as a
#     belt-and-braces guard against Type=notify edge cases).
#   - \$MAINPID is escaped so bash doesn't expand it inside this heredoc.
#   - \$(cat ...) is escaped so the subshell runs at unit-execution time
#     (inside bash -c), not at heredoc-expansion time here.
read -r -d '' DESIRED_UNIT <<EOF || true
[Unit]
Description=HashiCorp Vault
Documentation=https://developer.hashicorp.com/vault/docs
Requires=network-online.target
After=network-online.target
ConditionFileNotEmpty=${VAULT_CONFIG_FILE}
StartLimitIntervalSec=60
StartLimitBurst=3

[Service]
Type=notify
User=root
Group=root
Environment=VAULT_ADDR=http://127.0.0.1:8200
SecureBits=keep-caps
CapabilityBoundingSet=CAP_IPC_LOCK
AmbientCapabilities=CAP_IPC_LOCK
ExecStart=${VAULT_BIN} server -config=${VAULT_CONFIG_FILE}
ExecStartPost=/bin/bash -c 'sleep 2 && ${VAULT_BIN} operator unseal \$(cat ${VAULT_CONFIG_DIR}/unseal.key)'
ExecReload=/bin/kill --signal HUP \$MAINPID
KillMode=process
KillSignal=SIGINT
Restart=on-failure
RestartSec=5
TimeoutStopSec=30
LimitNOFILE=65536
LimitMEMLOCK=infinity

[Install]
WantedBy=multi-user.target
EOF

# ── Ensure config + data dirs exist ──────────────────────────────────────────
# /etc/vault.d is 0755 — vault.hcl is world-readable (no secrets in it);
# the real secrets (unseal.key, root.token) get their own 0400 mode.
# /var/lib/vault/data is 0700 — vault's on-disk state (encrypted-at-rest
# by Vault itself, but an extra layer of "don't rely on that").
if [ ! -d "$VAULT_CONFIG_DIR" ]; then
  log "creating ${VAULT_CONFIG_DIR}"
  install -d -m 0755 -o root -g root "$VAULT_CONFIG_DIR"
fi
if [ ! -d "$VAULT_DATA_DIR" ]; then
  log "creating ${VAULT_DATA_DIR}"
  install -d -m 0700 -o root -g root "$VAULT_DATA_DIR"
fi

# ── Install vault.hcl only if content differs ────────────────────────────────
if [ ! -f "$VAULT_CONFIG_FILE" ] \
   || ! cmp -s "$VAULT_HCL_SRC" "$VAULT_CONFIG_FILE"; then
  log "writing config → ${VAULT_CONFIG_FILE}"
  install -m 0644 -o root -g root "$VAULT_HCL_SRC" "$VAULT_CONFIG_FILE"
else
  log "config already up to date"
fi

# ── Install + reload + enable (shared with systemd-nomad.sh via lib-systemd) ─
systemd_install_unit "$UNIT_PATH" "vault.service" "$DESIRED_UNIT"

log "done — unit+config installed and enabled (NOT started; vault-init.sh next)"
