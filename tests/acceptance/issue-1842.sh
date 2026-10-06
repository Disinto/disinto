#!/usr/bin/env bash
# =============================================================================
# tests/acceptance/issue-1842.sh — the dispatcher gives sidecars their own forge token
#
# Issue #1842: on the Nomad edge the dispatcher has no FORGE_TOKEN (the caddy
# task renders only the admin PAT, for pushing vault results). Sidecars need
# their own token to read issues and post findings. The dispatcher now loads
# one via _load_sidecar_forge_token(): FORGE_TOKEN (compose .env) when set,
# else SIDECAR_FORGE_TOKEN_FILE, which the caddy task renders from
# kv/disinto/chat (sidecar_forge_token). Empty: no sidecar is fetched or
# launched.
#
# Covers criteria 1–3 (no forge / nomad / docker involved — read-only file
# checks plus a hermetic subshell against a curl stub):
#   1. no ${FORGE_TOKEN use remains between _dispatch_sidecar_docker() and
#      ensure_ops_repo().
#   2. edge.hcl renders /secrets/sidecar-forge-token exactly once, from
#      .Data.data.sidecar_forge_token.
#   3. _load_sidecar_forge_token + fetch_reproduce_candidates, run against a
#      hermetic curl stub, use the file token when FORGE_TOKEN is unset; an
#      empty token file keeps sidecars off and never calls curl.
#
# Acceptance: `bash tests/acceptance/issue-1842.sh` exits 0 and prints PASS.
# Run via: tools/run-acceptance.sh 1842
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../lib/acceptance-helpers.sh
source "$REPO_ROOT/tests/lib/acceptance-helpers.sh"

ac_require_cmd bash grep sed awk mktemp

DISPATCHER="$REPO_ROOT/docker/edge/dispatcher.sh"
EDGE_HCL="$REPO_ROOT/nomad/jobs/edge.hcl"
ac_assert_file "$DISPATCHER" "docker/edge/dispatcher.sh must exist"
ac_assert_file "$EDGE_HCL" "nomad/jobs/edge.hcl must exist"

# ── AC 1: the sidecar range no longer uses ${FORGE_TOKEN ─────────────────────
ac_log "AC 1: no \${FORGE_TOKEN use between _dispatch_sidecar_docker() and ensure_ops_repo()"
hits="$(sed -n '/^_dispatch_sidecar_docker()/,/^ensure_ops_repo()/p' "$DISPATCHER" \
  | grep -nF '${FORGE_TOKEN' || true)"
[ -z "$hits" ] \
  || ac_fail "the sidecar range still uses \${FORGE_TOKEN (got: ${hits})"

# ── AC 2: edge.hcl renders the sidecar forge token exactly once ─────────────
ac_log "AC 2: edge.hcl renders the sidecar forge token exactly once"
pat_count="$(grep -c 'secrets/sidecar-forge-token' "$EDGE_HCL")"
ac_assert_eq "$pat_count" "1" \
  "edge.hcl must reference secrets/sidecar-forge-token exactly once (got $pat_count)"
key_count="$(grep -c '.Data.data.sidecar_forge_token' "$EDGE_HCL")"
ac_assert_eq "$key_count" "1" \
  "edge.hcl must read .Data.data.sidecar_forge_token exactly once (got $key_count)"

# ── AC 3: the file token drives the fetch; empty file keeps sidecars off ────
ac_log "AC 3: _load_sidecar_forge_token + fetch_reproduce_candidates use the file token (hermetic curl stub)"
FN_LOAD="$(ac_extract_fn _load_sidecar_forge_token "$DISPATCHER")"
[ -n "$FN_LOAD" ] \
  || ac_fail "could not extract _load_sidecar_forge_token from docker/edge/dispatcher.sh"
FN_FETCH="$(ac_extract_fn fetch_reproduce_candidates "$DISPATCHER")"
[ -n "$FN_FETCH" ] \
  || ac_fail "could not extract fetch_reproduce_candidates from docker/edge/dispatcher.sh"

tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT
mkdir -p "${tmpdir}/stub"
cat > "${tmpdir}/stub/curl" <<'AC_CURL_STUB'
#!/usr/bin/env bash
# Hermetic forge stub: records every call (for the auth-header assertion)
# and answers the issues API (any *issues* URL) with a single issue #7.
echo "$*" >> "${AC_STUB_CALL_FILE}"
case "$*" in
  *"/issues"*)
    echo '[{"number":7,"labels":[{"name":"bug-report"}]}]'
    ;;
  *)
    exit 22
    ;;
esac
AC_CURL_STUB
chmod +x "${tmpdir}/stub/curl"

# Token fixtures: a token file holding tok123 (the dispatcher strips \r\n)
# and an empty file for the "no sidecar" case.
printf 'tok123' > "${tmpdir}/token-with-token"
: > "${tmpdir}/token-empty"

# The extracted functions + a sentinel env, run in a throwaway subshell.
# FORGE_TOKEN is explicitly unset (the Nomad edge has no such variable), and
# the file token is the only credential the fetch should use.
run_sidecar_fetch() {
  local token_file="$1" call_file="$2"
  (
    export PATH="${tmpdir}/stub:$PATH"
    export AC_STUB_CALL_FILE="$call_file"
    export FORGE_URL="https://forge.example"
    export FORGE_REPO="disinto-admin/disinto"
    export SIDECAR_FORGE_TOKEN_FILE="$token_file"
    unset FORGE_TOKEN || true
    # shellcheck disable=SC1090
    eval "$FN_LOAD"
    # shellcheck disable=SC1090
    eval "$FN_FETCH"
    _load_sidecar_forge_token
    fetch_reproduce_candidates
  ) 2>&1 || true
}

ac_log "AC 3a: file token loaded -> fetch prints 7 and the stub saw the auth header"
outfile="$tmpdir/call-with-token"
: > "$outfile"
out="$(run_sidecar_fetch "$tmpdir/token-with-token" "$outfile")"
if [ "$out" != "7" ]; then
  ac_fail "expected the fetch to print 7, got: ${out:-<empty>}"
fi
grep -qF "Authorization: token tok123" "$outfile" \
  || ac_fail "stub curl never saw 'Authorization: token tok123' (calls: $(tr '\n' ' ' < "$outfile"))"

ac_log "AC 3b: empty token file -> nothing printed and curl is not called"
outfile="$tmpdir/call-empty"
: > "$outfile"
out2="$(run_sidecar_fetch "$tmpdir/token-empty" "$outfile")"
if [ -n "$out2" ]; then
  ac_fail "expected no output with an empty token file, got: ${out2:-<empty>}"
fi
if [ -s "$outfile" ]; then
  ac_fail "curl was called with an empty token file (calls: $(tr '\n' ' ' < "$outfile"))"
fi

bash -n "$DISPATCHER" \
  || ac_fail "bash -n docker/edge/dispatcher.sh failed"

ac_pass