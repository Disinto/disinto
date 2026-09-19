#!/usr/bin/env bash
# =============================================================================
# tests/acceptance/issue-1426.sh
#
# Issue #1426: restore the `claude-shared` host_volume in nomad/client.hcl.
# nomad/jobs/edge.hcl declares volume "claude-shared" (source =
# "claude-shared", chat OAuth, #648 / #705), but client.hcl had no matching
# host_volume block — a client.hcl taken from the repo does not fingerprint
# the volume, so the edge job cannot place.
#
# The fix (two files):
#   1. nomad/client.hcl — host_volume "claude-shared" with
#      path = "/var/lib/disinto/claude-shared", read_only = false, placed
#      next to the claude-creds block.
#   2. lib/init/nomad/cluster-up.sh — "/var/lib/disinto/claude-shared"
#      appended to HOST_VOLUME_DIRS so the directory exists before Nomad
#      fingerprints.
#
# Read-only: greps both files from the checkout.
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../lib/acceptance-helpers.sh
source "$REPO_ROOT/tests/lib/acceptance-helpers.sh"

CLIENT_HCL="$REPO_ROOT/nomad/client.hcl"
CLUSTER_UP="$REPO_ROOT/lib/init/nomad/cluster-up.sh"
ac_assert_file "$CLIENT_HCL" "nomad/client.hcl must exist"
ac_assert_file "$CLUSTER_UP" "lib/init/nomad/cluster-up.sh must exist"

# ── 1. host_volume "claude-shared" block with the right path ────────────────
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
  || ac_fail "host_volume \"claude-shared\" must have path \"/var/lib/disinto/claude-shared\""
grep -Fq 'read_only = false' <<<"$BLOCK" \
  || ac_fail "host_volume \"claude-shared\" must have read_only = false (the edge chat process refreshes the OAuth session in place)"

# ── 2. HOST_VOLUME_DIRS includes the volume path ────────────────────────────
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
  || ac_fail "HOST_VOLUME_DIRS must include \"/var/lib/disinto/claude-shared\" so the dir exists before Nomad fingerprints"

# ── 3. Jobspecs unchanged ───────────────────────────────────────────────────
# The edge jobspec already sources "claude-shared"; this issue must not touch
# it. (Covered by the PR itself; here we only sanity-check the name it
# sources still matches the host_volume name.)
EDGE_HCL="$REPO_ROOT/nomad/jobs/edge.hcl"
grep -Fq 'source    = "claude-shared"' "$EDGE_HCL" \
  || ac_fail "nomad/jobs/edge.hcl must still source \"claude-shared\" (the host_volume name must match the jobspec)"

ac_pass
