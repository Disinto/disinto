#!/usr/bin/env bash
# =============================================================================
# tests/acceptance/issue-1839.sh
#
# Issue #1839: the dispatcher launches every sidecar with
# `docker run … disinto-reproduce:latest`, but no pipeline builds that tag
# on the Nomad box. `.woodpecker/publish-images.yml` builds it only for
# release tags and pushes it to ghcr.
#
# The fix adds `.woodpecker/build-reproduce.yml`, which builds
# `disinto-reproduce:latest` on the host Docker daemon when the sidecar
# inputs change. Sidecars are one-shot containers, so the next dispatch
# uses the new image and nothing is restarted.
#
# This test is read-only: it parses the pipeline and the factory update
# doc. It builds nothing and starts nothing.
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck disable=SC1091
source "$REPO_ROOT/tests/lib/acceptance-helpers.sh"

ac_require_cmd diff grep yq

PIPELINE="$REPO_ROOT/.woodpecker/build-reproduce.yml"
EDGE="$REPO_ROOT/.woodpecker/build-edge.yml"
UPDATING="$REPO_ROOT/docs/updating-factory.md"

ac_assert_file "$PIPELINE" ".woodpecker/build-reproduce.yml must exist"
ac_assert_file "$EDGE" ".woodpecker/build-edge.yml must exist"
ac_assert_file "$UPDATING" "docs/updating-factory.md must exist"

BUILD_CMD='docker build -t disinto-reproduce:latest -f docker/reproduce/Dockerfile .'

ac_log "checking the pipeline builds disinto-reproduce:latest exactly once"
build_count="$(grep -cF "$BUILD_CMD" "$PIPELINE" || true)"
ac_assert_eq "$build_count" "1" \
  "expected the reproduce docker build command once, found $build_count"

ac_log "checking when.event is push"
event="$(yq '.when[0].event' "$PIPELINE")"
ac_assert_eq "$event" "push" "when[0].event is '$event', expected push"

ac_log "checking path filters include the sidecar inputs"
paths="$(yq '.when[0].paths.include[]' "$PIPELINE")"
printf '%s\n' "$paths" | grep -qxF 'docker/reproduce/**' \
  || ac_fail "paths.include does not list docker/reproduce/**"
printf '%s\n' "$paths" | grep -qxF 'lib/**' \
  || ac_fail "paths.include does not list lib/**"

ac_log "checking the clone block matches build-edge.yml"
clone_diff="$(diff <(yq '.clone' "$EDGE") <(yq '.clone' "$PIPELINE") || true)"
if [ -n "$clone_diff" ]; then
  ac_fail "clone block differs from .woodpecker/build-edge.yml"
fi

ac_log "checking updating-factory.md names the pipeline once"
doc_count="$(grep -c 'build-reproduce.yml' "$UPDATING" || true)"
ac_assert_eq "$doc_count" "1" \
  "expected build-reproduce.yml once in docs/updating-factory.md, found $doc_count"

ac_pass
