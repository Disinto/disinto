#!/usr/bin/env bash
# =============================================================================
# tests/acceptance/issue-2123.sh
#
# Issue #2123: rung pitch texts for update-self, droplet provision.
#
# planner/pitch-or-idle.sh gains an `update-self` rung pitch: title `Self-update
# through a canary`, effect probes/can-update-self.sh, level `made`, soak 7d.
# The provision paragraph names a throwaway droplet on DigitalOcean, not the
# LXD ai-pool. Rungs other than update-self and provision stay byte-identical:
# no level line, soak 14d (#2166 later gave provision level `made` and soak 7d,
# see tests/acceptance/issue-2166.sh).
#
# planner/ladder.sh names update-self as rung 2: the ladder only names a rung
# it has a pitch for (#2124 landed the rung).
#
# Hermetic: the shared rung-pitch stubs from tests/lib/acceptance-helpers.sh.
# No forge, no agent.
#
# Acceptance: `bash tests/acceptance/issue-2123.sh` exits 0 and calls ac_pass.
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=../../tests/lib/acceptance-helpers.sh
source "$REPO_ROOT/tests/lib/acceptance-helpers.sh"

ac_require_cmd bash grep mktemp cmp
IDLE="$REPO_ROOT/planner/pitch-or-idle.sh"
LADDER="$REPO_ROOT/planner/ladder.sh"
ac_assert_file "$IDLE" "planner/pitch-or-idle.sh is missing"
ac_assert_file "$LADDER" "planner/ladder.sh is missing"

ac_log "static: bash -n, ladder.sh names the update-self rung (#2124 landed it)"
bash -n "$IDLE"
bash -n "$LADDER"
grep -qF 'update-self' "$LADDER" \
  || ac_fail "planner/ladder.sh must name the update-self rung (#2124)"
grep -qF 'Self-update through a canary' "$IDLE" \
  || ac_fail "pitch-or-idle.sh must carry the update-self title"
grep -qF 'throwaway droplet on DigitalOcean' "$IDLE" \
  || ac_fail "pitch-or-idle.sh provision paragraph must name a DigitalOcean droplet"
if grep -qF 'ai-pool' "$IDLE"; then
  ac_fail "the provision paragraph must no longer name ai-pool"
fi

# shellcheck source=../../planner/pitch-or-idle.sh
source "$IDLE"

BOX="$(mktemp -d)"
trap 'rm -rf "$BOX"' EXIT
ac_rung_fixture "$BOX"

ac_log "AC1: the ladder printing update-self opens the canary pitch"
PITCH="$(ac_rung_pitch "$BOX" update-self)"
ac_assert_eq "$(sed -n '1p' "$BOX/open-args")" "Self-update through a canary" \
  "update-self title passed to planner_pitch_open"
ac_assert_eq "$(sed -n '2p' "$BOX/open-args")" "update-self" "update-self slug is the rung id"
ac_assert_eq "$(sed -n '1p' "$BOX/open-argc")" "3" "a rung pitch takes no probe arguments"
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
PITCH="$(ac_rung_pitch "$BOX" sense)"
grep -qF 'soak: 14d' "$PITCH" || ac_fail "sense pitch must keep soak: 14d"
if grep -qF 'level:' "$PITCH"; then
  ac_fail "a rung with no level must print no level line"
fi
grep -qF 'effect: probes/can-sense.sh' "$PITCH" \
  || ac_fail "sense pitch must keep effect: probes/can-sense.sh"

ac_log "AC3: provision names DigitalOcean, not ai-pool, and aims at made with a 7d soak (#2166)"
PITCH="$(ac_rung_pitch "$BOX" provision)"
grep -qF 'DigitalOcean' "$PITCH" || ac_fail "provision pitch must name DigitalOcean"
if grep -qF 'ai-pool' "$PITCH"; then
  ac_fail "provision pitch must not name ai-pool"
fi
grep -qF 'level: made' "$PITCH" || ac_fail "provision pitch must set level: made (#2166)"
grep -qF 'soak: 7d' "$PITCH" || ac_fail "provision pitch must set soak: 7d (#2166)"

# rung_golden TITLE EFFECT PARAGRAPH — the whole pitch body a rung with no
# level and the default soak writes, byte for byte.
rung_golden() {
  {
    printf '# Sprint: %s\n' "$1"
    printf '\n%s\n' '## What this enables'
    printf '\n%s The planner pitches it and does not run it.\n' "$3"
    printf '\n%s\n' '<!-- sprint:begin -->'
    printf '%s\n' 'class: internal'
    printf 'effect: %s\n' "$2"
    printf '%s\n' 'expect: >= 1'
    printf '%s\n' 'soak: 14d'
    printf '%s\n' '<!-- sprint:end -->'
  }
}

ac_log "AC4: reach and replicate files are byte-identical to the pre-#2123 pitch"
PITCH="$(ac_rung_pitch "$BOX" reach)"
rung_golden "Reach the porter" "probes/can-reach-porter.sh" \
  "An action container logs in to the porter host, self.disinto.ai, and runs whoami and uname." \
  | cmp -s - "$PITCH" || ac_fail "reach pitch file must be byte-identical to today's"
PITCH="$(ac_rung_pitch "$BOX" replicate)"
rung_golden "Replicate" "probes/can-replicate.sh" \
  "Provision a container, install disinto at a ref, and run its acceptance tests and claim checks against the new instance." \
  | cmp -s - "$PITCH" || ac_fail "replicate pitch file must be byte-identical to today's"

ac_log "issue-1978 still passes with the new provision paragraph"
bash "$REPO_ROOT/tests/acceptance/issue-1978.sh" >/dev/null \
  || ac_fail "issue-1978.sh must still pass"

ac_pass
