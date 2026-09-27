#!/usr/bin/env bash
# =============================================================================
# tests/acceptance/issue-1571.sh
#
# Issue #1571: feat(edge): fresh Caddy listens on 443 with a wildcard cert
#
# A fresh porter-caddy.sh wrote a Caddyfile with only `admin localhost:2019`
# and the `extra.d` import — nothing listened on 443, no cert existed, and
# add_route (which looks for a server on :443) would never find one, so the
# first approve could not add a route. The script also never started Caddy or
# wrote its systemd unit.
#
# This change makes a fresh install (no Caddyfile, no caddy binary) write:
#   * the same global block (`admin localhost:2019`) and the same `extra.d`
#     import;
#   * ONE site block for `*.${DOMAIN_SUFFIX}` (default disinto.ai) whose only
#     directive is the wildcard cert
#     (`tls { dns gandi {env.GANDI_API_KEY} }`) — no reverse_proxy, no
#     self/, apex, or customer site, no catch-all :80/:443;
#   * `${prefix}etc/systemd/system/caddy.service` only when no `caddy.service`
#     already exists under `${prefix}etc/systemd/system` or
#     `${prefix}lib/systemd/system` (an existing unit is never overwritten).
#     The unit runs `${CADDY_BIN} run --config` the Caddyfile, loads
#     `${prefix}etc/caddy/gandi.env` with `EnvironmentFile=-` so a missing
#     token never stops the process, and contains no token.
#   * on a real host (PORTER_ROOT unset): `caddy validate`, then only on a
#     passing validate `systemctl enable --now caddy`. A failed validate
#     exits non-zero and never enables. With PORTER_ROOT set (acceptance
#     tests) files go under the prefix and no `caddy`/`systemctl` action is
#     taken.
#
# The adopt path is untouched: an existing Caddyfile is still not overwritten
# and its site blocks stay byte-for-byte; adopt never writes a unit.
#
# Contract under test (#1571):
#   * AC1 a fresh PORTER_ROOT install writes a `*.disinto.ai` site with `tls`
#     and `dns gandi`, and the file has neither a `self.disinto.ai` site nor
#     an apex site (and no catch-all :80/:443);
#   * AC2 the same Caddyfile still has `admin localhost:2019` and the `extra.d`
#     import;
#   * AC3 the unit file is written only when none exists (both etc and lib
#     locations); its ExecStart is `caddy run` and it contains no token;
#   * AC4 a PORTER_ROOT install does not invoke `systemctl` (nor the caddy
#     binary);
#   * AC5 the test exits 0 and calls ac_pass.
#
# Hermetic: no network, no real Caddy, no systemd. PORTER_ROOT is a throwaway
# $TMP_DIR subdir; caddy/systemctl are call-recording stubs.
#
# Run via: tools/run-acceptance.sh 1571
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=../lib/acceptance-helpers.sh
source "$REPO_ROOT/tests/lib/acceptance-helpers.sh"
# shellcheck source=../lib/caddy-stub.sh
source "$REPO_ROOT/tests/lib/caddy-stub.sh"

ac_require_cmd bash jq grep cmp mktemp rm cat sed awk printf chmod cp head
ac_require_cmd mktemp

PORTER_CADDY="$REPO_ROOT/tools/edge-control/porter-caddy.sh"
ac_assert_file "$PORTER_CADDY" "tools/edge-control/porter-caddy.sh is missing"
CADDY_LIB="$REPO_ROOT/tools/edge-control/lib/caddy.sh"
ac_assert_file "$CADDY_LIB" "tools/edge-control/lib/caddy.sh is missing"

# Source-level sanity: porter-caddy.sh must not invoke install.sh and must
# keep the admin listener / import / wildcard cert / systemd enable.
if grep -vE '^[[:space:]]*#' "$PORTER_CADDY" 2>/dev/null \
    | grep -EqE '(^|[^./])install\.sh\b'; then
  ac_fail "porter-caddy.sh must not call install.sh"
fi
if ! grep -qF 'systemctl enable --now caddy' "$PORTER_CADDY"; then
  ac_fail "porter-caddy.sh must enable caddy via systemctl on a real host"
fi
if ! grep -qF 'env.GANDI_API_KEY' "$PORTER_CADDY"; then
  ac_fail "porter-caddy.sh must reference env.GANDI_API_KEY in the cert"
fi

TMP_DIR="$(mktemp -d /tmp/disinto-acceptance-1571.XXXXXX)"
rc=0
cleanup() {
  rm -rf "$TMP_DIR" 2>/dev/null || true
}
trap cleanup EXIT

# ── Stubs ────────────────────────────────────────────────────────────────────
# A `caddy` binary that records every invocation and a `systemctl` that does
# the same. A fresh PORTER_ROOT run must call neither (TEST_MODE skips all
# real-host actions).
STUB_DIR="$TMP_DIR/stub"
mkdir -p "$STUB_DIR"
export SYSCTL_1571_CALLS="$TMP_DIR/sysctl-calls.log"
export CADDY_1571_CALLS="$TMP_DIR/caddy-calls.log"
: > "$SYSCTL_1571_CALLS"
: > "$CADDY_1571_CALLS"
cat > "$STUB_DIR/caddy" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${CADDY_1571_CALLS}"
exit 0
STUB
cat > "$STUB_DIR/systemctl" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${SYSCTL_1571_CALLS}"
exit 0
STUB
chmod +x "$STUB_DIR/caddy" "$STUB_DIR/systemctl"

# Fresh-install driver: runs porter-caddy.sh in INSTALL mode under PORTER_ROOT
# ($1) with the stubs on PATH.
run_install() {
  local out_file err_file
  out_file="$TMP_DIR/out.txt"
  err_file="$TMP_DIR/err.txt"
  rc=0
  {
    # env: force the vars into the child process (a bare assignment in a
    # brace group would not export them to `bash "$PORTER_CADDY"`).
    env PATH="$STUB_DIR:$PATH" \
      PORTER_ROOT="$1" DOMAIN_SUFFIX=disinto.ai \
      bash "$PORTER_CADDY"
  } >"$out_file" 2>"$err_file" || rc=$?
}

# ── AC1/AC2: fresh install Caddyfile content ─────────────────────────────────
ROOT1="$TMP_DIR/root1"
run_install "$ROOT1"
if [ "$rc" -ne 0 ]; then
  ac_fail "AC1: fresh PORTER_ROOT install should exit 0 (rc=$rc)"
fi
CADDYFILE="$ROOT1/etc/caddy/Caddyfile"
if [ ! -f "$CADDYFILE" ]; then
  ac_fail "AC1: Caddyfile missing after fresh install"
fi

# AC2: admin listener + extra.d import still present.
if ! grep -Eq 'admin[[:space:]]+localhost:2019' "$CADDYFILE"; then
  ac_fail "AC2: admin localhost:2019 missing from Caddyfile"
fi
if ! grep -qE 'import[[:space:]]+.*extra\.d/\*\.caddy' "$CADDYFILE"; then
  ac_fail "AC2: extra.d import missing from Caddyfile"
fi

# AC1: the *.disinto.ai site with tls + dns gandi + env ref, no self/apex.
if ! grep -Fq '*.disinto.ai {' "$CADDYFILE"; then
  ac_fail "AC1: *.disinto.ai site block missing from Caddyfile"
fi
if ! grep -qF 'tls {' "$CADDYFILE"; then
  ac_fail "AC1: tls block missing from Caddyfile"
fi
if ! grep -qF 'dns gandi' "$CADDYFILE"; then
  ac_fail "AC1: dns gandi directive missing from Caddyfile"
fi
if ! grep -qF 'env.GANDI_API_KEY' "$CADDYFILE"; then
  ac_fail "AC1: env.GANDI_API_KEY reference missing from Caddyfile"
fi
if grep -Eq '^[[:space:]]*self[[:space:]]*\{' "$CADDYFILE"; then
  ac_fail "AC1: self.disinto.ai site block present (forbidden)"
fi
if grep -Eq '^[[:space:]]*(disinto\.ai|www\.disinto\.ai)[[:space:]]*\{' "$CADDYFILE"; then
  ac_fail "AC1: apex or www site block present (forbidden)"
fi
if grep -qF 'reverse_proxy' "$CADDYFILE"; then
  ac_fail "AC1: reverse_proxy in fresh Caddyfile (forbidden)"
fi
if grep -qE '^[[:space:]]*(:80|:443)[[:space:]]*\{' "$CADDYFILE"; then
  ac_fail "AC1: catch-all :80/:443 site present (forbidden)"
fi
if grep -qF ':80, :443' "$CADDYFILE"; then
  ac_fail "AC1: catch-all ':80, :443' line present (forbidden)"
fi
if [ ! -d "$ROOT1/etc/caddy/extra.d" ]; then
  ac_fail "AC2: extra.d directory missing after fresh install"
fi
ac_log "AC1/AC2: fresh Caddyfile has *.disinto.ai tls gandi site + admin + import, no self/apex/catch-all"

# ── AC3: unit written only when none exists, right shape, no token ──────────
UNIT1="$ROOT1/etc/systemd/system/caddy.service"
if [ ! -f "$UNIT1" ]; then
  ac_fail "AC3: caddy.service not written under the prefix on fresh install"
fi
# `caddy run --config` appears only on the ExecStart line of the unit.
if ! grep -qF 'caddy run --config' "$UNIT1"; then
  ac_fail "AC3: unit ExecStart is not 'caddy run --config ...'"
fi
if ! grep -qF 'EnvironmentFile=-' "$UNIT1"; then
  ac_fail "AC3: unit must load gandi.env with EnvironmentFile=-"
fi
if grep -qF 'GANDI_API_KEY=' "$UNIT1"; then
  ac_fail "AC3: token value written into the unit"
fi
if ! grep -qF "$ROOT1/etc/caddy/gandi.env" "$UNIT1"; then
  ac_fail "AC3: unit must reference the prefixed gandi.env"
fi
if ! grep -qF "$ROOT1/usr/bin/caddy" "$UNIT1"; then
  ac_fail "AC3: unit must exec the prefixed caddy binary"
fi
ac_log "AC3a: unit written with caddy run --config + EnvironmentFile=-, no token"

# AC3b: a pre-existing etc unit is never overwritten.
ROOT2="$TMP_DIR/root2"
mkdir -p "$ROOT2/etc/systemd/system"
printf '# marker-1571-etc\n' > "$ROOT2/etc/systemd/system/caddy.service"
run_install "$ROOT2"
if [ "$rc" -ne 0 ]; then
  ac_fail "AC3: install with pre-existing etc unit should exit 0 (rc=$rc)"
fi
UNIT2="$ROOT2/etc/systemd/system/caddy.service"
if ! grep -qF 'marker-1571-etc' "$UNIT2"; then
  ac_fail "AC3: pre-existing etc unit was overwritten"
fi

# AC3c: a pre-existing lib unit also blocks the write (etc stays absent).
ROOT3="$TMP_DIR/root3"
mkdir -p "$ROOT3/lib/systemd/system"
printf '# marker-1571-lib\n' > "$ROOT3/lib/systemd/system/caddy.service"
run_install "$ROOT3"
if [ "$rc" -ne 0 ]; then
  ac_fail "AC3: install with pre-existing lib unit should exit 0 (rc=$rc)"
fi
if [ -f "$ROOT3/etc/systemd/system/caddy.service" ]; then
  ac_fail "AC3: etc unit written when a lib unit pre-exists"
fi
if ! grep -qF 'marker-1571-lib' "$ROOT3/lib/systemd/system/caddy.service"; then
  ac_fail "AC3: pre-existing lib unit was overwritten"
fi
ac_log "AC3b/c: existing units (etc and lib) are preserved; no overwrite"

# ── AC4: PORTER_ROOT does not invoke systemctl (or the caddy binary) ────────
: > "$SYSCTL_1571_CALLS"
: > "$CADDY_1571_CALLS"
ROOT4="$TMP_DIR/root4"
run_install "$ROOT4"
if [ "$rc" -ne 0 ]; then
  ac_fail "AC4: PORTER_ROOT install should exit 0 (rc=$rc)"
fi
if [ -s "$SYSCTL_1571_CALLS" ]; then
  ac_fail "AC4: systemctl invoked during a PORTER_ROOT run"
fi
if [ -s "$CADDY_1571_CALLS" ]; then
  ac_fail "AC4: caddy binary invoked during a PORTER_ROOT run"
fi
ac_log "AC4: no systemctl / caddy calls under PORTER_ROOT"

# ── AC5: all checks passed ───────────────────────────────────────────────────
ac_log "AC5: all checks passed"
ac_pass