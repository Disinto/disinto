#!/usr/bin/env bash
# =============================================================================
# tests/acceptance/issue-2029.sh
#
# Issue #2029: sprint_level reads the level line of a sprint block.
#
# The sprint block gains one line (docs/design/proposal-loop.md §2): `level:`
# names the effect-scale level the sprint aims at (held / made / reachable /
# reached), default held. lib/sprint-block.sh already parses class, effect,
# expect, soak and rests_on; two functions now read the level and its grade
# (§3, the effect scale). The live milestones carry no level line, so the
# default must hold for them.
#
# Functions (sourced; hermetic):
#   sprint_level TEXT
#     -> the level field of TEXT: a missing line prints `held`, rc 0;
#        `held`/`made`/`reachable`/`reached` print themselves, rc 0; any
#        other word (broke, none, huge, ...) prints nothing, rc 1.
#   sprint_level_value LEVEL
#     -> the grade of a level: broke -1, none 0, held 0.25, made 0.5,
#        reachable 0.75, reached 1; an unknown word prints nothing, rc 1.
#
# Hermetic: no network, no forge, no agent — fixture strings only, the lib
# sourced in a throwaway subshell via ac_run_block (same pattern as
# issue-1629.sh).
#
# Acceptance: `bash tests/acceptance/issue-2029.sh` exits 0 and calls ac_pass.
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=../lib/acceptance-helpers.sh
source "$REPO_ROOT/tests/lib/acceptance-helpers.sh"

ac_require_cmd bash
ac_assert_file "$REPO_ROOT/lib/sprint-block.sh" "lib/sprint-block.sh is missing"

# ── AC1: a block with no level line defaults to held ──────────────────────────
ac_log "AC1: sprint_level defaults to held when the line is missing"
ac_run_block "$REPO_ROOT/lib/sprint-block.sh" sprint_level $'class: internal\neffect: none'
ac_assert_eq "$OUT" "held" "a missing level line must print 'held' (got '$OUT') [stderr: $ERR]"
ac_assert_eq "$RC" "0" "a missing level line must return 0 (rc=$RC)"

# ── AC2: the four aim-words read back, padding stripped ────────────────────────
ac_log "AC2: sprint_level reads the four aim-words"
ac_run_block "$REPO_ROOT/lib/sprint-block.sh" sprint_level $'level: reachable\nclass: deploy'
ac_assert_eq "$OUT" "reachable" "level: reachable must print 'reachable' (got '$OUT') [stderr: $ERR]"
ac_assert_eq "$RC" "0" "level: reachable must return 0 (rc=$RC)"
ac_run_block "$REPO_ROOT/lib/sprint-block.sh" sprint_level "level:   made  "
ac_assert_eq "$OUT" "made" "a padded level line must print 'made' (got '$OUT')"
ac_assert_eq "$RC" "0" "a padded level line must return 0 (rc=$RC)"
ac_run_block "$REPO_ROOT/lib/sprint-block.sh" sprint_level $'level: held\nclass: internal'
ac_assert_eq "$OUT" "held" "level: held must print 'held' (got '$OUT')"
ac_run_block "$REPO_ROOT/lib/sprint-block.sh" sprint_level $'level: reached\nclass: deploy'
ac_assert_eq "$OUT" "reached" "level: reached must print 'reached' (got '$OUT')"

# ── AC3: an unknown level is refused, not defaulted ───────────────────────────
ac_log "AC3: sprint_level refuses a level it does not know"
ac_run_block "$REPO_ROOT/lib/sprint-block.sh" sprint_level "level: broke"
ac_assert_eq "$OUT" "" "level: broke must print nothing (got '$OUT') [stderr: $ERR]"
ac_assert_eq "$RC" "1" "level: broke must return 1 (rc=$RC)"
ac_run_block "$REPO_ROOT/lib/sprint-block.sh" sprint_level "level: huge"
ac_assert_eq "$OUT" "" "level: huge must print nothing (got '$OUT')"
ac_assert_eq "$RC" "1" "level: huge must return 1 (rc=$RC)"
ac_run_block "$REPO_ROOT/lib/sprint-block.sh" sprint_level "level: none"
ac_assert_eq "$OUT" "" "level: none must print nothing (got '$OUT')"
ac_assert_eq "$RC" "1" "level: none must return 1 (rc=$RC)"

# ── AC4: sprint_level_value gives the grade of every level ─────────────────────
ac_log "AC4: sprint_level_value maps the six levels to their grades"
for pair in "broke -1" "none 0" "held 0.25" "made 0.5" "reachable 0.75" "reached 1"; do
  level="${pair% *}"
  grade="${pair#* }"
  ac_run_block "$REPO_ROOT/lib/sprint-block.sh" sprint_level_value "$level"
  ac_assert_eq "$OUT" "$grade" "sprint_level_value $level must print $grade (got '$OUT') [stderr: $ERR]"
  ac_assert_eq "$RC" "0" "sprint_level_value $level must return 0 (rc=$RC)"
done
ac_run_block "$REPO_ROOT/lib/sprint-block.sh" sprint_level_value "tall"
ac_assert_eq "$OUT" "" "sprint_level_value tall must print nothing (got '$OUT')"
ac_assert_eq "$RC" "1" "sprint_level_value tall must return 1 (rc=$RC)"

# ── AC5: the header documents the level line ───────────────────────────────────
ac_log "AC5: the header block format lists the level line"
grep -q '^#   level: reachable' "$REPO_ROOT/lib/sprint-block.sh" \
  || ac_fail "the header must document the level: line in the block format"
grep -q 'sprint_level TEXT' "$REPO_ROOT/lib/sprint-block.sh" \
  || ac_fail "the header function list must document sprint_level"
grep -q 'sprint_level_value LEVEL' "$REPO_ROOT/lib/sprint-block.sh" \
  || ac_fail "the header function list must document sprint_level_value"
grep -qF "optional \`level:\`" "$REPO_ROOT/lib/AGENTS.md" \
  || ac_fail "lib/AGENTS.md must document the optional level: line"

ac_pass "issue #2029: sprint_level reads the level line of a sprint block"
