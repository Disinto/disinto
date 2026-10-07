#!/usr/bin/env bash
# =============================================================================
# tests/acceptance/issue-1887.sh
#
# Issue #1887: a pitch file carries its sprint block between sprint markers.
#
# A pitch is an ops-repo PR adding sprints/<slug>.md — the proposal for one
# vision issue. Nothing machine-readable about the sprint itself exists on the
# ops repo; the pitch carries two pieces the merged-pitch step (#1889) and
# reject-pitch step (#1891) must read, and lib/pitch.sh provides the two
# functions (no callers yet) that read them.
#
# Functions (sourced; no callers yet):
#   pitch_sprint_block FILE
#     -> the lines strictly between the first `<!-- sprint:begin -->` and the
#        next `<!-- sprint:end -->` marker, unchanged. Prints nothing and
#        returns 1 when FILE is missing, either marker is missing, or
#        `sprint_field "$block" class` is empty.
#   pitch_purpose FILE
#     -> the first paragraph under `## What this enables`. Skips blank lines
#        after the heading; prints lines up to the first blank line, or the
#        first line that starts with `#` or `<!--`. Prints nothing and returns
#        1 when the heading is missing or the paragraph is empty.
#
# Hermetic: no network, no forge, no agent — fixtures in a temp dir, the lib
# sourced in a throwaway subshell (same pattern as issue-1629.sh).
#
# Acceptance: `bash tests/acceptance/issue-1887.sh` exits 0 and calls ac_pass.
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=../../tests/lib/acceptance-helpers.sh
source "$REPO_ROOT/tests/lib/acceptance-helpers.sh"

ac_require_cmd bash
ac_assert_file "$REPO_ROOT/lib/pitch.sh" "lib/pitch.sh is missing"
ac_assert_file "$REPO_ROOT/lib/sprint-block.sh" "lib/sprint-block.sh is missing"

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

# Base pitch fixture: a full sprints/<slug>.md shape with a valid sprint block
# (class present) and a two-line purpose. The "## What exists today" section
# is the "next section" the purpose must not include.
cat >"$TMP_DIR/pitch.md" <<'EOF'
# Pitch: wider probe windows

## What this enables
Probe windows stop guessing from the old default.
One ops PR drives the whole sprint.

## What exists today
lib/sprint-block.sh parses milestone sprint blocks.

## Sprint

<!-- sprint:begin -->
class: internal
effect: probes/x.sh
expect: >= 1
soak: 14d
<!-- sprint:end -->

## Sub-issues

<!-- filer:begin -->
- id: pitch-window-1
  title: "vision(#1887): read the pitch's sprint block"
  labels: [backlog]
  depends_on: []
  body: |
    ## Goal
    pitch_sprint_block prints the block between the markers, unchanged.
    ## Acceptance criteria
    - [ ] `bash tests/acceptance/issue-1887.sh` exits 0
<!-- filer:end -->
EOF

BLOCK=$'class: internal\neffect: probes/x.sh\nexpect: >= 1\nsoak: 14d'
PARA=$'Probe windows stop guessing from the old default.\nOne ops PR drives the whole sprint.'

# ── AC1: the block between the markers, unchanged (rc 0, stderr-clean) ───────
ac_log "AC1: pitch_sprint_block prints the block between the markers, unchanged"
ac_run_block "$REPO_ROOT/lib/pitch.sh" pitch_sprint_block "$TMP_DIR/pitch.md"
ac_assert_eq "$OUT" "$BLOCK" \
  "pitch_sprint_block must print the block unchanged (got '$OUT') [stderr: $ERR]"
[ -z "$ERR" ] || ac_fail "pitch_sprint_block must not print stderr (got: $ERR)"
ac_assert_eq "$RC" "0" "pitch_sprint_block must return 0 (rc=$RC)"

# ── AC2: the first paragraph under the heading; nothing from the next section
ac_log "AC2: pitch_purpose prints the first paragraph under the heading"
ac_run_block "$REPO_ROOT/lib/pitch.sh" pitch_purpose "$TMP_DIR/pitch.md"
ac_assert_eq "$OUT" "$PARA" \
  "pitch_purpose must print the first paragraph under ## What this enables (got '$OUT') [stderr: $ERR]"
[[ "$OUT" != *'## What exists today'* && \
    "$OUT" != *"lib/sprint-block.sh parses milestone sprint blocks."* ]] \
  || ac_fail "next section leaked into the purpose output: $OUT"
[ -z "$ERR" ] || ac_fail "pitch_purpose must not print stderr (got: $ERR)"
ac_assert_eq "$RC" "0" "pitch_purpose must return 0 (rc=$RC)"

# ── AC3: no end marker -> prints nothing, returns 1 ───────────────────────────
cat >"$TMP_DIR/pitch-missing-end.md" <<'EOF'
# Pitch: missing end marker

## Sprint

<!-- sprint:begin -->
class: internal
effect: probes/x.sh
expect: >= 1
soak: 14d
EOF
ac_log "AC3: missing end marker prints nothing and returns 1"
ac_run_block "$REPO_ROOT/lib/pitch.sh" pitch_sprint_block "$TMP_DIR/pitch-missing-end.md"
ac_assert_eq "$OUT" "" "missing end marker must print nothing (got '$OUT')"
[ -z "$ERR" ] || ac_fail "missing end marker must not print stderr (got: $ERR)"
ac_assert_eq "$RC" "1" "missing end marker must return 1 (rc=$RC)"

# ── AC4: no class line -> prints nothing, returns 1 ──────────────────────────
cat >"$TMP_DIR/pitch-no-class.md" <<'EOF'
# Pitch: missing class line

## Sprint

<!-- sprint:begin -->
effect: probes/x.sh
expect: >= 1
soak: 14d
<!-- sprint:end -->
EOF
ac_log "AC4: missing class line prints nothing and returns 1"
ac_run_block "$REPO_ROOT/lib/pitch.sh" pitch_sprint_block "$TMP_DIR/pitch-no-class.md"
ac_assert_eq "$OUT" "" "missing class line must print nothing (got '$OUT')"
[ -z "$ERR" ] || ac_fail "missing class line must not print stderr (got: $ERR)"
ac_assert_eq "$RC" "1" "missing class line must return 1 (rc=$RC)"

# ── AC5: no purpose heading -> prints nothing, returns 1 ─────────────────────
cat >"$TMP_DIR/pitch-no-heading.md" <<'EOF'
# Pitch: no purpose heading

## Sprint

<!-- sprint:begin -->
class: internal
effect: probes/x.sh
expect: >= 1
soak: 14d
<!-- sprint:end -->
EOF
ac_log "AC5: missing purpose heading prints nothing and returns 1"
ac_run_block "$REPO_ROOT/lib/pitch.sh" pitch_purpose "$TMP_DIR/pitch-no-heading.md"
ac_assert_eq "$OUT" "" "missing purpose heading must print nothing (got '$OUT')"
[ -z "$ERR" ] || ac_fail "missing purpose heading must not print stderr (got: $ERR)"
ac_assert_eq "$RC" "1" "missing purpose heading must return 1 (rc=$RC)"

ac_pass "issue #1887: a pitch file carries its sprint block between sprint markers"
