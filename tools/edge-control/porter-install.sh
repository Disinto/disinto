#!/usr/bin/env bash
# =============================================================================
# porter-install.sh — installs the Porter door on the edge host (Debian DO box)
#
# The Porter door is sshd: `Match User porter` + AuthorizedKeysCommand
# -> key-command.sh -> porter-wrap.sh (loads $PORTER_ENV literally) ->
# dispatch.sh + verbs/. This script copies the door, seeds the ledger,
# seeds porter.env, and writes the drop-in. It needs no Gandi token;
# Caddy/DNS is separate optional work (install.sh).
#
# Paths (if PORTER_ROOT is set and non-empty, every path is prefixed with it,
# and the script does not useradd, does not chown, and does not reload sshd):
#   ${PORTER_ROOT}opt/porter           — the door: the copied scripts plus
#                                       lib/, verbs/, packs/
#   ${PORTER_ROOT}var/lib/porter       — the accounts.json ledger
#   ${PORTER_ROOT}etc/porter/porter.env  — allowlisted edge env (mode 640)
#   ${PORTER_ROOT}etc/ssh/sshd_config.d — the porter.conf drop-in
#
# Usage:
#   bash porter-install.sh [--admin-key <pubkey-file>]
#
# Copies exactly: dispatch.sh, key-command.sh, porter-wrap.sh,
# stripe-webhook.sh, lib/, verbs/, packs/. register.sh and install.sh are
# NOT copied. chmod 755 on every .sh in the prefix. The prefix is never
# rm -rf'd: a second run upgrades in place.
#
# Ledger (accounts.json): created only if missing
# ({"version":1,"accounts":{}}) and never overwritten. --admin-key ensures
# the row for the pubkey and sets admin=true, leaving credits and status
# untouched; a later run without --admin-key keeps both.
#
# The sshd drop-in is written every run (content is exactly the Match block
# below with the command path prefixed). sshd is not reloaded and
# /etc/ssh/sshd_config is never touched; `systemctl reload ssh` is
# operator work.
# =============================================================================
set -euo pipefail

log() { printf '%s\n' "$*"; }
die() { printf 'porter-install.sh: %s\n' "$*" >&2; exit 1; }

# ── Paths (PORTER_ROOT prefixes everything when set and non-empty) ──────────
# PREFIX is "/" for real installs; a trailing-slash-normalized PORTER_ROOT
# otherwise. (useradd/chown are only attempted for the real path.)
if [[ -n "${PORTER_ROOT:-}" ]]; then
  PREFIX="${PORTER_ROOT%/}/"
else
  PREFIX="/"
fi
OPT_DIR="${PREFIX}opt/porter"
LIB_DIR="${PREFIX}var/lib/porter"
ENV_FILE="${PREFIX}etc/porter/porter.env"
DROPIN_DIR="${PREFIX}etc/ssh/sshd_config.d"
DROPIN="${DROPIN_DIR}/porter.conf"
LEDGER="${LIB_DIR}/accounts.json"
SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ── Arguments: --admin-key <pubkey-file> ─────────────────────────────────────
ADMIN_KEY_FILE=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --admin-key)
      [[ $# -gt 1 ]] || die "--admin-key requires a pubkey file argument"
      ADMIN_KEY_FILE="$2"
      shift 2
      ;;
    -h|--help)
      printf 'Usage: %s [--admin-key <pubkey-file>]\n' "${BASH_SOURCE[0]}"
      exit 0
      ;;
    *)
      die "unknown option: $1 (see --help)"
      ;;
  esac
done

# ── Copy the door: exactly the listed paths, never register.sh / install.sh ──
log "Source tree: ${SRC_DIR}"
mkdir -p "${OPT_DIR}"

for src in dispatch.sh key-command.sh porter-wrap.sh stripe-webhook.sh; do
  [[ -f "${SRC_DIR}/${src}" ]] || die "source script missing: ${src}"
  cp -- "${SRC_DIR}/${src}" "${OPT_DIR}/${src}"
  chmod 755 "${OPT_DIR}/${src}"
done

for dir in lib verbs packs; do
  [[ -d "${SRC_DIR}/${dir}" ]] || die "source dir missing: ${dir}"
  cp -r "${SRC_DIR}/${dir}" "${OPT_DIR}/"
done

# 755 on every script that landed (lib/*.sh, verbs/*.sh).
find "${OPT_DIR}" -type f -name '*.sh' -exec chmod 755 {} +

# Never rm -rf the prefix: a second run upgrades in place.
log "Door copied to ${OPT_DIR} (lib/, verbs/, packs/; register.sh and install.sh excluded)"

# ── Ledger: create only if missing; never overwrite ───────────────────────────
mkdir -p "${LIB_DIR}"
if [[ ! -f "${LEDGER}" ]]; then
  printf '{"version":1,"accounts":{}}\n' > "${LEDGER}"
  chmod 640 "${LEDGER}"
  log "Ledger created: ${LEDGER}"
else
  log "Ledger present — left untouched: ${LEDGER}"
fi

# ── porter.env: create only if missing (mode 640); contents never clobbered ───
mkdir -p "${ENV_FILE%/*}"
if [[ ! -f "${ENV_FILE}" ]]; then
  printf 'TYPESAFE_API_KEY=\nJEV_MODEL=jev-1.13.0\n' > "${ENV_FILE}"
  chmod 640 "${ENV_FILE}"
  log "porter.env created: ${ENV_FILE}"
else
  log "porter.env present — contents untouched: ${ENV_FILE}"
fi

# Enforce the declared mode: tighten any env file looser than 640 (others
# read/writable, or group-writable) to 640. Contents are never rewritten.
_m="$(stat -c '%a' "${ENV_FILE}")"
if (( ( _m % 100 % 10 ) != 0 )) || (( ( ( _m % 100 / 10 ) & 2 ) != 0 )); then
  chmod 640 "${ENV_FILE}"
fi

# ── User + ownership: real-host installs only (skipped under PORTER_ROOT) ─────
if [[ -z "${PORTER_ROOT:-}" ]]; then
  if id porter >/dev/null 2>&1; then
    log "User porter already exists"
  else
    useradd -r -s /usr/sbin/nologin -m -d /home/porter porter \
      || die "cannot create user porter"
    log "User porter created"
  fi
  chown -R porter:porter "${OPT_DIR}" "${LIB_DIR}"
  log "Owned by porter: ${OPT_DIR} ${LIB_DIR}"
fi

# ── sshd drop-in: written every run; sshd not reloaded, sshd_config untouched ──
mkdir -p "${DROPIN_DIR}"
cat > "${DROPIN}" <<EOF
Match User porter
    AuthorizedKeysCommand ${OPT_DIR}/key-command.sh %f %t %k
    AuthorizedKeysCommandUser porter
    PasswordAuthentication no
    AllowTcpForwarding no
    X11Forwarding no
    PermitTunnel no
EOF
chmod 600 "${DROPIN}"
log "sshd drop-in written: ${DROPIN} (operator work: systemctl reload ssh)"

# ── --admin-key: ensure the row, set admin=true (credits/status untouched) ───
if [[ -n "${ADMIN_KEY_FILE}" ]]; then
  [[ -f "${ADMIN_KEY_FILE}" ]] || die "admin-key file missing: ${ADMIN_KEY_FILE}"
  # Fingerprint is the field starting with SHA256: (output is
  # "256 SHA256:… comment (TYPE)" in recent OpenSSH).
  fp_raw="$(ssh-keygen -lf "${ADMIN_KEY_FILE}" 2>/dev/null)" \
    || die "cannot fingerprint ${ADMIN_KEY_FILE} (not a valid public key?)"
  fp="$(printf '%s\n' "${fp_raw}" | awk '{for (i=1; i<=NF; i++) if ($i ~ /^SHA256:/) {print $i; exit}}')"
  [[ -n "${fp}" ]] \
    || die "cannot fingerprint ${ADMIN_KEY_FILE} (not a valid public key?)"
  [[ "${fp}" =~ ^SHA256:[A-Za-z0-9_-]{43}$ ]] \
    || die "unrecognizable public key: ${ADMIN_KEY_FILE}"
  now="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
  tmp="${LEDGER}.admin-tmp"
  jq --arg fp "$fp" --arg now "$now" \
     '.accounts = (.accounts // {})
      | .accounts[$fp] = (.accounts[$fp] //
         {fingerprint: $fp, status: "pending", credits: 0, name: null,
          admin: false, created_at: $now})
      | .accounts[$fp].admin = true' \
      "${LEDGER}" > "${tmp}" \
    || { rm -f "${tmp}"; die "failed to mark ${fp} admin in ${LEDGER}"; }
  mv "${tmp}" "${LEDGER}"
  chmod 640 "${LEDGER}"
  log "Ledger row ${fp} is admin"
fi

log "Porter door install complete"
exit 0
