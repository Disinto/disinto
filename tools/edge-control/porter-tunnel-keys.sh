#!/usr/bin/env bash
# =============================================================================
# porter-tunnel-keys.sh — root helper for the tunnel user's SSH keys
#
# Invoked as `sudo -n /opt/porter/porter-tunnel-keys.sh` by
# lib/authorized_keys.sh::rebuild_authorized_keys, which is allowed to run
# exactly this command via /etc/sudoers.d/porter-tunnel (NOPASSWD). Its only
# job is to hand ownership of the tunnel's .ssh to the tunnel user, so that
# sshd (StrictModes on) accepts the authorized_keys file:
#
#   - chown  .ssh            disinto-tunnel:disinto-tunnel  0700
#   - chown  authorized_keys disinto-tunnel:disinto-tunnel  0600
#
# Takes no arguments. The path is derived from the same PORTER_ROOT seam the
# installer/lib use, so it always resolves to the tunnel's authorized_keys —
# never anything the caller chooses. If the authorized_keys is not a regular
# file (missing, a directory, or a symlink), or .ssh is not a regular
# directory (symlink or missing), it refuses: non-zero exit, and it chowns
# nothing. This is the security boundary that keeps a mis-directed sudo call
# from chowning an arbitrary file.
# =============================================================================
set -euo pipefail

fail() { printf 'porter-tunnel-keys.sh: %s\n' "$*" >&2; exit 1; }

# No arguments, ever. The path is derived internally (see below), never passed
# in by the caller.
[[ $# -eq 0 ]] || fail "takes no arguments; got $# arg(s)"

TUNNEL_USER="disinto-tunnel"
if [[ -n "${PORTER_ROOT:-}" ]]; then
  TUNNEL_HOME="${PORTER_ROOT%/}/home/${TUNNEL_USER}"
else
  TUNNEL_HOME="/home/${TUNNEL_USER}"
fi
SSH_DIR="${TUNNEL_HOME}/.ssh"
AUTH_KEYS="${SSH_DIR}/authorized_keys"

# Guards: refuse before touching anything if the path is not the regular
# tunnel authorized_keys file. "The path is anything else" = missing, a
# directory, or a symlink; the symlink guard is explicit because -f follows
# links.
[[ -d "${TUNNEL_HOME}" ]] || fail "tunnel home missing: ${TUNNEL_HOME}"
[[ -d "${SSH_DIR}" ]]     || fail ".ssh missing: ${SSH_DIR}"
[[ ! -L "${SSH_DIR}" ]]   || fail ".ssh is a symlink: ${SSH_DIR}"
[[ -f "${AUTH_KEYS}" ]]   || fail "authorized_keys missing: ${AUTH_KEYS}"
[[ ! -L "${AUTH_KEYS}" ]] || fail "authorized_keys is a symlink: ${AUTH_KEYS}"

chown "${TUNNEL_USER}:${TUNNEL_USER}" "${SSH_DIR}"
chmod 700 "${SSH_DIR}"
chown "${TUNNEL_USER}:${TUNNEL_USER}" "${AUTH_KEYS}"
chmod 600 "${AUTH_KEYS}"
