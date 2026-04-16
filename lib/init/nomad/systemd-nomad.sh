#!/usr/bin/env bash
# =============================================================================
# lib/init/nomad/systemd-nomad.sh — Idempotent systemd unit installer for Nomad
#
# Part of the Nomad+Vault migration (S0.2, issue #822). Writes
# /etc/systemd/system/nomad.service pointing at /etc/nomad.d/ and runs
# `systemctl enable nomad` WITHOUT starting the service — we don't launch
# the cluster until S0.4 wires everything together.
#
# Idempotency contract:
#   - Existing unit file is NOT rewritten when on-disk content already
#     matches the desired content (avoids spurious `daemon-reload`).
#   - `systemctl enable` on an already-enabled unit is a no-op.
#   - This script is safe to run unconditionally before every factory boot.
#
# Preconditions:
#   - nomad binary installed (see lib/init/nomad/install.sh)
#   - /etc/nomad.d/ will hold server.hcl / client.hcl (placed by S0.4)
#
# Usage:
#   sudo lib/init/nomad/systemd-nomad.sh
#
# Exit codes:
#   0  success (unit installed + enabled, or already so)
#   1  precondition failure (not root, no systemctl, no nomad binary)
# =============================================================================
set -euo pipefail

UNIT_PATH="/etc/systemd/system/nomad.service"
NOMAD_CONFIG_DIR="/etc/nomad.d"
NOMAD_DATA_DIR="/var/lib/nomad"

log() { printf '[systemd-nomad] %s\n' "$*"; }
die() { printf '[systemd-nomad] ERROR: %s\n' "$*" >&2; exit 1; }

# ── Preconditions ────────────────────────────────────────────────────────────
if [ "$(id -u)" -ne 0 ]; then
  die "must run as root (needs write access to ${UNIT_PATH})"
fi

command -v systemctl >/dev/null 2>&1 \
  || die "systemctl not found (systemd is required)"

NOMAD_BIN="$(command -v nomad 2>/dev/null || true)"
[ -n "$NOMAD_BIN" ] \
  || die "nomad binary not found — run lib/init/nomad/install.sh first"

# ── Desired unit content ─────────────────────────────────────────────────────
# Upstream-recommended baseline (https://developer.hashicorp.com/nomad/docs/install/production/deployment-guide)
# trimmed for a single-node combined server+client dev box.
#   - Wants=/After= network-online: nomad must have networking up.
#   - User/Group=root: the Docker driver needs root to talk to dockerd.
#   - LimitNOFILE/LimitNPROC=infinity: avoid Nomad's startup warning.
#   - KillSignal=SIGINT: triggers Nomad's graceful shutdown path.
#   - Restart=on-failure with a bounded burst to avoid crash-loops eating the
#     journal when /etc/nomad.d/ is mis-configured.
read -r -d '' DESIRED_UNIT <<EOF || true
[Unit]
Description=Nomad
Documentation=https://developer.hashicorp.com/nomad/docs
Wants=network-online.target
After=network-online.target

# When Docker is present, ensure dockerd is up before nomad starts — the
# Docker task driver needs the daemon socket available at startup.
Wants=docker.service
After=docker.service

[Service]
Type=notify
User=root
Group=root
ExecReload=/bin/kill -HUP \$MAINPID
ExecStart=${NOMAD_BIN} agent -config=${NOMAD_CONFIG_DIR}
KillMode=process
KillSignal=SIGINT
LimitNOFILE=infinity
LimitNPROC=infinity
Restart=on-failure
RestartSec=2
StartLimitBurst=3
StartLimitIntervalSec=10
TasksMax=infinity
OOMScoreAdjust=-1000

[Install]
WantedBy=multi-user.target
EOF

# ── Ensure config + data dirs exist ──────────────────────────────────────────
# We do not populate /etc/nomad.d/ here (that's S0.4). We do create the
# directory so `nomad agent -config=/etc/nomad.d` doesn't error if the unit
# is started before hcl files are dropped in.
for d in "$NOMAD_CONFIG_DIR" "$NOMAD_DATA_DIR"; do
  if [ ! -d "$d" ]; then
    log "creating ${d}"
    install -d -m 0755 "$d"
  fi
done

# ── Install unit file only if content differs ────────────────────────────────
needs_reload=0
if [ ! -f "$UNIT_PATH" ] \
   || ! printf '%s\n' "$DESIRED_UNIT" | cmp -s - "$UNIT_PATH"; then
  log "writing unit → ${UNIT_PATH}"
  tmp="$(mktemp)"
  trap 'rm -f "$tmp"' EXIT
  printf '%s\n' "$DESIRED_UNIT" > "$tmp"
  install -m 0644 -o root -g root "$tmp" "$UNIT_PATH"
  rm -f "$tmp"
  trap - EXIT
  needs_reload=1
else
  log "unit file already up to date"
fi

# ── Reload + enable ──────────────────────────────────────────────────────────
if [ "$needs_reload" -eq 1 ]; then
  log "systemctl daemon-reload"
  systemctl daemon-reload
fi

if systemctl is-enabled --quiet nomad.service 2>/dev/null; then
  log "nomad.service already enabled"
else
  log "systemctl enable nomad"
  systemctl enable nomad.service >/dev/null
fi

log "done — unit installed and enabled (NOT started; S0.4 brings the cluster up)"
