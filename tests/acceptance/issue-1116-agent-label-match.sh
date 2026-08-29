#!/usr/bin/env bash
# =============================================================================
# tests/acceptance/issue-1116-agent-label-match.sh
#
# Issue #1116: .woodpecker/acceptance-tests.yml pins itself to
# `labels: host: disinto-nomad-box`, but the Woodpecker agent jobspec
# (nomad/jobs/woodpecker-agent.hcl) advertised no labels at all
# (WOODPECKER_AGENT_LABELS unset). A workflow whose label selector no agent
# satisfies is never dispatched, so every post-merge acceptance pipeline
# queued forever and its parent pipelines sat in `running` for up to 28h.
#
# This test locks in the invariant that prevents the regression: every label
# a `.woodpecker/*.yml` workflow selects on must be advertised by at least
# one agent jobspec under nomad/jobs/. Without a matching agent label, a new
# workflow label would silently queue forever instead of failing CI.
#
# Read-only: parses the workflow YAML and the jobspec HCL from the checkout;
# no live services, no network.
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck disable=SC1091
source "$REPO_ROOT/tests/lib/acceptance-helpers.sh"

ac_require_cmd awk
ac_require_cmd grep

JOBSPEC="$REPO_ROOT/nomad/jobs/woodpecker-agent.hcl"
ac_assert_file "$JOBSPEC" "jobspec nomad/jobs/woodpecker-agent.hcl must exist"

WORKFLOW_LABELS="$(mktemp)"
AGENT_LABELS="$(mktemp)"
trap 'rm -f "$WORKFLOW_LABELS" "$AGENT_LABELS"' EXIT

# ── 1. Collect the labels every workflow selects on ─────────────────────────
# A workflow's label selector is the top-level `labels:` mapping in its
# .woodpecker/*.yml — one `key: value` pair per selected label. Emit
# `<workflow-file>:<key>=<value>` per line.
for f in "$REPO_ROOT/.woodpecker"/*.yml; do
  [ -f "$f" ] || continue
  awk -v src="$(basename "$f")" '
    function trim(s) { sub(/^[[:space:]]+/, "", s); sub(/[[:space:]]+$/, "", s); return s }
    function unquote(s) {
      if (length(s) >= 2) {
        first = substr(s, 1, 1)
        last = substr(s, length(s), 1)
        if ((first == "\"" && last == "\"") || (first == SQ && last == SQ))
          return substr(s, 2, length(s) - 2)
      }
      return s
    }
    BEGIN { SQ = sprintf("%c", 39) }
    /^labels:[[:space:]]*$/ { inlbl = 1; next }
    inlbl == 1 {
      if ($0 ~ /^[[:space:]]*$/) next                # blank line inside block
      if ($0 !~ /^[[:space:]]/) { inlbl = 0; next }  # next top-level key ends block
      line = trim($0)
      if (line ~ /^#/) next
      idx = index(line, ":")
      if (idx == 0) next
      key = unquote(trim(substr(line, 1, idx - 1)))
      val = unquote(trim(substr(line, idx + 1)))
      if (key != "" && val != "") print src ":" key "=" val
    }
  ' "$f" >> "$WORKFLOW_LABELS"
done

# ── 2. Collect the labels every agent jobspec advertises ────────────────────
# WOODPECKER_AGENT_LABELS is a comma-separated `key=value` list. A workflow
# is dispatched when ANY agent matches its selector, so take the union across
# all jobspecs that set the variable.
for f in "$REPO_ROOT/nomad/jobs"/*.hcl; do
  [ -f "$f" ] || continue
  grep -hE '^[[:space:]]*WOODPECKER_AGENT_LABELS[[:space:]]*=' "$f" \
    | sed -E 's/^[[:space:]]*WOODPECKER_AGENT_LABELS[[:space:]]*=[[:space:]]*//' \
    | tr -d "\"'" | tr ',' '\n' \
    | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//' \
    | grep -vE '^[[:space:]]*$' \
    >> "$AGENT_LABELS" || true
done

# ── 3. The fix itself: the agent advertises the host label ──────────────────
# The acceptance workflow is deliberately pinned to this host (it needs the
# host's Docker daemon, nomad CLI, and the flock file), so the matching agent
# label must exist.
grep -q 'host=disinto-nomad-box' "$WORKFLOW_LABELS" \
  || ac_fail ".woodpecker/acceptance-tests.yml no longer selects the host label — the pin is deliberate, check the workflow"
grep -Fxq 'host=disinto-nomad-box' "$AGENT_LABELS" \
  || ac_fail "no agent jobspec advertises host=disinto-nomad-box — acceptance-tests workflows would queue forever"

# ── 4. Every workflow label has a matching agent label ──────────────────────
# The general invariant: any label a workflow selects on must be advertised
# by at least one agent, or the workflow can never be scheduled.
while IFS= read -r sel; do
  [ -n "$sel" ] || continue
  wf="${sel%%:*}"
  label="${sel#*:}"
  if ! grep -Fxq "$label" "$AGENT_LABELS"; then
    ac_fail "workflow label '$label' (selected by .woodpecker/$wf) is not advertised by any nomad/jobs/*.hcl jobspec — the workflow would queue forever"
  fi
done < "$WORKFLOW_LABELS"

ac_log "workflow labels: $(tr '\n' ' ' < "$WORKFLOW_LABELS")"
ac_log "agent labels:    $(tr '\n' ' ' < "$AGENT_LABELS")"

ac_pass
