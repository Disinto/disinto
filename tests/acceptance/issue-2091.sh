#!/usr/bin/env bash
# =============================================================================
# tests/acceptance/issue-2091.sh — supervisor and gardener mount the machine report
#
# Issue #2091: since #2075 the machine report is a host volume (host_volume
# "machine", /srv/disinto/machine, read-only) declared in nomad/client.hcl,
# written by the LXD host (#2070) and mounted read-only into the box. Two
# readers need it: the supervisor (supervisor/preflight.sh's `Disk owner:`
# line, #2077) and the gardener (the ops claim probes tools/claim-checks.sh
# runs, e.g. can-sense-machine). Both jobs must mount it at the box path
# /srv/disinto/machine so the readers' default path needs no env override —
# the same pattern as the tape mount (#1405).
#
# Contract under test (read-only, pure grep/awk over the checkout; the
# `nomad job validate` step runs only when the nomad CLI is on PATH,
# mirroring CI — .woodpecker/nomad-validate.yml runs it, the local
# acceptance runner in disinto/agents:local skips it):
#   1. Each of nomad/jobs/agents-supervisor-opus.hcl and
#      nomad/jobs/agents-gardener-qwen.hcl has a volume "machine" block
#      with type = "host", source = "machine", read_only = true.
#   2. Each has a volume_mount with volume = "machine", destination =
#      "/srv/disinto/machine", read_only = true.
#   3. Each file still defines exactly one job and pins its single role
#      (supervisor / gardener) unchanged.
#   4. (optional, when nomad is on PATH) nomad job validate exits 0.
#   5. INFRASTRUCTURE.md's machine row names both jobs, no longer "none yet".
#
# Run via: tools/run-acceptance.sh 2091
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../lib/acceptance-helpers.sh
source "$REPO_ROOT/tests/lib/acceptance-helpers.sh"

ac_require_cmd grep awk

SPECS=(
  "$REPO_ROOT/nomad/jobs/agents-supervisor-opus.hcl"
  "$REPO_ROOT/nomad/jobs/agents-gardener-qwen.hcl"
)
ROLES=(supervisor gardener)

for i in 0 1; do
  spec="${SPECS[$i]}"
  role="${ROLES[$i]}"
  base="${spec##*/}"
  ac_assert_file "$spec" "jobspec $base must exist"

  # AC1: the group declares volume "machine" as a read-only host volume
  # sourced from the host_volume declared in nomad/client.hcl (#2075).
  ac_log "AC1: volume \"machine\" block in $base"
  vol="$(awk '/volume "machine"/,/}/' "$spec")"
  [ -n "$vol" ] || ac_fail "$base has no volume \"machine\" block"
  grep -q 'type      = "host"' <<< "$vol" \
    || ac_fail "$base: volume \"machine\" must be a host volume"
  grep -q 'source    = "machine"' <<< "$vol" \
    || ac_fail "$base: volume \"machine\" must source the machine host volume"
  grep -q 'read_only = true' <<< "$vol" \
    || ac_fail "$base: volume \"machine\" must be read_only = true"

  # AC2: the task mounts it at the box path, read-only, so the readers'
  # default /srv/disinto/machine/machine.json needs no env override.
  ac_log "AC2: volume_mount of machine at /srv/disinto/machine in $base"
  mount="$(awk '/volume      = "machine"/,/}/' "$spec")"
  [ -n "$mount" ] || ac_fail "$base has no volume_mount for the machine volume"
  grep -q 'destination = "/srv/disinto/machine"' <<< "$mount" \
    || ac_fail "$base: machine volume_mount must mount at /srv/disinto/machine"
  grep -q 'read_only   = true' <<< "$mount" \
    || ac_fail "$base: machine volume_mount must be read_only = true"

  # AC3: exactly one job, role unchanged.
  ac_log "AC3: one job and AGENT_ROLES \"$role\" unchanged in $base"
  jobs="$(grep -cE '^[[:space:]]*job "' "$spec" || true)"
  ac_assert_eq "$jobs" "1" "$base must define exactly one job (got $jobs)"
  pinned="$(grep -E '^[[:space:]]*AGENT_ROLES[[:space:]]*=' "$spec" \
    | head -n1 | sed -E 's/^[[:space:]]*AGENT_ROLES[[:space:]]*=[[:space:]]*//; s/"//g; s/[[:space:]]+$//')"
  ac_assert_eq "$pinned" "$role" \
    "$base must still pin AGENT_ROLES to \"$role\" (got '$pinned')"

  # AC4: nomad job validate (skipped when the CLI is absent).
  if command -v nomad >/dev/null 2>&1; then
    ac_log "AC4: nomad job validate $base"
    nomad job validate "$spec" \
      || ac_fail "nomad job validate rejected $base"
  else
    ac_warn "nomad not on PATH — skipping job validate (CI's nomad-validate runs it)"
  fi
done

# AC5: the host-volume table names the two readers, not "none yet".
ac_log "AC5: INFRASTRUCTURE.md machine row names both jobs"
infra="$REPO_ROOT/INFRASTRUCTURE.md"
ac_assert_file "$infra" "INFRASTRUCTURE.md is missing"
row="$(grep -E "^\| *\`machine\`" "$infra" || true)"
[ -n "$row" ] || ac_fail "INFRASTRUCTURE.md has no machine row in the host-volume table"
grep -q 'agents-supervisor-opus' <<< "$row" \
  || ac_fail "machine row must name agents-supervisor-opus"
grep -q 'agents-gardener-qwen' <<< "$row" \
  || ac_fail "machine row must name agents-gardener-qwen"
grep -q 'none yet' <<< "$row" \
  && ac_fail "machine row still says the volume is mounted by nobody"

ac_pass
