#!/usr/bin/env bash
# =============================================================================
# tests/acceptance/issue-1537.sh
#
# Issue #1537: feat(edge): porter-install copies the door without a Gandi token
#
# The Porter door is the sshd drop-in `Match User porter` -> key-command.sh ->
# porter-wrap.sh (loads $PORTER_ENV literally) -> dispatch.sh + verbs/.
# porter-install.sh copies the door, seeds the ledger and porter.env, and
# writes the drop-in. It never needs a Gandi token (Caddy/DNS is the optional
# install.sh job).
#
#   AC0  install.sh carries the 6-line note: optional Caddy installer, NOT
#         the Porter door; the door is porter-install.sh.
#   AC1  A PORTER_ROOT run copies porter-wrap.sh and verbs/jev.sh (plus
#         dispatch.sh, key-command.sh, stripe-webhook.sh, lib/, packs/);
#         register.sh and install.sh are NOT copied; .sh files land 755.
#   AC2  The drop-in contains `Match User porter` and no line matching
#         ^AuthorizedKeysCommand (it is indented under Match), and its
#         command path is prefixed.
#   AC3  A second run leaves ledger credits and porter.env contents untouched;
#         a 666-mode env file is tightened to 640. The ledger is never
#         overwritten (seeded row survives).
#   AC4  --admin-key <pubkey> ensures the ledger row with admin=true and
#         credits=0 (status untouched); a later run without the flag keeps
#         admin=true.
#
# No network, no sshd, no /etc writes. PORTER_ROOT is a mktemp dir.
#
# Run with: tools/run-acceptance.sh 1537
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../lib/acceptance-helpers.sh
source "$REPO_ROOT/tests/lib/acceptance-helpers.sh"

ac_require_cmd bash jq mktemp grep cat chmod stat date printf ssh-keygen awk

PORTER_INSTALL="$REPO_ROOT/tools/edge-control/porter-install.sh"
ac_assert_file "${PORTER_INSTALL}" "tools/edge-control/porter-install.sh is missing"
INSTALL_SH="$REPO_ROOT/tools/edge-control/install.sh"
ac_assert_file "${INSTALL_SH}" "tools/edge-control/install.sh is missing"

# ── AC0: the 6-line door note lives at the top of install.sh ──────────────────
grep -qF 'not the Porter door' "${INSTALL_SH}" \
  || ac_fail "AC0: install.sh note says nothing about not being the Porter door"
grep -qF 'porter-install.sh' "${INSTALL_SH}" \
  || ac_fail "AC0: install.sh note does not name porter-install.sh as the door"
ac_log "AC0: install.sh notes it is the optional Caddy installer, not the door"

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT
ROOT="${TMP_DIR}/porter-root"
mkdir -p "${ROOT}"
ac_log "issue-1537: PORTER_ROOT=${ROOT}"

OPT_DIR="${ROOT}/opt/porter"
LEDGER="${ROOT}/var/lib/porter/accounts.json"
ENV_FILE="${ROOT}/etc/porter/porter.env"
DROPIN="${ROOT}/etc/ssh/sshd_config.d/porter.conf"

run_install() {
  PORTER_ROOT="${ROOT}" bash "${PORTER_INSTALL}" "$@"
}

# Fixture admin key (hardcoded ed25519; its fingerprint conforms to the
# ledger FINGERPRINT_RE: SHA256: + 43 chars of [A-Za-z0-9_-]).
KEYFILE="${TMP_DIR}/admin.pub"
cat > "${KEYFILE}" <<'EOF'
ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIBEKIKkeduG3UUPa9vNwdtXnAUYZ+GxyN48fPg1xaxRg agent@22eace42a192
EOF

# Fingerprint as this host's ssh-keygen reports it (field after the bit length).
FP_FROM_KEY="$(ssh-keygen -lf "${KEYFILE}" | awk '{for (i=1; i<=NF; i++) if ($i ~ /^SHA256:/) {print $i; exit}}')"
[[ "${FP_FROM_KEY}" =~ ^SHA256:[A-Za-z0-9_-]{43}$ ]] \
  || ac_fail "fixture key fingerprint malformed: ${FP_FROM_KEY}"

# ── Run 1: bare PORTER_ROOT install ───────────────────────────────────────────
run_install

# ── AC1: copies ───────────────────────────────────────────────────────────────
for f in dispatch.sh key-command.sh porter-wrap.sh stripe-webhook.sh \
         lib/accounts.sh lib/ports.sh verbs/jev.sh verbs/credits.sh \
         packs/scope.json; do
  [[ -f "${OPT_DIR}/${f}" ]] \
    || ac_fail "AC1: ${f} not copied to ${OPT_DIR}"
done
[[ ! -f "${OPT_DIR}/register.sh" ]] \
  || ac_fail "AC1: register.sh was copied (excluded by design)"
[[ ! -f "${OPT_DIR}/install.sh" ]] \
  || ac_fail "AC1: install.sh was copied (excluded by design)"
[[ "$(stat -c '%a' "${OPT_DIR}/verbs/jev.sh")" == 755 ]] \
  || ac_fail "AC1: verbs/jev.sh mode is not 755 (got $(stat -c '%a' "${OPT_DIR}/verbs/jev.sh"))"

# Ledger seeded empty, env seeded with exactly the two allowlisted lines.
[[ -f "${LEDGER}" ]] || ac_fail "AC1: ledger missing at ${LEDGER}"
jq -e '.version == 1 and (.accounts | length == 0)' "${LEDGER}" >/dev/null 2>&1 \
  || ac_fail "AC1: ledger is not {version:1, accounts:{}}: $(cat "${LEDGER}")"
[[ -f "${ENV_FILE}" ]] || ac_fail "AC1: porter.env missing at ${ENV_FILE}"
[[ "$(stat -c '%a' "${ENV_FILE}")" == 640 ]] \
  || ac_fail "AC1: porter.env mode is not 640 (got $(stat -c '%a' "${ENV_FILE}"))"
grep -qE '^TYPESAFE_API_KEY=$' "${ENV_FILE}" \
  || ac_fail "AC1: porter.env lacks the TYPESAFE_API_KEY= line"
grep -qE '^JEV_MODEL=jev-1.13.0$' "${ENV_FILE}" \
  || ac_fail "AC1: porter.env lacks the JEV_MODEL=jev-1.13.0 line"
ac_log "AC1: door copied (register.sh/install.sh excluded); ledger + env + drop-in seeded"

# ── AC2: drop-in shape ────────────────────────────────────────────────────────
[[ -f "${DROPIN}" ]] || ac_fail "AC2: drop-in missing at ${DROPIN}"
grep -qF 'Match User porter' "${DROPIN}" \
  || ac_fail "AC2: drop-in lacks Match User porter"
if grep -qE '^AuthorizedKeysCommand' "${DROPIN}"; then
  ac_fail "AC2: drop-in has an unindented ^AuthorizedKeysCommand line"
fi
grep -qF "AuthorizedKeysCommand ${OPT_DIR}/key-command.sh %f %t %k" "${DROPIN}" \
  || ac_fail "AC2: drop-in command path is not prefixed: $(cat "${DROPIN}")"
grep -qF 'AuthorizedKeysCommandUser porter' "${DROPIN}" \
  || ac_fail "AC2: drop-in lacks AuthorizedKeysCommandUser porter"
grep -qF 'PasswordAuthentication no' "${DROPIN}" \
  || ac_fail "AC2: drop-in lacks PasswordAuthentication no"
grep -qF 'AllowTcpForwarding no' "${DROPIN}" \
  || ac_fail "AC2: drop-in lacks AllowTcpForwarding no"
grep -qF 'X11Forwarding no' "${DROPIN}" \
  || ac_fail "AC2: drop-in lacks X11Forwarding no"
grep -qF 'PermitTunnel no' "${DROPIN}" \
  || ac_fail "AC2: drop-in lacks PermitTunnel no"
[[ "$(grep -c '' "${DROPIN}")" == 7 ]] \
  || ac_fail "AC2: drop-in has $(grep -c '' "${DROPIN}") lines, not the exact 7-line Match block"
ac_log "AC2: drop-in is the Match block only (no ^AuthorizedKeysCommand)"

# ── AC3: second run is idempotent ─────────────────────────────────────────────
# Operator state to preserve: a row with non-zero credits, an env file the
# operator filled in and loosened.
jq --arg fp "${FP_A}" \
  '.accounts[$fp] = {fingerprint: $fp, status: "pending", credits: 12,
   name: "tester-1537", admin: false,
   created_at: "2026-01-01T00:00:00Z"}' \
  "${LEDGER}" > "${LEDGER}.tmp" || ac_fail "AC3: cannot seed a credits row"
mv "${LEDGER}.tmp" "${LEDGER}"
printf 'STRIPE_PRICE_ID=p_test_1537\n' >> "${ENV_FILE}"
chmod 666 "${ENV_FILE}"

run_install

[[ "$(jq -r --arg fp "${FP_A}" '(.accounts // {})[$fp].credits // empty' "${LEDGER}")" == 12 ]] \
  || ac_fail "AC3: second run changed ledger credits"
[[ "$(jq -r --arg fp "${FP_A}" '(.accounts // {})[$fp].name // empty' "${LEDGER}")" == "tester-1537" ]] \
  || ac_fail "AC3: second run clobbered the ledger row"
grep -qE '^TYPESAFE_API_KEY=$' "${ENV_FILE}" \
  || ac_fail "AC3: second run changed porter.env contents"
grep -qF 'JEV_MODEL=jev-1.13.0' "${ENV_FILE}" \
  || ac_fail "AC3: second run changed porter.env contents"
grep -qF 'STRIPE_PRICE_ID=p_test_1537' "${ENV_FILE}" \
  || ac_fail "AC3: second run overwrote the operator's env line"
[[ "$(stat -c '%a' "${ENV_FILE}")" == 640 ]] \
  || ac_fail "AC3: env file is not 640 after the second run (got $(stat -c '%a' "${ENV_FILE}"))"
ac_log "AC3: second run preserved credits + env contents; 666 env tightened to 640"

# ── AC4: --admin-key ──────────────────────────────────────────────────────────
run_install --admin-key "${KEYFILE}"

admin_rows="$(jq -r '(.accounts // {}) | to_entries | map(select(.value.admin == true)) | length' "${LEDGER}")"
[[ "${admin_rows}" == 1 ]] || ac_fail "AC4: expected exactly one admin row, got ${admin_rows}"
FP_KEY="$(jq -r '(.accounts // {}) | to_entries | map(select(.value.admin == true)) | (.[0].value.fingerprint // empty)' "${LEDGER}")"
[[ "${FP_KEY}" == "${FP_FROM_KEY}" ]] \
  || ac_fail "AC4: ledger row fingerprint does not match the key (got ${FP_KEY})"
[[ "${FP_KEY}" =~ ^SHA256:[A-Za-z0-9_-]{43}$ ]] \
  || ac_fail "AC4: admin row fingerprint malformed: ${FP_KEY}"

admin="$(jq -r --arg fp "${FP_KEY}" '(.accounts // {})[$fp].admin // empty' "${LEDGER}")"
[[ "${admin}" == true ]] || ac_fail "AC4: --admin-key did not set admin=true (got ${admin})"
credits="$(jq -r --arg fp "${FP_KEY}" '(.accounts // {})[$fp].credits // empty' "${LEDGER}")"
[[ "${credits}" == 0 ]] || ac_fail "AC4: --admin-key changed credits on a fresh row (got ${credits})"
status="$(jq -r --arg fp "${FP_KEY}" '(.accounts // {})[$fp].status // empty' "${LEDGER}")"
[[ "${status}" == pending ]] || ac_fail "AC4: --admin-key touched status (got ${status})"
ac_log "AC4: --admin-key ensured admin row (admin=true, credits=0, status pending)"

# A plain run after must keep the row admin.
run_install
admin="$(jq -r --arg fp "${FP_KEY}" '(.accounts // {})[$fp].admin // empty' "${LEDGER}")"
[[ "${admin}" == true ]] \
  || ac_fail "AC4: later run without --admin-key cleared admin (got ${admin})"
credits="$(jq -r --arg fp "${FP_KEY}" '(.accounts // {})[$fp].credits // empty' "${LEDGER}")"
[[ "${credits}" == 0 ]] || ac_fail "AC4: later run changed credits (got ${credits})"

# Re-run --admin-key on the existing row: admin stays, credits/status untouched.
jq --arg fp "${FP_KEY}" '.accounts[$fp].credits = 5 | .accounts[$fp].status = "active"' \
  "${LEDGER}" > "${LEDGER}.tmp" || ac_fail "AC4: cannot update credits for re-run check"
mv "${LEDGER}.tmp" "${LEDGER}"
run_install --admin-key "${KEYFILE}"
[[ "$(jq -r --arg fp "${FP_KEY}" '(.accounts // {})[$fp].admin' "${LEDGER}")" == true ]] \
  || ac_fail "AC4: re-run --admin-key cleared admin"
[[ "$(jq -r --arg fp "${FP_KEY}" '(.accounts // {})[$fp].credits' "${LEDGER}")" == 5 ]] \
  || ac_fail "AC4: re-run --admin-key reset credits (got $(jq -r --arg fp "${FP_KEY}" '(.accounts // {})[$fp].credits // empty' "${LEDGER}"))"
[[ "$(jq -r --arg fp "${FP_KEY}" '(.accounts // {})[$fp].status' "${LEDGER}")" == "active" ]] \
  || ac_fail "AC4: re-run --admin-key changed status (got $(jq -r --arg fp "${FP_KEY}" '(.accounts // {})[$fp].status // empty' "${LEDGER}"))"
ac_log "AC4: re-run --admin-key kept admin, credits and status intact"

ac_pass
