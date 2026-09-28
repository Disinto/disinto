#!/usr/bin/env bash
# =============================================================================
# tests/acceptance/issue-1579.sh
#
# Issue #1579: fix(edge): wildcard certificate waits for the Gandi nameservers
#
# The wildcard site porter-caddy.sh wrote on a fresh install was
# `tls { dns gandi {env.GANDI_API_KEY} }` — no propagation window. Caddy's
# solver gave up after about two minutes with
# "timed out waiting for record to fully propagate", even when the TXT record
# was already on the Gandi nameservers, so the wildcard cert was not issued.
#
# This change makes a fresh install (no Caddyfile, no caddy binary) write the
# same Caddyfile shape with the wildcard block turned into the ACME issuer:
#   * the same global block (`admin localhost:2019`) and the same `extra.d`
#     import;
#   * ONE site block for `*.${DOMAIN_SUFFIX}` (default disinto.ai) whose only
#     directive is now
#       tls acme {
#         dns gandi {env.GANDI_API_KEY}
#         propagation_delay 20s
#         propagation_timeout 10m
#         resolvers ns-163-a.gandi.net ns-102-b.gandi.net ns-91-c.gandi.net
#       }
#     — no other issuer, no staging CA, no self/, apex, or customer site,
#     no catch-all :80/:443;
#   * the ADOPT path is untouched: an existing Caddyfile is still not
#     rewritten (adopt inserts `admin localhost:2019` only when missing; site
#     blocks stay byte-for-byte).
#
# Contract under test (#1579):
#   * AC1 a fresh PORTER_ROOT install writes a Caddyfile that contains
#     `propagation_timeout 10m` and the Gandi resolver
#     `ns-163-a.gandi.net` (plus the 20s delay, the full resolver list,
#     `dns gandi {env.GANDI_API_KEY}`, and the `tls acme` issuer block) and
#     still carries `admin localhost:2019` and the `extra.d` import;
#   * AC2 the same Caddyfile contains no `acme-staging` (no staging CA was
#     added) and no `self.`/apex/reverse_proxy/catch-all site; the only site
#     block is the wildcard `*.disinto.ai`;
#   * AC3 an existing Caddyfile passed through adopt is unchanged;
#   * AC4 the test exits 0 and calls ac_pass.
#
# Hermetic: no network, no real Caddy. PORTER_ROOT is a throwaway $TMP_DIR
# subdir; caddy/systemctl are call-recording stubs (TEST_MODE skips all real-
# host actions). The final /stripe/webhook add is non-fatal when the admin
# API is unreachable, as on a live fresh install before `systemctl` runs.
#
# Run via: tools/run-acceptance.sh 1579
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

# Source-level sanity: the new issuer fields must be present, no staging CA
# (acme-staging) anywhere, and no install.sh call.
if ! grep -qF 'propagation_timeout 10m' "$PORTER_CADDY"; then
  ac_fail "porter-caddy.sh must emit propagation_timeout 10m"
fi
if ! grep -qF 'ns-163-a.gandi.net' "$PORTER_CADDY"; then
  ac_fail "porter-caddy.sh must emit resolver ns-163-a.gandi.net"
fi
if grep -qF 'acme-staging' "$PORTER_CADDY"; then
  ac_fail "porter-caddy.sh must not add a staging CA (acme-staging)"
fi
if grep -vE '^[[:space:]]*#' "$PORTER_CADDY" 2>/dev/null \
    | grep -EqE '(^|[^./])install\.sh\b'; then
  ac_fail "porter-caddy.sh must not call install.sh"
fi

TMP_DIR="$(mktemp -d /tmp/disinto-acceptance-1579.XXXXXX)"
cleanup() {
  rm -rf "$TMP_DIR" 2>/dev/null || true
}
trap cleanup EXIT

# ── Stubs ────────────────────────────────────────────────────────────────────
# A `caddy` binary and a `systemctl` that record calls and exit 0. A
# PORTER_ROOT run must call neither (TEST_MODE skips every real-host action);
# the stubs prove it.
STUB_DIR="$TMP_DIR/stub"
mkdir -p "$STUB_DIR"
SYSCTL_1579_CALLS="$TMP_DIR/sysctl-calls.log"
CADDY_1579_CALLS="$TMP_DIR/caddy-calls.log"
: > "$SYSCTL_1579_CALLS"
: > "$CADDY_1579_CALLS"
cat > "$STUB_DIR/caddy" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${CADDY_1579_CALLS}"
exit 0
STUB
cat > "$STUB_DIR/systemctl" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${SYSCTL_1579_CALLS}"
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
    env PATH="$STUB_DIR:$PATH" \
      PORTER_ROOT="$1" DOMAIN_SUFFIX=disinto.ai \
      bash "$PORTER_CADDY"
  } >"$out_file" 2>"$err_file" || rc=$?
}

# ── AC1: fresh install Caddyfile carries the long-propagation ACME issuer ────
ROOT1="$TMP_DIR/root1"
run_install "$ROOT1"
if [ "$rc" -ne 0 ]; then
  ac_fail "AC1: fresh PORTER_ROOT install should exit 0 (rc=$rc)"
fi
CADDYFILE="$ROOT1/etc/caddy/Caddyfile"
if [ ! -f "$CADDYFILE" ]; then
  ac_fail "AC1: Caddyfile missing after fresh install"
fi
# The issuer fields the issue requires (literal strings).
if ! grep -qF 'propagation_timeout 10m' "$CADDYFILE"; then
  ac_fail "AC1: propagation_timeout 10m missing from Caddyfile"
fi
if ! grep -qF 'ns-163-a.gandi.net' "$CADDYFILE"; then
  ac_fail "AC1: resolver ns-163-a.gandi.net missing from Caddyfile"
fi
if ! grep -qF 'propagation_delay 20s' "$CADDYFILE"; then
  ac_fail "AC1: propagation_delay 20s missing from Caddyfile"
fi
if ! grep -qF 'dns gandi {env.GANDI_API_KEY}' "$CADDYFILE"; then
  ac_fail "AC1: dns gandi {env.GANDI_API_KEY} missing from Caddyfile"
fi
if ! grep -qF 'resolvers ns-163-a.gandi.net ns-102-b.gandi.net ns-91-c.gandi.net' "$CADDYFILE"; then
  ac_fail "AC1: resolver list missing from Caddyfile"
fi
# The single tls block is now the ACME issuer; exactly one tls block.
if ! grep -qF 'tls acme {' "$CADDYFILE"; then
  ac_fail "AC1: tls acme issuer block missing from Caddyfile"
fi
if [ "$(grep -cF 'tls acme {' "$CADDYFILE" || true)" -ne 1 ]; then
  ac_fail "AC1: expected exactly one tls acme block (no second issuer), got a second"
fi
# admin + import still present.
if ! grep -Eq 'admin[[:space:]]+localhost:2019' "$CADDYFILE"; then
  ac_fail "AC1: admin localhost:2019 missing from Caddyfile"
fi
if ! grep -qE 'import[[:space:]]+.*extra\.d/\*\.caddy' "$CADDYFILE"; then
  ac_fail "AC1: extra.d import missing from Caddyfile"
fi
ac_log "AC1: fresh Caddyfile has the tls acme issuer with 10m propagation timeout and Gandi resolvers"

# ── AC2: no staging/self/apex site; the wildcard is the only site ────────────
ROOT2="$TMP_DIR/root2"
: > "$SYSCTL_1579_CALLS"
: > "$CADDY_1579_CALLS"
run_install "$ROOT2"
if [ "$rc" -ne 0 ]; then
  ac_fail "AC2: fresh PORTER_ROOT install should exit 0 (rc=$rc)"
fi
CADDYFILE="$ROOT2/etc/caddy/Caddyfile"
if grep -qF 'acme-staging' "$CADDYFILE"; then
  ac_fail "AC2: staging CA (acme-staging) present in fresh Caddyfile (forbidden)"
fi
if grep -qF 'self.' "$CADDYFILE"; then
  ac_fail "AC2: 'self.' present in fresh Caddyfile (forbidden)"
fi
if grep -Eq '^[[:space:]]*self[[:space:]]*\{' "$CADDYFILE"; then
  ac_fail "AC2: self site block present (forbidden)"
fi
if grep -Eq '^[[:space:]]*(disinto\.ai|www\.disinto\.ai)[[:space:]]*\{' "$CADDYFILE"; then
  ac_fail "AC2: apex or www site block present (forbidden)"
fi
if grep -qF 'reverse_proxy' "$CADDYFILE"; then
  ac_fail "AC2: reverse_proxy in fresh Caddyfile (forbidden)"
fi
if grep -qE '^[[:space:]]*(:80|:443)[[:space:]]*\{' "$CADDYFILE"; then
  ac_fail "AC2: catch-all :80/:443 site present (forbidden)"
fi
# Exactly one site block: the wildcard *.disinto.ai — the only column-0 host
# block (the nested `tls acme {` / `dns gandi {` braces are not counted).
n_sites=$(grep -cE '^[A-Za-z0-9*.-]+[[:space:]]*\{' "$CADDYFILE" || true)
if [ "$n_sites" -ne 1 ]; then
  ac_fail "AC2: expected exactly one site block (the wildcard), found $n_sites"
fi
if ! grep -qF '*.disinto.ai {' "$CADDYFILE"; then
  ac_fail "AC2: the single site block is not *.disinto.ai"
fi
if [ ! -d "$ROOT2/etc/caddy/extra.d" ]; then
  ac_fail "AC2: extra.d directory missing after fresh install"
fi
ac_log "AC2: no staging/self/apex/catch-all site; *.disinto.ai is the only site block"

# ── AC3a: adopt leaves an existing Caddyfile byte-for-byte unchanged ─────────
# A complete Caddyfile (admin listener already configured): adopt must insert
# nothing and leave every byte — sites, block, everything — untouched.
ROOT3="$TMP_DIR/root3"
mkdir -p "$ROOT3/etc/caddy"
cat > "$ROOT3/etc/caddy/Caddyfile" <<'CADDYFILE'
{
  admin localhost:2019
}

*.disinto.ai {
  tls acme {
    dns gandi {env.GANDI_API_KEY}
    propagation_delay 20s
    propagation_timeout 10m
    resolvers ns-163-a.gandi.net ns-102-b.gandi.net ns-91-c.gandi.net
  }
}
CADDYFILE
snap="$ROOT3/Caddyfile.snap"
cp "$ROOT3/etc/caddy/Caddyfile" "$snap"
: > "$SYSCTL_1579_CALLS"
: > "$CADDY_1579_CALLS"
{
  env PATH="$STUB_DIR:$PATH" PORTER_ROOT="$ROOT3" \
    bash "$PORTER_CADDY"
} >"$ROOT3/adopts.out" 2>"$ROOT3/adopts.err" || rc=$?
if [ "$rc" -ne 0 ]; then
  ac_fail "AC3a: adopt on an admin-equipped Caddyfile should exit 0 (rc=$rc)"
fi
if ! cmp -s "$ROOT3/etc/caddy/Caddyfile" "$snap"; then
  ac_fail "AC3a: adopt changed the Caddyfile when the admin listener was already configured"
fi
ac_log "AC3a: adopt left a complete Caddyfile byte-for-byte unchanged"

# ── AC3b: adopt inserts only the admin line; the site block stays byte-for-byte ──
# (the adopt path must never rewrite an existing Caddyfile's sites)
ROOT4="$TMP_DIR/root4"
mkdir -p "$ROOT4/etc/caddy"
cat > "$ROOT4/etc/caddy/Caddyfile" <<'CADDYFILE'
{
}

self.disinto.ai {
  reverse_proxy 127.0.0.1:20000
}
CADDYFILE
site_before="$(awk '/^[[:space:]]*[^{}]+[[:space:]]*\{/{flag=1} flag{print}' "$ROOT4/etc/caddy/Caddyfile")"
: > "$SYSCTL_1579_CALLS"
: > "$CADDY_1579_CALLS"
{
  env PATH="$STUB_DIR:$PATH" PORTER_ROOT="$ROOT4" \
    bash "$PORTER_CADDY"
} >"$ROOT4/adopts.out" 2>"$ROOT4/adopts.err" || rc=$?
if [ "$rc" -ne 0 ]; then
  ac_fail "AC3b: adopt inserting the admin line should exit 0 (rc=$rc)"
fi
if ! grep -Eq 'admin[[:space:]]+localhost:2019' "$ROOT4/etc/caddy/Caddyfile"; then
  ac_fail "AC3b: admin listener not inserted into global block"
fi
site_after="$(awk '/^[[:space:]]*[^{}]+[[:space:]]*\{/{flag=1} flag{print}' "$ROOT4/etc/caddy/Caddyfile")"
if [ "$site_before" != "$site_after" ]; then
  ac_fail "AC3b: adopt altered the site region of an existing Caddyfile"
fi
site_hosts=$(printf '%s\n' "$site_after" \
    | grep -oE '^[[:space:]]*[A-Za-z0-9.-]*[[:space:]]*\{' | awk '{print $1}')
if [ "$site_hosts" != "self.disinto.ai" ]; then
  ac_fail "AC3b: a new site was written by adopt (found: $site_hosts)"
fi
ac_log "AC3b: adopt inserted only the admin line; site blocks untouched"

# ── AC4: all checks passed ───────────────────────────────────────────────────
ac_log "AC4: all checks passed"
ac_pass
