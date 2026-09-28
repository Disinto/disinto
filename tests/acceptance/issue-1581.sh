#!/usr/bin/env bash
# =============================================================================
# issue-1581.sh — acceptance test for the sshd-gate-before-DNS reorder in
# tools/edge-control/porter-install.sh
#
# Issue #1581: porter-install.sh ran porter-dns.sh (which can exit non-zero on
# a wildcard conflict) *before* the real-host sshd gate (sshd -t + conditional
# reload). Under `set -e`, a DNS refusal exited before the gate, so sshd never
# got revalidated/reloaded while the new drop-in sat on disk.
#
# Fix: the sshd gate now runs BEFORE porter-caddy.sh / porter-dns.sh. A later
# DNS refusal leaves the drop-in in place AND the gate has already run.
#
# Acceptance criteria:
#   AC1: when the DNS helper exits non-zero the sshd gate has already been
#        run (it is ordered before the DNS call, and with a clean drop-in it
#        invokes the sshd stub + reload) and the drop-in remains the
#        `Match User porter` block (the door is not rolled back).
#   AC2: a drop-in that is not a clean `Match User porter` block (a column-0
#        AuthorizedKeysCommand, or no Match line at all) is NOT reloaded.
#   AC3: under PORTER_ROOT the sshd gate is skipped (the sshd stub is not
#        invoked).
#   AC4: this test exits 0 and calls ac_pass.
#
# Hermetic: no network, no real sshd/caddy/systemctl. PORTER_ROOT is a
# throwaway $TMP_DIR subdirectory; nothing here touches /etc or live paths.
# Note: under PORTER_ROOT the gate is skipped by design (AC3), so AC1's
# "sshd still invoked" is proven by (a) source ordering — the gate precedes the
# DNS call, so a DNS refusal cannot exit before it — plus (b) the gate, when it
# runs, invoking the sshd stub and reloading for a clean drop-in.
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=../lib/acceptance-helpers.sh
source "$REPO_ROOT/tests/lib/acceptance-helpers.sh"

ac_require_cmd bash jq grep awk sed cat printf chmod cp rm mv find mktemp

PORTER_INSTALL="$REPO_ROOT/tools/edge-control/porter-install.sh"
ac_assert_file "$PORTER_INSTALL" "tools/edge-control/porter-install.sh is missing"

TMP_DIR="$(mktemp -d /tmp/disinto-acceptance-1581.XXXXXX)"
cleanup() {
  rm -rf "$TMP_DIR" 2>/dev/null || true
}
trap cleanup EXIT

# ── Hermetic stubs (written under $TMP_DIR, put on PATH when needed) ──────────
STUB_DIR="$TMP_DIR/stubs"
mkdir -p "$STUB_DIR"

# curl: a fake Gandi LiveDNS v5 endpoint. State lives in GANDI_STUB_STATE
# ({"data":[{"id","rrset_name","rrset_type","rrset_values"}]}); every request
# appends {method,url,auth,body} to GANDI_STUB_LOG. A PUT upserts the * A
# record when the auth is tok-1581 (the new API never POSTs).
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
  */domains/disinto.ai/records/*)
    if [[ "$method" == "PUT" && -n "$auth" && "$auth" == "tok-1581" && -n "$body" ]]; then
      jq --argjson b "$body" \
        '.data[0].rrset_name = "*"; .data[0].rrset_type = "A"; .data[0].rrset_values = $b.rrset_values' \
        "$state" > "$state.tmp" && mv "$state.tmp" "$state"
    fi
    jq . "$state" 2>/dev/null || echo "[]"
    ;;
  *)
    echo "[]" ;;
esac
AC_GANDI_STUB
chmod +x "$TMP_DIR/curl"

# sshd: controllable exit code (SSHD_STUB_RC, default 0); logs each invocation
# to SSHD_STUB_LOG so the test can assert the gate invoked sshd.
printf '#!/usr/bin/env bash\nrc="${SSHD_STUB_RC:-0}"\nif [[ -n "${SSHD_STUB_LOG:-}" ]]; then printf "sshd %%s\\n" "$*" >> "${SSHD_STUB_LOG}"; fi\nexit "$rc"\n' > "$TMP_DIR/sshd"
chmod +x "$TMP_DIR/sshd"

# systemctl: records every invocation to SYSTEMCTL_STUB_LOG, exits 0.
printf '#!/usr/bin/env bash\nif [[ -n "${SYSTEMCTL_STUB_LOG:-}" ]]; then printf "%%s\\n" "$*" >> "${SYSTEMCTL_STUB_LOG}"; fi; exit 0\n' > "$TMP_DIR/systemctl"
chmod +x "$TMP_DIR/systemctl"

cp "$TMP_DIR/curl" "$TMP_DIR/sshd" "$TMP_DIR/systemctl" "$STUB_DIR/"
export PATH="$STUB_DIR:$PATH"

TOKEN="tok-1581"
IP="203.0.113.10"            # PORTER_PUBLIC_IP (a public-looking address)
CONFLICT_IP="203.0.113.99"   # a * A value different from $IP => refusal

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

# run_install <root> [state-file] — run porter-install.sh under PORTER_ROOT
# against a zone state; capture rc/stdout/stderr. Agree state by default.
run_install() {
  local root="$1" state_file="$TMP_DIR/state-agree.json"
  [[ $# -ge 2 ]] && state_file="$2"
  export PORTER_ROOT="$root"
  export PORTER_PUBLIC_IP="$IP"
  export GANDI_STUB_STATE="$state_file"
  export GANDI_STUB_LOG="$TMP_DIR/curl.log"
  export SYSTEMCTL_STUB_LOG="$TMP_DIR/systemctl.log"
  export SSHD_STUB_LOG="$TMP_DIR/sshd.log"
  rm -f "$TMP_DIR/curl.log" "$TMP_DIR/systemctl.log" "$TMP_DIR/sshd.log" "$TMP_DIR/state.tmp"
  local out err rc
  out="$TMP_DIR/out.txt" err="$TMP_DIR/err.txt"
  rc=0
  bash "$PORTER_INSTALL" 2>"$err" >"$out" || rc=$?
  unset -v PORTER_ROOT PORTER_PUBLIC_IP GANDI_STUB_STATE GANDI_STUB_LOG \
             SYSTEMCTL_STUB_LOG SSHD_STUB_LOG
  RC=$rc OUT_FILE="$out"
}

# ───────────────────────────────────────────────────────────────────────────────
# AC1: the sshd gate is ordered before the DNS helper; a DNS refusal exits
# non-zero but leaves the drop-in (Match block) and door files in place.
# ───────────────────────────────────────────────────────────────────────────────
ac_log "AC1: sshd gate ordered before DNS; DNS refusal does not skip the gate"

# 1a: source ordering — the gate call must precede the porter-dns.sh call.
#     Before the fix the gate came after; this assertion is what catches the bug.
gate_line="$(grep -n 'reload_sshd_if_safe "${DROPIN}"' "$PORTER_INSTALL" | head -1 | cut -d: -f1)"
dns_line="$(grep -n 'bash "${SRC_DIR}/porter-dns.sh"' "$PORTER_INSTALL" | head -1 | cut -d: -f1)"
[[ -n "$gate_line" && -n "$dns_line" ]] \
  || ac_fail "could not locate sshd gate call / porter-dns.sh call in porter-install.sh"
(( "$gate_line" < "$dns_line" )) \
  || ac_fail "sshd gate (line $gate_line) must be ordered BEFORE porter-dns.sh (line $dns_line); a DNS refusal must not be able to skip the gate"

# 1b: full PORTER_ROOT run with a refusing DNS (wildcard points elsewhere).
ROOT1="$TMP_DIR/root1"
make_root "$ROOT1"
conflict_state="$TMP_DIR/state-conflict.json"
printf '{"data":[{"id":"rec1","rrset_name":"*","rrset_type":"A","rrset_values":["%s"]}]}' "$CONFLICT_IP" \
  > "$conflict_state"
run_install "$ROOT1" "$conflict_state"
ac_assert_eq "$RC" "1" "DNS refusal must make install exit non-zero (got $RC): ${RC}"
# Drop-in still exists and is the clean Match block (NOT rolled back / rewritten).
[[ -f "${ROOT1}/etc/ssh/sshd_config.d/porter.conf" ]] \
  || ac_fail "drop-in must still exist after DNS refusal: ${ROOT1}/etc/ssh"
grep -Eq '^Match[[:space:]]+User[[:space:]]+porter' "${ROOT1}/etc/ssh/sshd_config.d/porter.conf" \
  || ac_fail "drop-in must still be the Match User porter block after DNS refusal: ${ROOT1}/etc/ssh/sshd_config.d/porter.conf"
# Door files + ledger remain (not rolled back).
[[ -f "${ROOT1}/opt/porter/dispatch.sh" ]] \
  || ac_fail "door must not be rolled back on DNS refusal: ${ROOT1}/opt/porter"
[[ -f "${ROOT1}/var/lib/disinto/accounts.json" ]] \
  || ac_fail "ledger must still exist after DNS refusal: ${ROOT1}/var/lib/disinto"
# The refusal message shows the conflicting value; DNS was not edited
# (only a GET reached the API; no PUT/POST).
grep -q 're-run with --set-wildcard' "${OUT_FILE}" \
  || ac_fail "DNS refusal must log the wildcard mismatch: ${OUT_FILE}"
grep -q "$CONFLICT_IP" "${OUT_FILE}" \
  || ac_fail "refusal must show the current conflicting value: ${OUT_FILE}"
if grep -qE '"method":"(PUT|POST)"' "$TMP_DIR/curl.log" 2>/dev/null; then
  ac_fail "DNS must not be edited on refusal (PUT/POST seen): $TMP_DIR/curl.log"
fi
grep -q "$CONFLICT_IP" "$conflict_state" \
  || ac_fail "zone value must be unchanged on refusal: $conflict_state"

# 1c: the gate, when it runs, invokes sshd (sshd -t) and reloads for a clean
#     drop-in — the capability the fix preserves. (Under PORTER_ROOT the gate is
#     skipped by design; this drives the extracted gate directly.)
clean_conf="$TMP_DIR/clean.conf"
cat > "$clean_conf" <<EOF
Match User porter
    PermitTunnel no
    PasswordAuthentication no
EOF
sshd_log="$TMP_DIR/sshd-clean.log";  rm -f "$sshd_log"
sctl_log="$TMP_DIR/sctl-clean.log";  rm -f "$sctl_log"
fn_src="$(ac_extract_fn reload_sshd_if_safe "$PORTER_INSTALL")"
[[ "$fn_src" == *"reload_sshd_if_safe"* ]] \
  || ac_fail "ac_extract_fn did not return reload_sshd_if_safe"
printf '%s\n' "$fn_src" > "$TMP_DIR/reload-fn.sh"
rc=0
(
  set -u
  PATH="$STUB_DIR:$PATH"
  export SSHD_STUB_RC=0
  export SSHD_STUB_LOG="$sshd_log"
  export SYSTEMCTL_STUB_LOG="$sctl_log"
  source "$TMP_DIR/reload-fn.sh"
  reload_sshd_if_safe "$clean_conf"
) 2>&1 || rc=$?
ac_assert_eq "$rc" "0" "clean drop-in + sshd -t OK must return 0 (got $rc)"
grep -q 'sshd -t' "$sshd_log" \
  || ac_fail "clean drop-in must invoke sshd (sshd -t) via the stub: $sshd_log"
grep -q 'reload ssh' "$sctl_log" \
  || ac_fail "clean drop-in must reload ssh via the systemctl stub: $sctl_log"
ac_log "AC1 passed"

# ───────────────────────────────────────────────────────────────────────────────
# AC2: a drop-in that is not a clean `Match User porter` block is NOT reloaded
#     (a column-0 AuthorizedKeysCommand, or no Match line at all).
# ───────────────────────────────────────────────────────────────────────────────
ac_log "AC2: non-clean drop-in is not reloaded"

# AC2-a: column-0 AuthorizedKeysCommand -> no reload.
dirty_conf="$TMP_DIR/dirty.conf"
printf 'Match User porter\nAuthorizedKeysCommand /usr/local/bin/evil %%f\n' > "$dirty_conf"
sctl_log="$TMP_DIR/sctl-dirty.log"; rm -f "$sctl_log"
rc=0
(
  set -u
  PATH="$STUB_DIR:$PATH"
  export SSHD_STUB_RC=0
  export SYSTEMCTL_STUB_LOG="$sctl_log"
  source "$TMP_DIR/reload-fn.sh"
  reload_sshd_if_safe "$dirty_conf"
) 2>&1 || rc=$?
ac_assert_eq "$rc" "0" "dirty drop-in must return 0 (got $rc)"
if grep -q 'reload ssh' "$sctl_log" 2>/dev/null; then
  ac_fail "dirty drop-in (col-0 AuthorizedKeysCommand) must NOT reload ssh: $sctl_log"
fi

# AC2-b: no `Match User porter` line -> no reload.
nomatch_conf="$TMP_DIR/nomatch.conf"
printf 'PermitTunnel no\nPasswordAuthentication no\n' > "$nomatch_conf"
sctl_log="$TMP_DIR/sctl-nomatch.log"; rm -f "$sctl_log"
rc=0
(
  set -u
  PATH="$STUB_DIR:$PATH"
  export SSHD_STUB_RC=0
  export SYSTEMCTL_STUB_LOG="$sctl_log"
  source "$TMP_DIR/reload-fn.sh"
  reload_sshd_if_safe "$nomatch_conf"
) 2>&1 || rc=$?
ac_assert_eq "$rc" "0" "no-match drop-in must return 0 (got $rc)"
if grep -q 'reload ssh' "$sctl_log" 2>/dev/null; then
  ac_fail "no-Match-User drop-in must NOT reload ssh: $sctl_log"
fi
ac_log "AC2 passed"

# ───────────────────────────────────────────────────────────────────────────────
# AC3: under PORTER_ROOT the sshd gate is skipped (sshd stub not invoked).
# ───────────────────────────────────────────────────────────────────────────────
ac_log "AC3: PORTER_ROOT run does not invoke sshd"
ROOT2="$TMP_DIR/root2"
make_root "$ROOT2"
run_install "$ROOT2"
ac_assert_eq "$RC" "0" "PORTER_ROOT run with agreeing DNS must exit 0 (got $RC): ${RC}"
if [[ -s "$TMP_DIR/sshd.log" ]]; then
  ac_fail "PORTER_ROOT run must not invoke the sshd stub: $TMP_DIR/sshd.log"
fi
if grep -q 'reload ssh' "$TMP_DIR/systemctl.log" 2>/dev/null; then
  ac_fail "PORTER_ROOT run must not reload ssh: $TMP_DIR/systemctl.log"
fi
ac_log "AC3 passed"

ac_log "All acceptance criteria met"
ac_pass
