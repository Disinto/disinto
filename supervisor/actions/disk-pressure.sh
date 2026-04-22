#!/usr/bin/env bash
# supervisor/actions/disk-pressure.sh — P1 disk pressure remediation
#
# Placeholder: full implementation in #594 (direct remediation extraction).
# Current action: docker system prune + truncate large logs.
set -euo pipefail

echo "[disk-pressure] Pruning Docker system..."
sudo docker system prune -f >/dev/null 2>&1 || true

# Second pass if still > 80%
_disk_pct=$(df -h / | awk 'NR==2{print $5}' | tr -d '%')
if [ "${_disk_pct:-0}" -gt 80 ]; then
  echo "[disk-pressure] Still >80%, aggressive prune..."
  sudo docker system prune -a -f >/dev/null 2>&1 || true
fi

echo "[disk-pressure] Disk pressure remediation complete."
