#!/usr/bin/env bash
# =============================================================================
# machine/install.sh — install the machine sense on the LXD host
#
# Run as root on the machine that hosts the disinto box, from a disinto
# checkout:
#
#   sudo machine/install.sh [BOX]        BOX defaults to disinto-nomad-box
#
# Idempotent. Installs:
#   /usr/local/bin/disinto-machine-sense        machine/machine-sense.sh
#   /etc/systemd/system/disinto-machine-sense.{service,timer}
#   /etc/disinto-machine/neighbours.tsv         from the example, only if absent
#   /var/lib/disinto-machine/share (0755) and state (0700)
#   LXD disk device "machine-sense" on BOX: the share directory, read-only, at
#   /srv/disinto/machine in the box
# then enables the timer and writes the first report (du may take minutes).
# =============================================================================
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
box="${1:-disinto-nomad-box}"
share=/var/lib/disinto-machine/share

if [ "$(id -u)" -ne 0 ]; then
  echo "install.sh: run as root" >&2
  exit 1
fi

install -m 0755 "$here/machine-sense.sh" /usr/local/bin/disinto-machine-sense
install -m 0644 "$here/disinto-machine-sense.service" \
  "$here/disinto-machine-sense.timer" /etc/systemd/system/
install -d -m 0755 /etc/disinto-machine /var/lib/disinto-machine "$share"
install -d -m 0700 /var/lib/disinto-machine/state
if [ ! -f /etc/disinto-machine/neighbours.tsv ]; then
  install -m 0644 "$here/neighbours.example.tsv" /etc/disinto-machine/neighbours.tsv
fi

if ! lxc config device show "$box" | grep -q '^machine-sense:'; then
  lxc config device add "$box" machine-sense disk \
    source="$share" path=/srv/disinto/machine readonly=true
fi
# An existing device may have been added by hand: insist on the read-only mount.
for kv in "source=$share" "path=/srv/disinto/machine" "readonly=true"; do
  if [ "$(lxc config device get "$box" machine-sense "${kv%%=*}")" != "${kv#*=}" ]; then
    echo "install.sh: device machine-sense on $box must have $kv; fix or remove it" >&2
    exit 1
  fi
done

systemctl daemon-reload
systemctl enable --now disinto-machine-sense.timer
systemctl start disinto-machine-sense.service
echo "install.sh: report at $share/machine.json, in $box at /srv/disinto/machine/machine.json"
