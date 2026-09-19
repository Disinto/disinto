#!/usr/bin/env bash
# =============================================================================
# tests/acceptance/issue-1423.sh
#
# Issue #1423: the edge job (nomad/jobs/edge.hcl) does not mount the host
# volume "tape", so the production-loop run/outcome records the dispatcher
# appends via lib/tape.sh (#1407) cannot land on the shared tape.
#
# The fix (same change as #1405 / #1406, in this one file) adds:
#   - a group-level `volume "tape"` block (type = "host", source = "tape",
#     read_only = false)
#   - a `volume_mount` on the caddy task at /srv/disinto/tape (read_only =
#     false) — the lib/tape.sh default TAPE_DIR, so no env override is needed
#   - a `Host_volume contract` header update naming tape alongside the
#     volumes it already names
#
# This test locks in the jobspec:
#   1. The group declares volume "tape" with type = "host",
#      source = "tape", read_only = false.
#   2. The caddy task carries a volume_mount of volume "tape" with
#      destination = "/srv/disinto/tape", read_only = false.
#   3. No TAPE_DIR env override was introduced — the mount path IS the
#      lib/tape.sh default.
#   4. The `Host_volume contract` header names tape.
#   5. The referenced host_volume "tape" is declared in nomad/client.hcl
#      (the jobspec/client.hcl pair must stay in sync or nomad
#      fingerprinting leaves the node in "initializing", #1405).
#
# Read-only: parses the jobspec HCL from the checkout; starts no job.
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../lib/acceptance-helpers.sh
source "$REPO_ROOT/tests/lib/acceptance-helpers.sh"

ac_require_cmd awk

SPEC="$REPO_ROOT/nomad/jobs/edge.hcl"
ac_assert_file "$SPEC" "jobspec nomad/jobs/edge.hcl must exist"

# ── 1. group-level volume "tape" block ──────────────────────────────────────
TAPE_VOL="$(awk '
  /^[[:space:]]*volume[[:space:]]+"tape"[[:space:]]*\{/ { f = 1; buf = $0 ORS; next }
  f {
    buf = buf $0 ORS
    if ($0 ~ /^[[:space:]]*\}[[:space:]]*$/) { print buf; exit }
  }
' "$SPEC")"
[ -n "$TAPE_VOL" ] || ac_fail "edge.hcl must declare a group-level volume \"tape\" block"
echo "$TAPE_VOL" | grep -Eq 'type[[:space:]]*=[[:space:]]*"host"' \
  || ac_fail "volume \"tape\" must be type = \"host\""
echo "$TAPE_VOL" | grep -Eq 'source[[:space:]]*=[[:space:]]*"tape"' \
  || ac_fail "volume \"tape\" must be source = \"tape\""
echo "$TAPE_VOL" | grep -Eq 'read_only[[:space:]]*=[[:space:]]*false' \
  || ac_fail "volume \"tape\" must be read_only = false (the dispatcher appends records)"

# ── 2. caddy-task volume_mount at /srv/disinto/tape ─────────────────────────
# Collect each volume_mount block as a one-line record (mawk's regex lexer
# rejects / inside a class, so the destination match is done in grep below).
MOUNT_BLOCKS="$(awk '
  /^[[:space:]]*volume_mount[[:space:]]*\{/ { f = 1; buf = ""; next }
  f {
    if ($0 ~ /^[[:space:]]*\}[[:space:]]*$/) { f = 0; print buf; next }
    if (buf != "") buf = buf "; "
    buf = buf $0
  }
' "$SPEC")"
TAPE_MOUNT="$(grep -E 'destination[[:space:]]*=[[:space:]]*"/srv/disinto/tape"' \
  <<<"$MOUNT_BLOCKS" | head -n1)"
[ -n "$TAPE_MOUNT" ] \
  || ac_fail "the caddy task must carry a volume_mount with destination = \"/srv/disinto/tape\""
echo "$TAPE_MOUNT" | grep -Eq 'volume[[:space:]]*=[[:space:]]*"tape"' \
  || ac_fail "the /srv/disinto/tape mount must reference volume \"tape\""
echo "$TAPE_MOUNT" | grep -Eq 'read_only[[:space:]]*=[[:space:]]*false' \
  || ac_fail "the /srv/disinto/tape mount must be read_only = false"

# ── 3. no TAPE_DIR env override — the mount path IS the lib/tape.sh default ─
grep -Eq '^[[:space:]]*TAPE_DIR[[:space:]]*=' "$SPEC" \
  && ac_fail "edge.hcl must not set a TAPE_DIR env override: the mount at the lib/tape.sh default path makes it redundant"

# ── 4. Host_volume contract header names tape ───────────────────────────────
grep -q 'Host_volume contract' "$SPEC" \
  || ac_fail "edge.hcl must keep its Host_volume contract header"
grep -A 6 'Host_volume contract' "$SPEC" | grep -q 'tape' \
  || ac_fail "the Host_volume contract header must name tape alongside the volumes it already lists"

# ── 5. client.hcl declares the host_volume the jobspec references ───────────
CLIENT="$REPO_ROOT/nomad/client.hcl"
ac_assert_file "$CLIENT" "nomad/client.hcl must exist"
grep -q 'host_volume "tape"' "$CLIENT" \
  || ac_fail "nomad/client.hcl must declare host_volume \"tape\" (#1405)"

ac_pass
