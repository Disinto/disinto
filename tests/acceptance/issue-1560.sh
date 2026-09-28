#!/usr/bin/env bash
# =============================================================================
# issue-1560.sh — acceptance test for porter-install.sh
#
# Issue #1560: wire `tools/edge-control/porter-install.sh` to
#   (a) create the `disinto-tunnel` user (real host only, nologin, no home);
#   (b) call `porter-caddy.sh` + `porter-dns.sh` from the same directory
#       (no `--set-wildcard`);
#   (c) add `EDGE_APPLY=1` to porter.env (new line when creating, append-if-
#       absent when existing — other lines kept, mode enforced, and never a
#       Gandi token is written there);
#   (d) on a real host run `sshd -t` and reload sshd only when it exits 0 AND
#       the drop-in is a clean `Match User porter` block with no column-0
#       `AuthorizedKeysCommand`. On `sshd -t` failure restore the previous
#       drop-in (if any), do not reload, and exit non-zero.
#   Under `PORTER_ROOT` the useradd, sshd -t, and reload are all skipped.
#
# Acceptance criteria:
#   AC1: a PORTER_ROOT run calls the caddy + dns helpers and does not reload
#        sshd.
#   AC2: an existing env file gains EDGE_APPLY=1 and keeps other lines; the
#        Gandi token is not written into porter.env.
#   AC3: a drop-in that is not a clean `Match User porter` block is NOT
#        followed by a reload (and a clean one IS); sshd -t failure restores
#        the previous drop-in and returns non-zero.
#   AC4: a DNS refusal (wildcard pointing elsewhere, no --set-wildcard) makes
#        the run exit non-zero AFTER the door files are in place — the door is
#        not rolled back and DNS is not edited.
#   AC5: this test exits 0 and calls ac_pass.
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
SRC_DIR="$REPO_ROOT/tools/edge-control"

TMP_DIR="$(mktemp -d /tmp/disinto-acceptance-1560.XXXXXX)"
cleanup() {
  rm -rf "$TMP_DIR" 2>/dev/null || true
}
trap cleanup EXIT

# ── Hermetic stubs (written under $TMP_DIR, put on PATH when needed) ─────────
STUB_DIR="$TMP_DIR/stubs"
mkdir -p "$STUB_DIR"

# curl: a fake Gandi LiveDNS v5. Keys on the last URL segment, returns the
# zone record list (GET) or a single record (PUT), and records every call as
# JSONL {method,url,auth,body} for the test. A PUT/POST with the right
# Authorization header mutates the seeded state file; otherwise it no-ops.
cat > "$TMP_DIR/curl" <<'AC_GANDI_STUB'
#!/usr/bin/env bash
# Fake Gandi LiveDNS v5 endpoint. State lives in GANDI_STUB_STATE
# ({"data":[{"id","rrset_name","rrset_type","rrset_values"}]}); every request
# appends {method,url,auth,body} to GANDI_STUB_LOG. A PUT upserts the * A
# record when the auth is tok-1560 (the new API never POSTs).
state="${GANDI_STUB_STATE:-}"
log="${GANDI_STUB_LOG:-}"
method="GET"
url=""
body=""
auth=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    -X) method="$2"; shift 2 ;;
    -H) if [[ "$2" == "Authorization: Bearer "* ]]; then auth="${2#Authorization: Bearer }"; fi; shift 2 ;;
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
    if [[ "$method" == "PUT" && -n "$auth" && "$auth" == "tok-1560" && -n "$body" ]]; then
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

# sshd: controllable exit code (SSHD_STUB_RC, default 0).
printf '#!/usr/bin/env bash\nrc="${SSHD_STUB_RC:-0}"; exit "$rc"\n' > "$TMP_DIR/sshd"
chmod +x "$TMP_DIR/sshd"

# systemctl: records every invocation to SYSTEMCTL_STUB_LOG, exits 0.
printf '#!/usr/bin/env bash\nif [[ -n "${SYSTEMCTL_STUB_LOG:-}" ]]; then printf "%%s\\n" "$*" >> "${SYSTEMCTL_STUB_LOG}"; fi; exit 0\n' > "$TMP_DIR/systemctl"
chmod +x "$TMP_DIR/systemctl"

cp "$TMP_DIR/curl" "$TMP_DIR/sshd" "$TMP_DIR/systemctl" "$STUB_DIR/"
export PATH="$STUB_DIR:$PATH"

TOKEN="tok-1560"
IP="203.0.113.10"        # PORTER_PUBLIC_IP (a public-looking address)

# make_root <root> — throwaway PORTER_ROOT carrying the Gandi token file
# (mode 600, GANDI_API_KEY= line) that porter-dns.sh reads.
make_root() {
  local root="$1"
  mkdir -p "$root/etc/porter"
  printf 'GANDI_API_KEY=%s\n' "$TOKEN" > "$root/etc/porter/gandi.env"
  chmod 600 "$root/etc/porter/gandi.env"
}

# The no-op zone: wildcard * A already equals $IP, so porter-dns.sh no-ops.
printf '{"data":[{"id":"rec1","rrset_name":"*","rrset_type":"A","rrset_values":["%s"]}]}' "$IP" \
  > "$TMP_DIR/state.json"

# run_install <root> [state-file] — run porter-install.sh under PORTER_ROOT
# against a zone state; capture rc/stdout/stderr. No-op state by default.
run_install() {
  local root="$1" state_file="$TMP_DIR/state.json"
  [[ $# -ge 2 ]] && state_file="$2"
  export PORTER_ROOT="$root"
  export PORTER_PUBLIC_IP="$IP"
  export GANDI_STUB_STATE="$state_file"
  export GANDI_STUB_LOG="$TMP_DIR/curl.log"
  export SYSTEMCTL_STUB_LOG="$TMP_DIR/systemctl.log"
  rm -f "$TMP_DIR/curl.log" "$TMP_DIR/systemctl.log" "$TMP_DIR/state.tmp"
  local out err rc
  out="$TMP_DIR/out.txt" err="$TMP_DIR/err.txt"
  rc=0
  bash "$PORTER_INSTALL" 2>"$err" >"$out" || rc=$?
  unset -v PORTER_ROOT PORTER_PUBLIC_IP GANDI_STUB_STATE GANDI_STUB_LOG SYSTEMCTL_STUB_LOG
  RC=$rc OUT_FILE="$out"
}

# Assert the token was never written into porter.env. Returns 0 when the
# token is (correctly) absent.
assert_no_token_in_env() {
  local root="$1"
  if grep -q -- "$TOKEN" "${root}/etc/porter/porter.env"; then
    ac_fail "porter.env must not contain the Gandi token ($TOKEN): ${root}/etc/porter/porter.env"
  fi
}

# ── Source-level sanity: the door must call caddy + dns (not install.sh) ─────
grep -qF -- '"${SRC_DIR}/porter-caddy.sh"' "$PORTER_INSTALL" \
  || ac_fail "porter-install.sh must call ${SRC_DIR}/porter-caddy.sh"
grep -qF -- '"${SRC_DIR}/porter-dns.sh"' "$PORTER_INSTALL" \
  || ac_fail "porter-install.sh must call ${SRC_DIR}/porter-dns.sh"
ac_log "source wiring checks passed"

# ── AC1: PORTER_ROOT run calls caddy + dns, does not reload sshd ─────────────
ac_log "AC1: PORTER_ROOT run calls caddy+dns, no sshd reload"
ROOT1="$TMP_DIR/root1"
make_root "$ROOT1"
run_install "$ROOT1"
ac_assert_eq "$RC" "0" "PORTER_ROOT install must exit 0 (got $RC): $OUT_FILE"
grep -q 'porter-caddy:' "$OUT_FILE" \
  || ac_fail "caddy helper not invoked (no porter-caddy line): $OUT_FILE"
grep -q 'porter-dns:' "$OUT_FILE" \
  || ac_fail "dns helper not invoked (no porter-dns line): $OUT_FILE"
if grep -q 'reload ssh' "$TMP_DIR/systemctl.log" 2>/dev/null; then
  ac_fail "PORTER_ROOT run must not reload sshd: $TMP_DIR/systemctl.log"
fi
ac_log "AC1 passed"

# ── AC2: env file gains EDGE_APPLY=1, keeps other lines, no token ────────────
ac_log "AC2: porter.env EDGE_APPLY handling"

# AC2a: a FRESH porter.env gets 3 lines incl. EDGE_APPLY=1.
ac_log "AC2a: fresh porter.env has 3 lines incl. EDGE_APPLY=1"
ROOT2="$TMP_DIR/root2"
make_root "$ROOT2"
run_install "$ROOT2"
ac_assert_eq "$RC" "0" "fresh install must exit 0 (got $RC): $OUT_FILE"
env="$ROOT2/etc/porter/porter.env"
[[ -f "$env" ]] || ac_fail "porter.env not created: $env"
grep -q '^EDGE_APPLY=1$' "$env" \
  || ac_fail "fresh porter.env must contain EDGE_APPLY=1: $env"
ac_assert_eq "$(wc -l < "$env" | tr -d '[:space:]')" "3" \
  "fresh porter.env must have exactly 3 lines"
grep -q '^TYPESAFE_API_KEY=' "$env" \
  || ac_fail "fresh porter.env must keep TYPESAFE_API_KEY: $env"
grep -q '^JEV_MODEL=' "$env" \
  || ac_fail "fresh porter.env must keep JEV_MODEL: $env"
assert_no_token_in_env "$ROOT2"

# AC2b: an EXISTING env file (without EDGE_APPLY) gains it, keeps other lines.
ac_log "AC2b: existing porter.env gains EDGE_APPLY=1, keeps other lines"
ROOT3="$TMP_DIR/root3"
make_root "$ROOT3"
cat > "$ROOT3/etc/porter/porter.env" <<EOF
TYPESAFE_API_KEY=abc-123
JEV_MODEL=jev-1.13.0
SOME_OTHER_KEY=somevalue
EOF
chmod 640 "$ROOT3/etc/porter/porter.env"
run_install "$ROOT3"
ac_assert_eq "$RC" "0" "existing install must exit 0 (got $RC): $OUT_FILE"
env="$ROOT3/etc/porter/porter.env"
grep -q '^EDGE_APPLY=1$' "$env" \
  || ac_fail "existing porter.env must gain EDGE_APPLY=1: $env"
grep -q '^TYPESAFE_API_KEY=abc-123$' "$env" \
  || ac_fail "existing porter.env must keep TYPESAFE_API_KEY=abc-123: $env"
grep -q '^JEV_MODEL=jev-1.13.0$' "$env" \
  || ac_fail "existing porter.env must keep JEV_MODEL=jev-1.13.0: $env"
grep -q '^SOME_OTHER_KEY=somevalue$' "$env" \
  || ac_fail "existing porter.env must keep other lines: $env"
ac_assert_eq "$(grep -c '^EDGE_APPLY=' "$env")" "1" "must not duplicate EDGE_APPLY"
assert_no_token_in_env "$ROOT3"

# AC2c: an EXISTING env file (with EDGE_APPLY) is not duplicated.
ac_log "AC2c: existing porter.env with EDGE_APPLY not duplicated"
ROOT4="$TMP_DIR/root4"
make_root "$ROOT4"
cat > "$ROOT4/etc/porter/porter.env" <<EOF
TYPESAFE_API_KEY=abc-456
EDGE_APPLY=1
JEV_MODEL=jev-2.0
EOF
chmod 640 "$ROOT4/etc/porter/porter.env"
run_install "$ROOT4"
ac_assert_eq "$RC" "0" "existing-with-key install must exit 0 (got $RC): $OUT_FILE"
env="$ROOT4/etc/porter/porter.env"
ac_assert_eq "$(grep -c '^EDGE_APPLY=' "$env")" "1" "must not duplicate EDGE_APPLY when present"
grep -q '^TYPESAFE_API_KEY=abc-456$' "$env" \
  || ac_fail "existing porter.env must keep TYPESAFE_API_KEY=abc-456: $env"
grep -q '^JEV_MODEL=jev-2.0$' "$env" \
  || ac_fail "existing porter.env must keep JEV_MODEL=jev-2.0: $env"
assert_no_token_in_env "$ROOT4"
ac_log "AC2 passed"

# ── AC3: sshd drop-in decision (clean reloads, dirty/no-match do not, fail restores)
ac_log "AC3: sshd drop-in reload decision"
FN_SRC="$(ac_extract_fn reload_sshd_if_safe "$PORTER_INSTALL")" || true
[[ -n "$FN_SRC" ]] || ac_fail "could not extract reload_sshd_if_safe() from porter-install.sh"
printf '%s\n' "$FN_SRC" > "$TMP_DIR/reload-fn.sh"

# AC3-a: a clean drop-in (Match User porter, no column-0 AuthorizedKeysCommand)
#         reloads ssh. Minimal block on purpose — not a copy of the install's
#         drop-in — so duplicate-detection stays green.
clean_conf="$TMP_DIR/clean.conf"
cat > "$clean_conf" <<EOF
Match User porter
    PasswordAuthentication no
EOF
sctl_log="$TMP_DIR/sctl-clean.log"; rm -f "$sctl_log"
rc=0
(
  set -u
  PATH="$STUB_DIR:$PATH"
  export SSHD_STUB_RC=0
  export SYSTEMCTL_STUB_LOG="$sctl_log"
  source "$TMP_DIR/reload-fn.sh"
  reload_sshd_if_safe "$clean_conf"
) 2>&1 || rc=$?
ac_assert_eq "$rc" "0" "clean drop-in must return 0 (got $rc)"
grep -q 'reload ssh' "$sctl_log" \
  || ac_fail "clean drop-in must reload ssh: $sctl_log"

# AC3-b: a drop-in with a column-0 AuthorizedKeysCommand is NOT reloaded.
dirty_conf="$TMP_DIR/dirty.conf"
cat > "$dirty_conf" <<EOF
Match User porter
AuthorizedKeysCommand /usr/local/bin/evil %f
EOF
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
  ac_fail "dirty drop-in must NOT reload ssh: $sctl_log"
fi

# AC3-c: a drop-in with no `Match User porter` line is NOT reloaded.
nomatch_conf="$TMP_DIR/nomatch.conf"
printf 'PasswordAuthentication no\nPermitTunnel no\n' > "$nomatch_conf"
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

# AC3-d: sshd -t fails => non-zero, no reload, previous drop-in restored.
# The "new" live drop-in uses minimal distinct content on purpose (not a copy
# of the install's drop-in) so duplicate-detection stays green; the ".prev"
# carries the `old/key-command.sh` marker the restore assertion greps for.
live_conf="$TMP_DIR/live.conf"
live_conf_prev="$TMP_DIR/live.conf.prev"
cat > "$live_conf" <<EOF
Match User porter
    PermitTunnel no
EOF
printf 'Match User porter\n    AuthorizedKeysCommand /old/key-command.sh %%f %%t %%k\n    PasswordAuthentication no\n' > "$live_conf_prev"
sctl_log="$TMP_DIR/sctl-fail.log"; rm -f "$sctl_log"
rc=0
(
  set -u
  PATH="$STUB_DIR:$PATH"
  export SSHD_STUB_RC=1
  export SYSTEMCTL_STUB_LOG="$sctl_log"
  source "$TMP_DIR/reload-fn.sh"
  reload_sshd_if_safe "$live_conf"
) 2>&1 || rc=$?
ac_assert_eq "$rc" "1" "sshd -t failure must return 1 (got $rc)"
if grep -q 'reload ssh' "$sctl_log" 2>/dev/null; then
  ac_fail "sshd -t failure must NOT reload ssh: $sctl_log"
fi
grep -q 'old/key-command.sh' "$live_conf" \
  || ac_fail "sshd -t failure must restore previous drop-in: $live_conf"
ac_log "AC3 passed"

# ── AC4: DNS refusal => non-zero, no rollback, DNS not edited ────────────────
ac_log "AC4: DNS refusal propagates, no rollback, no DNS edit"
ROOT5="$TMP_DIR/root5"
make_root "$ROOT5"
# A conflicting zone: wildcard * A points elsewhere, so porter-dns.sh refuses
# without --set-wildcard.
printf '{"data":[{"id":"rec1","rrset_name":"*","rrset_type":"A","rrset_values":["203.0.113.99"]}]}' \
  > "$TMP_DIR/state-conflict.json"
export PORTER_ROOT="$ROOT5"
export PORTER_PUBLIC_IP="$IP"
export GANDI_STUB_STATE="$TMP_DIR/state-conflict.json"
export GANDI_STUB_LOG="$TMP_DIR/curl5.log"
export SYSTEMCTL_STUB_LOG="$TMP_DIR/systemctl5.log"
rm -f "$TMP_DIR/curl5.log" "$TMP_DIR/systemctl5.log" "$TMP_DIR/state-conflict.tmp"
OUT5="$TMP_DIR/out5.txt" ERR5="$TMP_DIR/err5.txt"
rc=0
bash "$PORTER_INSTALL" 2>"$ERR5" >"$OUT5" || rc=$?
unset -v PORTER_ROOT PORTER_PUBLIC_IP GANDI_STUB_STATE GANDI_STUB_LOG SYSTEMCTL_STUB_LOG
ac_assert_eq "$rc" "1" "DNS refusal must make install exit non-zero (got $rc): $OUT5"
grep -q 're-run with --set-wildcard' "$OUT5" \
  || ac_fail "DNS refusal must log the wildcard mismatch: $OUT5"
grep -q '203.0.113.99' "$OUT5" \
  || ac_fail "refusal must show the current conflicting value in output: $OUT5"
# Door files remain in place (NOT rolled back).
[[ -f "$ROOT5/opt/porter/dispatch.sh" ]] \
  || ac_fail "door must not be rolled back on DNS refusal: $ROOT5/opt/porter"
[[ -f "$ROOT5/opt/porter/key-command.sh" ]] \
  || ac_fail "door must not be rolled back on DNS refusal: $ROOT5/opt/porter"
[[ -f "$ROOT5/var/lib/disinto/accounts.json" ]] \
  || ac_fail "ledger must still exist after DNS refusal: $ROOT5/var/lib/disinto"
[[ -f "$ROOT5/etc/ssh/sshd_config.d/porter.conf" ]] \
  || ac_fail "drop-in must still exist after DNS refusal: $ROOT5/etc/ssh"
# DNS was NOT edited: only a GET reached the API (no PUT/POST), and the zone
# value is unchanged.
if grep -qE '"method":"(PUT|POST)"' "$TMP_DIR/curl5.log"; then
  ac_fail "DNS must not be edited on refusal (PUT/POST seen): $TMP_DIR/curl5.log"
fi
grep -q '203.0.113.99' "$TMP_DIR/state-conflict.json" \
  || ac_fail "zone value must be unchanged on refusal: $TMP_DIR/state-conflict.json"
ac_log "AC4 passed"

ac_log "All acceptance criteria met"
ac_pass
