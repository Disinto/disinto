#!/usr/bin/env bash
# =============================================================================
# tests/acceptance/issue-1780.sh
#
# Issue #1780: the nomad/jobs/edge.hcl row in nomad/AGENTS.md still described
# a /woodpecker route and loopback upstreams (127.0.0.1:3000 / :8000). The
# jobspec routes /forge, /ci, /staging and /api/engagement, and resolves the
# forgejo, woodpecker and staging upstreams with nomadService (#1156).
#
# This test is read-only: it greps that one row. It does not edit the doc
# and does not talk to forge or nomad.
#
# Run via: tools/run-acceptance.sh 1780
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../lib/acceptance-helpers.sh
source "$REPO_ROOT/tests/lib/acceptance-helpers.sh"

ac_require_cmd grep

EDGE_ROW_DOC="$REPO_ROOT/nomad/AGENTS.md"
ac_assert_file "$EDGE_ROW_DOC" "nomad/AGENTS.md must exist so the edge row can be checked"

# The three criteria from the issue, scoped to the edge.hcl row.
ac_log "edge row does not claim a /woodpecker route or a loopback upstream"
stale_edge="$(grep -n 'nomad/jobs/edge.hcl' "$EDGE_ROW_DOC" \
  | grep -E '/woodpecker|127\.0\.0\.1|:3000|:8000' || true)"
[ -z "$stale_edge" ] \
  || ac_fail "edge row still claims a /woodpecker route or a loopback upstream: ${stale_edge}"

ac_log "edge row lists routes /forge, /ci, /staging and /api/engagement"
route_hits="$(grep -n 'nomad/jobs/edge.hcl' "$EDGE_ROW_DOC" \
  | grep -cF 'routes /forge, /ci, /staging and /api/engagement' || true)"
ac_assert_eq "$route_hits" "1" \
  "edge row must name routes /forge, /ci, /staging and /api/engagement exactly once (got: ${route_hits})"

ac_log "edge row resolves those upstreams with nomadService (#1156)"
svc_hits="$(grep -n 'nomad/jobs/edge.hcl' "$EDGE_ROW_DOC" \
  | grep -cF '`nomadService` (#1156)' || true)"
ac_assert_eq "$svc_hits" "1" \
  "edge row must cite \`nomadService\` (#1156) exactly once (got: ${svc_hits})"

ac_pass
