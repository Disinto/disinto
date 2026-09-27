#!/usr/bin/env bash
# =============================================================================
# tests/acceptance/issue-1576.sh
#
# Issue #1576: fix(edge): detect the Gandi plugin with list-modules.
#
# porter-caddy.sh::install_caddy_binary rejected a good Caddy binary: it ran
# `caddy version` and grep'd `gandi`. Caddy 2.11.4 prints only the version
# line — the plugin's presence is in `caddy list-modules` (a line
# `dns.providers.gandi`). A fresh install died on that check and the binary
# was never installed. The fix:
#   * `install_caddy_binary` accepts the downloaded binary when `list-modules`
#     prints `dns.providers.gandi`;
#   * it no longer requires `caddy version` to contain `gandi`;
#   * if `list-modules` lacks that line it deletes the temp binary and exits
#     non-zero (as before).
#
# Contract under test (#1576):
#   * AC1: a stub caddy whose `version` output has no `gandi` and whose
#           `list-modules` prints `dns.providers.gandi` is installed (the
#           binary lands at the CADDY_BIN path);
#   * AC2: a stub caddy whose `list-modules` lacks `dns.providers.gandi` is
#           rejected (non-zero) and not installed (nothing lands at CADDY_BIN);
#   * AC3: the test exits 0 and calls ac_pass.
#
# Hermetic: no network. `install_caddy_binary` is a root-script function (not a
# lib, so porter-caddy.sh cannot be sourced without running its main), so it is
# extracted with ac_extract_fn and run in a throwaway subshell against a fake
# `curl` (which "downloads" a fake caddy binary) and a fake caddy binary that
# responds to `version` / `list-modules`. Each AC uses its own throwaway root so
# an earlier install can never mask a later rejection.
#
# Run via: tools/run-acceptance.sh 1576
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/../.." && pwd)"
# shellcheck source=../lib/acceptance-helpers.sh
source "$REPO_ROOT/tests/lib/acceptance-helpers.sh"

ac_require_cmd bash awk grep mktemp rm cp printf chmod mkdir cat

PORTER_CADDY="$REPO_ROOT/tools/edge-control/porter-caddy.sh"
ac_assert_file "$PORTER_CADDY" "tools/edge-control/porter-caddy.sh is missing"

# ── Extract the decision function (no main, so we cannot source the file) ────
fn_src="$(ac_extract_fn "install_caddy_binary" "$PORTER_CADDY")"
[ -n "$fn_src" ] \
  || ac_fail "could not extract install_caddy_binary() from ${PORTER_CADDY}"

# Static guard: the detection must now key on `list-modules` / `dns.providers.
# gandi`, and the old `version ... grep ... gandi` check must be gone. (The
# behavioural ACs prove the runtime effect; these assert the source.)
printf '%s\n' "$fn_src" | grep -Eq "list-modules" \
  || ac_fail "AC1: install_caddy_binary must call caddy list-modules to detect the gandi plugin"
printf '%s\n' "$fn_src" | grep -qF "dns.providers.gandi" \
  || ac_fail "AC1: install_caddy_binary must require dns.providers.gandi from list-modules"
if printf '%s\n' "$fn_src" | grep -qiE "version.*grep.*gandi"; then
  ac_fail "AC1: install_caddy_binary must not key on caddy version for the gandi check"
fi
ac_log "issue-1576: extracted install_caddy_binary; static checks (list-modules / dns.providers.gandi) passed"

# ── Throwaway roots + stubs ──────────────────────────────────────────────────
TMP_DIR="$(mktemp -d /tmp/disinto-acceptance-1576.XXXXXX)"
cleanup() { rm -rf "$TMP_DIR" 2>/dev/null || true; }
trap cleanup EXIT

ROOT1="$TMP_DIR/root1"; mkdir -p "$ROOT1/usr/bin"
ROOT2="$TMP_DIR/root2"; mkdir -p "$ROOT2/usr/bin"
STUB_DIR="$TMP_DIR/stub"; mkdir -p "$STUB_DIR"

# Fake caddy binary. `version` prints a plain 2.11.4 line (no `gandi`), just
# as the broken real binary did. `list-modules` prints the gandi module only
# when AC_HAS_GANDI_MODULES is set — that env var is the AC discriminator.
FAKE_CADDY="$TMP_DIR/caddy"
cat > "$FAKE_CADDY" <<'FCC'
#!/usr/bin/env bash
case "$1" in
  version)
    # Caddy 2.11.4: only the version line, no `gandi` string.
    printf 'caddy version 2.11.4\n'
    ;;
  list-modules)
    if [ -n "$AC_HAS_GANDI_MODULES" ]; then
      printf 'github.com/caddy-dns/gandi\ndns.providers.gandi\n'
    else
      printf 'github.com/caddy-dns/cloudflare\ndns.providers.dns\n'
    fi
    ;;
  *)
    exit 1
    ;;
esac
FCC

# Fake curl: `install_caddy_binary` runs `curl -fsSL ... -o $tmp`; this stub
# finds the `-o` target and "downloads" the fake caddy binary into it.
cat > "$STUB_DIR/curl" <<'CR'
#!/usr/bin/env bash
out=""; prev=""
for arg in "$@"; do
  if [ "$prev" = "-o" ]; then out="$arg"; fi
  prev="$arg"
done
if [ -n "$out" ]; then
  cp "$FAKE_CADDY" "$out"
  exit 0
else
  printf 'curl stub: no -o target\n' >&2
  exit 1
fi
CR
chmod +x "$FAKE_CADDY" "$STUB_DIR/curl"
ac_log "issue-1576: stubs ready — fake caddy: ${FAKE_CADDY}; fake curl: ${STUB_DIR}/curl"

# ── Run the extracted function in a throwaway subshell. `die` (exit 1) exits
# ─── only that subshell process; rc is its exit status, stderr is captured. ─────
run_install() {
  local has_gandi="$1" caddy_bin="$2" label="$3" err
  err="$TMP_DIR/err.$label"
  rc=0
  (
    export PATH="$STUB_DIR:$PATH"
    export FAKE_CADDY="$FAKE_CADDY"
    # AC_HAS_GANDI_MODULES is the AC discriminator: set only for AC1. Each AC
    # runs in its own subshell, so there is no leak between runs.
    if [ -n "$has_gandi" ]; then export AC_HAS_GANDI_MODULES=1; fi
    # export so the eval'd install_caddy_binary() reads the same CADDY_BIN
    # and shellcheck does not flag the assignment as unused (SC2034).
    export CADDY_BIN="$caddy_bin"
    # Compatible stand-ins for porter-caddy.sh's log/die so the extracted
    # function behaves exactly as on the real host.
    log() { printf 'porter-caddy: %s\n' "$*"; }
    die() { printf 'porter-caddy: %s\n' "$*" >&2; exit 1; }
    eval "$fn_src"
    install_caddy_binary
  ) 2>"$err" || rc=$?
}

# ── AC1: version has no gandi, list-modules prints dns.providers.gandi →
# ─── accepted and installed. (If the old version-based check were still in
# ─── play, this would be rejected, because the stub's version line has no
# ─── `gandi`.) ─────────────────────────────────────────────────────────────────
run_install "1" "$ROOT1/usr/bin/caddy" "ac1"
if [ "$rc" -ne 0 ]; then
  ac_fail "AC1: stub whose version has no gandi but list-modules prints dns.providers.gandi was rejected (rc=$rc; $(cat "${TMP_DIR}/err.ac1" 2>/dev/null || true))"
fi
if [ ! -f "$ROOT1/usr/bin/caddy" ]; then
  ac_fail "AC1: the good binary was not installed at ${ROOT1}/usr/bin/caddy (rc=$rc)"
fi
if [ ! -x "$ROOT1/usr/bin/caddy" ]; then
  ac_fail "AC1: the installed binary at ${ROOT1}/usr/bin/caddy is not executable"
fi
ac_log "AC1: accepted and installed the binary whose list-modules shows dns.providers.gandi"

# ── AC2: version has no gandi, list-modules LACKS dns.providers.gandi →
# ─── rejected (non-zero) and nothing installed at the CADDY_BIN path. ─────────
run_install "" "$ROOT2/usr/bin/caddy" "ac2"
if [ "$rc" -eq 0 ]; then
  ac_fail "AC2: stub whose list-modules lacks dns.providers.gandi was accepted (rc=$rc; $(cat "${TMP_DIR}/err.ac2" 2>/dev/null || true))"
fi
if [ -f "$ROOT2/usr/bin/caddy" ]; then
  ac_fail "AC2: a rejected binary was still written to ${ROOT2}/usr/bin/caddy (rc=$rc)"
fi
if ! grep -qF 'gandi' "${TMP_DIR}/err.ac2" 2>/dev/null; then
  ac_fail "AC2: the rejection did not name the missing gandi plugin (stderr: $(cat "${TMP_DIR}/err.ac2" 2>/dev/null || true))"
fi
ac_log "AC2: rejected the binary whose list-modules lacks dns.providers.gandi (no binary installed)"

# ── AC3: all acceptance criteria passed ─────────────────────────────────────
ac_pass
