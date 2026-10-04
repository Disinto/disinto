#!/usr/bin/env bash
# =============================================================================
# tests/lib/forge-stub.sh — shared forge_api stub helpers for acceptance tests
#
# Sourced by tests/acceptance/issue-<N>.sh that test tools which call
# forge_api GET "/milestones/<N>" (sprint-due.sh #1675, sprint-outcomes.sh
# #1676). Keeps the stub command and the milestone-fixture writer in one place
# so those tests do not duplicate them (duplicate detection, 5-line windows).
#
# Requires the caller to have set:
#   STUB_BIN       directory for the stub binary (must exist)
#   FIXTURES       directory for milestone fixtures
#   CALLS          file the stub appends recorded calls to
#   FORGE_FAIL_DIR (optional) directory whose per-<N> files force a failure
#
# Provides:
#   stub_milestone_forge_api
#   write_milestone N STATE OPEN CLOSED DESC
# =============================================================================

# stub_milestone_forge_api — write a stub forge_api that returns
# ${FORGE_FIXTURES}/${n}.json for GET "/milestones/<n>". Records the full
# call (args) into ${FORGE_CALLS}. A file at ${FORGE_FAIL_DIR}/${n} forces a
# failure. Hermetic: no network, no real curl.
stub_milestone_forge_api() {
  cat >"$STUB_BIN/forge_api" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "${FORGE_CALLS:?}"
method="${1:-}"
path="${2:-}"
if [ "$method" != "GET" ]; then
  echo "stub: bad method ${method}" >&2
  exit 1
fi
n="${path#/milestones/}"
if [ "$path" != "/milestones/${n}" ] || ! [[ "$n" =~ ^[0-9]+$ ]]; then
  echo "stub: bad path ${path}" >&2
  exit 1
fi
if [ -n "${FORGE_FAIL_DIR:-}" ] && [ -f "${FORGE_FAIL_DIR:?}/${n}" ]; then
  echo "stub: forced failure for ${n}" >&2
  exit 1
fi
cat "${FORGE_FIXTURES:?}/${n}.json"
EOF
  chmod +x "$STUB_BIN/forge_api"
}

# write_milestone N STATE OPEN CLOSED DESC — write the milestone fixture JSON
# the stub returns for GET /milestones/<N>. STATE closed / OPEN 0 CLOSED > 0
# ("drained") both count as done for sprint-due.sh's due-ness check.
write_milestone() {
  local n="$1" state="$2" open_n="$3" closed_n="$4" desc="$5"
  jq -n \
    --argjson id "$n" \
    --arg state "$state" \
    --argjson open_issues "$open_n" \
    --argjson closed_issues "$closed_n" \
    --arg description "$desc" \
    '{id: $id, state: $state, open_issues: $open_issues,
      closed_issues: $closed_issues, description: $description}' \
    >"$FIXTURES/${n}.json"
}
