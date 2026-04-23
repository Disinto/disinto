#!/usr/bin/env bash
# =============================================================================
# disinto — Uninstall script (ships with the disinto release)
#
# Usage:
#   sudo /opt/disinto/bin/uninstall.sh
# =============================================================================
set -euo pipefail

if [ "$(id -u)" -ne 0 ]; then
  echo "ERROR: This script must be run as root." >&2
  exit 1
fi

rm -rf /opt/disinto
rm -f /usr/local/bin/disinto

echo "disinto uninstalled."
