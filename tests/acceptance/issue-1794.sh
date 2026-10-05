#!/usr/bin/env bash
# =============================================================================
# tests/acceptance/issue-1794.sh — the threads-state host volume is gone
#
# Issue #1794: after #1770 dropped the last threads-state mount and #1789
# deleted the edge-threads-gc job, the delegate thread state
# (meta.json + stream.jsonl per task-id) is written by no one. This step
# removes what still configured, seeded, or documented the dead volume:
#   - nomad/client.hcl's `host_volume "threads-state"` block (+ its comments)
#   - the `/srv/disinto/threads-state` entry in cluster-up.sh's
#     HOST_VOLUME_DIRS array
#   - the doc/comment mentions of threads-state and edge-threads-gc
#
# Read-only: greps the checkout and runs `bash -n`. No live box, job submit,
# socket, or store write.
#
# Acceptance: `bash tests/acceptance/issue-1794.sh` exits 0 and prints PASS.
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck disable=SC1091
source "$REPO_ROOT/tests/lib/acceptance-helpers.sh"

ac_require_cmd grep bash

CLIENT_HCL="$REPO_ROOT/nomad/client.hcl"
CLUSTER_UP="$REPO_ROOT/lib/init/nomad/cluster-up.sh"
ac_assert_file "$CLIENT_HCL" "nomad/client.hcl must exist"
ac_assert_file "$CLUSTER_UP" "lib/init/nomad/cluster-up.sh must exist"

ac_log "criterion 1: no threads-state in nomad/, lib/ or INFRASTRUCTURE.md"
hits="$(grep -rn threads-state "$REPO_ROOT/nomad" "$REPO_ROOT/lib" "$REPO_ROOT/INFRASTRUCTURE.md" || true)"
if [ -n "$hits" ]; then
  printf '%s\n' "$hits" >&2
  ac_fail "threads-state is still referenced in nomad/, lib/ or INFRASTRUCTURE.md"
fi

ac_log "criterion 2: no edge-threads-gc in nomad/ or disinto-factory/"
hits="$(grep -rn edge-threads-gc "$REPO_ROOT/nomad" "$REPO_ROOT/disinto-factory" || true)"
if [ -n "$hits" ]; then
  printf '%s\n' "$hits" >&2
  ac_fail "edge-threads-gc is still referenced in nomad/ or disinto-factory/"
fi

ac_log "criterion 3: issue-1426.sh failure message no longer mentions chat"
hits="$(grep -n chat "$REPO_ROOT/tests/acceptance/issue-1426.sh" || true)"
if [ -n "$hits" ]; then
  printf '%s\n' "$hits" >&2
  ac_fail "tests/acceptance/issue-1426.sh still mentions chat"
fi

ac_log "criterion 4: cluster-up.sh passes bash -n"
bash -n "$CLUSTER_UP" || ac_fail "bash -n lib/init/nomad/cluster-up.sh failed"

ac_pass
