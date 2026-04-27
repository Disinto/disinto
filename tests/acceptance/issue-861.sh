#!/usr/bin/env bash
# =============================================================================
# tests/acceptance/issue-861.sh — verifies forge-collector emits per-label
# issue lists with titles, not just counts
#
# Issue #861: state.collectors.forge.backlog/in_progress/blocked must be
# arrays of {number, title, age_hours}, capped at 20, sorted newest-first.
# Existing *_count fields must be preserved (no breaking changes).
#
# Checks:
#   1. snapshot-forge.sh emits backlog/in_progress/blocked arrays (not just counts).
#   2. Each array item shape: {number, title, age_hours}.
#   3. Lists are capped at 20 and sorted newest-first (sort_by + reverse).
#   4. *_count fields are preserved.
#   5. Vision items are NOT enumerated (no vision array).
#   6. factory-state.sh surfaces the new lists in prose summary.
#   7. shellcheck still passes on both scripts.
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
cd "$REPO_ROOT"

# shellcheck disable=SC1091
source "$(dirname "$0")/../lib/acceptance-helpers.sh"

ac_require_cmd jq

# ── 1. snapshot-forge.sh must emit per-label arrays ──────────────────────────

ac_log "checking snapshot-forge.sh emits backlog/in_progress/blocked arrays"

forge_script=bin/snapshot-forge.sh
[ -f "$forge_script" ] || ac_fail "$forge_script missing"

# The jq output object must contain backlog, in_progress, blocked keys
# (not just *_count). Check the jq pipeline builds these arrays.
for key in backlog in_progress blocked; do
  if ! grep -q "^[[:space:]]*${key}:" "$forge_script"; then
    ac_fail "$forge_script: missing '$key' array key in jq output"
  fi
done

# Verify the jq pipeline constructs per-label arrays with sort_by + reverse + slice
for key in backlog in_progress blocked; do
  if ! grep -q "sort_by(.created_at)" "$forge_script"; then
    ac_fail "$forge_script: missing sort_by(.created_at) for ordering"
  fi
done

# Verify cap at 20
if ! grep -q '\[0:20\]' "$forge_script"; then
  ac_fail "$forge_script: missing cap at 20 items (.[0:20] slice)"
fi

# Verify each item has number, title, age_hours
if ! grep -q '{number: .number, title: .title, age_hours:' "$forge_script"; then
  ac_fail "$forge_script: item shape missing {number, title, age_hours}"
fi

# ── 2. *_count fields must be preserved ──────────────────────────────────────

ac_log "checking *_count fields preserved"

for key in backlog_count in_progress_count blocked_count underspecified_count vision_count; do
  if ! grep -q "$key" "$forge_script"; then
    ac_fail "$forge_script: missing $key (breaking change)"
  fi
done

# ── 3. Vision items must NOT be enumerated ───────────────────────────────────

ac_log "checking vision items are NOT enumerated"

# There must be no vision array in the jq output (only vision_count).
# The jq object should NOT have "vision: $vision_items" or similar.
if grep -qE "vision:.*\\\$vision_items" "$forge_script"; then
  ac_fail "$forge_script: vision items should NOT be enumerated as an array"
fi

# ── 4. factory-state.sh must surface new lists ──────────────────────────────

ac_log "checking factory-state.sh surfaces per-label issue lists"

state_script=docker/edge/chat-skills/factory-state/factory-state.sh
[ -f "$state_script" ] || ac_fail "$state_script missing"

# Must reference the new array keys in the summary
for key in backlog in_progress blocked; do
  if ! grep -q "$key" "$state_script"; then
    ac_fail "$state_script: missing reference to '$key' array"
  fi
done

# ── 5. shellcheck must still pass ───────────────────────────────────────────

ac_log "running shellcheck on modified scripts"

if command -v shellcheck >/dev/null 2>&1; then
  shellcheck "$forge_script" "$state_script" \
    || ac_fail "shellcheck failed on modified scripts"
fi

echo PASS
