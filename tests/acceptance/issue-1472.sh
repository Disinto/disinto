#!/usr/bin/env bash
# =============================================================================
# tests/acceptance/issue-1472.sh
#
# Issue #1472: feat(edge): TTY menu over the same dispatcher verbs
#
# Exercises the interactive login path: when SSH_ORIGINAL_COMMAND is empty (or
# DISPATCH_FORCE_MENU=1) the dispatcher prints the executable names in verbs/
# one per line and treats the next stdin line as the forced command, using the
# same verb rules as a non-interactive command.
#
#   AC1  key-command.sh line includes pty and restrict,command=, and includes
#         neither permitlisten nor permitopen.
#   AC2  DISPATCH_FORCE_MENU=1 with stdin line "whoami" prints the account JSON
#         (status=pending, credits=0, for a fresh fingerprint).
#   AC3  DISPATCH_FORCE_MENU=1 with a verb that is not in verbs/ ->
#         {"error":"unknown command"}.
#   AC4  DISPATCH_FORCE_MENU=1 with an empty line exits 0 and does not create
#         any account beyond the one created by ensure.
#
# Run via: tools/run-acceptance.sh 1472
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

ac_assert_file "$KEY_SCRIPT" "tools/edge-control/key-command.sh is missing"
ac_assert_file "$DISPATCH_SCRIPT" "tools/edge-control/dispatch.sh is missing"
ac_assert_file "$VERBS_DIR/whoami.sh" "verbs/whoami.sh is missing"
ac_assert_file "$VERBS_DIR/status.sh" "verbs/status.sh is missing"
ac_log "issue-1472: menu-over-verbs acceptance test"

# Throwaway ledger — never touches the live /var/lib/disinto or /etc/ssh.
TMP_DIR="$(mktemp -d)"
ACCOUNTS_FILE="$TMP_DIR/accounts.json"
trap 'rm -rf "$TMP_DIR"' EXIT
ac_log "issue-1472: ledger at $ACCOUNTS_FILE"

# Valid SHA256 fingerprint: "SHA256:" + exactly 43 base64url chars.
FP="SHA256:$(printf 'A%.0s' {1..43})"
FP2="SHA256:$(printf 'B%.0s' {1..43})"
FP3="SHA256:$(printf 'C%.0s' {1..43})"
[[ "$FP" =~ ^SHA256:[A-Za-z0-9_-]{43}$ ]] \
  || ac_fail "test fixture fingerprint is malformed: $FP"

# ── AC1. key-command.sh line includes pty and restrict,command=, no permitlisten/permitopen ───
KEY_OUT="$(ACCOUNTS_FILE="$ACCOUNTS_FILE" bash "$KEY_SCRIPT" "$FP" "ssh-ed25519" "AAAAB...")"
if [[ $(printf '%s\n' "$KEY_OUT" | grep -c .) -ne 1 ]]; then
  ac_fail "AC1: key-command.sh should print exactly one line, got: $KEY_OUT"
fi
if ! grep -qE '^pty,restrict,command=' <<<"$KEY_OUT"; then
  ac_fail "AC1: key-command.sh line is not a pty,restrict,command line: $KEY_OUT"
fi
if ! grep -qF "$FP" <<<"$KEY_OUT"; then
  ac_fail "AC1: restrict line does not contain the fingerprint"
fi
if grep -qE 'permitlisten|permitopen' <<<"$KEY_OUT"; then
  ac_fail "AC1: restrict line contains permitlisten/permitopen: $KEY_OUT"
fi
ac_log "AC1: key-command.sh prints pty,restrict,command line carrying the fingerprint"

# ── AC2. DISPATCH_FORCE_MENU=1 with stdin line "whoami" -> account JSON ───────
# The menu prints verb names to stdout, then the verb (whoami) prints the
# account JSON to stdout. The test extracts the JSON line (the only line that
# starts with {).
MENU_OUT=""
MENU_RC=0
MENU_OUT="$(printf 'whoami\n' | \
      ACCOUNTS_FILE="$ACCOUNTS_FILE" \
      SSH_ORIGINAL_COMMAND="" \
      DISPATCH_FORCE_MENU=1 \
      bash "$DISPATCH_SCRIPT" "--fp" "$FP")" || MENU_RC=$?
if [ "$MENU_RC" -ne 0 ]; then
  ac_fail "AC2: menu 'whoami' should exit 0 (rc=$MENU_RC, out=$MENU_OUT)"
fi
# Extract the account JSON line (first line starting with {).
JSON_LINE="$(printf '%s\n' "$MENU_OUT" | grep '^{' | head -n1)"
if [ -z "$JSON_LINE" ]; then
  ac_fail "AC2: menu whoami output has no JSON line: $MENU_OUT"
fi
if ! jq -e '.status == "pending" and .credits == 0' <<<"$JSON_LINE" >/dev/null; then
  ac_fail "AC2: menu whoami row is not pending/credits-0: $JSON_LINE"
fi
ac_log "AC2: DISPATCH_FORCE_MENU=1 with stdin 'whoami' -> account JSON"

# ── AC3. DISPATCH_FORCE_MENU=1 with verb not in verbs/ -> unknown command ────
UNK_OUT=""
UNK_RC=0
UNK_OUT="$(printf 'does-not-exist\n' | \
      ACCOUNTS_FILE="$ACCOUNTS_FILE" \
      SSH_ORIGINAL_COMMAND="" \
      DISPATCH_FORCE_MENU=1 \
      bash "$DISPATCH_SCRIPT" "--fp" "$FP2")" || UNK_RC=$?
if [ "$UNK_RC" -eq 0 ]; then
  ac_fail "AC3: unknown menu verb should exit non-zero (rc=0, out=$UNK_OUT)"
fi
if ! grep -qF '"unknown command"' <<<"$UNK_OUT"; then
  ac_fail "AC3: unknown menu verb did not return unknown-command JSON: $UNK_OUT"
fi
ac_log "AC3: DISPATCH_FORCE_MENU=1 with unknown verb -> unknown-command JSON"

# ── AC4. DISPATCH_FORCE_MENU=1 with empty line -> rc=0, no account beyond ensure ───
EMP_OUT=""
EMP_RC=0
EMP_OUT="$(printf '\n' | \
      ACCOUNTS_FILE="$ACCOUNTS_FILE" \
      SSH_ORIGINAL_COMMAND="" \
      DISPATCH_FORCE_MENU=1 \
      bash "$DISPATCH_SCRIPT" "--fp" "$FP3")" || EMP_RC=$?
if [ "$EMP_RC" -ne 0 ]; then
  ac_fail "AC4: empty menu line should exit 0 (rc=$EMP_RC, out=$EMP_OUT)"
fi
# The output should be just the menu lines (one per verb) — no extra output.
# Extract the JSON lines: there should be none.
JSON_COUNT="$(printf '%s\n' "$EMP_OUT" | grep -c '^{' || true)"
if [ "$JSON_COUNT" -gt 0 ]; then
  ac_fail "AC4: empty menu line produced JSON output (expected 0): $EMP_OUT"
fi
ac_log "AC4: DISPATCH_FORCE_MENU=1 with empty line -> rc=0, no verb ran"

ac_pass
