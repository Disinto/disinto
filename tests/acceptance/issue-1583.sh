#!/usr/bin/env bash
# =============================================================================
# issue-1583.sh — acceptance test for tools/edge-control/porter-front.sh
#
# Issue #1583: feat(edge): porter-front installs the factory tunnel user and site.
#
# The factory front was built by hand (a non-porter, non-tunnel user, a Match
# block, a permitlisten key line, and an extra.d site). This test proves
# tools/edge-control/porter-front.sh does that deterministically, hermetically.
#
# Contract under test (#1583):
#   * AC1: a PORTER_ROOT run writes a Match block whose PermitListen is ONLY
#          the given ports, and does not reload sshd (sshd/systemctl not
#          invoked).
#   * AC2: the site file proxies only the given host -> the upstream, carries
#          the wildcard-site TLS issuer, and contains no forced command; the
#          printed operator line has each permitlisten and no command=; the
#          drop-in carries no AuthorizedKeysCommand.
#   * AC3: --user porter and --user disinto-tunnel exit non-zero and write
#          nothing (no new drop-in / site file).
#   * AC4: a pre-existing extra.d file for another name is still present (byte
#          for byte) after a successful run.
#   * AC5: the real-host gate (front_sshd_gate) reloads ssh on a passing sshd
#          -t and removes the drop-in with no reload on a failing sshd -t.
#
# Hermetic: no network, no real sshd/caddy/systemctl/useradd, no root.
# PORTER_ROOT is a throwaway $TMP_DIR subdir; AC5 drives the extracted gate
# function with a stubbed sshd/systemctl.
#
# Run via: tools/run-acceptance.sh 1583
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=../lib/acceptance-helpers.sh
source "$REPO_ROOT/tests/lib/acceptance-helpers.sh"

ac_require_cmd bash grep awk cat printf head rm chmod

PORTER_FRONT="$REPO_ROOT/tools/edge-control/porter-front.sh"
ac_assert_file "$PORTER_FRONT" "tools/edge-control/porter-front.sh is missing"

TMP_DIR="$(mktemp -d /tmp/disinto-acceptance-1583.XXXXXX)"
teardown() {
  rm -rf "$TMP_DIR" 2>/dev/null || true
}
trap teardown EXIT

# ── Hermetic stubs (under $TMP_DIR/stubs, put on PATH when needed) ────────────
STUB_DIR="$TMP_DIR/stubs"
mkdir -p "$STUB_DIR"

# sshd: controllable exit code (SSHD_STUB_RC, default 0); logs each invocation
# to SSHD_STUB_LOG so the test can assert the gate invoked it. The quoted
# heredoc keeps the ${VAR} tokens literal in the stub (they expand only when
# the stub runs), while producing real newlines.
cat > "$TMP_DIR/sshd" <<'SSHD_STUB_EOF'
#!/usr/bin/env bash
rc="${SSHD_STUB_RC:-0}"
if [[ -n "${SSHD_STUB_LOG:-}" ]]; then
  printf 'sshd: %s\n' "$*" >> "${SSHD_STUB_LOG}"
fi
exit "$rc"
SSHD_STUB_EOF
chmod +x "$TMP_DIR/sshd"
cp "$TMP_DIR/sshd" "$STUB_DIR/sshd"

# systemctl: records every invocation to SYSTEMCTL_STUB_LOG, always exits 0.
cat > "$TMP_DIR/systemctl" <<'SCTL_STUB_EOF'
#!/usr/bin/env bash
if [[ -n "${SYSTEMCTL_STUB_LOG:-}" ]]; then
  printf '%s\n' "$*" >> "${SYSTEMCTL_STUB_LOG}"
fi
exit 0
SCTL_STUB_EOF
chmod +x "$TMP_DIR/systemctl"
cp "$TMP_DIR/systemctl" "$STUB_DIR/systemctl"
export PATH="$STUB_DIR:$PATH"

# ── Test fixtures ─────────────────────────────────────────────────────────────
USER_NAME="front"
SITE="front.disinto.ai"
UPSTREAM="127.0.0.1:1000"
PORTS=("1000" "2000")

# make_root <root> — throwaway PORTER_ROOT with the standard dirs plus a
# pre-existing extra.d file for ANOTHER name (AC4 fixture), written byte-for-
# byte known so AC4 can compare.
make_root() {
  local root="$1"
  mkdir -p "$root/etc/caddy/extra.d" "$root/etc/ssh/sshd_config.d" "$root/home"
  printf 'other-operator-site\n' > "$root/etc/caddy/extra.d/other.caddy"
}

# run_front <root> [extra-args...] — run porter-front.sh under PORTER_ROOT with
# the standard flags; capture rc/stdout/stderr in RC/OUT_FILE/ERR_FILE.
run_front() {
  local root="$1"; shift
  export PORTER_ROOT="$root"
  export SSHD_STUB_LOG="$TMP_DIR/sshd.log"
  export SYSTEMCTL_STUB_LOG="$TMP_DIR/systemctl.log"
  rm -f "$TMP_DIR/sshd.log" "$TMP_DIR/systemctl.log"
  local out err rc
  out="$TMP_DIR/out.txt"; err="$TMP_DIR/err.txt"
  rc=0
  bash "$PORTER_FRONT" --user "${USER_NAME}" \
    --port "${PORTS[0]}" --port "${PORTS[1]}" \
    --site "${SITE}" --upstream "${UPSTREAM}" "$@" 2>"$err" >"$out" || rc=$?
  RC=$rc OUT_FILE="$out" ERR_FILE="$err"
  unset -v PORTER_ROOT SSHD_STUB_LOG SYSTEMCTL_STUB_LOG
}

# ───────────────────────────────────────────────────────────────────────────────
# AC1: PORTER_ROOT run writes the Match block (PermitListen = only the given
#     ports) and does not reload sshd.
# ───────────────────────────────────────────────────────────────────────────────
ac_log "AC1: PORTER_ROOT run writes the Match block (PermitListen only the given ports), no sshd reload"

ROOT1="$TMP_DIR/root1"
make_root "$ROOT1"
run_front "$ROOT1"
ac_assert_eq "$RC" "0" "AC1: PORTER_ROOT run must exit 0 (got $RC): $(cat "${ERR_FILE}" 2>/dev/null || true)"

DROPIN="${ROOT1}/etc/ssh/sshd_config.d/${USER_NAME}.conf"
ac_assert_file "${DROPIN}" "AC1: drop-in missing: ${DROPIN}"

# The Match User block and its directives.
grep -Eq "^Match[[:space:]]+User[[:space:]]+${USER_NAME}" "${DROPIN}" \
  || ac_fail "AC1: drop-in lacks a 'Match User ${USER_NAME}' block"
grep -qF "PasswordAuthentication no" "${DROPIN}" \
  || ac_fail "AC1: drop-in lacks 'PasswordAuthentication no'"
grep -qF "AllowTcpForwarding remote" "${DROPIN}" \
  || ac_fail "AC1: drop-in lacks 'AllowTcpForwarding remote'"
grep -qF "PermitTTY no" "${DROPIN}" \
  || ac_fail "AC1: drop-in lacks 'PermitTTY no'"
grep -qF "X11Forwarding no" "${DROPIN}" \
  || ac_fail "AC1: drop-in lacks 'X11Forwarding no'"

# PermitListen is ONLY the given ports: extract every 127.0.0.1:N token in the
# file and assert the set is exactly {1000, 2000}.
plist_tokens="$(grep -oE '127\.0\.0\.1:[0-9]+' "${DROPIN}" | sort -u)"
if [[ "${plist_tokens}" != "127.0.0.1:1000
127.0.0.1:2000" ]]; then
  ac_fail "AC1: drop-in must contain exactly the given permitlisten ports (got: ${plist_tokens}): ${DROPIN}"
fi
ac_log "AC1: Match block has PermitListen only for the given ports"

# No sshd/systemctl invocation under PORTER_ROOT (the real-host gate is skipped).
if [[ -s "$TMP_DIR/sshd.log" ]]; then
  ac_fail "AC1: PORTER_ROOT run must not invoke the sshd stub: $(cat "$TMP_DIR/sshd.log" 2>/dev/null || true)"
fi
if grep -q 'reload ssh' "$TMP_DIR/systemctl.log" 2>/dev/null; then
  ac_fail "AC1: PORTER_ROOT run must not reload ssh: $(cat "$TMP_DIR/systemctl.log" 2>/dev/null || true)"
fi
ac_log "AC1: no sshd reload under PORTER_ROOT"

# ───────────────────────────────────────────────────────────────────────────────
# AC2: the site file proxies only the given host + wildcard TLS issuer + no
#     forced command; the printed operator line has each permitlisten and no
#     command=; the drop-in carries no AuthorizedKeysCommand.
# ───────────────────────────────────────────────────────────────────────────────
ac_log "AC2: site file proxies only the given host + wildcard TLS issuer; operator line has no command="

EXTRA_FILE="${ROOT1}/etc/caddy/extra.d/${USER_NAME}.caddy"
ac_assert_file "${EXTRA_FILE}" "AC2: Caddy site missing: ${EXTRA_FILE}"

# The single site block is addressed to exactly the given host (not a wildcard
# or a different customer host). Only the top-level block header line begins
# with a hostname char, so [[:space:]] (not \s) and an explicit block-opening
# brace are the portable way to pick it out.
block_host="$(awk '/^[A-Za-z0-9.-]+[[:space:]]+\{/{print $1}' "${EXTRA_FILE}" | head -1)"
ac_assert_eq "${block_host}" "${SITE}" \
  "AC2: the site block must be addressed to ${SITE}, got: '${block_host}'"

# It proxies to the given upstream.
grep -qF "reverse_proxy" "${EXTRA_FILE}" \
  || ac_fail "AC2: site must use a reverse_proxy directive"
grep -qF "${UPSTREAM}" "${EXTRA_FILE}" \
  || ac_fail "AC2: site must proxy to the upstream ${UPSTREAM}"
if grep -qE '^\*' "${EXTRA_FILE}"; then
  ac_fail "AC2: site must not contain a wildcard block"
fi

# Same TLS issuer block as the wildcard site.
grep -qF 'tls acme {' "${EXTRA_FILE}" \
  || ac_fail "AC2: site lacks a 'tls acme {' issuer block"
grep -qF 'dns gandi {env.GANDI_API_KEY}' "${EXTRA_FILE}" \
  || ac_fail "AC2: site lacks 'dns gandi {env.GANDI_API_KEY}'"
grep -qF 'propagation_timeout 10m' "${EXTRA_FILE}" \
  || ac_fail "AC2: site lacks 'propagation_timeout 10m'"
grep -qF 'resolvers ns-163-a.gandi.net ns-102-b.gandi.net ns-91-c.gandi.net' "${EXTRA_FILE}" \
  || ac_fail "AC2: site lacks the three Gandi resolvers"

# No forced command anywhere in the site file.
if grep -qF 'command=' "${EXTRA_FILE}"; then
  ac_fail "AC2: site file must not contain 'command=': ${EXTRA_FILE}"
fi
ac_log "AC2: site file proxies only the given host with the wildcard TLS issuer"

# Printed operator's authorized_keys line: one line starting with 'restrict,'
# carrying each permitlisten, no command=.
key_line="$(grep -E '^restrict,' "${OUT_FILE}" | head -1)"
if [[ -z "${key_line}" ]]; then
  ac_fail "AC2: no authorized_keys line (starting with 'restrict,') in stdout: $(cat "${OUT_FILE}" 2>/dev/null || true)"
fi
for p in "${PORTS[@]}"; do
  grep -qF "permitlisten=\"127.0.0.1:${p}\"" <<<"$key_line" \
    || ac_fail "AC2: operator line lacks permitlisten for port ${p}: ${key_line}"
done
if grep -qF 'command=' <<<"$key_line"; then
  ac_fail "AC2: operator line must not contain 'command=': ${key_line}"
fi

# The drop-in must carry no AuthorizedKeysCommand (this user has none).
if grep -qF 'AuthorizedKeysCommand' "${DROPIN}"; then
  ac_fail "AC2: drop-in must not contain 'AuthorizedKeysCommand': ${DROPIN}"
fi
ac_log "AC2: operator line has each permitlisten and no forced command"

# ───────────────────────────────────────────────────────────────────────────────
# AC3: --user porter and --user disinto-tunnel exit non-zero and write nothing.
# ───────────────────────────────────────────────────────────────────────────────
ac_log "AC3: --user porter and --user disinto-tunnel exit non-zero, write nothing"

for bad_user in porter disinto-tunnel; do
  ROOT="${TMP_DIR}/root-${bad_user}"
  make_root "$ROOT"
  export PORTER_ROOT="$ROOT"
  out="$TMP_DIR/bad-${bad_user}-out.txt"; err="$TMP_DIR/bad-${bad_user}-err.txt"
  rc=0
  bash "$PORTER_FRONT" --user "${bad_user}" --port 1000 \
    --site "${SITE}" --upstream "${UPSTREAM}" 2>"$err" >"$out" || rc=$?
  unset -v PORTER_ROOT
  if [[ "$rc" -eq 0 ]]; then
    ac_fail "AC3: --user ${bad_user} must exit non-zero (got $rc)"
  fi
  # Wrote nothing: no new drop-in, no new caddy site for that user.
  if [[ -f "${ROOT}/etc/ssh/sshd_config.d/${bad_user}.conf" ]]; then
    ac_fail "AC3: --user ${bad_user} must not write a drop-in: ${ROOT}/etc/ssh"
  fi
  if [[ -f "${ROOT}/etc/caddy/extra.d/${bad_user}.caddy" ]]; then
    ac_fail "AC3: --user ${bad_user} must not write a caddy site: ${ROOT}/etc/caddy"
  fi
  # The pre-existing other-name site survives the refused run, untouched.
  ac_assert_file "${ROOT}/etc/caddy/extra.d/other.caddy" \
    "AC3: pre-existing other.caddy should survive the refused run for ${bad_user}"
done
ac_log "AC3: reserved users refused without writing"

# ───────────────────────────────────────────────────────────────────────────────
# AC4: a pre-existing extra.d file for another name is still present after a
#     successful run (byte for byte).
# ───────────────────────────────────────────────────────────────────────────────
ac_log "AC4: a pre-existing extra.d file for another name survives the run"

if [[ ! -f "${ROOT1}/etc/caddy/extra.d/other.caddy" ]]; then
  ac_fail "AC4: pre-existing other.caddy for another name was deleted/missing"
fi
other_content="$(cat "${ROOT1}/etc/caddy/extra.d/other.caddy")"
if [[ "${other_content}" != "other-operator-site" ]]; then
  ac_fail "AC4: pre-existing other.caddy for another name was altered (got: '${other_content}')"
fi
# The new site file for NAME also exists alongside it.
if [[ ! -f "${ROOT1}/etc/caddy/extra.d/${USER_NAME}.caddy" ]]; then
  ac_fail "AC4: the new ${USER_NAME}.caddy site is missing"
fi
ac_log "AC4: both the pre-existing and the new extra.d files are present"

# ───────────────────────────────────────────────────────────────────────────────
# AC5: the real-host gate (front_sshd_gate) reloads ssh on a passing sshd -t,
#     and removes the drop-in with no reload on a failing sshd -t.
# ───────────────────────────────────────────────────────────────────────────────
ac_log "AC5: real-host gate reloads on sshd -t OK, removes + no reload on failure"

fn_src="$(ac_extract_fn front_sshd_gate "$PORTER_FRONT")"
if [[ "${fn_src}" != *"front_sshd_gate()"* ]]; then
  ac_fail "AC5: ac_extract_fn did not return front_sshd_gate from ${PORTER_FRONT}"
fi
printf '%s\n' "$fn_src" > "$TMP_DIR/gate-fn.sh"

# AC5-a: passing sshd -t -> reload ssh.
clean_conf="$TMP_DIR/gate-clean.conf"
printf 'Match User front\n    PermitListen 127.0.0.1:1000\n' > "$clean_conf"
sshd_log="$TMP_DIR/sshd-clean.log"; rm -f "$sshd_log"
sctl_log="$TMP_DIR/sctl-clean.log"; rm -f "$sctl_log"
rc=0
(
  # Fresh subshell: stubs on PATH, gate against the clean drop-in.
  set -u
  export PATH="$STUB_DIR:$PATH"
  export SSHD_STUB_RC=0 SSHD_STUB_LOG="$sshd_log" SYSTEMCTL_STUB_LOG="$sctl_log"
  # shellcheck source=gate-fn.sh
  source "$TMP_DIR/gate-fn.sh"
  front_sshd_gate "$clean_conf"
) 2>&1 || rc=$?
ac_assert_eq "$rc" "0" "AC5-a: passing sshd -t gate must return 0 (got $rc)"
grep -q 'sshd: ' "$sshd_log" 2>/dev/null \
  || ac_fail "AC5-a: passing gate must invoke sshd via the stub: $(cat "$sshd_log" 2>/dev/null || true)"
grep -q 'reload ssh' "$sctl_log" 2>/dev/null \
  || ac_fail "AC5-a: passing gate must reload ssh via the systemctl stub: $(cat "$sctl_log" 2>/dev/null || true)"
ac_log "AC5-a: gate reloads on a passing sshd -t"

# AC5-b: failing sshd -t -> drop-in removed, no reload.
fail_conf="$TMP_DIR/gate-fail.conf"
printf 'Match User front\n    # intentionally not a clean block\n' > "$fail_conf"
sshd_log="$TMP_DIR/sshd-fail.log"; rm -f "$sshd_log"
sctl_log="$TMP_DIR/sctl-fail.log"; rm -f "$sctl_log"
rc=0
(
  # Fresh subshell: stubs on PATH, gate against the failing drop-in.
  set -u
  export PATH="$STUB_DIR:$PATH"
  export SSHD_STUB_RC=1 SSHD_STUB_LOG="$sshd_log" SYSTEMCTL_STUB_LOG="$sctl_log"
  # shellcheck source=gate-fn.sh
  source "$TMP_DIR/gate-fn.sh"
  front_sshd_gate "$fail_conf"
) 2>&1 || rc=$?
if [[ "$rc" -eq 0 ]]; then
  ac_fail "AC5-b: failing sshd -t gate must return non-zero (got $rc)"
fi
if [[ -f "$fail_conf" ]]; then
  ac_fail "AC5-b: failing gate must remove the drop-in: ${fail_conf}"
fi
if grep -q 'reload ssh' "$sctl_log" 2>/dev/null; then
  ac_fail "AC5-b: failing gate must not reload ssh: $(cat "$sctl_log" 2>/dev/null || true)"
fi
ac_log "AC5-b: failing gate removes the drop-in and does not reload"

ac_log "All acceptance criteria met"
ac_pass
