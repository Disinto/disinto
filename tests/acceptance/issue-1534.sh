#!/usr/bin/env bash
# =============================================================================
# tests/acceptance/issue-1534.sh
#
# Issue #1534: feat(edge): porter-wrap loads an allowlisted env and is the forced command
#
# key-command.sh used to force /opt/disinto-edge/dispatch.sh, which is not Porter
# and, being a forced command, arrives at sshd with its environment stripped —
# no TYPESAFE_API_KEY. This change makes the forced command porter-wrap.sh, which
# loads the allowlisted edge env from PORTER_ENV (read LITERALLY — never
# `source`, never `eval`) and then execs the sibling dispatch.sh.
#
#   AC1  key-command.sh emits a pty,restrict,command= line whose forced command
#         is the sibling porter-wrap.sh (contains "porter-wrap.sh" and
#         "restrict", contains neither "disinto-edge" nor "dispatch.sh").
#   AC2  porter-wrap.sh + fake dispatch.sh: an allowlisted value (TYPESAFE_API_KEY
#         =sekrit) is exported to dispatch.sh, while a non-allowlisted key with a
#         command-substitution value (EVIL=$(touch ...)) is ignored and NEVER
#         executed — the sentinel file is absent.
#   AC3  a command substitution in an ALLOWLISTED value is literal: the value is
#         the raw string "$(touch ...)" (not the result of running it), so the
#         sentinel file is absent.
#
# No network, no sshd, no /etc/ssh.
#
# Run via: tools/run-acceptance.sh 1534
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../tests/lib/acceptance-helpers.sh
source "$REPO_ROOT/tests/lib/acceptance-helpers.sh"

ac_require_cmd bash mktemp printf

KEY_SCRIPT="$REPO_ROOT/tools/edge-control/key-command.sh"
WRAPPER="$REPO_ROOT/tools/edge-control/porter-wrap.sh"

ac_assert_file "$KEY_SCRIPT" "tools/edge-control/key-command.sh is missing"
ac_assert_file "$WRAPPER"    "tools/edge-control/porter-wrap.sh is missing"
ac_assert_file "${WRAPPER%/}" "tools/edge-control/porter-wrap.sh is missing"

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT
ac_log "issue-1534: sandbox at $TMP_DIR"

# Valid SHA256 fingerprint: "SHA256:" + exactly 43 base64url chars.
FP="SHA256:$(printf 'A%.0s' {1..43})"
[[ "$FP" =~ ^SHA256:[A-Za-z0-9_-]{43}$ ]] \
  || ac_fail "test fixture fingerprint is malformed: $FP"

# ── AC1. key-command.sh forces porter-wrap.sh (restrict line, no disinto-edge)
# ─────────────────────────────────────────────────────────────────────────────
out=""
rc=0
out="$(ACCOUNTS_FILE="$TMP_DIR/acc.json" bash "$KEY_SCRIPT" "$FP" "ssh-ed25519" "AAAAB...")" || rc=$?
if [ "$rc" -ne 0 ]; then
  ac_fail "AC1: key-command.sh should succeed on valid input (rc=$rc, out=$out)"
fi
if [ "$(printf '%s\n' "$out" | grep -c .)" -ne 1 ]; then
  ac_fail "AC1: key-command.sh should print exactly one line, got: $out"
fi
grep -qE '^pty,restrict,command=' <<<"$out" \
  || ac_fail "AC1: key-command.sh line is not a pty,restrict,command line: $out"
if ! grep -qF 'porter-wrap.sh' <<<"$out"; then
  ac_fail "AC1: forced command is not porter-wrap.sh: $out"
fi
if ! grep -qF 'restrict' <<<"$out"; then
  ac_fail "AC1: restrict is not present: $out"
fi
if [[ "$out" == *disinto-edge* ]]; then
  ac_fail "AC1: output references disinto-edge: $out"
fi
if [[ "$out" == *dispatch.sh* ]]; then
  ac_fail "AC1: output still references dispatch.sh: $out"
fi
ac_log "AC1: key-command.sh forces porter-wrap.sh (pty,restrict, no disinto-edge)"

# Sandbox: a TEMP copy of porter-wrap.sh with a FAKE sibling dispatch.sh that
# simply prints the value of TYPESAFE_API_KEY (the only thing it "sees").
SBOX="$TMP_DIR/sandbox"
mkdir -p "$SBOX"
cp "$WRAPPER" "$SBOX/porter-wrap.sh"
printf '#!/usr/bin/env bash\nset -euo pipefail\nprintf "TYPESAFE_API_KEY=%%s\\n" "${TYPESAFE_API_KEY:-(unset)}"\n' \
  > "$SBOX/dispatch.sh"
chmod +x "$SBOX/porter-wrap.sh" "$SBOX/dispatch.sh"

run_wrap() {
  PORTER_ENV="$1" ACCOUNTS_FILE="$TMP_DIR/run.json" bash "$SBOX/porter-wrap.sh" --fp "$FP"
}

# ── AC2. allowlisted value exported; non-allowlisted EVIL command never run
# ─────────────────────────────────────────────────────────────────────────────
# A literal $(touch ...) in a NON-allowlisted key: must be ignored (not exported)
# and must never be executed.
printf 'TYPESAFE_API_KEY=sekrit\nEVIL=$(touch %s)\nPATH=/usr/bin\nBASH_ENV=/x\nACCOUNTS_FILE=/x\n' \
  "$TMP_DIR/pwn" > "$TMP_DIR/env2"
out2=""
rc2=0
out2="$(run_wrap "$TMP_DIR/env2")" || rc2=$?
if [ "$rc2" -ne 0 ]; then
  ac_fail "AC2: wrap should exit 0 (rc=$rc2, out=$out2)"
fi
if ! grep -qF 'TYPESAFE_API_KEY=sekrit' <<<"$out2"; then
  ac_fail "AC2: dispatch did not see TYPESAFE_API_KEY=sekrit: $out2"
fi
if [ -f "$TMP_DIR/pwn" ]; then
  ac_fail "AC2: EVIL command was executed (sentinel $TMP_DIR/pwn exists)"
fi
ac_log "AC2: allowlisted sekrit exported; EVIL command ignored, sentinel absent"

# ── AC3. command substitution in an ALLOWLISTED value is literal, not run
# ─────────────────────────────────────────────────────────────────────────────
# Build a literal '$(touch /path/pwn2)' WITHOUT executing it: the format string
# is single-quoted so $(...) is inert, and %s is substituted.
literal="$(printf '$(touch %s)' "${TMP_DIR}/pwn2")"
# The env line must be:  TYPESAFE_API_KEY='$(touch /path/pwn2)'
printf "TYPESAFE_API_KEY='%s'\n" "$literal" > "$TMP_DIR/env3"

# Show the file contents for debugging (the literal must be visible, unrun).
ac_log "AC3: env3 line = $(cat "$TMP_DIR/env3")"

out3=""
rc3=0
out3="$(run_wrap "$TMP_DIR/env3")" || rc3=$?
if [ "$rc3" -ne 0 ]; then
  ac_fail "AC3: wrap should exit 0 (rc=$rc3, out=$out3)"
fi
# The fake dispatch saw the literal value (with the command substitution intact).
if ! grep -qF "$literal" <<<"$out3"; then
  ac_fail "AC3: dispatch did not see the literal value $literal: $out3"
fi
if [ -f "$TMP_DIR/pwn2" ]; then
  ac_fail "AC3: allowlisted command substitution was executed (sentinel $TMP_DIR/pwn2 exists)"
fi
ac_log "AC3: command substitution in allowlisted value is literal, sentinel absent"

ac_pass
