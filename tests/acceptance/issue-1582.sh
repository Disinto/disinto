#!/usr/bin/env bash
# =============================================================================
# tests/acceptance/issue-1582.sh
#
# Issue #1582: fix(edge): a reverse-tunnel key must not force /bin/false
#
# rebuild_authorized_keys (lib/authorized_keys.sh) used to write
# command="/bin/false" into each tunnel line. sshd runs a forced command
# instead of keeping the session idle; /bin/false exits immediately, so the
# connection closes and the -R reverse forward dies — a persistent tunnel
# cannot use that line. This change drops command="/bin/false": the line is
# restrict,port-forwarding,permitlisten="127.0.0.1:PORT" PUBKEY, with no forced
# command. permitlisten is still pinned to the registry port (not weakened),
# and the tunnel user's shell is still nologin, so a session without -N gets
# no shell.
#
# Contract under test (#1582):
#   * AC1: a generated line carries permitlisten="127.0.0.1:PORT" for the
#          registry port and contains no command=;
#   * AC2: a ledger row with no valid pubkey (absent or a fingerprint) produces
#          no line;
#   * AC3: tests/acceptance/issue-1557.sh exits 0 against the new line;
#   * AC4: all acceptance criteria pass (this script exits 0 and calls ac_pass).
#
# Hermetic: no network, no root. Throwaway registry + ledger under a throwaway
# PORTER_ROOT (never /var/lib/disinto). The tunnel user is NOT created by the
# lib under test — the test only verifies the file the lib writes.
#
# Run via: tools/run-acceptance.sh 1582
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=../lib/acceptance-helpers.sh
source "$REPO_ROOT/tests/lib/acceptance-helpers.sh"

ac_require_cmd bash jq grep cmp mktemp rm cat printf head

AUTH_KEYS_LIB="$REPO_ROOT/tools/edge-control/lib/authorized_keys.sh"
ac_assert_file "$AUTH_KEYS_LIB" "tools/edge-control/lib/authorized_keys.sh is missing"

# ── Fixtures: throwaway registry + ledger under a throwaway PORTER_ROOT ──────
TMP_DIR="$(mktemp -d /tmp/disinto-acceptance-1582.XXXXXX)"
cleanup() {
  rm -rf "$TMP_DIR" 2>/dev/null || true
}
trap cleanup EXIT

ROOT="$TMP_DIR/root"
mkdir -p "$ROOT/var/lib/disinto" "$ROOT/home"

ACCOUNTS_FILE="$ROOT/var/lib/disinto/accounts.json"
REGISTRY_DIR="$ROOT/var/lib/disinto"
REGISTRY_FILE="$ROOT/var/lib/disinto/registry.json"
TUNNEL_AUTH_KEYS="$ROOT/home/disinto-tunnel/.ssh/authorized_keys"

# Realistic fingerprints (SHA256: + 43 base64url chars), distinct per row.
FP_A="SHA256:$(printf 'A%.0s' {1..43})"
FP_B="SHA256:$(printf 'B%.0s' {1..43})"
FP_C="SHA256:$(printf 'C%.0s' {1..43})"

# The valid ed25519 key stored on acme's ledger row (AC1's expected key).
KEY_DATA="AAAAC3NzaC1lZDI1NTE5AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAB"
ACME_PUBKEY="ssh-ed25519 ${KEY_DATA}"

# Ledger: acme has a valid pubkey; norkey has none; fakekey's "pubkey" is its
# own fingerprint.
cat > "$ACCOUNTS_FILE" <<EOF
{
  "version": 1,
  "accounts": {
    "$FP_A": {
      "fingerprint": "$FP_A",
      "status": "approved", "credits": 0, "name": "acme", "admin": false,
      "created_at": "2026-01-01T00:00:00Z",
      "pubkey": "$ACME_PUBKEY"
    },
    "$FP_B": {
      "fingerprint": "$FP_B",
      "status": "approved", "credits": 0, "name": "norkey", "admin": false,
      "created_at": "2026-01-01T00:00:00Z"
    },
    "$FP_C": {
      "fingerprint": "$FP_C",
      "status": "approved", "credits": 0, "name": "fakekey", "admin": false,
      "created_at": "2026-01-01T00:00:00Z",
      "pubkey": "$FP_C"
    }
  }
}
EOF

# Registry: acme/norkey/fakekey are registered.
# The registry's copied `pubkey` fields are deliberately *wrong* garbage so a
# regression that read the registry instead of the ledger fails loudly.
cat > "$REGISTRY_FILE" <<EOF
{
  "version": 1,
  "projects": {
    "acme":    { "port": 20000, "fqdn": "acme.disinto.ai",  "registered_by": "admin", "pubkey": "ssh-ed25519 XREGISTRY" },
    "norkey":  { "port": 20001, "fqdn": "norkey.disinto.ai", "registered_by": "admin", "pubkey": "not-a-key-at-all" },
    "fakekey": { "port": 20002, "fqdn": "fakekey.disinto.ai","registered_by": "admin", "pubkey": "ssh-ed25519 YREGISTRY" }
  }
}
EOF

# ── Drive the lib: source it in a subshell with throwaway env ───────────────
run_rebuild() {
  local err_file
  err_file="$TMP_DIR/rebuild.err"
  rc=0
  {
    export ACCOUNTS_FILE="$ACCOUNTS_FILE"
    export REGISTRY_DIR="$REGISTRY_DIR"
    export PORTER_ROOT="$ROOT"
    # shellcheck source=lib/authorized_keys.sh
    source "$AUTH_KEYS_LIB"
    rebuild_authorized_keys
  } 2>"$err_file" || rc=$?
  err="$(cat "$err_file" 2>/dev/null || true)"
}

run_rebuild
if [ "$rc" -ne 0 ]; then
  ac_fail "precondition: rebuild_authorized_keys must exit 0 (rc=$rc, err=$err)"
fi

# ── AC1. generated line: permitlisten for the port, no command= ───────────────
ac_assert_file "$TUNNEL_AUTH_KEYS" \
  "authorized_keys file not written at the PORTER_ROOT-prefixed path ($TUNNEL_AUTH_KEYS)"

actual="$(cat "$TUNNEL_AUTH_KEYS" 2>/dev/null || true)"

# The acme line must be present: permitlisten pinned to the registry port.
if ! printf '%s\n' "$actual" | grep -qF 'permitlisten="127.0.0.1:20000"'; then
  ac_fail "AC1: no permitlisten line for the registry port 20000 (got: '$actual')"
fi

# The line must carry the ledger key, not the registry garbage.
if ! printf '%s\n' "$actual" | grep -qF "$ACME_PUBKEY"; then
  ac_fail "AC1: the ledger pubkey is missing (got: '$actual')"
fi

# No forced command= anywhere — the crux of this issue. (Fixed-string match
# so there is no regex to get wrong: the old line was command="/bin/false".)
if printf '%s\n' "$actual" | grep -qF 'command="'; then
  ac_fail "AC1: generated line still carries command= (got: '$actual')"
fi

# Byte-for-byte the expected new format: one line, permitlisten, no command=,
# then the ledger pubkey.
EXPECTED_LINE='restrict,port-forwarding,permitlisten="127.0.0.1:20000" '"$ACME_PUBKEY"
if [ "$actual" != "$EXPECTED_LINE" ]; then
  ac_fail "AC1: authorized_keys content is not exactly the expected new line (got: '$actual')"
fi
ac_log "AC1: generated line has permitlisten for the registry port and no command="

# ── AC2. no-key / fingerprint row -> no line; registry garbage never written ──
if grep -qF 'permitlisten="127.0.0.1:20001"' "$TUNNEL_AUTH_KEYS" 2>/dev/null; then
  ac_fail "AC2: norkey (ledger row has no pubkey) produced a line"
fi
if grep -qF 'permitlisten="127.0.0.1:20002"' "$TUNNEL_AUTH_KEYS" 2>/dev/null; then
  ac_fail "AC2: fakekey (ledger pubkey is a fingerprint) produced a line"
fi
if grep -qF "$FP_C" "$TUNNEL_AUTH_KEYS" 2>/dev/null; then
  ac_fail "AC2: the ledger fingerprint was written into authorized_keys"
fi
if grep -qF 'ssh-ed25519 XREGISTRY' "$TUNNEL_AUTH_KEYS" 2>/dev/null; then
  ac_fail "AC2: the registry's copied acme pubkey was written (lib must read the ledger)"
fi
if grep -qF 'ssh-ed25519 YREGISTRY' "$TUNNEL_AUTH_KEYS" 2>/dev/null; then
  ac_fail "AC2: the registry's copied fakekey pubkey was written (lib must read the ledger)"
fi
# Exactly one line total (only the valid acme row).
if [ "$(wc -l < "$TUNNEL_AUTH_KEYS" 2>/dev/null || echo 0)" != "1" ]; then
  ac_fail "AC2: expected exactly one line, got $(wc -l < "$TUNNEL_AUTH_KEYS" 2>/dev/null || echo 0)"
fi
ac_log "AC2: no-key and fingerprint rows produce no line; the registry's copied field is never written"

# ── AC3. issue-1557.sh exits 0 against the new line ──────────────────────────
ac_log "AC3: issue-1557.sh passes against the new line"
FIFTYSEVEN="$REPO_ROOT/tests/acceptance/issue-1557.sh"
ac_assert_file "$FIFTYSEVEN" "tests/acceptance/issue-1557.sh is missing"
rc=0
out="$(bash "$FIFTYSEVEN" 2>&1) || rc=$?"
if [ "$rc" -ne 0 ]; then
  ac_fail "AC3: issue-1557.sh does not exit 0 against the new line (rc=$rc, out=$out)"
fi
ac_log "AC3: issue-1557.sh exited 0"

# ── AC4. all acceptance criteria passed ──────────────────────────────────────
ac_log "AC4: all checks passed"
ac_pass
