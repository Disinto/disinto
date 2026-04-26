#!/usr/bin/env bash
# =============================================================================
# tools/sync-nomad-client-config.sh — Sync nomad/client.hcl onto a factory box
#
# Copies the in-repo nomad/client.hcl (and nomad/server.hcl, optional via
# --with-server) onto /etc/nomad.d/, then `nomad agent reload` (or restart
# if reload is insufficient — host_volume + plugin block changes require a
# full restart, see contract below).
#
# Why this exists: in-cluster host_volume declarations and plugin enables
# (raw_exec, docker) drift is silent. A jobspec that references
# `volume "snapshot-state"` schedules fine offline-validate but fails at
# placement with "missing host volume" if the live client.hcl was wiped on
# a fresh-box rebuild. Owning client.hcl in the repo + scripting the sync
# makes the bootstrap reproducible from a clean LXC.
#
# Reload vs restart contract (Nomad 1.9):
#   - `nomad agent reload`/SIGHUP picks up:
#       * client.options changes
#       * server quorum / encryption rotation (server-mode only)
#   - Restart is REQUIRED for:
#       * adding/removing host_volume blocks
#       * enabling/disabling plugin blocks (raw_exec, docker, etc.)
#       * any change to the docker plugin config block
#   This script always restarts to keep the contract obvious — host_volume
#   + raw_exec are the deltas it was built for, and they need a restart.
#
# Idempotency contract:
#   - Running twice back-to-back is a no-op once /etc/nomad.d/client.hcl
#     matches the repo file (cmp -s short-circuits).
#   - The `nomad agent-info` post-check verifies the agent came back up
#     and the host_volume set is non-empty — fails fast on a typo'd HCL
#     that left the agent dead.
#
# Usage:
#   sudo tools/sync-nomad-client-config.sh             # client.hcl only
#   sudo tools/sync-nomad-client-config.sh --with-server  # also server.hcl
#   sudo tools/sync-nomad-client-config.sh --dry-run   # diff + skip restart
#
# Exit codes:
#   0  success (synced, or already in sync)
#   1  precondition failure (not root, files missing, nomad not installed)
#   2  post-restart health check failed (agent not up, host_volume empty)
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

NOMAD_CONFIG_DIR="/etc/nomad.d"
NOMAD_CLIENT_HCL_SRC="${REPO_ROOT}/nomad/client.hcl"
NOMAD_SERVER_HCL_SRC="${REPO_ROOT}/nomad/server.hcl"
NOMAD_CLIENT_HCL_DST="${NOMAD_CONFIG_DIR}/client.hcl"
NOMAD_SERVER_HCL_DST="${NOMAD_CONFIG_DIR}/server.hcl"

NOMAD_ADDR_DEFAULT="http://127.0.0.1:4646"
RESTART_POLL_SECS="${RESTART_POLL_SECS:-30}"

log() { printf '[sync-nomad-client] %s\n' "$*"; }
die() { printf '[sync-nomad-client] ERROR: %s\n' "$*" >&2; exit 1; }

# ── Flag parsing ─────────────────────────────────────────────────────────────
dry_run=false
with_server=false
while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run)     dry_run=true; shift ;;
    --with-server) with_server=true; shift ;;
    -h|--help)
      cat <<EOF
Usage: sudo $(basename "$0") [--with-server] [--dry-run]

Copies nomad/client.hcl (+ optionally server.hcl) from the repo onto
/etc/nomad.d/, then restarts nomad to pick up host_volume / plugin
changes. Idempotent.

  --with-server  also sync nomad/server.hcl
  --dry-run      print the diff and exit; do not write or restart
EOF
      exit 0
      ;;
    *) die "unknown flag: $1" ;;
  esac
done

# ── Preconditions ────────────────────────────────────────────────────────────
if [ "$dry_run" = false ] && [ "$(id -u)" -ne 0 ]; then
  die "must run as root (writes /etc/nomad.d/ and restarts nomad.service)"
fi

[ -f "$NOMAD_CLIENT_HCL_SRC" ] \
  || die "source not found: ${NOMAD_CLIENT_HCL_SRC}"
[ "$with_server" = false ] || [ -f "$NOMAD_SERVER_HCL_SRC" ] \
  || die "source not found: ${NOMAD_SERVER_HCL_SRC}"

command -v nomad >/dev/null 2>&1 \
  || die "nomad binary not found — run lib/init/nomad/install.sh first"
command -v systemctl >/dev/null 2>&1 \
  || die "systemctl not found (systemd required)"

# ── Helpers ──────────────────────────────────────────────────────────────────

# diff_or_skip SRC DST — print unified diff if files differ, return 0 if
# changes pending, 1 if already in sync.
diff_or_skip() {
  local src="$1" dst="$2"
  if [ ! -f "$dst" ]; then
    log "new file: ${dst}"
    return 0
  fi
  if cmp -s "$src" "$dst"; then
    log "unchanged: ${dst}"
    return 1
  fi
  log "diff ${dst}:"
  diff -u "$dst" "$src" || true
  return 0
}

# install_file_if_differs SRC DST — copy iff content differs, root:root 0644.
install_file_if_differs() {
  local src="$1" dst="$2"
  if [ -f "$dst" ] && cmp -s "$src" "$dst"; then
    return 0
  fi
  log "writing: ${dst}"
  install -m 0644 -o root -g root "$src" "$dst"
}

# nomad_agent_up — true iff `nomad agent-info` succeeds and the client
# stanza reports ≥1 host_volume. Catches the "HCL parse error left agent
# dead" case where systemctl reports active but the agent never finished
# bootstrap. Uses `nomad node status -self -verbose` since agent-info
# does not list host_volumes.
nomad_agent_up() {
  local out
  out="$(NOMAD_ADDR="$NOMAD_ADDR_DEFAULT" nomad node status -self -verbose 2>/dev/null || true)"
  [ -n "$out" ] || return 1
  printf '%s\n' "$out" | grep -q '^Host Volumes' \
    || return 1
  return 0
}

# ── Stage the diff ───────────────────────────────────────────────────────────
client_changed=false
server_changed=false

if diff_or_skip "$NOMAD_CLIENT_HCL_SRC" "$NOMAD_CLIENT_HCL_DST"; then
  client_changed=true
fi
if [ "$with_server" = true ]; then
  if diff_or_skip "$NOMAD_SERVER_HCL_SRC" "$NOMAD_SERVER_HCL_DST"; then
    server_changed=true
  fi
fi

if [ "$dry_run" = true ]; then
  log "dry-run: no files written, nomad not restarted"
  exit 0
fi

if [ "$client_changed" = false ] && [ "$server_changed" = false ]; then
  log "nothing to do"
  exit 0
fi

# ── Apply ────────────────────────────────────────────────────────────────────
install -d -m 0755 -o root -g root "$NOMAD_CONFIG_DIR"
install_file_if_differs "$NOMAD_CLIENT_HCL_SRC" "$NOMAD_CLIENT_HCL_DST"
if [ "$with_server" = true ]; then
  install_file_if_differs "$NOMAD_SERVER_HCL_SRC" "$NOMAD_SERVER_HCL_DST"
fi

# Validate before restart — a bad HCL that survives apply leaves the
# agent unable to come back up. `nomad config validate` parses against
# the live binary's grammar; it does not need a running agent.
log "validating ${NOMAD_CLIENT_HCL_DST}"
if [ "$with_server" = true ]; then
  nomad config validate "$NOMAD_SERVER_HCL_DST" "$NOMAD_CLIENT_HCL_DST" \
    || die "nomad config validate rejected the new HCL — aborting before restart"
else
  # Pass server.hcl too so validate sees the full agent role; otherwise
  # client.hcl alone yields "no server stanza" which is a false positive.
  nomad config validate "$NOMAD_SERVER_HCL_DST" "$NOMAD_CLIENT_HCL_DST" \
    || die "nomad config validate rejected the new HCL — aborting before restart"
fi

# Host_volume + plugin changes require restart, not reload. See the
# contract in the file header.
log "restarting nomad.service"
systemctl restart nomad

# Poll until agent is back up and host_volume set is non-empty.
log "polling nomad agent (≤${RESTART_POLL_SECS}s)"
waited=0
while [ "$waited" -lt "$RESTART_POLL_SECS" ]; do
  if systemctl is-failed --quiet nomad; then
    systemctl --no-pager --full status nomad >&2 || true
    die "nomad.service entered failed state after restart"
  fi
  if nomad_agent_up; then
    log "nomad healthy after ${waited}s"
    log "── done ──"
    exit 0
  fi
  waited=$((waited + 1))
  sleep 1
done

systemctl --no-pager --full status nomad >&2 || true
exit 2
