#!/usr/bin/env bash
# =============================================================================
# tests/acceptance/issue-1926.sh — supervisor mounts snapshot state read-only
#
# Issue #1926: the supervisor container is on a bridge network and cannot
# reach Nomad's loopback API. It must mount the snapshot-state host volume
# read-only and point SNAPSHOT_PATH at the mounted state.json so #1927 can
# read the snapshot daemon's Nomad alerts.
#
# Read-only: greps nomad/jobs/agents-supervisor-opus.hcl. No job is
# dispatched, no network is reached.
#
# Acceptance: `bash tests/acceptance/issue-1926.sh` exits 0 and prints PASS.
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../lib/acceptance-helpers.sh
source "$REPO_ROOT/tests/lib/acceptance-helpers.sh"

ac_require_cmd grep

HCL="$REPO_ROOT/nomad/jobs/agents-supervisor-opus.hcl"
ac_assert_file "$HCL" "nomad/jobs/agents-supervisor-opus.hcl must exist"

ac_log "snapshot-state volume is a read-only host volume"
vol="$(awk '
  $0 ~ /volume "snapshot-state"/ { in_vol = 1; buf = $0; next }
  in_vol { buf = buf "\n" $0 }
  in_vol && $0 ~ /^    \}/ { print buf; exit }
' "$HCL")"
printf '%s\n' "$vol" | grep -q 'type *= *"host"' \
  || ac_fail "snapshot-state must be a host volume"
printf '%s\n' "$vol" | grep -q 'source *= *"snapshot-state"' \
  || ac_fail "snapshot-state must source the snapshot-state host volume"
printf '%s\n' "$vol" | grep -q 'read_only *= *true' \
  || ac_fail "snapshot-state volume must be read_only = true"

ac_log "volume_mount is /var/lib/disinto/snapshot read-only"
mount="$(awk '
  $0 ~ /volume_mount/ { buf = $0; in_mnt = 1; next }
  in_mnt { buf = buf "\n" $0 }
  in_mnt && $0 ~ /^      \}/ {
    if (buf ~ /volume *= *"snapshot-state"/) { print buf; exit }
    in_mnt = 0
  }
' "$HCL")"
printf '%s\n' "$mount" | grep -q 'destination *= *"/var/lib/disinto/snapshot"' \
  || ac_fail "snapshot-state must mount at /var/lib/disinto/snapshot"
printf '%s\n' "$mount" | grep -q 'read_only *= *true' \
  || ac_fail "snapshot-state volume_mount must be read_only = true"

ac_log "SNAPSHOT_PATH is the mounted state.json, exactly once"
count="$(grep -cE '^ *SNAPSHOT_PATH *= *"/var/lib/disinto/snapshot/state.json"' "$HCL" || true)"
ac_assert_eq "$count" "1" \
  "supervisor job must set SNAPSHOT_PATH to /var/lib/disinto/snapshot/state.json exactly once (got: ${count})"

ac_pass
