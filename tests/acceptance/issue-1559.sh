#!/usr/bin/env bash
# =============================================================================
# tests/acceptance/issue-1559.sh
#
# Issue #1559: feat(edge): revoke removes only that name's route and tunnel line
#
# revoke is the admin undo of a bound name. When EDGE_APPLY=1 it must drop EXACTLY
# the revoked name's Caddy route, free the port, and rebuild the tunnel
# authorized_keys so the revoked name's permitlisten line is gone while every
# other project's line remains. It must never touch DNS (no porter-dns.sh, no
# Gandi request) and must leave the ledger row intact (only `status` becomes
# revoked). This test drives verbs/revoke.sh through lib/apply-name.sh against
# a throwaway root and a stateful curl stub (no network) and asserts:
#
#   * AC1: with EDGE_APPLY=1, revoke of "acme" deletes only the route whose
#          host is exactly acme.disinto.ai — a stub server route for
#          self.disinto.ai survives, the route list holds no POST and exactly
#          one DELETE, the registry loses only "acme", and the row is rewritten
#          to status=revoked while keeping name, admin, credits and pubkey;
#   * AC2: the rebuilt authorized_keys contains the second project's
#          permitlisten line but none for the revoked name;
#   * AC3: with EDGE_APPLY=0, revoke invokes no curl at all (a pure ledger
#          mutation) and still prints the status=revoked row;
#   * AC4: no stubbed request URL/path contains gandi or a DNS record path
#          (the revoke path never calls porter-dns.sh), and the verb/lib
#          source is clean of such calls.
#
# The "failed route delete -> status unchanged" contract is enforced by the
# verb wiring (apply_revoke() returns 1 on any side-effect failure, so
# name-verbs.sh fail-exits with {"error":"apply failed"} BEFORE
# account_set_status runs) — the same contract 1558.sh AC2 exercises.
#
# Hermetic: no network. curl is a stateful stub that records every request
# (method, url, path, body) in a JSONL log and serves the Caddy admin API shape
# used by lib/caddy.sh. The port registry + account ledger are throwaway under
# $TMP_DIR (never /var/lib/disinto).
#
# Run via: tools/run-acceptance.sh 1559
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=../lib/acceptance-helpers.sh
source "$REPO_ROOT/tests/lib/acceptance-helpers.sh"
# shellcheck source=../lib/caddy-stub.sh
source "$REPO_ROOT/tests/lib/caddy-stub.sh"

ac_require_cmd bash jq grep mktemp rm cat printf sed awk chmod hostname env

REVOKE="$REPO_ROOT/tools/edge-control/verbs/revoke.sh"
APPLY="$REPO_ROOT/tools/edge-control/lib/apply-name.sh"
ac_assert_file "$REVOKE" "tools/edge-control/verbs/revoke.sh is missing"
ac_assert_file "$APPLY" "tools/edge-control/lib/apply-name.sh is missing"

# Source-level sanity: the revoke path must not shell out to Gandi /
# porter-dns.sh (comment lines may mention the files; code lines may not).
if grep -vE '^[[:space:]]*#' "$REVOKE" 2>/dev/null \
    | grep -EqiE 'porter-dns|gandi'; then
  ac_fail "verbs/revoke.sh must not call porter-dns.sh or shell out to Gandi"
fi
if grep -vE '^[[:space:]]*#' "$APPLY" 2>/dev/null \
    | grep -EqiE 'porter-dns|gandi'; then
  ac_fail "lib/apply-name.sh must not call porter-dns.sh or shell out to Gandi"
fi

# The verb reads EDGE_APPLY / PORTER_SSH_HOST from its environment; start the
# test with both clean so the "0" case is a real zero and "unset" would be
# genuinely unset.
unset -v PORTER_SSH_HOST EDGE_APPLY 2>/dev/null || true

# ── Fixtures ────────────────────────────────────────────────────────────────
# A valid (allowlisted) public key per customer project. The revoked project
# ("acme") and a second project ("other") each carry one.
KEY_DATA_ACME="AAAAC3NzaC1lZDI1NTE5AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAB"
ACME_PUBKEY="ssh-ed25519 ${KEY_DATA_ACME}"
KEY_DATA_OTHER="AAAAB3NzaC1yc2EAAAADAQABAAAAAAA"
OTHER_PUBKEY="ssh-rsa ${KEY_DATA_OTHER}"
# The exact line rebuild_authorized_keys must write for "other" (AC2).
OTHER_LINE='restrict,port-forwarding,permitlisten="127.0.0.1:20000" '"$OTHER_PUBKEY"

TMP_DIR="$(mktemp -d /tmp/disinto-acceptance-1559.XXXXXX)"
cleanup() {
  rm -rf "$TMP_DIR" 2>/dev/null || true
}
trap cleanup EXIT

ac_caddy_stub

# ── Helpers ─────────────────────────────────────────────────────────────────
# new_root <name> — a throwaway root: a registry holding "other" (port 20000)
# and "acme" (port 20001); a ledger with the admin plus both customers (each
# carrying a valid pubkey, plus a credits/name/admin mix to verify revocation
# preserves them); and a Caddy route list holding the operator's own
# self.disinto.ai route PLUS acme.disinto.ai (the route to be revoked).
new_root() {
  local name="$1"
  ROOT="$TMP_DIR/$name"
  mkdir -p "$ROOT/var/lib/disinto" "$ROOT/home/disinto-tunnel/.ssh"
  ACCOUNTS_FILE="$ROOT/var/lib/disinto/accounts.json"
  REGISTRY_DIR="$ROOT/var/lib/disinto"
  REGISTRY_FILE="$ROOT/var/lib/disinto/registry.json"
  TUNNEL_AUTH_KEYS="$ROOT/home/disinto-tunnel/.ssh/authorized_keys"

  printf '[]' > "$STATE"
  : > "$LOG"

  cat > "$REGISTRY_FILE" <<EOF
{
  "version": 1,
  "projects": {
    "other": { "port": 20000, "fqdn": "other.disinto.ai", "registered_by": "admin" },
    "acme":  { "port": 20001, "fqdn": "acme.disinto.ai", "registered_by": "admin" }
  }
}
EOF

  # Ledger: FP_ADMIN (the admin caller), FP_A = acme holder, FP_B = other
  # holder. Both holders carry a valid pubkey and non-zero credits/name/admin
  # values that revocation must NOT clear.
  cat > "$ACCOUNTS_FILE" <<EOF
{
  "version": 1,
  "accounts": {
    "$FP_ADMIN": {
      "fingerprint": "$FP_ADMIN",
      "status": "pending", "credits": 0, "name": null, "admin": true,
      "created_at": "2026-01-01T00:00:00Z"
    },
    "$FP_A": {
      "fingerprint": "$FP_A",
      "status": "approved", "credits": 100, "name": "acme", "admin": false,
      "created_at": "2026-01-01T00:00:00Z",
      "pubkey": "$ACME_PUBKEY"
    },
    "$FP_B": {
      "fingerprint": "$FP_B",
      "status": "approved", "credits": 50, "name": "other", "admin": false,
      "created_at": "2026-01-01T00:00:00Z",
      "pubkey": "$OTHER_PUBKEY"
    }
  }
}
EOF

  # Caddy routes: the operator's own site (must survive) and acme's route
  # (the target of revocation).
  cat > "$STATE" <<EOF
[
  {
    "match": [{"host": ["self.disinto.ai"]}],
    "handle": [{"handler": "reverse_proxy", "upstreams": [{"dial": "127.0.0.1:20000"}]}]
  },
  {
    "match": [{"host": ["acme.disinto.ai"]}],
    "handle": [{"handler": "reverse_proxy", "upstreams": [{"dial": "127.0.0.1:20001"}]}]
  }
]
EOF
}

# run_revoke — invokes verbs/revoke.sh <name> with the given extra env pairs
# (e.g. "EDGE_APPLY=1"), against the current root/stub. Sets RC (exit code) and
# OUT (stdout; the verb prints only the compact account row). stderr lands in a
# per-run file (route/port/authorized_keys helpers log there).
run_revoke() {
  local envs=(
    PATH="$STUB_DIR:$PATH"
    ACCOUNTS_FILE="$ACCOUNTS_FILE"
    REGISTRY_DIR="$REGISTRY_DIR"
    PORTER_ROOT="$ROOT"
    CADDY_ADMIN_URL="http://127.0.0.1:2019"
    DOMAIN_SUFFIX="disinto.ai"
    CADDY_STUB_STATE="$STATE"
    CADDY_STUB_LOG="$LOG"
    DISPATCH_FP="$FP_ADMIN"
  )
  local rc_env
  for rc_env in "$@"; do
    envs+=("$rc_env")
  done
  RC=0
  OUT="$(env "${envs[@]}" bash "$REVOKE" "acme" 2>"$TMP_DIR/stderr.txt")" || RC=$?
  ERR="$(cat "$TMP_DIR/stderr.txt" 2>/dev/null || true)"
}

# no_dns_request — fail if any recorded stub request URL/path touches DNS.
# (The Caddy admin paths under 127.0.0.1:2019 are the only traffic; a
# porter-dns/Gandi shell-out would show up here.)
no_dns_request() {
  if grep -EqE 'gandi|self|zone' "$LOG"; then
    ac_fail "a stubbed request URL/path contains gandi/self/zone: $(grep -E 'gandi|self|zone' "$LOG" || true)"
  fi
}

# ── AC1. EDGE_APPLY=1: revoke deletes only acme's route; self survives ──────
ac_log "AC1: EDGE_APPLY=1 revoke — only acme's route is removed; self survives"

new_root "a1"
run_revoke "EDGE_APPLY=1"
no_dns_request
if [ "$RC" -ne 0 ]; then
  ac_fail "AC1: EDGE_APPLY=1 revoke of a present name must return 0 (rc=$RC, out='$OUT', err='$ERR')"
fi
if jq -e 'select(.method == "POST")' "$LOG" >/dev/null 2>&1; then
  ac_fail "AC1: a POST was issued (revoke must not add routes)"
fi
if [ "$(jq -cs 'length' <(jq -c 'select(.method == "DELETE")' "$LOG" 2>/dev/null))" != "1" ]; then
  ac_fail "AC1: expected exactly one DELETE, got $(jq -cs 'length' <(jq -c 'select(.method == "DELETE")' "$LOG" 2>/dev/null || echo 0))"
fi
# The operator's own route must survive.
if ! jq -e 'any(.[]; .match[0].host == ["self.disinto.ai"])' "$STATE" >/dev/null 2>&1; then
  ac_fail "AC1: self.disinto.ai missing from the stub after revoke"
fi
# The revoked route must be gone.
if jq -e 'any(.[]; .match[0].host == ["acme.disinto.ai"])' "$STATE" >/dev/null 2>&1; then
  ac_fail "AC1: acme.disinto.ai still present in the stub after revoke"
fi
# The port registry lost only acme; "other" kept its port.
if jq -e '.projects["acme"]' "$REGISTRY_FILE" >/dev/null 2>&1; then
  ac_fail "AC1: acme still present in the registry after revoke (port not freed)"
fi
if ! jq -e '.projects["other"].port == 20000' "$REGISTRY_FILE" >/dev/null 2>&1; then
  ac_fail "AC1: other.project lost its port after revoking acme"
fi
# The row: status=revoked, everything else preserved.
row_fp="$FP_A"
if ! jq -e --arg fp "$row_fp" '.accounts[$fp].status == "revoked"' "$ACCOUNTS_FILE" >/dev/null 2>&1; then
  ac_fail "AC1: row status is not revoked after a successful revoke"
fi
if ! jq -e --arg fp "$row_fp" '.accounts[$fp].name == "acme"' "$ACCOUNTS_FILE" >/dev/null 2>&1; then
  ac_fail "AC1: name was cleared (must remain 'acme')"
fi
if ! jq -e --arg fp "$row_fp" '.accounts[$fp].pubkey == "'"$ACME_PUBKEY"'"' "$ACCOUNTS_FILE" >/dev/null 2>&1; then
  ac_fail "AC1: pubkey was cleared (must remain)"
fi
if ! jq -e --arg fp "$row_fp" '.accounts[$fp].credits == 100' "$ACCOUNTS_FILE" >/dev/null 2>&1; then
  ac_fail "AC1: credits were altered (must remain 100)"
fi
if ! jq -e --arg fp "$row_fp" '.accounts[$fp].admin == false' "$ACCOUNTS_FILE" >/dev/null 2>&1; then
  ac_fail "AC1: admin flag was altered"
fi
# Stdout is exactly the compact account row (one line, no URL/tunnel command).
if [ "$(printf '%s\n' "$OUT" | wc -l | tr -d ' ')" != "1" ]; then
  ac_fail "AC1: expected exactly one stdout line, got: $OUT"
fi
if printf '%s\n' "$OUT" | grep -EqE 'https://|ssh -N -R'; then
  ac_fail "AC1: stdout contains a URL/tunnel command (revoke prints none): $OUT"
fi
ac_log "AC1: only acme's route removed; self survived; port freed; row -> revoked (fields preserved)"

# ── AC2. EDGE_APPLY=1: tunnel authorized_keys — other remains, acme gone ────
ac_log "AC2: rebuilt authorized_keys keeps the second project, drops the revoked one"

new_root "a2"
run_revoke "EDGE_APPLY=1"
no_dns_request
if [ "$RC" -ne 0 ]; then
  ac_fail "AC2: EDGE_APPLY=1 revoke must return 0 (rc=$RC, out='$OUT')"
fi
if [ ! -f "$TUNNEL_AUTH_KEYS" ]; then
  ac_fail "AC2: authorized_keys file not written at $TUNNEL_AUTH_KEYS"
fi
actual_keys="$(cat "$TUNNEL_AUTH_KEYS" 2>/dev/null || true)"
if [ "$actual_keys" != "$OTHER_LINE" ]; then
  ac_fail "AC2: authorized_keys content is not exactly the other line (got: '$actual_keys')"
fi
if grep -qF "$ACME_PUBKEY" "$TUNNEL_AUTH_KEYS" 2>/dev/null; then
  ac_fail "AC2: the revoked name's pubkey remains in authorized_keys"
fi
if grep -qF 'permitlisten="127.0.0.1:20001"' "$TUNNEL_AUTH_KEYS" 2>/dev/null; then
  ac_fail "AC2: the revoked name's permitlisten line remains"
fi
if grep -qF "$OTHER_PUBKEY" "$TUNNEL_AUTH_KEYS" 2>/dev/null; then
  :
else
  ac_fail "AC2: the second project's line is missing"
fi
if [ "$(wc -l < "$TUNNEL_AUTH_KEYS" 2>/dev/null || echo 0)" != "1" ]; then
  ac_fail "AC2: expected exactly one line (only registered projects), got $(wc -l < "$TUNNEL_AUTH_KEYS" 2>/dev/null || echo 0)"
fi
ac_log "AC2: revoked name's tunnel line gone; second project's line remains"

# ── AC3. EDGE_APPLY=0: no curl (pure ledger mutation), status still revoked ──
ac_log "AC3: EDGE_APPLY=0 — no curl, status revoked, network untouched"

new_root "a3"
run_revoke "EDGE_APPLY=0"
if [ "$RC" -ne 0 ]; then
  ac_fail "AC3: EDGE_APPLY=0 revoke must return 0 (rc=$RC, out='$OUT')"
fi
no_dns_request
if [ -s "$LOG" ]; then
  ac_fail "AC3: EDGE_APPLY=0 must invoke no curl (call log has content): $(cat "$LOG")"
fi
# Network state must be untouched by a pure-0 revoke.
if jq -e '.projects["acme"].port == 20001' "$REGISTRY_FILE" >/dev/null 2>&1; then
  :
else
  ac_fail "AC3: EDGE_APPLY=0 must not free the port (acme port changed)"
fi
if ! jq -e 'any(.[]; .match[0].host == ["self.disinto.ai"])' "$STATE" >/dev/null 2>&1; then
  ac_fail "AC3: EDGE_APPLY=0 must not touch the operator's self route"
fi
if ! jq -e 'any(.[]; .match[0].host == ["acme.disinto.ai"])' "$STATE" >/dev/null 2>&1; then
  ac_fail "AC3: EDGE_APPLY=0 must not remove the route (acme route gone)"
fi
if ! jq -e --arg fp "$FP_A" '.accounts[$fp].status == "revoked"' "$ACCOUNTS_FILE" >/dev/null 2>&1; then
  ac_fail "AC3: row status is not revoked after an EDGE_APPLY=0 revoke"
fi
if printf '%s\n' "$OUT" | grep -EqE 'https://|ssh -N -R'; then
  ac_fail "AC3: EDGE_APPLY=0 must print no URL/tunnel command: $OUT"
fi
ac_log "AC3: EDGE_APPLY=0 invoked no curl and left the network untouched"

# ── AC4. all acceptance criteria passed ─────────────────────────────────────
ac_log "AC4: all checks passed"
ac_pass
