#!/usr/bin/env bash
# =============================================================================
# tests/acceptance/issue-1978.sh
#
# Issue #1978: open the ladder pitch, or stay idle.
#
# planner/pitch-or-idle.sh sources planner/ladder.sh and planner/pitch-open.sh
# and does not source lib/env.sh. planner_pitch_or_idle prints held, opened
# <n>, or session, and does not call agent_run. A rung pitch is opened even
# when its probe is missing from the ops repo. planner_publish_session_pitch
# opens a session pitch whose effect is already in the ops repo, or adds the
# probe from PLANNER_PROBE_FILE; a missing probe file is not an open.
#
# planner-run.sh no longer walks an ops PR and does not set CLAUDE_MODEL.
#
# Hermetic: stubs for the ladder and the opener. No forge, no agent.
#
# Acceptance: `bash tests/acceptance/issue-1978.sh` exits 0 and calls ac_pass.
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=../../tests/lib/acceptance-helpers.sh
source "$REPO_ROOT/tests/lib/acceptance-helpers.sh"

ac_require_cmd bash grep mktemp
ac_assert_file "$REPO_ROOT/planner/pitch-or-idle.sh" "planner/pitch-or-idle.sh is missing"
ac_assert_file "$REPO_ROOT/planner/planner-run.sh" "planner/planner-run.sh is missing"

RUN="$REPO_ROOT/planner/planner-run.sh"
IDLE="$REPO_ROOT/planner/pitch-or-idle.sh"

ac_log "static: bash -n, sources ladder and pitch-open, not env.sh"
bash -n "$IDLE"
bash -n "$RUN"
if grep -E '^[[:space:]]*(source|\.)[[:space:]]' "$IDLE" | grep -q 'env.sh'; then
  ac_fail "planner/pitch-or-idle.sh must not source lib/env.sh"
fi
grep -q 'ladder.sh' "$IDLE" || ac_fail "planner/pitch-or-idle.sh must source planner/ladder.sh"
grep -q 'pitch-open.sh' "$IDLE" || ac_fail "planner/pitch-or-idle.sh must source planner/pitch-open.sh"
if grep -E '^[[:space:]]*agent_run([[:space:]]|$)' "$IDLE"; then
  ac_fail "planner/pitch-or-idle.sh must not call agent_run"
fi
grep -q 'pitch-or-idle.sh' "$RUN" || ac_fail "planner-run.sh must source planner/pitch-or-idle.sh"
grep -qF 'ops:catalog/claims.md' "$RUN" \
  || ac_fail "planner-run.sh must build context from ops:catalog/claims.md"
if grep -q 'ops:prerequisites.md' "$RUN"; then
  ac_fail "planner-run.sh must not inject ops:prerequisites.md"
fi

ac_log "planner-run.sh has no pr walk and does not set CLAUDE_MODEL"
if grep -n 'pr_walk_to_merge' "$RUN"; then
  ac_fail "grep pr_walk_to_merge planner/planner-run.sh must print nothing"
fi
if grep -n 'CLAUDE_MODEL=' "$RUN"; then
  ac_fail "grep CLAUDE_MODEL= planner/planner-run.sh must print nothing"
fi
grep -qF 'ladder: none' "$RUN" \
  || ac_fail "planner-run.sh must append ladder: none on the session path"

ac_log "docs: the run calls planner_pitch_or_idle and does not hardcode opus"
DOC="$REPO_ROOT/planner/AGENTS.md"
grep -qF 'The run calls `planner_pitch_or_idle`.' "$DOC" \
  || ac_fail "planner/AGENTS.md must say the run calls planner_pitch_or_idle"
grep -qF 'does not call `pr_walk_to_merge`.' "$DOC" \
  || ac_fail "planner/AGENTS.md must say the run does not call pr_walk_to_merge"
grep -qF '`planner-run.sh` does not set `CLAUDE_MODEL`.' "$DOC" \
  || ac_fail "planner/AGENTS.md must say planner-run.sh does not set CLAUDE_MODEL"
ac_assert_eq "$(grep -cF 'Called by `planner/pitch-or-idle.sh`.' "$DOC")" "2" \
  "ladder.sh and pitch-open.sh bullets must name planner/pitch-or-idle.sh"

# shellcheck source=../../planner/pitch-or-idle.sh
source "$IDLE"

T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
export OPS_REPO_ROOT="$T/ops"
mkdir -p "$OPS_REPO_ROOT"

# record_open — stub planner_pitch_open. Prints 9. Args land in $T/open-args.
record_open() {
  printf '%s\n' "$#" >"$T/open-argc"
  printf '%s\n' "$@" >"$T/open-args"
  printf '9\n'
}

# clear_open — drop the previous stub record.
clear_open() {
  rm -f "$T/open-argc" "$T/open-args"
}

# assert_not_opened — the stub was not called.
assert_not_opened() {
  [ ! -e "$T/open-argc" ] || ac_fail "planner_pitch_open must not be called ($1)"
}

ac_log "AC1: ladder sense opens a pitch with slug sense and no filer block"
clear_open
OUT="$(
  planner_pitch_pending() { return 0; }
  ladder_lowest_gap() { printf 'sense\n'; }
  planner_pitch_open() { record_open "$@"; }
  planner_pitch_or_idle
)"
ac_assert_eq "$OUT" "opened 9" "planner_pitch_or_idle must print opened <n> (got '$OUT')"
ac_assert_eq "$(sed -n '1p' "$T/open-args")" "Sense" "title passed to planner_pitch_open"
ac_assert_eq "$(sed -n '2p' "$T/open-args")" "sense" "slug passed must be sense"
ac_assert_eq "$(sed -n '1p' "$T/open-argc")" "3" "a rung pitch takes no probe arguments"
PITCH_FILE="$(sed -n '3p' "$T/open-args")"
grep -qF 'effect: probes/can-sense.sh' "$PITCH_FILE" \
  || ac_fail "pitch file must contain effect: probes/can-sense.sh"
if grep -qF 'filer:begin' "$PITCH_FILE"; then
  ac_fail "pitch file must not contain filer:begin"
fi
grep -qF 'The planner pitches it and does not run it.' "$PITCH_FILE" \
  || ac_fail "the rung paragraph must end with the pitch sentence"
grep -qF 'class: internal' "$PITCH_FILE" || ac_fail "rung pitch must set class: internal"
grep -qF 'expect: >= 1' "$PITCH_FILE" || ac_fail "rung pitch must set expect: >= 1"
grep -qF 'soak: 14d' "$PITCH_FILE" || ac_fail "rung pitch must set soak: 14d"

ac_log "AC2: a missing probes/can-sense.sh still opens"
clear_open
[ ! -e "$OPS_REPO_ROOT/probes/can-sense.sh" ] || ac_fail "fixture must not contain the sense probe"
OUT="$(
  planner_pitch_pending() { return 0; }
  ladder_lowest_gap() { printf 'sense\n'; }
  planner_pitch_open() { record_open "$@"; }
  planner_pitch_or_idle
)"
ac_assert_eq "$OUT" "opened 9" "a missing rung probe must still print opened (got '$OUT')"

ac_log "reach title is Reach the porter and the slug is the rung id"
clear_open
OUT="$(
  planner_pitch_pending() { return 0; }
  ladder_lowest_gap() { printf 'reach\n'; }
  planner_pitch_open() { record_open "$@"; }
  planner_pitch_or_idle
)"
ac_assert_eq "$OUT" "opened 9" "reach must open (got '$OUT')"
ac_assert_eq "$(sed -n '1p' "$T/open-args")" "Reach the porter" "reach title"
ac_assert_eq "$(sed -n '2p' "$T/open-args")" "reach" "reach slug is the rung id"
PITCH_FILE="$(sed -n '3p' "$T/open-args")"
grep -qF 'effect: probes/can-reach-porter.sh' "$PITCH_FILE" \
  || ac_fail "reach pitch must name probes/can-reach-porter.sh"

ac_log "provision paragraph names ai-pool and keeps the pool path"
clear_open
(
  planner_pitch_pending() { return 0; }
  ladder_lowest_gap() { printf 'provision\n'; }
  planner_pitch_open() { record_open "$@"; }
  planner_pitch_or_idle >/dev/null
)
grep -qF 'ai-pool (`/opt/ai`) only' "$(sed -n '3p' "$T/open-args")" \
  || ac_fail "provision paragraph must name ai-pool (/opt/ai)"

ac_log "AC3: an empty ladder prints session and does not open"
clear_open
OUT="$(
  planner_pitch_pending() { return 0; }
  ladder_lowest_gap() { return 0; }
  planner_pitch_open() { record_open "$@"; }
  planner_pitch_or_idle
)"
ac_assert_eq "$OUT" "session" "an empty ladder must print session (got '$OUT')"
assert_not_opened "session"

ac_log "AC4: a pending pitch prints held and does not open"
clear_open
OUT="$(
  planner_pitch_pending() { printf '4\n'; }
  ladder_lowest_gap() { printf 'sense\n'; record_open ladder-called; }
  planner_pitch_open() { record_open "$@"; }
  planner_pitch_or_idle
)"
ac_assert_eq "$OUT" "held" "a pending number must print held (got '$OUT')"
assert_not_opened "held"

ac_log "pending failure prints nothing and returns 1"
clear_open
RC=0
OUT="$(
  planner_pitch_pending() { return 1; }
  planner_pitch_open() { record_open "$@"; }
  planner_pitch_or_idle
)" || RC=$?
ac_assert_eq "$RC" "1" "planner_pitch_pending failure must return 1 (rc=$RC)"
ac_assert_eq "$OUT" "" "planner_pitch_pending failure must print nothing (got '$OUT')"
assert_not_opened "pending failure"

# write_pitch EFFECT [extra] — a session pitch file. Prints the path.
write_pitch() {
  local effect="$1" extra="${2:-}"
  local path="$T/session-pitch.md"
  # Field order differs from the rung writer so the two files do not share
  # a 5-line window. sprint_field does not care about order.
  cat >"$path" <<EOF
# Sprint: New thing

## What this enables

A probe the session wrote. The planner pitches it and does not run it.

<!-- sprint:begin -->
class: internal
expect: >= 1
soak: 14d
effect: ${effect}
<!-- sprint:end -->
${extra}
EOF
  printf '%s\n' "$path"
}

ac_log "AC5: missing ops probe plus a probe file opens with PROBE_SRC and PROBE_DEST"
clear_open
PROBE="$T/probe.sh"
printf 'echo 1\n' >"$PROBE"
PITCH="$(write_pitch 'probes/new-thing.sh')"
export PLANNER_PITCH_FILE="$PITCH"
export PLANNER_PROBE_FILE="$PROBE"
rm -rf "$OPS_REPO_ROOT/probes"
RC=0
(
  planner_pitch_open() { record_open "$@"; }
  planner_publish_session_pitch
) || RC=$?
ac_assert_eq "$RC" "0" "publish with a probe file must return 0 (rc=$RC)"
ac_assert_eq "$(sed -n '1p' "$T/open-argc")" "5" "publish must pass probe arguments"
ac_assert_eq "$(sed -n '2p' "$T/open-args")" "new-thing" "session slug is the squeezed title"
ac_assert_eq "$(sed -n '4p' "$T/open-args")" "$PROBE" "PROBE_SRC must be PLANNER_PROBE_FILE"
ac_assert_eq "$(sed -n '5p' "$T/open-args")" "probes/new-thing.sh" "PROBE_DEST must be the effect path"

ac_log "AC6: missing ops probe and no probe file returns 0 and does not open"
clear_open
export PLANNER_PROBE_FILE="$T/no-such-probe.sh"
RC=0
(
  planner_pitch_open() { record_open "$@"; }
  planner_publish_session_pitch
) || RC=$?
ac_assert_eq "$RC" "0" "a missing probe file must return 0 (rc=$RC)"
assert_not_opened "missing probe file"

ac_log "AC7: an ops probe that is already a file opens with no probe arguments"
clear_open
mkdir -p "$OPS_REPO_ROOT/probes"
: >"$OPS_REPO_ROOT/probes/new-thing.sh"
export PLANNER_PROBE_FILE="$PROBE"
RC=0
(
  planner_pitch_open() { record_open "$@"; }
  planner_publish_session_pitch
) || RC=$?
ac_assert_eq "$RC" "0" "an ops probe already present must return 0 (rc=$RC)"
ac_assert_eq "$(sed -n '1p' "$T/open-argc")" "3" "an ops probe already present takes no probe arguments"

ac_log "effect none opens with no probe arguments"
clear_open
PITCH="$(write_pitch 'none')"
export PLANNER_PITCH_FILE="$PITCH"
RC=0
(
  planner_pitch_open() { record_open "$@"; }
  planner_publish_session_pitch
) || RC=$?
ac_assert_eq "$RC" "0" "effect none must return 0 (rc=$RC)"
ac_assert_eq "$(sed -n '1p' "$T/open-argc")" "3" "effect none takes no probe arguments"
ac_assert_eq "$(sed -n '1p' "$T/open-args")" "New thing" "effect none keeps the sprint title"

ac_log "a bad effect, a filer block, and a missing file"
clear_open
PITCH="$(write_pitch 'not-a-probe')"
export PLANNER_PITCH_FILE="$PITCH"
RC=0
(
  planner_pitch_open() { record_open "$@"; }
  planner_publish_session_pitch
) || RC=$?
ac_assert_eq "$RC" "1" "a bad effect must return 1 (rc=$RC)"
assert_not_opened "bad effect"

clear_open
PITCH="$(write_pitch 'none' '<!-- filer:begin -->')"
export PLANNER_PITCH_FILE="$PITCH"
RC=0
(
  planner_pitch_open() { record_open "$@"; }
  planner_publish_session_pitch
) || RC=$?
ac_assert_eq "$RC" "1" "filer:begin must return 1 (rc=$RC)"
assert_not_opened "filer block"

clear_open
export PLANNER_PITCH_FILE="$T/missing-pitch.md"
RC=0
(
  planner_pitch_open() { record_open "$@"; }
  planner_publish_session_pitch
) || RC=$?
ac_assert_eq "$RC" "0" "a missing pitch file must return 0 (rc=$RC)"
assert_not_opened "missing pitch file"

ac_log "issue-1476 and issue-1334 still pass"
bash "$REPO_ROOT/tests/acceptance/issue-1476.sh" >/dev/null
bash "$REPO_ROOT/tests/acceptance/issue-1334.sh" >/dev/null

ac_pass
