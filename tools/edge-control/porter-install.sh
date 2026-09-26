#!/usr/bin/env bash
# =============================================================================
# porter-install.sh — installs the Porter door on the edge host (Debian DO box)
#
# The Porter door is sshd: `Match User porter` + AuthorizedKeysCommand
# -> key-command.sh -> porter-wrap.sh (loads $PORTER_ENV literally) ->
# dispatch.sh + verbs/. This script copies the door, seeds the ledger,
# seeds porter.env, creates the tunnel user, writes the drop-in, and then
# wires in the Caddy + DNS steps (porter-caddy.sh / porter-dns.sh) plus one
# conditional sshd reload. It needs no Gandi token of its own: porter-dns.sh
# reads the token from the existing gandi env file, and porter.env is never
# given one.
#
# Paths (if PORTER_ROOT is set and non-empty, every path is prefixed with it;
# the script also skips useradd/chown, sshd -t, and the reload):
#   ${PORTER_ROOT}opt/porter            — the door: the copied scripts plus
#                                         lib/, verbs/, packs/
#   ${PORTER_ROOT}var/lib/disinto       — the accounts.json ledger (the door
#                                         runtime's ACCOUNTS_FILE default; the
#                                         installer must match it, since
#                                         porter-wrap.sh will not load an
#                                         alternate ACCOUNTS_FILE)
#   ${PORTER_ROOT}etc/porter/porter.env — allowlisted edge env (mode 640)
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
# Tunnel user: the real-host run creates `disinto-tunnel` (system, nologin,
# no home) when it is missing. That user carries no AuthorizedKeysCommand:
# its keys are the plain file lib/authorized_keys.sh (rebuild_authorized_keys)
# writes — the installer never useradds any match block for it.
#
# Caddy + DNS: after the door copy and the drop-in, this script calls
# porter-caddy.sh and porter-dns.sh from the same directory (no
# --set-wildcard). porter-dns.sh ensures the wildcard * A record once and
# never edits other names. A DNS refusal (wildcard pointing elsewhere) is a
# non-zero exit AFTER the door files are in place: the door is not rolled
# back and DNS is not edited (the refusal propagates as this script's exit
# code).
#
# sshd: the drop-in is written every run. On a real host, sshd -t is run;
# sshd is reloaded only when that exits 0 and the drop-in is a `Match User
# porter` block with no column-0 AuthorizedKeysCommand. If sshd -t fails the
# previous drop-in (if any) is restored, sshd is not reloaded, and the
# script exits non-zero. Under PORTER_ROOT (acceptance tests) useradd,
# sshd -t and the reload are all skipped.
# =============================================================================
set -euo pipefail

log() { printf '%s\n' "$*"; }
die() { printf 'porter-install.sh: %s\n' "$*" >&2; exit 1; }

# ── Real-host sshd safety gate: validate, then reload only if the drop-in is
#     a clean `Match User porter` block with no column-0 AuthorizedKeysCommand.
#     On sshd -t failure it restores any previous drop-in, does not reload, and
#     returns non-zero. Self-contained (no die/log) so acceptance tests can
#     extract and drive it with stubbed sshd/systemctl. ─────────────────────────
reload_sshd_if_safe() {
  local dropin="$1"
  local backup="${dropin}.prev"
  if ! sshd -t > /dev/null 2>&1; then
    if [[ -n "${backup}" && -f "${backup}" ]]; then
      mv -- "${backup}" "${dropin}"
      chmod 600 "${dropin}" 2>/dev/null || true
    fi
    printf 'sshd -t failed; did not reload sshd\n' >&2
    return 1
  fi
  # Config validated: discard the backup (the new drop-in is now live).
  [[ -f "${backup}" ]] && rm -f -- "${backup}"
  if grep -Eq '^Match[[:space:]]+User[[:space:]]+porter' "${dropin}" \
     && ! grep -Eq '^AuthorizedKeysCommand' "${dropin}"; then
    systemctl reload ssh
  else
    printf 'drop-in not a clean Match User porter block; skipping sshd reload\n' >&2
  fi
}

# ── Paths (PORTER_ROOT prefixes everything when set and non-empty) ──────────
# PREFIX is "/" for real installs; a trailing-slash-normalized PORTER_ROOT
# otherwise. (useradd/chown are only attempted for the real path.)
if [[ -n "${PORTER_ROOT:-}" ]]; then
  PREFIX="${PORTER_ROOT%/}/"
else
  PREFIX="/"
fi
# The door runtime reads the ledger via lib/accounts.sh's ACCOUNTS_FILE
# default (/var/lib/disinto/accounts.json) and porter-wrap.sh excludes
# ACCOUNTS_FILE from its env allowlist, so the installer MUST seed the ledger
# at exactly that path (prefixed). A different path would mean the door never
# sees the seeded rows.
OPT_DIR="${PREFIX}opt/porter"
LIB_DIR="${PREFIX}var/lib/disinto"
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
  # EDGE_APPLY=1 sits beside the two existing assignments: the door is the
  # apply-side of a bound name (see verbs/approve.sh), so a fresh install
  # enables it by default. Never a Gandi token.
  printf 'TYPESAFE_API_KEY=\nJEV_MODEL=jev-1.13.0\nEDGE_APPLY=1\n' > "${ENV_FILE}"
  chmod 640 "${ENV_FILE}"
  log "porter.env created: ${ENV_FILE} (mode 640)"
else
  # Append EDGE_APPLY=1 only when the key is absent; do not change any other
  # line, and never write a Gandi token here.
  if ! grep -EqE '^EDGE_APPLY=' "${ENV_FILE}"; then
    printf 'EDGE_APPLY=1\n' >> "${ENV_FILE}"
  fi
  log "porter.env: EDGE_APPLY=1 ensured (${ENV_FILE})"
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

  # The forced command runs as user `porter`, which must be able to (a) read/
  # exec the door, (b) read porter.env (loaded by porter-wrap.sh), and (c)
  # write the ledger — the verbs `mv` a tmp file into ${LIB_DIR}/. So chown the
  # door to porter and give porter ownership of the ledger dir + ledger file
  # + env file.
  #
  # ${LIB_DIR} (/var/lib/disinto) is shared with install.sh's registry
  # (root:disinto-register 0750). We hand it to porter (the only user that
  # must *write* there for the ledger) and open it to 0755 so other users
  # (disinto-register, etc.) can still read it — the files inside (e.g.
  # registry.json 0644) were already world-readable, so 0755 exposes nothing
  # new. The ledger itself stays 0640 (porter-owned) so it is not world-
  # readable. The drop-in is read by sshd (root), so it stays root-owned.
  chown -R porter:porter "${OPT_DIR}"
  chown porter:porter "${LIB_DIR}"
  chmod 0755 "${LIB_DIR}"
  chown porter:porter "${LEDGER}" "${ENV_FILE}"
  log "Owned by porter: ${OPT_DIR} ${LIB_DIR} (0755) ${LEDGER} ${ENV_FILE}"
fi

# ── Tunnel user: real host only; keys live in a file, never AuthorizedKeysCommand
#     disinto-tunnel is the sshd user whose authorized_keys (a plain file,
#     rebuilt by lib/authorized_keys.sh) carries the projects' keys. No match
#     block / AuthorizedKeysCommand is written for it. ─────────────────────────
if [[ -z "${PORTER_ROOT:-}" ]]; then
  if id disinto-tunnel >/dev/null 2>&1; then
    log "Tunnel user disinto-tunnel already exists"
  else
    useradd -r -s /usr/sbin/nologin -M disinto-tunnel \
      || die "cannot create user disinto-tunnel"
    log "Tunnel user disinto-tunnel created (nologin, no home, no AuthorizedKeysCommand)"
  fi
fi

# ── sshd drop-in: written every run ───────────────────────────────────────────
mkdir -p "${DROPIN_DIR}"
# Keep a backup of any existing drop-in so a failed sshd -t (real host) can
# restore it. The door files are never rolled back on a DNS refusal.
DROPIN_BACKUP="${DROPIN}.prev"
if [[ -f "${DROPIN}" ]]; then
  cp -- "${DROPIN}" "${DROPIN_BACKUP}"
else
  DROPIN_BACKUP=""
fi
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
log "sshd drop-in written: ${DROPIN}"

# ── Caddy + DNS: called from the same directory; never --set-wildcard ─────────
# porter-caddy.sh adopts/installs the Caddy admin listener (never rewrites
# operator sites). porter-dns.sh ensures the wildcard * A record once and
# never edits other names. A DNS refusal is a non-zero exit after the door
# files are in place (the door is not rolled back; DNS is not edited).
# These are library-style helpers (mode 100644), invoked via bash.
bash "${SRC_DIR}/porter-caddy.sh"
bash "${SRC_DIR}/porter-dns.sh"

# ── sshd: real host only — validate then conditionally reload ────────────────
if [[ -z "${PORTER_ROOT:-}" ]]; then
  if ! reload_sshd_if_safe "${DROPIN}"; then
    die "sshd -t failed; previous drop-in restored (if any); not reloaded"
  fi
fi

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
