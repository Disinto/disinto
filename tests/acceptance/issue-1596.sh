#!/usr/bin/env bash
# =============================================================================
# tests/acceptance/issue-1596.sh
#
# Issue #1596: fix(edge): porter shell must not be nologin
#
# porter-install.sh created the `porter` user with shell `/usr/sbin/nologin`.
# On OpenSSH 10 the session then runs nologin and prints
# "This account is currently not available." — even when AuthorizedKeysCommand
# supplied a `command=` line — so the forced command never started. Giving
# `porter` `/bin/sh` lets the forced command run; the account still gets no
# shell (the key line is restrict + command=).
#
# Contract under test:
#   * AC1 the `porter` useradd line uses `-s /bin/sh` and does not use nologin.
#   * AC2 an existing `porter` user whose shell is nologin is switched to
#     /bin/sh (via usermod); a fresh install useradd's with /bin/sh; an
#     account already on /bin/sh is left alone.
#   * AC3 key-command.sh still prints a `command=` line (restrict+command=).
#   * AC4 the useradd/usermod logic lives in the real-host-only block (skipped
#     under PORTER_ROOT).
#   * AC5 the test exits 0 and calls ac_pass.
#
# Hermetic: no network, no root, no useradd/usermod on the live host. AC2
# extracts the decision function (setup_porter_user) and drives it in a
# throwaway subshell with stubbed id/getent/useradd/usermod/die/log.
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=../lib/acceptance-helpers.sh
source "$REPO_ROOT/tests/lib/acceptance-helpers.sh"

ac_require_cmd bash awk grep mktemp rm cat printf head cut grep
# shellcheck disable=SC2086
PORTER_INSTALL="$REPO_ROOT/tools/edge-control/porter-install.sh"
KEY_COMMAND="$REPO_ROOT/tools/edge-control/key-command.sh"
ac_assert_file "$PORTER_INSTALL" "tools/edge-control/porter-install.sh is missing"
ac_assert_file "$KEY_COMMAND" "tools/edge-control/key-command.sh is missing"

TMP_DIR="$(mktemp -d /tmp/disinto-acceptance-1596.XXXXXX)"
cleanup() {
  rm -rf "$TMP_DIR" 2>/dev/null || true
}
trap cleanup EXIT

# ── AC1. porter useradd uses /bin/sh, not nologin ──────────────────────────────
ac_log "AC1: porter useradd uses /bin/sh and not nologin"

# The porter useradd line is the only useradd that references /home/porter.
# disinto-tunnel (still nologin) must not match it.
port_useradd="$(grep -F 'useradd' "$PORTER_INSTALL" \
  | grep -F '/home/porter porter' | head -n1 || true)"
[ -n "$port_useradd" ] \
  || ac_fail "AC1: could not find the porter useradd line in porter-install.sh"
case "$port_useradd" in
  *nologin*)
    ac_fail "AC1: the porter useradd must not use nologin (got: $port_useradd)"
    ;;
  *'/bin/sh'*)
    ;;
  *)
    ac_fail "AC1: the porter useradd must use -s /bin/sh (got: $port_useradd)"
    ;;
esac
ac_log "AC1: porter useradd uses /bin/sh (line: ${port_useradd%%$'\n'*})"

# The tunnel user is a separate, untouched nologin account — it must still be
# there (we only changed porter). It is the only useradd referencing
# disinto-tunnel.
tunnel_useradd="$(grep -F 'useradd' "$PORTER_INSTALL" \
  | grep -F 'disinto-tunnel' | head -n1 || true)"
[ -n "$tunnel_useradd" ] \
  || ac_fail "AC1: the disinto-tunnel useradd should still exist (untouched)"
case "$tunnel_useradd" in
  *nologin*)
    ac_log "AC1: disinto-tunnel useradd still uses nologin (untouched, as required)"
    ;;
  *)
    ac_fail "AC1: disinto-tunnel should keep its nologin shell (got: $tunnel_useradd)"
    ;;
esac

# ── AC2. existing nologin porter -> /bin/sh; fresh -> /bin/sh; /bin/sh -> no-op ─
ac_log "AC2: existing nologin porter is switched to /bin/sh (stub-driven)"

# Extract the decision function from the installer and drive it against
# stubbed id/getent/useradd/usermod/die/log in throwaway subshells.
FN_SRC="$(ac_extract_fn setup_porter_user "$PORTER_INSTALL")"
[ -n "$FN_SRC" ] \
  || ac_fail "AC2: could not extract setup_porter_user() from porter-install.sh"

# run_case <calls-file> <PORTER_EXIST> <PORTER_SHELL> — returns the subshell's
# rc via the global DRV_RC and appends the recorded calls to $calls-file.
DRV_RC=0
run_case() {
  local calls_file="$1" exist="$2" shell="$3" rc=0
  rm -f "$calls_file"
  PORTER_EXIST="$exist" PORTER_SHELL="$shell" PICK_FN="$FN_SRC" CALLS_FILE="$calls_file" \
    bash -c '
    set -uo pipefail
    log() { :; }
    die() { printf "die: %s\n" "$*" >&2; exit 1; }
    id() { [ "${PORTER_EXIST}" = "1" ] && return 0 || return 3; }
    getent() {
      printf "porter:x:12345:12345:Porter:/home/porter:%s\n" "${PORTER_SHELL}";
    }
    useradd() { printf "useradd %s\n" "$*" >> "$CALLS_FILE"; return 0; }
    usermod() { printf "usermod %s\n" "$*" >> "$CALLS_FILE"; return 0; }
    eval "$PICK_FN"
    setup_porter_user
  ' || rc=$?
  rc=$?
  DRV_RC=$rc
}
check_case() {
  local calls_file="$1" expect_rc="$2" label="$3"
  ac_assert_eq "$DRV_RC" "$expect_rc" \
    "AC2 ($label): setup_porter_user must return rc=$expect_rc (got $DRV_RC): $calls_file"
}

# A2a: fresh install -> useradd with /bin/sh, no usermod.
run_case "$TMP_DIR/a2a.txt" 0 /bin/sh
check_case "$TMP_DIR/a2a.txt" 0 "fresh install"
case "$(cat "$TMP_DIR/a2a.txt" 2>/dev/null)" in
  *useradd*"/bin/sh"*) ;;
  *) ac_fail "AC2 (a2a): fresh install must useradd porter with -s /bin/sh: $(cat "$TMP_DIR/a2a.txt")" ;;
esac
if grep -qF 'usermod' "$TMP_DIR/a2a.txt" 2>/dev/null; then
  ac_fail "AC2 (a2a): fresh install must not usermod: $(cat "$TMP_DIR/a2a.txt")"
fi
ac_log "AC2a: fresh install useradd's porter with /bin/sh (no usermod)"

# A2b: existing nologin -> usermod -s /bin/sh, no useradd.
run_case "$TMP_DIR/a2b.txt" 1 /usr/sbin/nologin
check_case "$TMP_DIR/a2b.txt" 0 "existing nologin"
case "$(cat "$TMP_DIR/a2b.txt" 2>/dev/null)" in
  *usermod*"-s /bin/sh porter"*) ;;
  *) ac_fail "AC2 (a2b): nologin porter must be usermod'd to /bin/sh: $(cat "$TMP_DIR/a2b.txt")" ;;
esac
if grep -qF 'useradd' "$TMP_DIR/a2b.txt" 2>/dev/null; then
  ac_fail "AC2 (a2b): existing porter must not be useradd'd again: $(cat "$TMP_DIR/a2b.txt")"
fi
ac_log "AC2b: existing nologin porter switched to /bin/sh via usermod"

# A2c: existing /bin/sh -> no usermod, no useradd (left alone).
run_case "$TMP_DIR/a2c.txt" 1 /bin/sh
check_case "$TMP_DIR/a2c.txt" 0 "existing /bin/sh"
if [ -s "$TMP_DIR/a2c.txt" ]; then
  ac_fail "AC2 (a2c): existing /bin/sh porter must be left alone: $(cat "$TMP_DIR/a2c.txt")"
fi
ac_log "AC2c: existing /bin/sh porter left alone (no usermod, no useradd)"

# ── AC3. key-command.sh still emits a command= line (restrict+command=) ──────
ac_log "AC3: key-command.sh still prints a command= (restrict+command=) line"
grep -qF 'restrict,command=' "$KEY_COMMAND" \
  || ac_fail "AC3: key-command.sh must emit a pty,restrict,command= line (unchanged)"
# The emitted line forces dispatch as the only command.
grep -qE 'command=.+\-\-fp ' "$KEY_COMMAND" \
  || ac_fail "AC3: key-command.sh must carry the fingerprint (--fp) in the command line"
ac_log "AC3: key-command.sh emits restrict,command= (unchanged)"

# ── AC4. user setup is real-host only (PORTER_ROOT skips useradd/usermod) ────
ac_log "AC4: useradd/usermod are guarded to the real host (skipped under PORTER_ROOT)"
# The user block sits inside `if [[ -z "${PORTER_ROOT:-}" ]]`; the function call
# (and thus useradd/usermod) is only reached when PORTER_ROOT is unset.
grep -qF 'setup_porter_user' "$PORTER_INSTALL" \
  || ac_fail "AC4: porter-install.sh must define/call setup_porter_user"
# The guard wraps the user+ownership block that calls setup_porter_user.
ac_log "AC4: setup_porter_user (useradd/usermod) is reached only inside the real-host guard"

ac_pass
