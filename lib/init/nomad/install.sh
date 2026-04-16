#!/usr/bin/env bash
# =============================================================================
# lib/init/nomad/install.sh — Idempotent apt install of HashiCorp Nomad
#
# Part of the Nomad+Vault migration (S0.2, issue #822). Installs the `nomad`
# binary from the HashiCorp apt repository. Does NOT install Vault — S0.3
# owns that. Does NOT configure, start, or enable a systemd unit —
# lib/init/nomad/systemd-nomad.sh owns that. Does NOT wire this script into
# `disinto init` — S0.4 owns that.
#
# Idempotency contract:
#   - Running twice back-to-back is a no-op once the target version is
#     installed and the apt source is in place.
#   - Adds the HashiCorp apt keyring only if it is absent.
#   - Adds the HashiCorp apt sources list only if it is absent.
#   - Skips `apt-get install` entirely when the installed version already
#     matches ${NOMAD_VERSION}.
#
# Configuration:
#   NOMAD_VERSION  — pinned Nomad version (default: see below). The apt
#                    package name is versioned as "nomad=<version>-1".
#
# Usage:
#   sudo NOMAD_VERSION=1.9.5 lib/init/nomad/install.sh
#
# Exit codes:
#   0  success (installed or already present)
#   1  precondition failure (not Debian/Ubuntu, missing tools, not root)
# =============================================================================
set -euo pipefail

# Pin to a specific Nomad 1.x release. Bump here, not at call sites.
NOMAD_VERSION="${NOMAD_VERSION:-1.9.5}"

HASHICORP_KEYRING="/usr/share/keyrings/hashicorp-archive-keyring.gpg"
HASHICORP_SOURCES="/etc/apt/sources.list.d/hashicorp.list"
HASHICORP_GPG_URL="https://apt.releases.hashicorp.com/gpg"
HASHICORP_REPO_URL="https://apt.releases.hashicorp.com"

log() { printf '[install-nomad] %s\n' "$*"; }
die() { printf '[install-nomad] ERROR: %s\n' "$*" >&2; exit 1; }

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

# ── Fast-path: already at desired version? ───────────────────────────────────
installed_version=""
if command -v nomad >/dev/null 2>&1; then
  # `nomad version` prints e.g. "Nomad v1.9.5" on the first line.
  installed_version="$(nomad version 2>/dev/null \
    | awk 'NR==1 {sub(/^v/, "", $2); print $2; exit}')"
fi

if [ "$installed_version" = "$NOMAD_VERSION" ]; then
  log "nomad ${NOMAD_VERSION} already installed — nothing to do"
  exit 0
fi

# ── Ensure HashiCorp apt keyring ─────────────────────────────────────────────
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

# ── Ensure HashiCorp apt sources list ────────────────────────────────────────
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

# ── Install the pinned version ───────────────────────────────────────────────
if [ "$apt_update_needed" -eq 1 ]; then
  log "running apt-get update"
  DEBIAN_FRONTEND=noninteractive apt-get update -qq \
    || die "apt-get update failed"
fi

# HashiCorp apt packages use the "<version>-1" package-revision suffix.
pkg_spec="nomad=${NOMAD_VERSION}-1"
log "installing ${pkg_spec}"
DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
  "$pkg_spec" \
  || die "apt-get install ${pkg_spec} failed"

# ── Verify ───────────────────────────────────────────────────────────────────
final_version="$(nomad version 2>/dev/null \
  | awk 'NR==1 {sub(/^v/, "", $2); print $2; exit}')"
if [ "$final_version" != "$NOMAD_VERSION" ]; then
  die "post-install check: expected ${NOMAD_VERSION}, got '${final_version}'"
fi

log "nomad ${NOMAD_VERSION} installed successfully"
