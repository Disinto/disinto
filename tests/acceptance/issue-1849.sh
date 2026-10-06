#!/usr/bin/env bash
# =============================================================================
# tests/acceptance/issue-1849.sh
#
# Issue #1849: the dispatcher's docker runner defaults to an image the box
# has. An action with no image field used to always run
# disinto/agents:latest. The Nomad edge builds disinto/agents:local, so the
# docker backend now honors VAULT_RUNNER_IMAGE, then falls back to
# disinto/agents:latest (compose). The edge job sets that variable.
#
# Acceptance (no live box, no docker daemon):
#   1. dispatcher.sh pins the nested default exactly once.
#   2. edge.hcl sets VAULT_RUNNER_IMAGE = "disinto/agents:local" exactly once.
#   3. Extracted _launch_runner_docker, docker stub printing its arguments:
#      empty IMAGE + VAULT_RUNNER_IMAGE=disinto/agents:local → local;
#      IMAGE x/y:z → x/y:z; VAULT_RUNNER_IMAGE unset → disinto/agents:latest.
#
# Run via: tools/run-acceptance.sh 1849
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../lib/acceptance-helpers.sh
source "$REPO_ROOT/tests/lib/acceptance-helpers.sh"

ac_require_cmd bash grep awk

DISPATCHER="$REPO_ROOT/docker/edge/dispatcher.sh"
EDGE_HCL="$REPO_ROOT/nomad/jobs/edge.hcl"
ac_assert_file "$DISPATCHER" "docker/edge/dispatcher.sh must exist"
ac_assert_file "$EDGE_HCL" "nomad/jobs/edge.hcl must exist"

ac_log "AC 1: docker runner default nests VAULT_RUNNER_IMAGE"
pin='local image_name="${image:-${VAULT_RUNNER_IMAGE:-disinto/agents:latest}}"'
pin_count="$(grep -cF "$pin" "$DISPATCHER" || true)"
ac_assert_eq "$pin_count" "1" \
  "dispatcher.sh must pin the nested image default exactly once (got: ${pin_count})"

ac_log "AC 2: edge.hcl sets VAULT_RUNNER_IMAGE to the box image"
edge_count="$(grep -cE '^ *VAULT_RUNNER_IMAGE *= *"disinto/agents:local"' "$EDGE_HCL" || true)"
ac_assert_eq "$edge_count" "1" \
  "edge.hcl must set VAULT_RUNNER_IMAGE = disinto/agents:local exactly once (got: ${edge_count})"

FN="$(ac_extract_fn _launch_runner_docker "$DISPATCHER")"
[ -n "$FN" ] || ac_fail "could not extract _launch_runner_docker from docker/edge/dispatcher.sh"

work="$(mktemp -d "${TMPDIR:-/tmp}/issue-1849.XXXXXX")"
trap 'rm -rf "$work"' EXIT
mkdir -p "${work}/ops" "${work}/artifacts"

# Run the extracted launcher in a subshell so its RETURN trap stays local.
# docker prints its arguments; write_result echoes the captured log.
run_launcher() {
  local image="$1"
  local vault_mode="$2"
  local vault_image="${3:-}"
  # shellcheck disable=SC2016  # FN is the extracted function source, not a command
  IMAGE_ARG="$image" VAULT_MODE="$vault_mode" VAULT_IMAGE="$vault_image" \
    FN_SRC="$FN" WORK="$work" bash -c '
      set -euo pipefail
      eval "$FN_SRC"
      log() { :; }
      write_result() { printf "%s\n" "$3"; }
      docker() { printf "%s\n" "$*"; }
      export FORGE_URL="http://forge.example"
      export FORGE_TOKEN="tok"
      export OPS_REPO_ROOT="${WORK}/ops"
      export VAULT_ARTIFACTS_DIR="${WORK}/artifacts"
      if [ "$VAULT_MODE" = "unset" ]; then
        unset VAULT_RUNNER_IMAGE
      else
        export VAULT_RUNNER_IMAGE="$VAULT_IMAGE"
      fi
      _launch_runner_docker "act-1849" "" "" "$IMAGE_ARG" ""
    '
}

ac_log "AC 3a: empty image uses VAULT_RUNNER_IMAGE"
out="$(run_launcher "" set "disinto/agents:local")"
grep -qF 'disinto/agents:local' <<<"$out" \
  || ac_fail "empty IMAGE with VAULT_RUNNER_IMAGE=disinto/agents:local did not pass that image (got: ${out})"
grep -qF 'disinto/agents:latest' <<<"$out" \
  && ac_fail "empty IMAGE should not fall through to disinto/agents:latest when VAULT_RUNNER_IMAGE is set (got: ${out})"
ac_log "AC 3a OK"

ac_log "AC 3b: explicit image wins"
out="$(run_launcher "x/y:z" set "disinto/agents:local")"
grep -qF 'x/y:z' <<<"$out" \
  || ac_fail "IMAGE x/y:z was not passed to docker (got: ${out})"
ac_log "AC 3b OK"

ac_log "AC 3c: unset VAULT_RUNNER_IMAGE keeps the compose default"
out="$(run_launcher "" unset)"
grep -qF 'disinto/agents:latest' <<<"$out" \
  || ac_fail "unset VAULT_RUNNER_IMAGE did not default to disinto/agents:latest (got: ${out})"
ac_log "AC 3c OK"

bash -n "$DISPATCHER" || ac_fail "bash -n docker/edge/dispatcher.sh failed"

ac_pass
