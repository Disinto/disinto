#!/usr/bin/env bash
# =============================================================================
# porter-front.sh — installs the factory front tunnel user + Caddy site
#
# Root script (not a verb), run directly by the operator on the edge host:
#
#   bash tools/edge-control/porter-front.sh --user NAME \
#       --port PORT [--port PORT ...] --site HOST --upstream ADDR:PORT
#
# It does, in order:
#   * refuses the reserved door/tunnel accounts (--user porter / disinto-tunnel)
#     with a non-zero exit and writes nothing;
#   * creates NAME (home /home/NAME, shell /usr/sbin/nologin) when missing; if
#     NAME already exists with a different home, it exits non-zero and leaves
#     passwd untouched;
#   * writes <prefix>etc/ssh/sshd_config.d/NAME.conf: a clean `Match User
#     NAME` block — PasswordAuthentication no, AllowTcpForwarding remote,
#     PermitTTY no, X11Forwarding no, and PermitListen limited to exactly the
#     given 127.0.0.1:PORT values (one per --port).
#   * real host only: validates with `sshd -t`; on failure it removes the new
#     drop-in and does not reload ssh, on success it reloads ssh.
#   * prints the single authorized_keys line the operator must install —
#     `restrict,port-forwarding,permitlisten="127.0.0.1:p"` (once per port),
#     with a `<pubkey>` placeholder; no forced command is written here (no key
#     is generated or fetched — that is porter-tunnel-keys.sh / the registry
#     flow's job).
#   * writes <prefix>etc/caddy/extra.d/NAME.caddy: one site block for HOST
#     that reverse_proxies to the upstream, carrying the same TLS issuer block
#     as the wildcard site (Gandi DNS, propagation_delay 20s,
#     propagation_timeout 10m, the three ns-*-*.gandi.net resolvers).
#
# It never edits the main Caddyfile. It never deletes or rewrites other files
# in extra.d (it only creates the one file for NAME). No network, no DNS, no
# authorized-key generation.
#
# Paths (when PORTER_ROOT is set and non-empty, every path is prefixed by it,
# and useradd / sshd -t / the reload are all skipped):
#   ${PORTER_ROOT}etc/ssh/sshd_config.d/NAME.conf
#   ${PORTER_ROOT}etc/caddy/extra.d/NAME.caddy
#
# Under PORTER_ROOT the script is a pure file writer, so it is safe to run in
# acceptance tests with no real sshd, caddy, systemctl, or useradd.
# =============================================================================
set -euo pipefail

log() { printf '%s\n' "$*"; }
die() { printf 'porter-front.sh: %s\n' "$*" >&2; exit 1; }

# ── Arguments: --user NAME --port PORT (repeatable) --site HOST --upstream ADDR:PORT ──
USER_NAME=""
PORTS=()
SITE=""
UPSTREAM=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --user)
      [[ $# -gt 1 ]] || die "--user requires NAME"
      USER_NAME="$2"; shift 2 ;;
    --port)
      [[ $# -gt 1 ]] || die "--port requires PORT"
      PORTS+=("$2"); shift 2 ;;
    --site)
      [[ $# -gt 1 ]] || die "--site requires HOST"
      SITE="$2"; shift 2 ;;
    --upstream)
      [[ $# -gt 1 ]] || die "--upstream requires ADDR:PORT"
      UPSTREAM="$2"; shift 2 ;;
    -h|--help)
      printf 'Usage: %s --user NAME --port PORT [--port PORT ...] --site HOST --upstream ADDR:PORT\n' \
        "${BASH_SOURCE[0]}"
      exit 0 ;;
    *)
      die "unknown option: $1" ;;
  esac
done
[[ -n "${USER_NAME}" && -n "${SITE}" && -n "${UPSTREAM}" ]] \
  || die "required options: --user, --site, --upstream"
[[ "${#PORTS[@]}" -gt 0 ]] || die "required: at least one --port"

# ── Reserved accounts: this is NOT the door or the tunnel user ────────────────
# porter carries the AuthorizedKeysCommand door; disinto-tunnel carries the
# registry authorized_keys. Neither is a factory-front forwarder.
if [[ "${USER_NAME}" == "porter" || "${USER_NAME}" == "disinto-tunnel" ]]; then
  die "user must not be 'porter' (the door) or 'disinto-tunnel' (the tunnel user)"
fi

# ── Paths (PORTER_ROOT prefixes everything when set/non-empty) ────────────────
PREFIX="${PORTER_ROOT:-/}"
[[ "$PREFIX" == "/" ]] || PREFIX="${PREFIX%/}/"
USER_HOME="${PREFIX%/}/home/${USER_NAME}"
DROPIN_DIR="${PREFIX}etc/ssh/sshd_config.d"
DROPIN="${DROPIN_DIR}/${USER_NAME}.conf"
EXTRA_DIR="${PREFIX}etc/caddy/extra.d"
EXTRA_FILE="${EXTRA_DIR}/${USER_NAME}.caddy"

# ── User: real host only (skipped under PORTER_ROOT) ──────────────────────────
if [[ -z "${PORTER_ROOT:-}" ]]; then
  if id "${USER_NAME}" >/dev/null 2>&1; then
    existing_home="$(getent passwd "${USER_NAME}" | cut -d: -f6)"
    if [[ "${existing_home}" != "${USER_HOME}" ]]; then
      die "user ${USER_NAME} home is ${existing_home:-<unset>}; expected ${USER_HOME} (passwd untouched)"
    fi
    log "User ${USER_NAME} already exists (home ${USER_HOME})"
  else
    # -r system user, -m real home from /etc/skel, nologin shell: a reverse
    # tunnel user must have a home (sshd StrictModes) but no interactive shell.
    useradd -r -m -d "${USER_HOME}" -s /usr/sbin/nologin "${USER_NAME}" \
      || die "cannot create user ${USER_NAME}"
    log "User ${USER_NAME} created (home ${USER_HOME}, nologin)"
  fi
fi

# ── sshd drop-in: written every run; always a clean Match block (no
#     AuthorizedKeysCommand) ────────────────────────────────────────────────────
# PermitListen is a space-separated list of addr-specs (host:port), one per --port.
permit_listen=""
for p in "${PORTS[@]}"; do
  if [[ -n "${permit_listen}" ]]; then
    permit_listen="${permit_listen} 127.0.0.1:${p}"
  else
    permit_listen="127.0.0.1:${p}"
  fi
done
mkdir -p "${DROPIN_DIR}"
cat > "${DROPIN}" <<EOF
Match User ${USER_NAME}
    PasswordAuthentication no
    AllowTcpForwarding remote
    PermitTTY no
    X11Forwarding no
    PermitListen ${permit_listen}
EOF
chmod 600 "${DROPIN}"
log "sshd drop-in written: ${DROPIN}"

# ── Real-host sshd gate: validate, then reload. On sshd -t failure it removes
#     the new drop-in and does not reload. Self-contained (no log/die) so
#     acceptance tests can extract and drive it with a stubbed sshd/systemctl. ───
front_sshd_gate() {
  local dropin="$1"
  if ! sshd -t > /dev/null 2>&1; then
    rm -f -- "${dropin}"
    printf 'sshd -t failed; removed %s; did not reload sshd\n' "${dropin}" >&2
    return 1
  fi
  systemctl reload ssh
}

if [[ -z "${PORTER_ROOT:-}" ]]; then
  if ! front_sshd_gate "${DROPIN}"; then
    die "sshd -t failed; new drop-in removed; not reloaded"
  fi
  log "sshd validated (sshd -t) and reloaded"
fi

# ── Operator's authorized_keys line (NOT generated here: no key source. The
#     operator appends the project's own public key after the last option; no
#     forced command is present, so a session without -N gets no shell.) ────────
opts=""
for p in "${PORTS[@]}"; do
  if [[ -n "${opts}" ]]; then
    opts="${opts},permitlisten=\"127.0.0.1:${p}\""
  else
    opts="permitlisten=\"127.0.0.1:${p}\""
  fi
done
KEY_LINE="restrict,port-forwarding,${opts} <pubkey>"
log "authorized_keys line for ${USER_NAME} (append your public key after the last option):"
printf '%s\n' "${KEY_LINE}"

# ── Caddy site: one extra.d file for HOST -> upstream, same TLS issuer as the
#     wildcard. Never edits the main Caddyfile; never deletes other extra.d
#     files (only creates the one file for NAME). ───────────────────────────────
mkdir -p "${EXTRA_DIR}"
printf '%s {\n  tls acme {\n    dns gandi {env.GANDI_API_KEY}\n    propagation_delay 20s\n    propagation_timeout 10m\n    resolvers ns-163-a.gandi.net ns-102-b.gandi.net ns-91-c.gandi.net\n  }\n  reverse_proxy %s\n}\n' "${SITE}" "${UPSTREAM}" > "${EXTRA_FILE}"
chmod 644 "${EXTRA_FILE}"
log "Caddy site written: ${EXTRA_FILE} (${SITE} -> ${UPSTREAM})"
log "porter-front complete for ${USER_NAME}"
exit 0
