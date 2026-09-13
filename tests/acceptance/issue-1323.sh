#!/usr/bin/env bash
# =============================================================================
# tests/acceptance/issue-1323.sh
#
# Issue #1323: cluster-up appends cpu_total_compute from nproc.
# Nomad fingerprints the whole host unless cpu_total_compute is set; a capped
# LXC then schedules work it cannot run. cluster-up.sh step 5 must append a
# second client { } block (cpu_total_compute = nproc * 3400) to the installed
# /etc/nomad.d/client.hcl only when no installed file declares the key — the
# key must come from nproc at init time, not from git.
#
# Verifies (all checks read-only — the ensure_client_cpu_total_compute
# function is extracted from cluster-up.sh and executed in a stubbed
# subshell against mktemp fixtures; nproc and log are stubbed so the test
# is deterministic and never touches /etc/nomad.d):
#   1. A fixture client.hcl without the key gets a second client { } block
#      with cpu_total_compute = nproc*3400 (stub nproc=4 → 13600).
#   2. A fixture that already declares cpu_total_compute is left unchanged.
#   3. A second cluster-up pass on the same tree does not duplicate the
#      block (key count stays 1, file byte-identical).
#   4. The repo's nomad/client.hcl is not required to carry the key: a copy
#      of it is processed by the same function and ends up correct either
#      way.
#   5. On a cluster-up'd live box (/etc/nomad.d readable), the installed
#      client.hcl declares cpu_total_compute.
#
# Run via: tools/run-acceptance.sh 1323
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck disable=SC1091
source "$REPO_ROOT/tests/lib/acceptance-helpers.sh"

ac_require_cmd bash grep mktemp

CLUSTER_UP="$REPO_ROOT/lib/init/nomad/cluster-up.sh"
ac_assert_file "$CLUSTER_UP" "lib/init/nomad/cluster-up.sh is missing"

FN_SRC=$(ac_extract_fn ensure_client_cpu_total_compute "$CLUSTER_UP")
[ -n "$FN_SRC" ] \
  || ac_fail "could not extract ensure_client_cpu_total_compute from cluster-up.sh"

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

# run_ensure FILE NPROC — execute the extracted function against FILE in a
# throwaway subshell with log() silenced and nproc stubbed to NPROC.
run_ensure() {
  local file="$1" np="$2"
  ENSURE_FILE="$file" NPROC_OVERRIDE="$np" bash -s "$FN_SRC" <<'EOF'
set -u
log() { :; }
nproc() { echo "$NPROC_OVERRIDE"; }
eval "$1"
ensure_client_cpu_total_compute "$ENSURE_FILE"
EOF
}

count_keys() { grep -cE '^[[:space:]]*cpu_total_compute[[:space:]]*=' "$1" || true; }

# ── 1. fixture without the key gets a block with nproc*3400 ─────────────────
cat > "$TMP_DIR/client-bare.hcl" <<'EOF'
client {
  host_volume "forgejo-data" {
    path      = "/srv/disinto/forgejo-data"
    read_only = false
  }
}
EOF
run_ensure "$TMP_DIR/client-bare.hcl" 4
grep -qE '^[[:space:]]*cpu_total_compute[[:space:]]*=[[:space:]]*13600$' "$TMP_DIR/client-bare.hcl" \
  || ac_fail "fixture without key: cpu_total_compute = 13600 (nproc 4 * 3400) not appended"
ac_assert_eq "$(count_keys "$TMP_DIR/client-bare.hcl")" 1 \
  "fixture without key: expected exactly one cpu_total_compute key"
# The appended value must sit inside a client { } block: block count went
# from 1 to 2, and the new block closes the file.
ac_assert_eq "$(grep -c '^client {' "$TMP_DIR/client-bare.hcl" || true)" 2 \
  "fixture without key: expected a second client { } block"
tail -n 1 "$TMP_DIR/client-bare.hcl" | grep -qx '}' \
  || ac_fail "fixture without key: appended client block does not close at end of file"
ac_log "fixture without key: client { cpu_total_compute = 13600 } appended"

# ── 2. fixture already declaring the key is left unchanged ──────────────────
cat > "$TMP_DIR/client-set.hcl" <<'EOF'
client {
  cpu_total_compute = 9999
}
EOF
cp "$TMP_DIR/client-set.hcl" "$TMP_DIR/client-set.orig"
run_ensure "$TMP_DIR/client-set.hcl" 4
cmp -s "$TMP_DIR/client-set.hcl" "$TMP_DIR/client-set.orig" \
  || ac_fail "fixture with key: file was modified (must be left unchanged)"
ac_log "fixture with key: left unchanged"

# ── 3. second pass on the same tree does not duplicate ──────────────────────
cp "$TMP_DIR/client-bare.hcl" "$TMP_DIR/client-bare.after1"
run_ensure "$TMP_DIR/client-bare.hcl" 4
cmp -s "$TMP_DIR/client-bare.hcl" "$TMP_DIR/client-bare.after1" \
  || ac_fail "second pass: file changed (must be a no-op)"
ac_assert_eq "$(count_keys "$TMP_DIR/client-bare.hcl")" 1 \
  "second pass: cpu_total_compute key duplicated"
ac_log "second pass: no-op, no duplicated block"

# ── 4. repo nomad/client.hcl is not required to carry the key ───────────────
REPO_CLIENT="$REPO_ROOT/nomad/client.hcl"
ac_assert_file "$REPO_CLIENT" "nomad/client.hcl is missing"
cp "$REPO_CLIENT" "$TMP_DIR/client-repo.hcl"
run_ensure "$TMP_DIR/client-repo.hcl" 4
if grep -qE '^[[:space:]]*cpu_total_compute[[:space:]]*=' "$REPO_CLIENT"; then
  # Key already in git: the copy must be untouched.
  cmp -s "$TMP_DIR/client-repo.hcl" "$REPO_CLIENT" \
    || ac_fail "repo client.hcl (key present): copy was modified"
  ac_log "repo client.hcl: key present in git, copy untouched"
else
  # Key absent in git (the expected state): the copy must gain the block.
  grep -qE '^[[:space:]]*cpu_total_compute[[:space:]]*=[[:space:]]*13600$' "$TMP_DIR/client-repo.hcl" \
    || ac_fail "repo client.hcl (key absent): nproc*3400 block not appended to a copy"
  ac_log "repo client.hcl: key absent in git, copy of it receives the block from nproc"
fi

# ── 5. live box: installed client.hcl declares the key ──────────────────────
LIVE_CLIENT="/etc/nomad.d/client.hcl"
if [ -r "$LIVE_CLIENT" ]; then
  grep -qE '^[[:space:]]*cpu_total_compute[[:space:]]*=' "$LIVE_CLIENT" \
    || ac_fail "live ${LIVE_CLIENT} does not declare cpu_total_compute"
  ac_log "live ${LIVE_CLIENT} declares cpu_total_compute"
else
  ac_log "no readable ${LIVE_CLIENT} (non-cluster-up host) — live check skipped"
fi

ac_pass
