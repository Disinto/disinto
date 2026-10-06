#!/usr/bin/env bash
# =============================================================================
# tests/acceptance/issue-1843.sh — the dispatcher finds the project TOMLs on
# the Nomad edge
#
# Issue #1843: on the Nomad edge the dispatcher's PROJECTS_DIR default
# (${FACTORY_ROOT}-projects = /opt/disinto-projects) does not exist, so every
# dispatch logged "no project TOML found" and skipped. The reproduce/triage/
# verify sidecars now run against the local model (DSH_BASE_URL) — the
# sidecars are dsh, and the dispatcher no longer hands them the Claude CLI or
# a session. The fix (owner decision 2026-10-06) is twofold:
#
#   - docker/edge/dispatcher.sh: PROJECTS_DIR falls back to the factory-projects
#     host path /srv/disinto/projects when the compose mounted path is absent.
#   - nomad/jobs/edge.hcl: a read-only "factory-projects" group-level volume
#     plus a caddy-task volume_mount at its host path, so the dispatcher's
#     `docker run -v <toml>` (which resolves on the host via docker.sock) can
#     reach the project TOMLs.
#
# Read-only: only reads the changed files. No job dispatch, no daemon, no
# socket.
#
# Acceptance: `bash tests/acceptance/issue-1843.sh` exits 0 and prints PASS.
# Run via: tools/run-acceptance.sh 1843
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck disable=SC1091
source "$REPO_ROOT/tests/lib/acceptance-helpers.sh"

ac_require_cmd bash grep awk

DISPATCHER="$REPO_ROOT/docker/edge/dispatcher.sh"
EDGE_HCL="$REPO_ROOT/nomad/jobs/edge.hcl"
DOCS="$REPO_ROOT/INFRASTRUCTURE.md"

ac_assert_file "$DISPATCHER" "docker/edge/dispatcher.sh must exist"
ac_assert_file "$EDGE_HCL" "nomad/jobs/edge.hcl must exist"
ac_assert_file "$DOCS" "INFRASTRUCTURE.md must exist"

# ── AC 1: the dispatcher falls back to the factory-projects host path ────────
ac_log "AC 1: PROJECTS_DIR=/srv/disinto/projects appears exactly once in the dispatcher"
toml_count="$(grep -c 'PROJECTS_DIR=/srv/disinto/projects' "$DISPATCHER")"
ac_assert_eq "$toml_count" "1" \
  "the dispatcher must name PROJECTS_DIR=/srv/disinto/projects exactly once (got $toml_count)"

# The compose mounted path is still the default before the fallback.
default_count="$(grep -c "PROJECTS_DIR=\"\${FACTORY_ROOT:-/opt/disinto}-projects\"" "$DISPATCHER")"
ac_assert_eq "$default_count" "1" \
  "the compose default PROJECTS_DIR=\${FACTORY_ROOT:-/opt/disinto}-projects must remain (got $default_count)"

# The fallback is wired through a -d check, not an unconditional assignment.
fallback_block="$(sed -n '/if \[ -z.*PROJECTS_DIR/,/fi/p' "$DISPATCHER")"
[[ "$fallback_block" == *"if [ -z"* ]] ||
  ac_fail "the PROJECTS_DIR fallback must live in an if [ -z ... ] block"

# ── AC 2: the group declares a read-only factory-projects volume ─────────────
ac_log "AC 2: a read-only group-level volume \"factory-projects\" is declared"
vol_block="$(awk '/volume "factory-projects"/,/}/' "$EDGE_HCL")"
[[ -n "$vol_block" ]] || ac_fail "edge.hcl must declare volume \"factory-projects\""
vol_readonly="$(echo "$vol_block" | grep -c 'read_only = true')"
ac_assert_eq "$vol_readonly" "1" \
  "the factory-projects volume block must be read_only = true (got $vol_readonly)"
vol_host="$(echo "$vol_block" | grep -c 'type      = "host"')"
ac_assert_eq "$vol_host" "1" \
  "the factory-projects volume block must be type = \"host\" (got $vol_host)"
vol_source="$(echo "$vol_block" | grep -c 'source    = "factory-projects"')"
ac_assert_eq "$vol_source" "1" \
  "the factory-projects volume block must be source = \"factory-projects\" (got $vol_source)"

# ── AC 3: the caddy task mounts it at the host path, read-only ───────────────
ac_log "AC 3: the caddy task carries a read-only factory-projects mount at /srv/disinto/projects"
mount_lines="$(grep -A2 'volume      = "factory-projects"' "$EDGE_HCL")"
[[ -n "$mount_lines" ]] || ac_fail "the caddy task must reference volume \"factory-projects\" in a volume_mount"
mount_count="$(echo "$mount_lines" | grep -c -e 'destination = "/srv/disinto/projects"' -e 'read_only   = true')"
ac_assert_eq "$mount_count" "2" \
  "the factory-projects volume_mount must set destination and read_only (got $mount_count)"

# ── AC 4: the host_volume contract docs name factory-projects ────────────────
ac_log "AC 4: the edge job header and INFRASTRUCTURE.md name factory-projects"
header_count="$(grep -c 'factory-projects' "$EDGE_HCL")"
[ "$header_count" -gt 0 ] \
  || ac_fail "edge.hcl must name factory-projects (got $header_count)"
docs_count="$(grep -c 'factory-projects' "$DOCS")"
[ "$docs_count" -gt 0 ] \
  || ac_fail "INFRASTRUCTURE.md must name factory-projects (got $docs_count)"

# ── Syntax: the dispatcher still parses ───────────────────────────────────────
ac_log "AC 5: bash -n passes on the dispatcher"
bash -n "$DISPATCHER" \
  || ac_fail "bash -n docker/edge/dispatcher.sh failed"

ac_pass
