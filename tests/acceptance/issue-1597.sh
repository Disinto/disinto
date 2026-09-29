#!/usr/bin/env bash
# =============================================================================
# tests/acceptance/issue-1597.sh
#
# Issue #1597: feat(dev): jev-scope calls the door and fails closed.
#
# Contract under test:
#   * AC1: missing configuration (missing key file, empty target, missing
#          known_hosts file) → exit 2, nothing on stdout or stderr, ssh
#          never invoked.
#   * AC2: a stub ssh that prints a scope body (a JSON object with an
#          `answers` object) is passed through verbatim on stdout and the
#          script exits 0. The stub is invoked as `jev scope` against the
#          configured target, and the issue text is forwarded through stdin.
#   * AC3: a stub ssh that prints {"error":"not approved"} exits 1 and
#          prints nothing on stdout (one line on stderr, no key material).
#   * AC4: a stub ssh that exits non-zero (ssh failure) exits 1 and prints
#          nothing on stdout.
#   * AC5: an empty, non-JSON, or answers-less body exits 1 and prints
#          nothing on stdout.
#   * AC6: the test exits 0 and calls ac_pass.
#
# Hermetic: no network, no ssh client. A single controllable fake `ssh` is
# written to a throwaway dir and put on PATH for each run, so every outcome
# is decided by the stub.
#
# Run via: tools/run-acceptance.sh 1597
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=../lib/acceptance-helpers.sh
source "$REPO_ROOT/tests/lib/acceptance-helpers.sh"

ac_require_cmd bash grep cat cmp mktemp printf rm chmod jq

TOOL="$REPO_ROOT/tools/jev-scope.sh"
ac_assert_file "$TOOL" "tools/jev-scope.sh is missing"

TMP_DIR="$(mktemp -d /tmp/disinto-acceptance-1597.XXXXXX)"
teardown() {
  rm -rf "$TMP_DIR" 2>/dev/null || true
}
trap teardown EXIT

ISSUE_TEXT="the proposal is one concept, one repo, one observable behavior"
KEY_FILE="$TMP_DIR/jev-key"
KNOWN_HOSTS="$TMP_DIR/known_hosts"
printf '%s\n' "ssh-ed25519 door fingerprint placeholder" > "$KNOWN_HOSTS"
printf '%s\n' 'fake private key' > "$KEY_FILE"

TARGET="porter@door.example"

# ── Stub: a fake `ssh` whose behaviour is set by exported env vars ───────────
STUB_DIR="$TMP_DIR/stubs"
mkdir -p "$STUB_DIR"

# The stub records its invocation and stdin so the test can prove the tool
# dialed the door and forwarded the issue text. SSH_STUB_RC / SSH_STUB_BODY
# play the role the real door would: exit status and response body.
cat > "$STUB_DIR/ssh" <<'STUB_EOF'
#!/usr/bin/env bash
if [[ -n "${SSH_STUB_LOG:-}" ]]; then
  printf 'ssh: %s\n' "$*" >> "${SSH_STUB_LOG}"
fi
if [[ -n "${SSH_STDIN_LOG:-}" ]]; then
  cat >> "${SSH_STDIN_LOG}"
fi
printf '%s\n' "${SSH_STUB_BODY:-}"
exit "${SSH_STUB_RC:-0}"
STUB_EOF
chmod +x "$STUB_DIR/ssh"

# Run the tool exactly as the factory would: issue text piped in on stdin,
# the stub `ssh` at the front of PATH, stdout/stderr captured separately.
# Sets RC / OUT_FILE / ERR_FILE in the caller.
run_case() {
  rc=0
  printf '%s\n' "$ISSUE_TEXT" \
    | PATH="$STUB_DIR:$PATH" bash "$TOOL" \
      >"$OUT_FILE" 2>"$ERR_FILE" || rc=$?
  RC=$rc
}

# ── AC1. missing configuration → exit 2, no output, no ssh ────────────────────
ac_log "AC1: missing configuration exits 2 with no output and no ssh"
mkdir -p "$TMP_DIR/case1"
OUT_FILE="$TMP_DIR/case1/out.txt"
ERR_FILE="$TMP_DIR/case1/err.txt"
SSH_LOG="$TMP_DIR/case1/ssh.log"

# 1a: missing key file (key path does not exist).
export PORTER_SSH_TARGET="$TARGET" PORTER_JEV_KEY="$TMP_DIR/missing-key" \
       PORTER_JEV_KNOWN_HOSTS="$KNOWN_HOSTS" SSH_STUB_LOG="$SSH_LOG"
run_case
ac_assert_eq "$RC" "2" "AC1a: missing key file must exit 2 (got $RC)"
[ -s "$OUT_FILE" ] && ac_fail "AC1a: missing key file must print nothing on stdout"
[ -s "$ERR_FILE" ] && ac_fail "AC1a: missing key file must print nothing on stderr"
[ -s "$SSH_LOG" ] && ac_fail "AC1a: ssh must not be invoked when the key is missing"

# 1b: empty target.
: > "$SSH_LOG"
export PORTER_SSH_TARGET='' PORTER_JEV_KEY="$KEY_FILE"
run_case
ac_assert_eq "$RC" "2" "AC1b: empty target must exit 2 (got $RC)"
[ -s "$OUT_FILE" ] && ac_fail "AC1b: empty target must print nothing on stdout"
[ -s "$ERR_FILE" ] && ac_fail "AC1b: empty target must print nothing on stderr"
[ -s "$SSH_LOG" ] && ac_fail "AC1b: ssh must not be invoked with an empty target"

# 1c: missing known_hosts file.
: > "$SSH_LOG"
export PORTER_SSH_TARGET="$TARGET" \
       PORTER_JEV_KEY="$KEY_FILE" PORTER_JEV_KNOWN_HOSTS="$TMP_DIR/missing-known-hosts"
run_case
ac_assert_eq "$RC" "2" "AC1c: missing known_hosts file must exit 2 (got $RC)"
[ -s "$OUT_FILE" ] && ac_fail "AC1c: missing known_hosts must print nothing on stdout"
[ -s "$ERR_FILE" ] && ac_fail "AC1c: missing known_hosts must print nothing on stderr"
[ -s "$SSH_LOG" ] && ac_fail "AC1c: ssh must not be invoked with a missing known_hosts file"
ac_log "AC1: all missing-configuration paths exit 2, silent, ssh-free"

# ── AC2. valid scope reading → verbatim pass-through, exit 0 ─────────────────
ac_log "AC2: a stub ssh printing an answers object is passed through, exit 0"
SCOPE_BODY='{"model":"jev-1.13.0","answers":{"one_concept":true,"one_repo":true,"one_behavior":true}}'
mkdir -p "$TMP_DIR/case2"
OUT_FILE="$TMP_DIR/case2/out.txt"
ERR_FILE="$TMP_DIR/case2/err.txt"
SSH_LOG="$TMP_DIR/case2/ssh.log"
SSH_STDIN_LOG="$TMP_DIR/case2/stdin.log"
export PORTER_SSH_TARGET="$TARGET" PORTER_JEV_KEY="$KEY_FILE" \
       PORTER_JEV_KNOWN_HOSTS="$KNOWN_HOSTS" SSH_STUB_RC=0 \
       SSH_STUB_BODY="$SCOPE_BODY" SSH_STUB_LOG="$SSH_LOG" \
       SSH_STDIN_LOG="$SSH_STDIN_LOG"
run_case
ac_assert_eq "$RC" "0" "AC2: valid scope reading must exit 0 (got $RC)"
[ -s "$ERR_FILE" ] && ac_fail "AC2: valid scope reading must print nothing on stderr"
# Byte-for-byte pass-through: the tool must echo the body, unaltered.
printf '%s\n' "$SCOPE_BODY" > "$TMP_DIR/case2/expected.txt"
cmp -s "$OUT_FILE" "$TMP_DIR/case2/expected.txt" \
  || ac_fail "AC2: stdout is not the body verbatim"
# The door was called as `jev scope` against the configured target.
grep -qF "jev scope" "$SSH_LOG" \
  || ac_fail "AC2: the stub was not invoked with the verb 'jev scope'"
grep -qF "$TARGET" "$SSH_LOG" \
  || ac_fail "AC2: the stub was not invoked against the configured target"
# The issue text reached the door on stdin.
grep -qF "$ISSUE_TEXT" "$SSH_STDIN_LOG" \
  || ac_fail "AC2: the issue text was not forwarded on stdin"
# jq agrees the body is a scope reading (object with an answers object).
jq -e 'type == "object" and ((.answers | type) == "object")' "$OUT_FILE" >/dev/null \
  || ac_fail "AC2: the body is not an object with an answers object"
ac_log "AC2: body passed through verbatim, exit 0, door dialed as jev scope"

# ── AC3. {"error":"not approved"} → exit 1, nothing on stdout ─────────────────
ac_log "AC3: a stub ssh printing an error body exits 1, nothing on stdout"
mkdir -p "$TMP_DIR/case3"
OUT_FILE="$TMP_DIR/case3/out.txt"
ERR_FILE="$TMP_DIR/case3/err.txt"
SSH_LOG="$TMP_DIR/case3/ssh.log"
export PORTER_SSH_TARGET="$TARGET" PORTER_JEV_KEY="$KEY_FILE" \
       PORTER_JEV_KNOWN_HOSTS="$KNOWN_HOSTS" SSH_STUB_RC=0 \
       SSH_STUB_BODY='{"error":"not approved"}' SSH_STUB_LOG="$SSH_LOG"
run_case
ac_assert_eq "$RC" "1" "AC3: {\"error\":\"not approved\"} must exit 1 (got $RC)"
[ -s "$OUT_FILE" ] && ac_fail "AC3: an error body must print nothing on stdout"
[ -s "$ERR_FILE" ] || ac_fail "AC3: an error body must print one line on stderr"
err_lines="$(wc -l < "$ERR_FILE")"
[ "$err_lines" -eq 1 ] \
  || ac_fail "AC3: the stderr line must be exactly one line (got $err_lines)"
# Never the key path, never key material.
grep -qF "$KEY_FILE" "$ERR_FILE" && ac_fail "AC3: stderr must never carry the key path"
ac_log "AC3: error body fails closed (exit 1, silent stdout)"

# ── AC4. ssh failure (non-zero stub) → exit 1, nothing on stdout ──────────────
ac_log "AC4: a failing stub ssh exits 1, nothing on stdout"
mkdir -p "$TMP_DIR/case4"
OUT_FILE="$TMP_DIR/case4/out.txt"
ERR_FILE="$TMP_DIR/case4/err.txt"
SSH_LOG="$TMP_DIR/case4/ssh.log"
export PORTER_SSH_TARGET="$TARGET" PORTER_JEV_KEY="$KEY_FILE" \
       PORTER_JEV_KNOWN_HOSTS="$KNOWN_HOSTS" SSH_STUB_RC=99 SSH_STUB_BODY='' \
       SSH_STUB_LOG="$SSH_LOG"
run_case
ac_assert_eq "$RC" "1" "AC4: a non-zero ssh exit must yield exit 1 (got $RC)"
[ -s "$OUT_FILE" ] && ac_fail "AC4: an ssh failure must print nothing on stdout"
[ -s "$ERR_FILE" ] || ac_fail "AC4: an ssh failure must print one line on stderr"
err_lines="$(wc -l < "$ERR_FILE")"
[ "$err_lines" -eq 1 ] \
  || ac_fail "AC4: the stderr line must be exactly one line (got $err_lines)"
grep -qF "$KEY_FILE" "$ERR_FILE" && ac_fail "AC4: stderr must never carry the key path"
ac_log "AC4: ssh failure fails closed (exit 1, silent stdout)"

# ── AC5. empty / non-JSON / answers-less body → exit 1, nothing on stdout ─────
ac_log "AC5: empty, non-JSON, and answers-less bodies exit 1, nothing on stdout"
mkdir -p "$TMP_DIR/case5"
OUT_FILE="$TMP_DIR/case5/out.txt"
ERR_FILE="$TMP_DIR/case5/err.txt"
SSH_LOG="$TMP_DIR/case5/ssh.log"
export PORTER_SSH_TARGET="$TARGET" PORTER_JEV_KEY="$KEY_FILE" \
       PORTER_JEV_KNOWN_HOSTS="$KNOWN_HOSTS" SSH_STUB_RC=0 \
       SSH_STUB_LOG="$SSH_LOG"

# 5a: empty body (ssh exits 0 with no output).
SSH_STUB_BODY=""
run_case
ac_assert_eq "$RC" "1" "AC5a: empty body must exit 1 (got $RC)"
[ -s "$OUT_FILE" ] && ac_fail "AC5a: empty body must print nothing on stdout"

# 5b: non-JSON body.
SSH_STUB_BODY="not json at all"
run_case
ac_assert_eq "$RC" "1" "AC5b: non-JSON body must exit 1 (got $RC)"
[ -s "$OUT_FILE" ] && ac_fail "AC5b: non-JSON body must print nothing on stdout"

# 5c: a JSON object without an answers object.
SSH_STUB_BODY='{"model":"jev-1.13.0"}'
run_case
ac_assert_eq "$RC" "1" "AC5c: an object without answers must exit 1 (got $RC)"
[ -s "$OUT_FILE" ] && ac_fail "AC5c: an answers-less object must print nothing on stdout"
ac_log "AC5: empty, non-JSON, and answers-less bodies fail closed"

# ── AC6. this test exits 0 via ac_pass ─────────────────────────────────────────
unset -v PORTER_SSH_TARGET PORTER_JEV_KEY PORTER_JEV_KNOWN_HOSTS \
      SSH_STUB_RC SSH_STUB_BODY SSH_STUB_LOG SSH_STDIN_LOG

ac_log "all acceptance criteria met for issue 1597"
ac_pass
