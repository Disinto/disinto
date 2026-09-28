#!/usr/bin/env bash
# =============================================================================
# issue-1595.sh — acceptance test for the door ownership in porter-install.sh
#
# Issue #1595: sshd refuses to run AuthorizedKeysCommand when the script or
# its directory is owned by the target user (porter). porter-install.sh did
# `chown -R porter:porter /opt/porter`, so the live host logged
# `Unsafe AuthorizedKeysCommand ... bad ownership or modes for file
# /opt/porter/key-command.sh` and closed the connection — no key could get in.
#
# Fix:
#   * /opt/porter (the prefix) and /opt/porter/key-command.sh are root:root,
#     mode 755 — not writable by group or other.
#   * No `chown -R` of the prefix to porter. The rest of the door (everything
#     except the AuthorizedKeysCommand path) stays porter-owned: 755 is
#     world-readable/executable, which is all porter needs for dispatch.sh,
#     porter-wrap.sh, stripe-webhook.sh, lib/, verbs/, packs/ — and the
#     ledger stays porter-owned, so porter can still write it.
#   * Under PORTER_ROOT (the acceptance-test seam, run without root) the
#     install skips *all* chown.
#
# Acceptance criteria:
#   AC1: the installer source sets the prefix + key-command.sh to root:root
#        and chmods them 755 (ledger/env ownership untouched).
#   AC2: the installer does not `chown -R` the prefix to porter (nor chown it
#        to porter at all).
#   AC3: every chown in the installer lives inside a real-host
#        `if [[ -z "${PORTER_ROOT:-}" ]]` guard, so a PORTER_ROOT run
#        performs no chown.
#   AC4: a real PORTER_ROOT run (non-root, no network) exits 0, the prefix and
#        key-command.sh are mode 755 and remain owned by the invoking user
#        (never porter), and the sshd gate is still skipped.
#
# Hermetic: no network (Gandi is a stub; the caddy admin stub is a no-op),
# no root (PORTER_ROOT skips useradd/chown/sshd/reload).
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=../lib/acceptance-helpers.sh
source "$REPO_ROOT/tests/lib/acceptance-helpers.sh"

ac_require_cmd bash jq grep awk sed cat printf chmod cp rm mv find mktemp
ac_require_cmd curl   # only needed to be present for the stub path; not invoked

PORTER_INSTALL="$REPO_ROOT/tools/edge-control/porter-install.sh"
ac_assert_file "$PORTER_INSTALL" "tools/edge-control/porter-install.sh is missing"

TMP_DIR="$(mktemp -d /tmp/disinto-acceptance-1595.XXXXXX)"
cleanup() {
  rm -rf "$TMP_DIR" 2>/dev/null || true
}
trap cleanup EXIT

# ── Hermetic stubs (written under $TMP_DIR, put on PATH when needed) ─────────
STUB_DIR="$TMP_DIR/stubs"
mkdir -p "$STUB_DIR"

# curl: a fake Gandi LiveDNS v5 endpoint. State lives in GANDI_STUB_STATE
# ({"data":[...]}); the agreeing zone means porter-dns.sh no-ops. Every other
# URL (e.g. the caddy admin calls) returns "[]".
cat > "$TMP_DIR/curl" <<'AC_GANDI_STUB'
#!/usr/bin/env bash
state="${GANDI_STUB_STATE:-}"
log="${GANDI_STUB_LOG:-}"
method="GET"
url=""
body=""
auth=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    -X) method="$2"; shift 2 ;;
    -u) url="$2"; shift 2 ;;
    -H) auth="$2"; shift 2 ;;
    -d) body="$2"; shift 2 ;;
    -o) shift 2 ;;
    -f|-s|-S|-L) shift ;;
    --max-time) shift 2 ;;
    --*|-*) shift ;;
    *)
      if [[ -z "$url" ]]; then url="$1"; else echo "$1" >&2; fi
      shift
      ;;
  esac
done
[[ -n "$url" ]] || { echo "no url" >&2; exit 22; }
[[ -n "$state" && -f "$state" ]] || { echo "[]" >&2; exit 22; }
if [[ -n "$log" && -n "$url" ]]; then
  printf '{"method":"%s","url":"%s","auth":"%s","body":"%s"}\n' \
    "$method" "$url" "$auth" "${body//\"/\\\"}" >> "$log"
fi
case "$url" in
  */domains/disinto.ai/records)
    jq . "$state" 2>/dev/null || echo "[]"
    ;;
  *)
    echo "[]" ;;
esac
AC_GANDI_STUB
chmod +x "$TMP_DIR/curl"

# sshd + systemctl: only invoked on the real-host gate, which PORTER_ROOT
# skips; present so a regression that calls them fails loudly.
printf '#!/usr/bin/env bash\nrc="${SSHD_STUB_RC:-0}"\nif [[ -n "${SSHD_STUB_LOG:-}" ]]; then printf "sshd %%s\\n" "$*" >> "${SSHD_STUB_LOG}"; fi\nexit "$rc"\n' > "$TMP_DIR/sshd"
printf '#!/usr/bin/env bash\nif [[ -n "${SYSTEMCTL_STUB_LOG:-}" ]]; then printf "%%s\\n" "$*" >> "${SYSTEMCTL_STUB_LOG}"; fi; exit 0\n' > "$TMP_DIR/systemctl"
chmod +x "$TMP_DIR/sshd" "$TMP_DIR/systemctl"
cp "$TMP_DIR/curl" "$TMP_DIR/sshd" "$TMP_DIR/systemctl" "$STUB_DIR/"
export PATH="$STUB_DIR:$PATH"

TOKEN="tok-1595"
IP="203.0.113.10"

# make_root <root> — throwaway PORTER_ROOT carrying the Gandi token file
# (mode 600, GANDI_API_KEY= line) that porter-dns.sh reads.
make_root() {
  local root="$1"
  mkdir -p "$root/etc/porter"
  printf 'GANDI_API_KEY=%s\n' "$TOKEN" > "$root/etc/porter/gandi.env"
  chmod 600 "$root/etc/porter/gandi.env"
}

# The agreeing zone: wildcard * A already equals $IP, so porter-dns.sh no-ops.
printf '{"data":[{"id":"rec1","rrset_name":"*","rrset_type":"A","rrset_values":["%s"]}]}' "$IP" \
  > "$TMP_DIR/state-agree.json"

# run_install <root> — run porter-install.sh under PORTER_ROOT; capture rc/out.
run_install() {
  local root="$1"
  export PORTER_ROOT="$root"
  export PORTER_PUBLIC_IP="$IP"
  export GANDI_STUB_STATE="$TMP_DIR/state-agree.json"
  export GANDI_STUB_LOG="$TMP_DIR/curl.log"
  export SYSTEMCTL_STUB_LOG="$TMP_DIR/systemctl.log"
  export SSHD_STUB_LOG="$TMP_DIR/sshd.log"
  rm -f "$TMP_DIR/curl.log" "$TMP_DIR/systemctl.log" "$TMP_DIR/sshd.log"
  local out err rc
  out="$TMP_DIR/out.txt" err="$TMP_DIR/err.txt"
  rc=0
  bash "$PORTER_INSTALL" 2>"$err" >"$out" || rc=$?
  unset -v PORTER_ROOT PORTER_PUBLIC_IP GANDI_STUB_STATE GANDI_STUB_LOG \
             SYSTEMCTL_STUB_LOG SSHD_STUB_LOG
  RC=$rc OUT_FILE="$out"
}

# ───────────────────────────────────────────────────────────────────────────────
# AC1: the installer sets the prefix + key-command.sh to root:root, mode 755.
# ───────────────────────────────────────────────────────────────────────────────
ac_log "AC1: prefix + key-command.sh set to root:root mode 755"
grep -qF 'chown root:root "${OPT_DIR}" "${OPT_DIR}/key-command.sh"' "$PORTER_INSTALL" \
  || ac_fail "AC1: must chown root:root both the prefix and key-command.sh"
grep -qF 'chmod 755 "${OPT_DIR}" "${OPT_DIR}/key-command.sh"' "$PORTER_INSTALL" \
  || ac_fail "AC1: must chmod 755 both the prefix and key-command.sh"
# Ledger ownership unchanged: porter must still own the ledger (and env) it writes.
grep -qF 'chown porter:porter "${LIB_DIR}"' "$PORTER_INSTALL" \
  || ac_fail "AC1: ledger dir must stay porter:porter"
grep -qF 'chown porter:porter "${LEDGER}" "${ENV_FILE}"' "$PORTER_INSTALL" \
  || ac_fail "AC1: ledger + env file must stay porter:porter"
ac_log "AC1 passed"

# ───────────────────────────────────────────────────────────────────────────────
# AC2: no `chown -R` of the prefix to porter (nor any chown of the prefix to
# porter).
# ───────────────────────────────────────────────────────────────────────────────
ac_log "AC2: no chown of the prefix to porter"
if grep -qF 'chown -R porter:porter "${OPT_DIR}"' "$PORTER_INSTALL"; then
  ac_fail "AC2: must not chown -R the prefix to porter"
fi
if grep -qF 'chown porter:porter "${OPT_DIR}"' "$PORTER_INSTALL"; then
  ac_fail "AC2: must not chown the prefix to porter (recursive or not)"
fi
ac_log "AC2 passed"

# ───────────────────────────────────────────────────────────────────────────────
# AC3: every chown call in the installer is inside a real-host
# `if [[ -z "${PORTER_ROOT:-}" ]]` guard (PORTER_ROOT runs skip chown).
# ───────────────────────────────────────────────────────────────────────────────
ac_log "AC3: every chown sits in the real-host guard"
# Extract the bodies of all `if [[ -z "${PORTER_ROOT:-}" ]]` blocks (their
# top-level closers are the unindented `fi` lines) and assert each chown
# command line is one of them.
guard_lines="$(awk '
  {
    if (index($0, "if [[ -z \"${PORTER_ROOT:-}\" ]]; then") > 0 && in_guard == 0) { in_guard = 1; next }
    if (in_guard && $0 == "fi") { in_guard = 0; next }
    if (in_guard) print
  }' "$PORTER_INSTALL")"
total_chown="$(grep -cE '^[[:space:]]+chown ' "$PORTER_INSTALL")"
guard_chown="$(printf '%s\n' "$guard_lines" | grep -cE '^[[:space:]]+chown ' || true)"
[[ -n "$guard_chown" ]] || guard_chown=0
if [[ "$total_chown" -ne "$guard_chown" ]]; then
  ac_fail "AC3: ${total_chown} chown call(s) in porter-install.sh but only ${guard_chown} inside a real-host (PORTER_ROOT) guard — a PORTER_ROOT run must skip chown"
fi
ac_log "AC3 passed: ${total_chown} chown call(s), all under the PORTER_ROOT guard"

# ───────────────────────────────────────────────────────────────────────────────
# AC4: a PORTER_ROOT run (non-root) performs no chown and leaves the door
# root/invoker-owned at mode 755.
# ───────────────────────────────────────────────────────────────────────────────
ac_log "AC4: PORTER_ROOT run — no chown, mode 755, invoker-owned"
ROOT="$TMP_DIR/root"
make_root "$ROOT"
run_install "$ROOT"
ac_assert_eq "$RC" "0" "AC4: PORTER_ROOT install must exit 0 (got $RC): $(tail -n 3 "$OUT_FILE")"
prefix="$ROOT/opt/porter"
key="$ROOT/opt/porter/key-command.sh"
[[ -d "$prefix" ]] || ac_fail "AC4: door prefix missing: $prefix"
[[ -f "$key" ]] || ac_fail "AC4: key-command.sh missing: $key"
# stat -c '%a' prints the octal access bits without the leading zero, so
# compare against "755".
[[ "$(stat -c '%a' "$prefix")" == "755" ]] \
  || ac_fail "AC4: prefix must be mode 755 (got $(stat -c '%a' "$prefix"))"
[[ "$(stat -c '%a' "$key")" == "755" ]] \
  || ac_fail "AC4: key-command.sh must be mode 755 (got $(stat -c '%a' "$key"))"
caller_user="$(id -un)"
key_user="$(stat -c '%U' "$key")"
prefix_user="$(stat -c '%U' "$prefix")"
[[ "$key_user" != "porter" ]] \
  || ac_fail "AC4: key-command.sh must not be porter-owned under PORTER_ROOT (got $key_user)"
[[ "$prefix_user" != "porter" ]] \
  || ac_fail "AC4: prefix must not be porter-owned under PORTER_ROOT (got $prefix_user)"
[[ "$key_user" == "$caller_user" ]] \
  || ac_fail "AC4: PORTER_ROOT install must not chown (key-command.sh owner $key_user, caller is $caller_user)"
[[ "$prefix_user" == "$caller_user" ]] \
  || ac_fail "AC4: PORTER_ROOT install must not chown (prefix owner $prefix_user, caller is $caller_user)"
# The sshd gate is also skipped under PORTER_ROOT.
if [[ -s "$TMP_DIR/sshd.log" ]]; then
  ac_fail "AC4: PORTER_ROOT run must not invoke sshd: $TMP_DIR/sshd.log"
fi
# The drop-in still points at key-command.sh (now required to be root-owned).
dropin="$ROOT/etc/ssh/sshd_config.d/porter.conf"
grep -qF "AuthorizedKeysCommand ${ROOT}/opt/porter/key-command.sh %f %t %k" "$dropin" \
  || ac_fail "AC4: drop-in must point at key-command.sh: $dropin"
ac_log "AC4 passed: prefix + key-command.sh $caller_user-owned, 0755, sshd gate skipped"

ac_log "All acceptance criteria met"
ac_pass
