#!/usr/bin/env bash
# =============================================================================
# tests/acceptance/issue-1557.sh
#
# Issue #1557: feat(edge): tunnel authorized_keys uses the stored public key
#
# The tunnel account (disinto-tunnel) is a different sshd user than the caller
# (`porter`); its authorized_keys is rebuilt from the port registry. The old
# rebuild wrote the registry entry's copied `pubkey` — and apply_approve put
# the ledger *fingerprint* there when the row has no pubkey — so the line
# could never authenticate. This change makes rebuild_authorized_keys
# (lib/authorized_keys.sh) read each registered project, find the ledger row
# for that project name, and write a line ONLY when that row's `pubkey` field
# is an allowlisted public key:
#
#     restrict,port-forwarding,permitlisten="127.0.0.1:PORT",command="/bin/false" PUBKEY
#
# Contract under test (#1557):
#   * AC1: a registered project whose ledger row carries a valid pubkey produces
#         exactly one permitlisten line for that port and that (ledger) key —
#         byte-for-byte, no extra options, command="/bin/false";
#   * AC2: a row with no `pubkey`, or a `pubkey` equal to a fingerprint,
#         produces no line (the fingerprint and the registry's copied field
#         are never written);
#   * AC3: a second project that is not in the registry is not written, even
#         if its ledger row carries a valid key;
#   * AC4: the test exits 0 and calls ac_pass.
#
# Hermetic: no network. Temp registry + ledger in a throwaway root (never
# /var/lib/disinto); PORTER_ROOT is that root so every path is throwaway.
# The tunnel user is NOT created by the lib under test — the test only verifies
# the file the lib writes.
#
# Run via: tools/run-acceptance.sh 1557
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=../lib/acceptance-helpers.sh
source "$REPO_ROOT/tests/lib/acceptance-helpers.sh"

ac_require_cmd bash jq grep cmp mktemp rm cat printf head
ac_require_cmd mktemp

AUTH_KEYS_LIB="$REPO_ROOT/tools/edge-control/lib/authorized_keys.sh"
ac_assert_file "$AUTH_KEYS_LIB" "tools/edge-control/lib/authorized_keys.sh is missing"

# The lib must never *invoke* the tunnel-user creation (that is
# porter-install.sh's job). Comments may mention it; an actual command line
# (a non-comment line with `useradd` as a word) must not exist.
if grep -vE '^[[:space:]]*#' "$AUTH_KEYS_LIB" | grep -EqE '\buseradd\b'; then
  ac_fail "lib/authorized_keys.sh must not call useradd (that is porter-install.sh's job)"
fi

# ── Fixtures: throwaway registry + ledger under a throwaway PORTER_ROOT ──────
TMP_DIR="$(mktemp -d /tmp/disinto-acceptance-1557.XXXXXX)"
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
FP_D="SHA256:$(printf 'D%.0s' {1..43})"

# The valid ed25519 key stored on acme's ledger row (AC1's expected key).
KEY_DATA="AAAAC3NzaC1lZDI1NTE5AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAB"
ACME_PUBKEY="ssh-ed25519 ${KEY_DATA}"
# A valid key for a project that is NOT in the registry (AC3's discriminator).
GHOST_PUBKEY="ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAAAAAA"

# Ledger: acme has a valid pubkey; norkey has none; fakekey's "pubkey" is its
# own fingerprint; ghost has a valid pubkey but is never registered.
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
    },
    "$FP_D": {
      "fingerprint": "$FP_D",
      "status": "approved", "credits": 0, "name": "ghost", "admin": false,
      "created_at": "2026-01-01T00:00:00Z",
      "pubkey": "$GHOST_PUBKEY"
    }
  }
}
EOF

# Registry: acme/norkey/fakekey are registered (ghost is deliberately absent).
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

# ── AC1. registered project with a valid ledger pubkey -> exactly one line ───
ac_assert_file "$TUNNEL_AUTH_KEYS" \
  "authorized_keys file not written at the PORTER_ROOT-prefixed path ($TUNNEL_AUTH_KEYS)"

# Byte-for-byte: one line, the registry port, the LEDGER key (not the
# registry's copied garbage "ssh-ed25519 XREGISTRY"), restrict +
# port-forwarding + permitlisten + command="/bin/false" and nothing else.
actual="$(cat "$TUNNEL_AUTH_KEYS" 2>/dev/null || true)"
EXPECTED_LINE='restrict,port-forwarding,permitlisten="127.0.0.1:20000",command="/bin/false" '"$ACME_PUBKEY"
if [ "$actual" != "$EXPECTED_LINE" ]; then
  ac_fail "AC1: authorized_keys content is not exactly the acme line (got: '$actual')"
fi
ac_log "AC1: registered project with a valid ledger pubkey produced exactly its permitlisten line"

# ── AC2. no row-key / fingerprint row -> no line; registry garbage never written ──
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
ac_log "AC2: no-key and fingerprint rows produce no line; the registry's copied field is never written"

# ── AC3. project not in the registry -> not written (even with a valid key) ─
if grep -qF "$GHOST_PUBKEY" "$TUNNEL_AUTH_KEYS" 2>/dev/null; then
  ac_fail "AC3: ghost (valid ledger key but NOT in the registry) was written"
fi
if [ "$(wc -l < "$TUNNEL_AUTH_KEYS" 2>/dev/null || echo 0)" != "1" ]; then
  ac_fail "AC3: expected exactly one line (only registered projects), got $(wc -l < "$TUNNEL_AUTH_KEYS" 2>/dev/null || echo 0)"
fi
ac_log "AC3: a project absent from the registry is not written"

# ── AC4. all acceptance criteria passed ──────────────────────────────────────
ac_log "AC4: all checks passed"
ac_pass
