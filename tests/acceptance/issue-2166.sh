#!/usr/bin/env bash
# =============================================================================
# tests/acceptance/issue-2166.sh
#
# Issue #2166: the provision pitch aims at level made with a 7-day soak and
# names its design note.
#
# planner/pitch-or-idle.sh: the `provision)` case of `_planner_rung_pitch_write`
# sets level `made` and soak 7d, like `update-self)` (#2123). The paragraph
# keeps "throwaway droplet on DigitalOcean" — two tests grep for it — and names
# the design note docs/design/notes/provision.md. The sense, reach, deploy and
# replicate pitch files stay byte-identical: no level line, soak 14d.
#
# Hermetic: the shared rung-pitch stubs from tests/lib/acceptance-helpers.sh.
# No forge, no agent.
#
# Acceptance: `bash tests/acceptance/issue-2166.sh` exits 0 and calls ac_pass.
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=../../tests/lib/acceptance-helpers.sh
source "$REPO_ROOT/tests/lib/acceptance-helpers.sh"

ac_require_cmd bash grep mktemp cmp
IDLE="$REPO_ROOT/planner/pitch-or-idle.sh"
DOC="$REPO_ROOT/planner/AGENTS.md"
ac_assert_file "$IDLE" "planner/pitch-or-idle.sh is missing"
ac_assert_file "$DOC" "planner/AGENTS.md is missing"

ac_log "static: bash -n; the function comment and planner/AGENTS.md name both rungs"
bash -n "$IDLE"
# shellcheck disable=SC2016  # backticks are markdown in the required sentence
grep -qF 'update-self and provision aim at level `made`' "$IDLE" \
  || ac_fail "the pitch comment must name update-self and provision (#2123, #2166)"
grep -qF '(#2123, #2166)' "$IDLE" \
  || ac_fail "the pitch comment must cite #2123 and #2166"
grep -qF '`provision` aim at level `made` with a 7-day soak, #2123, #2166' "$DOC" \
  || ac_fail "planner/AGENTS.md must name provision alongside update-self"

# shellcheck source=../../planner/pitch-or-idle.sh
source "$IDLE"

BOX="$(mktemp -d)"
trap 'rm -rf "$BOX"' EXIT
ac_rung_fixture "$BOX"

ac_log "AC1: the provision pitch sets level made, soak 7d, and the probe and class lines"
PITCH="$(ac_rung_pitch "$BOX" provision)"
grep -qF 'level: made' "$PITCH" || ac_fail "provision pitch must set level: made"
grep -qF 'soak: 7d' "$PITCH" || ac_fail "provision pitch must set soak: 7d"
grep -qF 'effect: probes/can-provision.sh' "$PITCH" \
  || ac_fail "provision pitch must name probes/can-provision.sh"
grep -qF 'expect: >= 1' "$PITCH" || ac_fail "provision pitch must set expect: >= 1"
grep -qF 'class: internal' "$PITCH" || ac_fail "provision pitch must set class: internal"
if grep -qF 'filer:begin' "$PITCH"; then
  ac_fail "provision pitch must not contain filer:begin"
fi

ac_log "AC2: the paragraph keeps the droplet phrase, names the design note, ends with the pitch sentence"
grep -qF 'throwaway droplet on DigitalOcean' "$PITCH" \
  || ac_fail "provision paragraph must keep 'throwaway droplet on DigitalOcean'"
grep -qF 'docs/design/notes/provision.md' "$PITCH" \
  || ac_fail "provision paragraph must name docs/design/notes/provision.md"
grep -qF 'The planner pitches it and does not run it.' "$PITCH" \
  || ac_fail "provision paragraph must end with the pitch sentence"
if grep -qF 'ai-pool' "$PITCH"; then
  ac_fail "provision pitch must not name ai-pool"
fi

# rung_pitch_golden TITLE EFFECT PARAGRAPH — the whole pitch body a no-level
# rung with the default 14d soak writes, byte for byte.
rung_pitch_golden() {
  cat <<EOF
# Sprint: $1

## What this enables

$3 The planner pitches it and does not run it.

<!-- sprint:begin -->
class: internal
effect: $2
expect: >= 1
soak: 14d
<!-- sprint:end -->
EOF
}

ac_log "AC3: sense, reach, deploy and replicate pitch files are byte-identical to before"
PITCH="$(ac_rung_pitch "$BOX" sense)"
rung_pitch_golden "Sense" "probes/can-sense.sh" \
  "An action container on the factory host runs a read-only inventory (CPU, memory, disk, docker, LXD) and stores it as an artifact." \
  | cmp -s - "$PITCH" || ac_fail "sense pitch file must be byte-identical to before"
PITCH="$(ac_rung_pitch "$BOX" reach)"
rung_pitch_golden "Reach the porter" "probes/can-reach-porter.sh" \
  "An action container logs in to the porter host, self.disinto.ai, and runs whoami and uname." \
  | cmp -s - "$PITCH" || ac_fail "reach pitch file must be byte-identical to before"
PITCH="$(ac_rung_pitch "$BOX" deploy)"
rung_pitch_golden "Deploy the porter" "probes/can-deploy-porter.sh" \
  "An action runs porter-install.sh at a ref on self.disinto.ai and verifies it with the status verb." \
  | cmp -s - "$PITCH" || ac_fail "deploy pitch file must be byte-identical to before"
PITCH="$(ac_rung_pitch "$BOX" replicate)"
rung_pitch_golden "Replicate" "probes/can-replicate.sh" \
  "Provision a container, install disinto at a ref, and run its acceptance tests and claim checks against the new instance." \
  | cmp -s - "$PITCH" || ac_fail "replicate pitch file must be byte-identical to before"

ac_log "issue-2123.sh still passes with AC3 requiring level: made and soak: 7d"
bash "$REPO_ROOT/tests/acceptance/issue-2123.sh" >/dev/null \
  || ac_fail "issue-2123.sh must still pass"

ac_log "issue-1978.sh still passes with the provision paragraph naming the design note"
bash "$REPO_ROOT/tests/acceptance/issue-1978.sh" >/dev/null \
  || ac_fail "issue-1978.sh must still pass"

ac_pass
