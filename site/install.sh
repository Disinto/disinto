#!/usr/bin/env bash
# =============================================================================
# disinto — Bootstrap installer for fresh hosts
#
# Usage:
#   curl -fsSL https://disinto.ai/install.sh | sudo bash
#
# Installs the disinto CLI at /opt/disinto and symlinks it to /usr/local/bin.
# =============================================================================
set -euo pipefail

# --- Require root -----------------------------------------------------------
if [ "$(id -u)" -ne 0 ]; then
  echo "ERROR: This installer must be run as root (try: sudo bash)." >&2
  exit 1
fi

# --- Check for existing installation ----------------------------------------
if [ -d /opt/disinto ]; then
  echo "ERROR: /opt/disinto already exists." >&2
  echo "       Remove it first: /opt/disinto/bin/uninstall.sh" >&2
  exit 1
fi

# --- Resolve version --------------------------------------------------------
VERSION="$(curl -fsSL https://disinto.ai/LATEST)"
if [ -z "$VERSION" ]; then
  echo "ERROR: Failed to resolve version from https://disinto.ai/LATEST" >&2
  exit 1
fi
echo "Installing disinto ${VERSION} ..."

# --- Check dependencies -----------------------------------------------------
MISSING=()
for cmd in docker jq curl git tmux psql python3; do
  if ! command -v "$cmd" &>/dev/null; then
    MISSING+=("$cmd")
  fi
done

if [ "${#MISSING[@]}" -gt 0 ]; then
  echo "ERROR: Missing dependencies: ${MISSING[*]}" >&2
  echo "       Install them first (e.g. apt install -y ${MISSING[*]})" >&2
  exit 1
fi

# --- Clone the tagged release -----------------------------------------------
echo "Cloning repository (tag ${VERSION}) ..."
git clone --depth 1 --branch "$VERSION" https://codeberg.org/johba/disinto /opt/disinto

# --- Symlink the CLI --------------------------------------------------------
ln -sf /opt/disinto/bin/disinto /usr/local/bin/disinto

# --- Done -------------------------------------------------------------------
echo ""
echo "disinto ${VERSION} installed."
echo ""
echo "Next step: run 'disinto init https://your.forge.io/you/project'"
echo "           to bootstrap your first project."
