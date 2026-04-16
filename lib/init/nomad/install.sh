#!/usr/bin/env bash
# =============================================================================
# lib/init/nomad/install.sh — Idempotent apt install of HashiCorp Nomad + Vault
#                             + Ubuntu-native Docker for Nomad's docker driver
#
# Part of the Nomad+Vault migration. Installs the `nomad` binary (S0.2,
# issue #822), the `vault` binary (S0.3, issue #823), and the `docker`
# daemon (S0.2-fix, issue #871) needed by Nomad's docker task driver.
# Nomad + Vault come from the pinned HashiCorp apt repo; docker comes from
# Ubuntu's default apt repo (docker.io) — matches the existing factory
# dev-box setup and avoids adding a second apt source with pinning.
#
# Does NOT configure, start, or enable nomad.service or vault.service —
# lib/init/nomad/systemd-nomad.sh and lib/init/nomad/systemd-vault.sh own
# those. The docker.service unit ships with the docker.io package and is
# enabled+started here directly (not a disinto-owned unit), because Nomad's
# docker driver reports Healthy=false without a running dockerd — that
# silently blocks job placement at Step 1 with a confusing "missing
# drivers" error (issue #871). Does NOT wire this script into `disinto
# init` — S0.4 owns that.
#
# Idempotency contract:
#   - Running twice back-to-back is a no-op once all three targets are
#     installed and the HashiCorp apt source is in place.
#   - Adds the HashiCorp apt keyring only if it is absent.
#   - Adds the HashiCorp apt sources list only if it is absent.
#   - Skips `apt-get install` for any package whose installed version already
#     matches the pin. If all three are satisfied, exits before touching apt.
#   - `command -v docker` is the docker install sentinel; `systemctl
#     enable --now` is a no-op on an already-enabled+active unit.
#
# Configuration:
#   NOMAD_VERSION  — pinned Nomad version (default: see below). Apt package
#                    name is versioned as "nomad=<version>-1".
#   VAULT_VERSION  — pinned Vault version (default: see below). Apt package
#                    name is versioned as "vault=<version>-1".
#
# Usage:
#   sudo lib/init/nomad/install.sh
#   sudo NOMAD_VERSION=1.9.5 VAULT_VERSION=1.18.5 lib/init/nomad/install.sh
#
# Exit codes:
#   0  success (installed or already present)
#   1  precondition failure (not Debian/Ubuntu, missing tools, not root)
# =============================================================================
set -euo pipefail

# Pin to specific 1.x releases. Bump here, not at call sites.
NOMAD_VERSION="${NOMAD_VERSION:-1.9.5}"
VAULT_VERSION="${VAULT_VERSION:-1.18.5}"

HASHICORP_KEYRING="/usr/share/keyrings/hashicorp-archive-keyring.gpg"
HASHICORP_SOURCES="/etc/apt/sources.list.d/hashicorp.list"
HASHICORP_GPG_URL="https://apt.releases.hashicorp.com/gpg"
HASHICORP_REPO_URL="https://apt.releases.hashicorp.com"

log() { printf '[install] %s\n' "$*"; }
die() { printf '[install] ERROR: %s\n' "$*" >&2; exit 1; }

# _installed_version BINARY
#   Echoes the installed semver for `nomad` or `vault` (e.g. "1.9.5").
#   Both tools print their version on the first line of `<bin> version` as
#   "<Name> v<semver>..." — the shared awk extracts $2 with the leading "v"
#   stripped. Empty string when the binary is absent or output is unexpected.
_installed_version() {
  local bin="$1"
  command -v "$bin" >/dev/null 2>&1 || { printf ''; return 0; }
  "$bin" version 2>/dev/null \
    | awk 'NR==1 {sub(/^v/, "", $2); print $2; exit}'
}

# ── Preconditions ────────────────────────────────────────────────────────────
if [ "$(id -u)" -ne 0 ]; then
  die "must run as root (needs apt-get + /usr/share/keyrings write access)"
fi

for bin in apt-get gpg curl lsb_release; do
  command -v "$bin" >/dev/null 2>&1 \
    || die "required binary not found: ${bin}"
done

CODENAME="$(lsb_release -cs)"
[ -n "$CODENAME" ] || die "lsb_release returned empty codename"

# ── Fast-path: are both already at desired versions? ─────────────────────────
nomad_installed="$(_installed_version nomad)"
vault_installed="$(_installed_version vault)"

need_pkgs=()
if [ "$nomad_installed" = "$NOMAD_VERSION" ]; then
  log "nomad ${NOMAD_VERSION} already installed"
else
  need_pkgs+=("nomad=${NOMAD_VERSION}-1")
fi
if [ "$vault_installed" = "$VAULT_VERSION" ]; then
  log "vault ${VAULT_VERSION} already installed"
else
  need_pkgs+=("vault=${VAULT_VERSION}-1")
fi

# Docker isn't version-pinned (Ubuntu's docker.io tracks the distro's
# ship-stable release — good enough for a dev box and avoids a second
# apt source). Sentinel is binary presence, not a semver match.
if command -v docker >/dev/null 2>&1; then
  log "docker already installed"
  docker_needs_install=0
else
  docker_needs_install=1
fi

if [ "${#need_pkgs[@]}" -eq 0 ] && [ "$docker_needs_install" -eq 0 ]; then
  log "nothing to do"
  exit 0
fi

# ── HashiCorp apt setup + nomad/vault install (skipped if both at pin) ───────
if [ "${#need_pkgs[@]}" -gt 0 ]; then
  # Ensure HashiCorp apt keyring.
  if [ ! -f "$HASHICORP_KEYRING" ]; then
    log "adding HashiCorp apt keyring → ${HASHICORP_KEYRING}"
    tmpkey="$(mktemp)"
    trap 'rm -f "$tmpkey"' EXIT
    curl -fsSL "$HASHICORP_GPG_URL" -o "$tmpkey" \
      || die "failed to fetch HashiCorp GPG key from ${HASHICORP_GPG_URL}"
    gpg --dearmor -o "$HASHICORP_KEYRING" < "$tmpkey" \
      || die "failed to dearmor HashiCorp GPG key"
    chmod 0644 "$HASHICORP_KEYRING"
    rm -f "$tmpkey"
    trap - EXIT
  else
    log "HashiCorp apt keyring already present"
  fi

  # Ensure HashiCorp apt sources list.
  desired_source="deb [signed-by=${HASHICORP_KEYRING}] ${HASHICORP_REPO_URL} ${CODENAME} main"
  if [ ! -f "$HASHICORP_SOURCES" ] \
     || ! grep -qxF "$desired_source" "$HASHICORP_SOURCES"; then
    log "writing HashiCorp apt sources list → ${HASHICORP_SOURCES}"
    printf '%s\n' "$desired_source" > "$HASHICORP_SOURCES"
    apt_update_needed=1
  else
    log "HashiCorp apt sources list already present"
    apt_update_needed=0
  fi

  # Install the pinned versions.
  if [ "$apt_update_needed" -eq 1 ]; then
    log "running apt-get update"
    DEBIAN_FRONTEND=noninteractive apt-get update -qq \
      || die "apt-get update failed"
  fi

  log "installing ${need_pkgs[*]}"
  DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
    "${need_pkgs[@]}" \
    || die "apt-get install ${need_pkgs[*]} failed"

  # Verify pinned versions.
  final_nomad="$(_installed_version nomad)"
  if [ "$final_nomad" != "$NOMAD_VERSION" ]; then
    die "post-install check: expected nomad ${NOMAD_VERSION}, got '${final_nomad}'"
  fi
  final_vault="$(_installed_version vault)"
  if [ "$final_vault" != "$VAULT_VERSION" ]; then
    die "post-install check: expected vault ${VAULT_VERSION}, got '${final_vault}'"
  fi
fi

# ── Install docker.io + enable+start docker.service (if missing) ─────────────
# Nomad's docker task driver reports Healthy=false without a running
# dockerd. On the factory dev box docker was pre-installed so Step 0's
# cluster-up passed silently; on a fresh LXC the first docker-driver
# jobspec (forgejo, Step 1) fails placement with "missing drivers".
# Install from Ubuntu's default apt repo — no second source, no pinning.
# `docker.service` ships with the package; `enable --now` is idempotent.
if [ "$docker_needs_install" -eq 1 ]; then
  log "installing docker.io"
  DEBIAN_FRONTEND=noninteractive apt-get install -y -q docker.io \
    || die "apt-get install docker.io failed"
  log "enabling + starting docker.service"
  systemctl enable --now docker \
    || die "failed to enable/start docker.service"
  command -v docker >/dev/null 2>&1 \
    || die "post-install check: docker binary still not found"
fi

log "nomad ${NOMAD_VERSION} + vault ${VAULT_VERSION} + docker installed successfully"
