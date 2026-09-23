#!/usr/bin/env bash
# =============================================================================
# tests/acceptance/issue-1464.sh
#
# Issue #1464: feat(edge): restricted dispatcher for any SSH key
#
# Exercises the "store door" scripts (tools/edge-control/) against a throwaway
# ACCOUNTS_FILE in a mktemp dir — no live services, no sshd, and never /etc/ssh.
#
#   AC1  key-command.sh: valid (fingerprint, key-type, key-data) -> exactly one
#         restrict line containing the fingerprint; the line has neither
#         permitlisten nor permitopen (nor pty / agent-forwarding).
#   AC2  key-command.sh: unsupported key type -> empty stdout, non-zero exit.
#   AC3  dispatch.sh `whoami` on a fresh fingerprint -> status=pending, credits=0
#         (the row is created by account_ensure).
#   AC4  dispatch.sh: unknown verb -> {"error":"unknown command"}, and a command
#         string carrying shell metacharacters is never eval'd / executed outside
#         verbs/ (a sentinel dir survives).
#   AC5  dispatch.sh: no --fp -> non-zero exit, and no account row is written.
#
# Run via: tools/run-acceptance.sh 1464
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../tests/lib/acceptance-helpers.sh
source "$REPO_ROOT/tests/lib/acceptance-helpers.sh"

ac_require_cmd bash jq mktemp

KEY_SCRIPT="$REPO_ROOT/tools/edge-control/key-command.sh"
DISPATCH_SCRIPT="$REPO_ROOT/tools/edge-control/dispatch.sh"
VERBS_DIR="$REPO_ROOT/tools/edge-control/verbs"

ac_assert_file "$KEY_SCRIPT"    "tools/edge-control/key-command.sh is missing"
ac_assert_file "$DISPATCH_SCRIPT" "tools/edge-control/dispatch.sh is missing"
ac_assert_file "$VERBS_DIR/whoami.sh" "verbs/whoami.sh is missing"
ac_assert_file "$VERBS_DIR/status.sh" "verbs/status.sh is missing"

# A throwaway ledger — never touches the live /var/lib/disinto or /etc/ssh.
TMP_DIR="$(mktemp -d)"
ACCOUNTS_FILE="$TMP_DIR/accounts.json"
trap 'rm -rf "$TMP_DIR"' EXIT

# A valid SHA256 fingerprint: "SHA256:" + exactly 43 base64url chars.
FP="SHA256:$(printf 'A%.0s' {1..43})"
FP2="SHA256:$(printf 'B%.0s' {1..43})"
[[ "$FP" =~ ^SHA256:[A-Za-z0-9_-]{43}$ ]] \
  || ac_fail "test fixture fingerprint is malformed: $FP"

# ── AC1. key-command.sh: valid input -> one restrict line, fp present, no
#    permitlisten/permitopen/agent-forward ----------------------------------
out=""
rc=0
out="$(ACCOUNTS_FILE="$ACCOUNTS_FILE" bash "$KEY_SCRIPT" "$FP" "ssh-ed25519" "AAAAB...")" || rc=$?
if [ "$rc" -ne 0 ]; then
  ac_fail "AC1: key-command.sh should succeed on valid input (rc=$rc, out=$out)"
fi
if [ "$(printf '%s\n' "$out" | grep -c .)" -ne 1 ]; then
  ac_fail "AC1: key-command.sh should print exactly one line, got: $out"
fi
case "$out" in
  pty,restrict,command=*) ;;
  restrict,command=*) ;;
  *) ac_fail "AC1: key-command.sh line is not a restrict line: $out" ;;
esac
[[ "$out" == *"$FP"* ]] \
  || ac_fail "AC1: restrict line does not contain the fingerprint"
if [[ "$out" == *permitlisten* || "$out" == *permitopen* ]]; then
  ac_fail "AC1: restrict line contains permitlisten/permitopen: $out"
fi
# pty is now allowed (needed for the interactive menu); agent-forward is still not.
if [[ "$out" == *agent-forward* ]]; then
  ac_fail "AC1: restrict line contains agent-forward: $out"
fi
ac_log "AC1: key-command.sh prints one restrict line carrying the fingerprint"

# ── AC2. key-command.sh: unsupported key type -> empty stdout, non-zero exit ─
out=""
rc=0
out="$(ACCOUNTS_FILE="$ACCOUNTS_FILE" bash "$KEY_SCRIPT" "$FP" "ssh-dsa" "AAAAB...")" || rc=$?
if [ -n "$out" ]; then
  ac_fail "AC2: unsupported key type must produce empty stdout, got: $out"
fi
if [ "$rc" -eq 0 ]; then
  ac_fail "AC2: unsupported key type should exit non-zero (rc=0)"
fi
ac_log "AC2: unsupported key type -> empty stdout, exit 1"

# ── AC3. dispatch.sh whoami: fresh fp -> status=pending, credits=0 ────────────
out=""
rc=0
out="$(SSH_ORIGINAL_COMMAND="whoami" ACCOUNTS_FILE="$ACCOUNTS_FILE" bash "$DISPATCH_SCRIPT" "--fp" "$FP")" || rc=$?
if [ "$rc" -ne 0 ]; then
  ac_fail "AC3: dispatch whoami should succeed on a fresh fingerprint (rc=$rc, out=$out)"
fi
if ! jq -e '.status == "pending" and .credits == 0' <<<"$out" >/dev/null; then
  ac_fail "AC3: whoami row is not pending/credits-0: $out"
fi
# The ledger actually holds the row (proves account_ensure wrote it).
if ! jq -e --arg fp "$FP" '.accounts[$fp] | .status == "pending" and .credits == 0' "$ACCOUNTS_FILE" >/dev/null 2>&1; then
  ac_fail "AC3: ledger does not contain the fresh row for $FP"
fi
ac_log "AC3: dispatch whoami on a fresh fingerprint -> pending, credits 0"

# ── AC4. dispatch.sh: unknown verb -> {"error":"unknown command"}; and a
#    command string with shell metacharacters is never eval'd / executed
#    outside verbs/ (a sentinel dir must survive). ────────────────────────────
# (a) a token that is not a verb in verbs/ must be refused.
out=""
rc=0
out="$(SSH_ORIGINAL_COMMAND="rm -rf /nope" ACCOUNTS_FILE="$ACCOUNTS_FILE" bash "$DISPATCH_SCRIPT" "--fp" "$FP2")" || rc=$?
if [ "$rc" -eq 0 ]; then
  ac_fail "AC4a: unknown verb should exit non-zero (rc=$rc, out=$out)"
fi
case "$out" in
  *"unknown command"*) ;;
  *) ac_fail "AC4a: unknown verb did not return unknown-command JSON: $out" ;;
esac
ac_log "AC4a: unknown verb -> unknown-command JSON"

# (b) a 'safe' verb must survive a malicious command string: the ';' and
# 'rm -rf' are passed as inert arguments to the verb, never eval'd. A sentinel
# dir would be destroyed if the string were ever shell-interpreted.
out=""
rc=0
SENTINEL="$TMP_DIR/sentinel"
mkdir -p "$SENTINEL"
printf 'must-survive\n' > "$SENTINEL/keep.txt"
out="$(SSH_ORIGINAL_COMMAND="whoami ; rm -rf $TMP_DIR" ACCOUNTS_FILE="$ACCOUNTS_FILE" bash "$DISPATCH_SCRIPT" "--fp" "$FP")" || rc=$?
if [ "$rc" -ne 0 ]; then
  ac_fail "AC4b: dispatch of 'whoami ; rm -rf ...' should still run whoami (rc=$rc, out=$out)"
fi
if ! jq -e '.status == "pending"' <<<"$out" >/dev/null; then
  ac_fail "AC4b: whoami row missing from malicious-string dispatch: $out"
fi
if [ ! -f "$SENTINEL/keep.txt" ]; then
  ac_fail "AC4b: command string was eval'd/exec'd outside verbs/ (sentinel destroyed)"
fi
ac_log "AC4b: command string is never eval'd; only verbs/ files execute"

# ── AC5. dispatch.sh: no --fp -> non-zero, no account row written ─────────────
ACCOUNTS_FILE_5="$TMP_DIR/accounts-no-fp.json"
out=""
rc=0
out="$(SSH_ORIGINAL_COMMAND="whoami" ACCOUNTS_FILE="$ACCOUNTS_FILE_5" bash "$DISPATCH_SCRIPT")" || rc=$?
if [ "$rc" -eq 0 ]; then
  ac_fail "AC5: dispatch with no --fp must exit non-zero (rc=0, out=$out)"
fi
if [ -f "$ACCOUNTS_FILE_5" ] && jq -e '.accounts | length > 0' "$ACCOUNTS_FILE_5" >/dev/null 2>&1; then
  ac_fail "AC5: dispatch with no --fp wrote an account row"
fi
ac_log "AC5: dispatch with no --fp -> non-zero, no account row"

ac_pass
