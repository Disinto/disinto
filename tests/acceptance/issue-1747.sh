#!/usr/bin/env bash
# =============================================================================
# tests/acceptance/issue-1747.sh
#
# Issue #1747: chore(nomad): drop the claude-creds host volume
#
# #705 decided to remove the claude-creds path rather than repair it. #1746
# did the jobspec half (the supervisor no longer mounts it); this issue does
# the declaration half. The `claude-creds` host_volume block in
# nomad/client.hcl and the `"/srv/disinto/claude-creds"` entry in
# HOST_VOLUME_DIRS are dead weight: no job mounts the volume, so Nomad
# fingerprints a path nobody consumes (and the directory is re-created on every
# cluster-up).
#
# Contract under test (read-only, pure grep over the checkout):
#   1. The `claude-creds` volume is declared nowhere in client.hcl or in the
#      cluster-up HOST_VOLUME_DIRS list — the exact grep from the issue prints
#      nothing: `grep -n claude-creds nomad/client.hcl lib/init/nomad/cluster-up.sh`.
#   2. The `claude-shared` host_volume survives untouched: it still declares the
#      path "/var/lib/disinto/claude-shared" with read_only = false, and that
#      path is still in HOST_VOLUME_DIRS — the edge job still mounts it.
#   3. (run-level, enforced by tools/run-acceptance.sh) tests/acceptance/
#      issue-1426.sh (which asserts the claude-shared block) still passes.
#
# Read-only: pure grep over the checkout; no job is dispatched, no network
# reached.
#
# Run via: tools/run-acceptance.sh 1747
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../lib/acceptance-helpers.sh
source "$REPO_ROOT/tests/lib/acceptance-helpers.sh"

ac_require_cmd grep

CLIENT_HCL="$REPO_ROOT/nomad/client.hcl"
CLUSTER_UP="$REPO_ROOT/lib/init/nomad/cluster-up.sh"
ac_assert_file "$CLIENT_HCL" "nomad/client.hcl must exist"
ac_assert_file "$CLUSTER_UP" "lib/init/nomad/cluster-up.sh must exist"

# ── AC1: no claude-creds declaration in either file ─────────────────────────
ac_log "AC1: grep -n claude-creds over both files must print nothing"
MATCHES="$(grep -n 'claude-creds' "$CLIENT_HCL" "$CLUSTER_UP" || true)"
ac_assert_eq "$MATCHES" "" \
  "claude-creds must be declared in neither nomad/client.hcl nor HOST_VOLUME_DIRS (got: $MATCHES)"

# ── AC2: claude-shared survives (path + read_only + dirs entry) ─────────────
ac_log "AC2: host_volume \"claude-shared\" must survive with path + read_only=false"
BLOCK="$(awk '
  /^ *host_volume "claude-shared" / { inblock = 1 }
  inblock {
    buf = buf $0 ORS
    if ($0 ~ /^[[:space:]]*\}[[:space:]]*$/) exit
  }
  END { printf "%s", buf }
' "$CLIENT_HCL")"
[ -n "$BLOCK" ] \
  || ac_fail "nomad/client.hcl must declare a host_volume \"claude-shared\" block"
grep -Fq 'path      = "/var/lib/disinto/claude-shared"' <<<"$BLOCK" \
  || ac_fail 'host_volume "claude-shared" must still have path "/var/lib/disinto/claude-shared"'
grep -Fq 'read_only = false' <<<"$BLOCK" \
  || ac_fail 'host_volume "claude-shared" must still have read_only = false'

HOST_DIRS="$(awk '
  /^HOST_VOLUME_DIRS=\(/ { inarr = 1; next }
  inarr {
    if ($0 ~ /^[[:space:]]*\)[[:space:]]*$/) exit
    buf = buf $0 ORS
  }
  END { printf "%s", buf }
' "$CLUSTER_UP")"
[ -n "$HOST_DIRS" ] \
  || ac_fail "lib/init/nomad/cluster-up.sh must define a HOST_VOLUME_DIRS array"
grep -Fq '"/var/lib/disinto/claude-shared"' <<<"$HOST_DIRS" \
  || ac_fail "HOST_VOLUME_DIRS must still include \"/var/lib/disinto/claude-shared\" (the edge job still mounts claude-shared)"

ac_pass
