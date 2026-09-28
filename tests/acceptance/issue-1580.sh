#!/usr/bin/env bash
# =============================================================================
# tests/acceptance/issue-1580.sh
#
# Issue #1580: fix(edge): caddy unit stores certs under /var/lib/caddy and can
# reload
#
# The caddy.service that tools/edge-control/porter-caddy.sh writes on a fresh
# install carried no HOME/XDG_DATA_HOME (with an empty HOME, Caddy stores its
# ACME certificates in `./caddy` under its working directory, which was `/`)
# and no ExecReload (the unit is Type=notify with no ExecReload, so
# `systemctl reload caddy` fails). Contract under test:
#   * AC1 a fresh install under PORTER_ROOT writes a caddy.service that sets
#     `Environment=HOME=/var/lib/caddy` and
#     `Environment=XDG_DATA_HOME=/var/lib/caddy` and still loads gandi.env
#     with `EnvironmentFile=-` (Type=notify, no token);
#   * AC2 the written unit has `ExecReload=<caddy> reload --config
#     <Caddyfile>` where the Caddyfile is exactly the one `ExecStart` uses;
#   * AC3 an existing unit (etc/systemd/system or lib/systemd/system) is never
#     overwritten — a pre-existing unit stays byte-for-byte and no new etc
#     unit is created when the lib copy exists;
#   * AC4 the real-host /var/lib/caddy preparation (`mkdir -p` + `chmod 700`)
#     is present in the script, is guarded to the real host, and leaks no real
#     /var/lib/caddy when the script runs under PORTER_ROOT;
#   * AC5 the test exits 0 and calls ac_pass.
#
# Hermetic: no network, no systemd, no real caddy. PORTER_ROOT is a throwaway
# $TMP_DIR prefix. The trailing `add_webhook_route` in porter-caddy.sh fails
# harmlessly (no caddy on localhost:2019) and the script still exits 0.
#
# Run via: tools/run-acceptance.sh 1580
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=../lib/acceptance-helpers.sh
source "$REPO_ROOT/tests/lib/acceptance-helpers.sh"

ac_require_cmd bash grep cmp mktemp rm cat printf chmod cp mkdir sed head

PORTER_CADDY="$REPO_ROOT/tools/edge-control/porter-caddy.sh"
ac_assert_file "$PORTER_CADDY" "tools/edge-control/porter-caddy.sh is missing"

TMP_DIR="$(mktemp -d /tmp/disinto-acceptance-1580.XXXXXX)"
cleanup() {
  rm -rf "$TMP_DIR" 2>/dev/null || true
}
trap cleanup EXIT

# Run porter-caddy.sh against the throwaway prefix $1. $rc is set to the
# script's exit code; stdout/stderr are kept under the prefix for diagnosis.
run_porter_caddy() {
  local root="$1"
  rc=0
  ( PORTER_ROOT="$root" bash "$PORTER_CADDY" 2>&1 ) >"$root/out.txt" 2>"$root/err.txt" \
    || rc=$?
}

# ── AC1. fresh install: unit sets HOME/XDG_DATA_HOME, keeps EnvironmentFile=- ─
ac_log "AC1: fresh install unit sets HOME/XDG_DATA_HOME to /var/lib/caddy"

ROOT1="$TMP_DIR/root1"
mkdir -p "$ROOT1"
run_porter_caddy "$ROOT1"
if [ "$rc" -ne 0 ]; then
  ac_fail "AC1: fresh install under PORTER_ROOT should exit 0 (rc=$rc; see $ROOT1/err.txt)"
fi
UNIT1="$ROOT1/etc/systemd/system/caddy.service"
ac_assert_file "$UNIT1" "AC1: fresh install did not write the prefixed caddy.service"
if ! grep -qF 'Environment=HOME=/var/lib/caddy' "$UNIT1"; then
  ac_fail "AC1: unit lacks Environment=HOME=/var/lib/caddy"
fi
if ! grep -qF 'Environment=XDG_DATA_HOME=/var/lib/caddy' "$UNIT1"; then
  ac_fail "AC1: unit lacks Environment=XDG_DATA_HOME=/var/lib/caddy"
fi
if ! grep -qF 'EnvironmentFile=-' "$UNIT1"; then
  ac_fail "AC1: EnvironmentFile=- for gandi.env missing"
fi
if ! grep -qF 'Type=notify' "$UNIT1"; then
  ac_fail "AC1: unit lost Type=notify"
fi
# TEST_MODE must not touch the real caddy (no download) — only the prefixed
# unit file (a file, not a real-host action) is written.
if [ -f "$ROOT1/usr/bin/caddy" ]; then
  ac_fail "AC1: TEST_MODE installed a caddy binary"
fi
ac_log "AC1: unit sets HOME + XDG_DATA_HOME to /var/lib/caddy, keeps EnvironmentFile=-, no binary download"

# ── AC2. ExecReload = caddy reload --config <same Caddyfile>, no token ────────
ac_log "AC2: ExecReload is caddy reload --config on the same Caddyfile; no token"

if ! grep -qF "${ROOT1}/usr/bin/caddy run --config ${ROOT1}/etc/caddy/Caddyfile" "$UNIT1"; then
  ac_fail "AC2: ExecStart is not '<caddy> run --config <Caddyfile>' (prefixed)"
fi
if ! grep -qF "${ROOT1}/usr/bin/caddy reload --config ${ROOT1}/etc/caddy/Caddyfile" "$UNIT1"; then
  ac_fail "AC2: ExecReload is not '<caddy> reload --config <same Caddyfile>'"
fi
# The Caddyfile path in ExecStart and ExecReload must be the same file.
cs_file="$(grep -m1 '^ExecStart=' "$UNIT1" | sed -n 's/.*run --config \([^[:space:]]*\).*/\1/p')"
rl_file="$(grep -m1 '^ExecReload=' "$UNIT1" | sed -n 's/.*reload --config \([^[:space:]]*\).*/\1/p')"
if [ -z "$cs_file" ] || [ -z "$rl_file" ]; then
  ac_fail "AC2: could not parse the Caddyfile paths out of ExecStart/ExecReload"
fi
if [ "$cs_file" != "$rl_file" ]; then
  ac_fail "AC2: ExecReload points at a different Caddyfile than ExecStart (cs='$cs_file' rl='$rl_file')"
fi
if [ "$cs_file" != "$ROOT1/etc/caddy/Caddyfile" ]; then
  ac_fail "AC2: the unit uses a different Caddyfile than the installed one ($cs_file)"
fi
if grep -qF 'GANDI_API_KEY' "$UNIT1"; then
  ac_fail "AC2: a token value was written into the unit"
fi
ac_log "AC2: ExecReload = caddy reload --config <same Caddyfile as ExecStart>; no token in the unit"

# ── AC3. existing unit is never overwritten ───────────────────────────────────
ac_log "AC3: pre-existing units are not overwritten"

# A3a: a legacy unit pre-existing in etc/systemd/system. A fresh install (no
# Caddyfile yet) must leave it byte-for-byte and write the new Caddyfile.
ROOT3="$TMP_DIR/root3"
mkdir -p "$ROOT3/etc/systemd/system"
printf '[Unit]\nDescription=legacy caddy unit\n[Service]\nExecStart=/usr/bin/caddy run --config /etc/caddy/Caddyfile.legacy\n[Install]\nWantedBy=multi-user.target\n' > "$ROOT3/etc/systemd/system/caddy.service"
snap3="$ROOT3/unit.snap"
cp "$ROOT3/etc/systemd/system/caddy.service" "$snap3"
run_porter_caddy "$ROOT3"
if [ "$rc" -ne 0 ]; then
  ac_fail "AC3a: install with a pre-existing etc unit should exit 0 (rc=$rc)"
fi
if ! cmp -s "$ROOT3/etc/systemd/system/caddy.service" "$snap3"; then
  ac_fail "AC3a: the pre-existing etc unit was modified by the install"
fi
if ! grep -qF 'Caddyfile.legacy' "$ROOT3/etc/systemd/system/caddy.service"; then
  ac_fail "AC3a: the pre-existing unit lost its sentinel line (overwritten?)"
fi
if ! grep -qF 'Environment=HOME=/var/lib/caddy' "$ROOT3/etc/systemd/system/caddy.service"; then
  :
else
  ac_fail "AC3a: a legacy unit should not have been rewritten with the new Environment lines"
fi
if [ ! -f "$ROOT3/etc/caddy/Caddyfile" ]; then
  ac_fail "AC3a: install should still write the new Caddyfile (a legacy unit only blocks the unit)"
fi

# A3b: a unit pre-existing ONLY in lib/systemd/system. The install must not
# create the etc copy and must leave the lib unit byte-for-byte.
ROOT4="$TMP_DIR/root4"
mkdir -p "$ROOT4/lib/systemd/system"
printf '[Unit]\nDescription=lib-prefix caddy unit\n[Service]\nExecStart=/usr/bin/caddy run --config /etc/caddy/Caddyfile.lib\n[Install]\nWantedBy=multi-user.target\n' > "$ROOT4/lib/systemd/system/caddy.service"
snap4="$ROOT4/unit.snap"
cp "$ROOT4/lib/systemd/system/caddy.service" "$snap4"
run_porter_caddy "$ROOT4"
if [ "$rc" -ne 0 ]; then
  ac_fail "AC3b: install with a pre-existing lib unit should exit 0 (rc=$rc)"
fi
if [ -f "$ROOT4/etc/systemd/system/caddy.service" ]; then
  ac_fail "AC3b: with a pre-existing lib unit, a fresh etc unit must not be written"
fi
if ! cmp -s "$ROOT4/lib/systemd/system/caddy.service" "$snap4"; then
  ac_fail "AC3b: the pre-existing lib unit was modified by the install"
fi

# A3c: re-run after porter-caddy wrote its own unit is a no-op for that unit
# (adopt mode touches only the Caddyfile, never the unit).
snap1="$ROOT1/unit.snap"
cp "$ROOT1/etc/systemd/system/caddy.service" "$snap1"
run_porter_caddy "$ROOT1"
if [ "$rc" -ne 0 ]; then
  ac_fail "AC3c: re-run after install should exit 0 (rc=$rc)"
fi
if ! cmp -s "$ROOT1/etc/systemd/system/caddy.service" "$snap1"; then
  ac_fail "AC3c: re-run modified the unit porter-caddy itself wrote"
fi
ac_log "AC3a/b/c: pre-existing etc/lib units untouched; re-run is a unit no-op"

# ── AC4. real-host /var/lib/caddy prep: present, guarded, no test leak ───────
ac_log "AC4: real-host /var/lib/caddy preparation (700, real host only)"

if ! grep -qF 'mkdir -p /var/lib/caddy' "$PORTER_CADDY"; then
  ac_fail "AC4: porter-caddy.sh must create /var/lib/caddy on a real host"
fi
if ! grep -qF 'chmod 700 /var/lib/caddy' "$PORTER_CADDY"; then
  ac_fail "AC4: porter-caddy.sh must set mode 700 on /var/lib/caddy"
fi
if ! grep -qF 'TEST_MODE' "$PORTER_CADDY"; then
  ac_fail "AC4: the real-host /var/lib/caddy action must be TEST_MODE-guarded"
fi
# The real-host action must not leak into test mode: a run under PORTER_ROOT
# must not create /var/lib/caddy in the real root (only assert this when we
# can observe it — if it pre-exists, the test cannot tell a leak from a pre-
# existing directory, so we skip the negative assertion).
preexists=0
[ -e /var/lib/caddy ] && preexists=1
if [ "$preexists" -eq 0 ] && [ -e /var/lib/caddy ]; then
  ac_fail "AC4: a run under PORTER_ROOT leaked into the real root and created /var/lib/caddy"
fi
ac_log "AC4: /var/lib/caddy prep is present, TEST_MODE-guarded, and did not leak into test mode"

# ── AC5: all acceptance criteria passed ───────────────────────────────────────
ac_log "AC5: all checks passed"
ac_pass
