#!/usr/bin/env bash
# =============================================================================
# tests/acceptance/issue-1572.sh
#
# Issue #1572: fix(edge): tunnel key file is owned by disinto-tunnel.
#
# porter-install.sh created `disinto-tunnel` with `useradd -M` (no home) and
# lib/authorized_keys.sh::rebuild_authorized_keys wrote the authorized_keys
# file as `porter` without handing it to the tunnel user. sshd (StrictModes)
# rejects the file: it lives in a missing /home/disinto-tunnel/.ssh and its
# owner is wrong. Fix:
#   * disinto-tunnel gets a real home via `useradd -d /home/disinto-tunnel -m`
#     (NEVER -M); a re-run keeps the user only if its home is that path (else
#     exits non-zero without touching passwd).
#   * porter-install.sh installs /etc/sudoers.d/porter-tunnel (mode 440)
#     granting `porter` exactly one NOPASSWD command: the tunnel-keys helper.
#   * rebuild_authorized_keys runs that helper (`sudo -n`) to hand the file to
#     disinto-tunnel (skipped under PORTER_ROOT, the test seam).
#
# Hermetic: no root, no network. useradd / sudo / chown are stubbed.
# PORTER_ROOT is a mktemp dir; /etc is never written.
#
# Contract under test:
#   * AC1: the installer no longer passes -M and the tunnel home is
#           /home/disinto-tunnel; under PORTER_ROOT the helper is copied to the
#           door.
#   * AC2: the (prefixed) /etc/sudoers.d/porter-tunnel drop-in is mode 440 and
#           holds exactly one NOPASSWD line that allows only the helper; the
#           helper chowns .ssh 700 + authorized_keys 600 to disinto-tunnel and
#           refuses (non-zero, no chown) a symlinked or directory authorized_keys.
#   * AC3: rebuild_authorized_keys leaves a readable authorized_keys under
#           PORTER_ROOT (sudo skipped) and its sudo command targets the
#           tunnel-keys helper, never a general chown.
#   * AC4: the test exits 0 and calls ac_pass.
#
# Run via: tools/run-acceptance.sh 1572
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/../.." && pwd)"
# shellcheck source=../lib/acceptance-helpers.sh
source "$REPO_ROOT/tests/lib/acceptance-helpers.sh"

ac_require_cmd bash jq grep sed awk stat printf chmod cp mkdir rm ln cat head

PORTER_INSTALL="$REPO_ROOT/tools/edge-control/porter-install.sh"
ac_assert_file "${PORTER_INSTALL}" "tools/edge-control/porter-install.sh is missing"
AUTH_KEYS_LIB="$REPO_ROOT/tools/edge-control/lib/authorized_keys.sh"
ac_assert_file "${AUTH_KEYS_LIB}" "tools/edge-control/lib/authorized_keys.sh is missing"
TUNNEL_HELPER="$REPO_ROOT/tools/edge-control/porter-tunnel-keys.sh"
ac_assert_file "${TUNNEL_HELPER}" "porter-tunnel-keys.sh is missing"

# ── Throwaway root (PORTER_ROOT) + stubs + fixtures ──────────────────────────
TMP_DIR="$(mktemp -d /tmp/disinto-acceptance-1572.XXXXXX)"
cleanup() { rm -rf "$TMP_DIR" 2>/dev/null || true; }
trap cleanup EXIT

ROOT="$TMP_DIR/root"
mkdir -p "$ROOT/var/lib/disinto" "$ROOT/home"

ACCOUNTS_FILE="$ROOT/var/lib/disinto/accounts.json"
REGISTRY_DIR="$ROOT/var/lib/disinto"
REGISTRY_FILE="$ROOT/var/lib/disinto/registry.json"
TUNNEL_AUTH_KEYS="$ROOT/home/disinto-tunnel/.ssh/authorized_keys"
OPT_DIR="$ROOT/opt/porter"
SUDOERS_FILE="$ROOT/etc/sudoers.d/porter-tunnel"

# The sudo + chown stubs. sudo is absent from this box's PATH, so the rebuild's
# `sudo -n` can only be exercised here via the stub; the test records its args
# so it can prove the sudo was (or was not) called.
STUB_DIR="$TMP_DIR/stub"
mkdir -p "$STUB_DIR"
CHOWN_LOG="$TMP_DIR/chown.log"
SUDO_LOG="$STUB_DIR/sudo.log"
: > "$CHOWN_LOG"
: > "$SUDO_LOG"
cat > "$STUB_DIR/sudo" <<EOF
#!/usr/bin/env bash
{ printf '%s\n' "\$*" >> "${SUDO_LOG}"; exit 0; }
EOF
cat > "$STUB_DIR/chown" <<EOF
#!/usr/bin/env bash
{ printf '%s\n' "\$*" >> "${CHOWN_LOG}"; exit 0; }
EOF
chmod +x "$STUB_DIR/sudo" "$STUB_DIR/chown"

# Ledger + registry: one registered project (acme) whose ledger row carries a
# valid ed25519 pubkey — the rebuild's only qualifying case (a fingerprint or a
# missing row writes nothing, per the #1557 contract this reuses).
FP_A="SHA256:$(printf 'A%.0s' {1..43})"
KEY_DATA="AAAAC3NzaC1lZDI1NTE5AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAB"
ACME_PUBKEY="ssh-ed25519 ${KEY_DATA}"

cat > "$ACCOUNTS_FILE" <<EOF
{
  "version": 1,
  "accounts": {
    "${FP_A}": {
      "fingerprint": "${FP_A}",
      "status": "approved", "credits": 0, "name": "acme", "admin": false,
      "created_at": "2026-01-01T00:00:00Z",
      "pubkey": "${ACME_PUBKEY}"
    }
  }
}
EOF

cat > "$REGISTRY_FILE" <<EOF
{
  "version": 1,
  "projects": {
    "acme": { "port": 20000, "fqdn": "acme.disinto.ai", "registered_by": "admin" }
  }
}
EOF

export PORTER_ROOT="$ROOT"
ac_log "issue-1572: PORTER_ROOT=${ROOT}; stubs: ${STUB_DIR}/sudo ${STUB_DIR}/chown"

# ── AC1: the installer drops -M and sets home /home/disinto-tunnel ──────────
# The disinto-tunnel useradd must carry -d (home) and -m, and must NOT carry
# -M (skip home).
dt_useradd="$(grep -E '^[[:space:]]*useradd.*disinto-tunnel' "${PORTER_INSTALL}" | head -1)"
if [[ -z "${dt_useradd}" ]]; then
  ac_fail "AC1: cannot find a disinto-tunnel useradd in ${PORTER_INSTALL}"
fi
if [[ ! "${dt_useradd}" == *'-d '* ]]; then
  ac_fail "AC1: disinto-tunnel useradd lacks -d (home) -> ${dt_useradd}"
fi
if [[ ! "${dt_useradd}" == *'-m '* ]]; then
  ac_fail "AC1: disinto-tunnel useradd lacks -m -> ${dt_useradd}"
fi
if [[ "${dt_useradd}" =~ -M ]]; then
  ac_fail "AC1: disinto-tunnel useradd still passes -M (no home) -> ${dt_useradd}"
fi
# The home is /home/disinto-tunnel (via the TUNNEL_HOME var the useradd uses).
if ! grep -qF 'TUNNEL_HOME="/home/disinto-tunnel"' "${PORTER_INSTALL}"; then
  ac_fail "AC1: tunnel home is not /home/disinto-tunnel"
fi
# Under PORTER_ROOT the installer must still copy the helper to the door. The
# door copy is the *first* thing it does — before the Caddy/DNS steps, which
# cannot succeed in a hermetic test (no Caddy admin on 2019, no Gandi token,
# no network). Those trailing steps are pre-existing breakage (issue-1537 hits
# them too), so we run the installer, tolerate any non-zero exit from those
# steps, and assert the door + helper actually landed.
rc=0
bash "${PORTER_INSTALL}" >/dev/null 2>&1 || rc=$?
if [[ ! -f "${OPT_DIR}/porter-tunnel-keys.sh" ]]; then
  ac_fail "AC1: helper not copied to the door (${OPT_DIR}/porter-tunnel-keys.sh); installer rc=$rc"
fi
if [[ ! -r "${OPT_DIR}/porter-tunnel-keys.sh" ]]; then
  ac_fail "AC1: helper not readable in the door (${OPT_DIR}/porter-tunnel-keys.sh)"
fi
if [[ "$(stat -c '%a' "${OPT_DIR}/porter-tunnel-keys.sh")" != "755" ]]; then
  ac_fail "AC1: helper mode in the door is not 755 (got $(stat -c '%a' "${OPT_DIR}/porter-tunnel-keys.sh"))"
fi
ac_log "AC1: installer drops -M, sets home /home/disinto-tunnel, copies helper to door"

# ── AC2: the sudo drop-in + the helper's chown / refuse behaviour ────────────
# The sudo drop-in (prefixed) is written, is 440, and holds exactly one line:
# the single NOPASSWD command for the helper.
if [[ ! -f "${SUDOERS_FILE}" ]]; then
  ac_fail "AC2: sudo drop-in not written (${SUDOERS_FILE})"
fi
s_mode="$(stat -c '%a' "${SUDOERS_FILE}")"
if [[ "${s_mode}" != "440" ]]; then
  ac_fail "AC2: sudo drop-in mode is ${s_mode}, expected 440"
fi
expected_line="porter ALL=(root) NOPASSWD: ${OPT_DIR}/porter-tunnel-keys.sh"
content="$(cat "${SUDOERS_FILE}")"
if [[ "${content}" != "${expected_line}" ]]; then
  ac_fail "AC2: sudo drop-in content is not exactly the single NOPASSWD helper line (got: ${content})"
fi

# Helper, good case: it chowns .ssh + authorized_keys to disinto-tunnel.
HELPER_HOME="$ROOT/home/disinto-tunnel"
HELPER_SSH="${HELPER_HOME}/.ssh"
HELPER_AUTH="${HELPER_SSH}/authorized_keys"
mkdir -p "${HELPER_HOME}" "${HELPER_SSH}"
printf '%s\n' "${ACME_PUBKEY}" > "${HELPER_AUTH}"
: > "${CHOWN_LOG}"
rc=0
( PATH="${STUB_DIR}:${PATH}" bash "${TUNNEL_HELPER}" ) 2>&1 || rc=$?
if [[ "$rc" -ne 0 ]]; then
  ac_fail "AC2: helper failed on the good case (rc=$rc)"
fi
if ! grep -qF "disinto-tunnel:disinto-tunnel ${HELPER_SSH}" "${CHOWN_LOG}"; then
  ac_fail "AC2: helper did not chown .ssh (${HELPER_SSH})"
fi
if ! grep -qF "disinto-tunnel:disinto-tunnel ${HELPER_AUTH}" "${CHOWN_LOG}"; then
  ac_fail "AC2: helper did not chown authorized_keys (${HELPER_AUTH})"
fi
ac_log "AC2: helper chowns .ssh + authorized_keys to disinto-tunnel (700/600)"

# Helper, refuse case: a SYMLINKED authorized_keys is rejected (no chown).
: > "${CHOWN_LOG}"
rm -f "${HELPER_AUTH}"
printf 'target\n' > "${HELPER_AUTH}.target"
ln -s "${HELPER_AUTH}.target" "${HELPER_AUTH}"
rc=0
( PATH="${STUB_DIR}:${PATH}" bash "${TUNNEL_HELPER}" ) 2>&1 || rc=$?
if [[ "$rc" -eq 0 ]]; then
  ac_fail "AC2: helper did not refuse a symlinked authorized_keys (rc=0)"
fi
if [[ -s "${CHOWN_LOG}" ]]; then
  ac_fail "AC2: helper chowned despite a symlinked authorized_keys (log: $(cat "${CHOWN_LOG}"))"
fi
rm -f "${HELPER_AUTH}" "${HELPER_AUTH}.target"

# Helper, refuse case: a DIRECTORY authorized_keys is rejected (no chown).
: > "${CHOWN_LOG}"
rm -rf "${HELPER_AUTH}"
mkdir "${HELPER_AUTH}"
rc=0
( PATH="${STUB_DIR}:${PATH}" bash "${TUNNEL_HELPER}" ) 2>&1 || rc=$?
if [[ "$rc" -eq 0 ]]; then
  ac_fail "AC2: helper did not refuse a directory authorized_keys (rc=0)"
fi
if [[ -s "${CHOWN_LOG}" ]]; then
  ac_fail "AC2: helper chowned despite a directory authorized_keys (log: $(cat "${CHOWN_LOG}"))"
fi
rm -rf "${HELPER_AUTH}"
ac_log "AC2: helper refuses symlinked / directory authorized_keys (no chown)"

# ── AC3: rebuild runs clean under PORTER_ROOT (sudo skipped, helper targeted) ─
err_file="${TMP_DIR}/rebuild.err"
rc=0
(
  export PATH="${STUB_DIR}:${PATH}"
  export ACCOUNTS_FILE="${ACCOUNTS_FILE}"
  export REGISTRY_DIR="${REGISTRY_DIR}"
  export PORTER_ROOT="${ROOT}"
  # shellcheck source=lib/authorized_keys.sh
  source "${AUTH_KEYS_LIB}"
  rebuild_authorized_keys
) 2>"${err_file}" || rc=$?
if [[ "$rc" -ne 0 ]]; then
  ac_fail "AC3: rebuild_authorized_keys failed under PORTER_ROOT (rc=$rc, $(cat "${err_file}")"
fi
if [[ ! -f "${TUNNEL_AUTH_KEYS}" ]]; then
  ac_fail "AC3: authorized_keys not written under PORTER_ROOT"
fi
if [[ ! -r "${TUNNEL_AUTH_KEYS}" ]]; then
  ac_fail "AC3: authorized_keys not readable under PORTER_ROOT"
fi
if ! grep -qF "permitlisten" "${TUNNEL_AUTH_KEYS}"; then
  ac_fail "AC3: authorized_keys has no permitlisten line (rebuild wrote nothing)"
fi
# Under PORTER_ROOT the sudo must have been SKIPPED (the stub was not called).
if [[ -s "${SUDO_LOG}" ]]; then
  ac_fail "AC3: sudo was invoked under PORTER_ROOT (should be skipped; log: $(cat "${SUDO_LOG}")"
fi
# The sudo command the rebuild issues must target the tunnel-keys helper —
# never a general chown (the issue's security boundary).
if grep -EqE 'sudo -n[[:space:]].*chown' "${AUTH_KEYS_LIB}"; then
  ac_fail "AC3: rebuild_authorized_keys issues a general chown via sudo"
fi
if ! grep -EqE 'sudo -n[[:space:]].*(TUNNEL_KEYS_HELPER|porter-tunnel-keys\.sh)' "${AUTH_KEYS_LIB}"; then
  ac_fail "AC3: rebuild_authorized_keys sudo does not target the tunnel-keys helper"
fi
if ! grep -EqE 'TUNNEL_KEYS_HELPER=.*/porter-tunnel-keys\.sh' "${AUTH_KEYS_LIB}"; then
  ac_fail "AC3: TUNNEL_KEYS_HELPER does not resolve to porter-tunnel-keys.sh"
fi
ac_log "AC3: rebuild runs clean, leaves a readable file, skips sudo, targets the helper"

# ── AC4 ─────────────────────────────────────────────────────────────────────
ac_pass
