#!/usr/bin/env bash
# =============================================================================
# tests/acceptance/issue-2075.sh
#
# Issue #2075: feat(nomad): declare the machine report as the host_volume
# "machine".
#
# PR #2070 made the LXD host write machine.json every 10 minutes into a
# directory that machine/install.sh mounts read-only into the box at
# /srv/disinto/machine. Docker agent tasks cannot mount it until a
# host_volume "machine" block exists in nomad/client.hcl and the path is
# registered in lib/init/nomad/cluster-up.sh's HOST_VOLUME_DIRS — and
# cluster-up.sh must not chmod a read-only mountpoint (set -e would abort
# the bootstrap on a box where the machine device is present).
#
# Contract under test (read-only, pure grep/awk over the checkout; the
# `nomad config validate` step runs only when the nomad CLI is on PATH,
# mirroring the CI behavior — .woodpecker/nomad-validate.yml runs it,
# the local acceptance runner in disinto/agents:local skips it):
#   1. nomad/client.hcl declares host_volume "machine" with
#      path = "/srv/disinto/machine" and read_only = true.
#   2. "/srv/disinto/machine" appears exactly once in cluster-up.sh and
#      sits inside the HOST_VOLUME_DIRS array.
#   3. cluster-up.sh's step-4 loop skips mountpoints with
#      `mountpoint -q "$d"` (exactly once) and the script parses with
#      bash -n.
#   4. (optional, when nomad is on PATH) nomad config validate
#      nomad/server.hcl nomad/client.hcl exits 0.
#
# Run via: tools/run-acceptance.sh 2075
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../lib/acceptance-helpers.sh
source "$REPO_ROOT/tests/lib/acceptance-helpers.sh"

ac_require_cmd grep awk bash

CLIENT_HCL="$REPO_ROOT/nomad/client.hcl"
CLUSTER_UP="$REPO_ROOT/lib/init/nomad/cluster-up.sh"
ac_assert_file "$CLIENT_HCL" "nomad/client.hcl is missing"
ac_assert_file "$CLUSTER_UP" "lib/init/nomad/cluster-up.sh is missing"

# ── AC1: client.hcl declares host_volume "machine" (ro, /srv/disinto/machine) ─
ac_log 'AC1: awk host_volume "machine" block in nomad/client.hcl'
BLOCK="$(awk '/host_volume "machine"/,/}/' "$CLIENT_HCL")"
[ -n "$BLOCK" ] || ac_fail 'nomad/client.hcl has no host_volume "machine" block'
grep -q 'path      = "/srv/disinto/machine"' <<< "$BLOCK" \
  || ac_fail 'host_volume "machine" block does not set path = "/srv/disinto/machine"'
grep -q 'read_only = true' <<< "$BLOCK" \
  || ac_fail 'host_volume "machine" block is not read_only = true'

# ── AC2: the path appears once, inside the HOST_VOLUME_DIRS array ──────────────
ac_log 'AC2: "/srv/disinto/machine" in HOST_VOLUME_DIRS exactly once'
COUNT="$(grep -c '"/srv/disinto/machine"' "$CLUSTER_UP")"
ac_assert_eq "$COUNT" "1" \
  'expected exactly one "/srv/disinto/machine" occurrence in cluster-up.sh, got '"$COUNT"
ARRAY_BLOCK="$(awk '/^HOST_VOLUME_DIRS=\(/,/^\)/' "$CLUSTER_UP")"
grep -q '"/srv/disinto/machine"' <<< "$ARRAY_BLOCK" \
  || ac_fail '"/srv/disinto/machine" is not inside the HOST_VOLUME_DIRS array'

# ── AC3: the real step-4 loop skips mountpoints; script parses ─────────────────
ac_log 'AC3: mountpoint guard in the HOST_VOLUME_DIRS loop; bash -n'
MP_COUNT="$(grep -c 'mountpoint -q "[$]d"' "$CLUSTER_UP")"
ac_assert_eq "$MP_COUNT" "1" \
  "expected exactly one mountpoint guard in the HOST_VOLUME_DIRS loop, got $MP_COUNT"
bash -n "$CLUSTER_UP" \
  || ac_fail "bash -n failed on lib/init/nomad/cluster-up.sh"

# ── AC4: nomad config validate (skipped when the CLI is absent) ────────────────
if command -v nomad >/dev/null 2>&1; then
  ac_log "AC4: nomad config validate nomad/server.hcl nomad/client.hcl"
  nomad config validate "$REPO_ROOT/nomad/server.hcl" "$REPO_ROOT/nomad/client.hcl" \
    || ac_fail "nomad config validate rejected nomad/client.hcl"
else
  ac_warn "nomad not on PATH — skipping config validate (CI's nomad-validate runs it)"
fi

ac_pass
