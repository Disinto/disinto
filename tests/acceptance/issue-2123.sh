#!/usr/bin/env bash
# =============================================================================
# tests/acceptance/issue-2123.sh
#
# Issue #2123: rung pitch texts for update-self, droplet provision.
#
# planner/pitch-or-idle.sh gains an `update-self` rung pitch: title `Self-update
# through a canary`, effect probes/can-update-self.sh, level `made`, soak 7d.
# The provision paragraph names a throwaway droplet on DigitalOcean, not the
# LXD ai-pool. Every other rung's pitch file stays byte-identical: no level
# line, soak 14d.
#
# planner/ladder.sh is untouched: #2124 adds the rung to the ladder, so the
# ladder never names a rung without a pitch.
#
# Hermetic: stubs for the ladder and the opener. No forge, no agent.
#
# Acceptance: `bash tests/acceptance/issue-2123.sh` exits 0 and calls ac_pass.
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=../../tests/lib/acceptance-helpers.sh
source "$REPO_ROOT/tests/lib/acceptance-helpers.sh"

ac_require_cmd bash grep mktemp
IDLE="$REPO_ROOT/planner/pitch-or-idle.sh"
LADDER="$REPO_ROOT/planner/ladder.sh"
ac_assert_file "$IDLE" "planner/pitch-or-idle.sh is missing"
ac_assert_file "$LADDER" "planner/ladder.sh is missing"

ac_log "static: bash -n, ladder.sh still names no update-self rung"
bash -n "$IDLE"
bash -n "$LADDER"
if grep -qF 'update-self' "$LADDER"; then
  ac_fail "planner/ladder.sh must not name update-self yet (#2124 adds it)"
fi
grep -qF 'Self-update through a canary' "$IDLE" \
  || ac_fail "pitch-or-idle.sh must carry the update-self title"
grep -qF 'throwaway droplet on DigitalOcean' "$IDLE" \
  || ac_fail "pitch-or-idle.sh provision paragraph must name a DigitalOcean droplet"
if grep -qF 'ai-pool' "$IDLE"; then
  ac_fail "the provision paragraph must no longer name ai-pool"
fi

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

clear_open() {
  rm -f "$T/open-argc" "$T/open-args"
}

# rung_pitch RUNG — open RUNG's pitch through planner_pitch_or_idle with the
# ladder and the opener stubbed. Prints the pitch file path.
rung_pitch() {
  local rung="$1" out
  clear_open
  out="$(
    RUNG_NAME="$rung"
    planner_pitch_pending() { return 0; }
    ladder_lowest_gap() { printf '%s\n' "$RUNG_NAME"; }
    planner_pitch_open() { record_open "$@"; }
    planner_pitch_or_idle
  )"
  ac_assert_eq "$out" "opened 9" "the rung pitch must print opened <n> (got '$out')"
  sed -n '3p' "$T/open-args"
}

ac_log "AC1: the ladder printing update-self opens the canary pitch"
PITCH="$(rung_pitch update-self)"
ac_assert_eq "$(sed -n '1p' "$T/open-args")" "Self-update through a canary" \
  "update-self title passed to planner_pitch_open"
ac_assert_eq "$(sed -n '2p' "$T/open-args")" "update-self" "update-self slug is the rung id"
ac_assert_eq "$(sed -n '1p' "$T/open-argc")" "3" "a rung pitch takes no probe arguments"
grep -qF 'effect: probes/can-update-self.sh' "$PITCH" \
  || ac_fail "update-self pitch must name probes/can-update-self.sh"
grep -qF 'level: made' "$PITCH" || ac_fail "update-self pitch must set level: made"
grep -qF 'soak: 7d' "$PITCH" || ac_fail "update-self pitch must set soak: 7d"
grep -qF 'A merged change runs first on one agent, the canary,' "$PITCH" \
  || ac_fail "update-self paragraph must describe the canary and the rollback"
grep -qF 'class: internal' "$PITCH" || ac_fail "update-self pitch must set class: internal"
grep -qF 'expect: >= 1' "$PITCH" || ac_fail "update-self pitch must set expect: >= 1"
if grep -qF 'filer:begin' "$PITCH"; then
  ac_fail "update-self pitch must not contain filer:begin"
fi

ac_log "AC2: sense has no level line and keeps soak: 14d"
PITCH="$(rung_pitch sense)"
grep -qF 'soak: 14d' "$PITCH" || ac_fail "sense pitch must keep soak: 14d"
if grep -qF 'level:' "$PITCH"; then
  ac_fail "a rung with no level must print no level line"
fi
grep -qF 'effect: probes/can-sense.sh' "$PITCH" \
  || ac_fail "sense pitch must keep effect: probes/can-sense.sh"

ac_log "AC3: provision names DigitalOcean and not ai-pool"
PITCH="$(rung_pitch provision)"
grep -qF 'DigitalOcean' "$PITCH" || ac_fail "provision pitch must name DigitalOcean"
if grep -qF 'ai-pool' "$PITCH"; then
  ac_fail "provision pitch must not name ai-pool"
fi
if grep -qF 'level:' "$PITCH"; then
  ac_fail "provision pitch must have no level line"
fi

ac_log "AC4: reach and replicate files are byte-identical to the pre-#2123 pitch"
golden() {
  local title="$1" effect="$2" paragraph="$3"
  cat <<EOF
# Sprint: ${title}

## What this enables

${paragraph} The planner pitches it and does not run it.

<!-- sprint:begin -->
class: internal
effect: ${effect}
expect: >= 1
soak: 14d
<!-- sprint:end -->
EOF
}
PITCH="$(rung_pitch reach)"
golden "Reach the porter" "probes/can-reach-porter.sh" \
  "An action container logs in to the porter host, self.disinto.ai, and runs whoami and uname." \
  | cmp -s - "$PITCH" || ac_fail "reach pitch file must be byte-identical to today's"
PITCH="$(rung_pitch replicate)"
golden "Replicate" "probes/can-replicate.sh" \
  "Provision a container, install disinto at a ref, and run its acceptance tests and claim checks against the new instance." \
  | cmp -s - "$PITCH" || ac_fail "replicate pitch file must be byte-identical to today's"

ac_log "issue-1978 still passes with the new provision paragraph"
bash "$REPO_ROOT/tests/acceptance/issue-1978.sh" >/dev/null || ac_fail "issue-1978.sh must still pass"

ac_pass
