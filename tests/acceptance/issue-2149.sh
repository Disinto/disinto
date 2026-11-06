#!/usr/bin/env bash
# =============================================================================
# tests/acceptance/issue-2149.sh
#
# Issue #2149: docs(design): the self-update note records the wall and the
# branches as applied.
#
# docs/design/notes/self-update.md, "The wall", claimed "The ops repo has no
# branch rule today" (checked on the live forge 2026-11-04). Since 2026-11-06
# it has one, applied with lib/wall.sh (#2120): on the disinto repo the
# patterns sit on the existing `main` rule; the ops repo's `main` now protects
# vault/policy.toml, packs/repair.toml and packs/rollout.toml and leaves every
# other push open. A gardener-bot push changing packs/rollout.toml was refused
# that day. setup_vault_branch_protection is still not in place.
#
# "Build order" now also records that all seven rungs landed as milestone 7
# (#2106-#2124) by 2026-11-05, and that on 2026-11-06 the owner created `live`
# and `canary` at `main`'s head, applied the four agent jobspecs, restarted
# the healer and applied the wall.
#
# Hermetic: the note and lib/wall.sh are only read; no forge, no network.
#
# Acceptance:
#   1. the stale "no branch rule today" sentence is gone.
#   2. the wall paragraph records the 2026-11-06 application, the refused
#      gardener-bot push, and setup_vault_branch_protection as still missing.
#   3. the ops files the note names are exactly lib/wall.sh's ops patterns.
#   4. the milestone-7 paragraph sits at the end of "Build order", after the
#      can-update-self claim sentence, with no heading between them.
#   5. awk 'length > 80' on the note still prints exactly 1 line.
#
# Run via `tools/run-acceptance.sh 2149` or `bash tests/acceptance/issue-2149.sh`.
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=../lib/acceptance-helpers.sh
source "$REPO_ROOT/tests/lib/acceptance-helpers.sh"

ac_require_cmd bash awk grep

NOTE="$REPO_ROOT/docs/design/notes/self-update.md"
WALL="$REPO_ROOT/lib/wall.sh"
ac_assert_file "$NOTE" "docs/design/notes/self-update.md is missing"
ac_assert_file "$WALL" "lib/wall.sh is missing (the wall #2120 records)"

# note_has TEXT — the note must contain the literal TEXT.
note_has() {
  grep -qF -- "$1" "$NOTE" \
    || ac_fail "the note must contain: $1"
}

# ── AC1: the stale "no branch rule today" claim is gone ──────────────────────
ac_log "AC1: the note no longer says the ops repo has no branch rule today"
STALE="$(grep -c 'The ops repo has no branch rule today' "$NOTE" || true)"
ac_assert_eq "$STALE" "0" \
  "the stale 'no branch rule today' sentence must be gone (found $STALE)"
if grep -qF 'Checked on the live forge on 2026-11-04' "$NOTE"; then
  ac_fail "the 2026-11-04 reading of an unruled ops repo must be replaced"
fi
if grep -qF 'leaves every other push as it is' "$NOTE"; then
  ac_fail "the old wall paragraph must be replaced in full, not extended"
fi
ac_log "AC1 OK: the stale paragraph is gone"

# ── AC2: the wall paragraph records the wall as applied ───────────────────────
ac_log "AC2: the wall paragraph records the 2026-11-06 application"
note_has 'Applied on 2026-11-06 with `lib/wall.sh` (#2120)'
note_has 'the patterns sit on the existing `main` rule'
note_has 'The ops repo had no'
note_has 'leaves every other push open'
note_has 'A `gardener-bot` push changing'
note_has '"branch main is protected'
note_has 'from changing file packs/rollout.toml'
note_has 'is still not in place on this deployment'
ac_log "AC2 OK: the wall is recorded as applied, with the refused push"

# ── AC3: the ops files named in the note match lib/wall.sh (#2120) ────────────
ac_log "AC3: the three ops patterns the note names are lib/wall.sh's ops list"
run_wall() {
  WALL="$WALL" bash -c 'set -euo pipefail; source "$WALL"; "$@"' bash "$@"
}
OPS_LIST="$(run_wall wall_patterns ops)"
OPS_MISSING=0
for path in $(printf '%s\n' "$OPS_LIST" | tr ';' '\n'); do
  needle="$(printf '`%s`' "$path")"
  grep -qF -- "$needle" "$NOTE" || OPS_MISSING=1
done
ac_assert_eq "$OPS_MISSING" "0" \
  "every ops pattern in lib/wall.sh must be named in the note's wall paragraph"
ac_log "AC3 OK: the note names all of the wall's ops patterns ($OPS_LIST)"

# ── AC4: the milestone-7 paragraph sits at the end of "Build order" ───────────
ac_log "AC4: the milestone-7 paragraph follows the can-update-self sentence"
CLAIM_LINE="$(grep -nF 'The claim `can-update-self` follows as an ops PR' "$NOTE" | head -n1 | cut -d: -f1)"
SEVEN_LINE="$(grep -nF 'All seven were merged as milestone 7' "$NOTE" | head -n1 | cut -d: -f1)"
[ -n "$CLAIM_LINE" ] || ac_fail "the note must still carry the can-update-self claim sentence"
[ -n "$SEVEN_LINE" ] || ac_fail "the note must carry the milestone-7 paragraph"
[ "$SEVEN_LINE" -gt "$CLAIM_LINE" ] \
  || ac_fail "the milestone-7 paragraph (line $SEVEN_LINE) must follow the claim sentence (line $CLAIM_LINE)"
BETWEEN_HEADINGS="$(awk -v from="$CLAIM_LINE" -v to="$SEVEN_LINE" \
  'NR > from && NR < to && /^## / { print NR }' "$NOTE")"
[ -z "$BETWEEN_HEADINGS" ] \
  || ac_fail "the milestone-7 paragraph must stay inside Build order, not sit under a new heading (headings between: $BETWEEN_HEADINGS)"
note_has 'the owner created `live` and `canary` at `main`'
note_has 'applied the four agent jobspecs, restarted the healer and applied the'
note_has 'wall.'
ac_log "AC4 OK: the build order is recorded as applied"

# ── AC5: the note still has exactly one line longer than 80 characters ────────
ac_log "AC5: awk 'length > 80' on the note prints 1 (the untouched table row)"
LONG="$(awk 'length > 80' "$NOTE" | wc -l | tr -d ' ')"
ac_assert_eq "$LONG" "1" \
  "the note must keep exactly one line over 80 characters (got $LONG)"
ac_log "AC5 OK: no new line exceeds 80 characters"

ac_pass
