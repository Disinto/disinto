#!/usr/bin/env bash
# =============================================================================
# tests/acceptance/issue-1305.sh
#
# Issue #1305: thin research runner image — docker/research (ssh, rsync, jq;
# no Meep, no Claude, no Playwright), tagged disinto/research:local and added
# to the release image list so v0.6.0 publishes it.
#
# Verifies:
#   1. docker/research/Dockerfile installs exactly the thin transport toolset
#      (bash, openssh-client, rsync, jq, ca-certificates) and installs no
#      science stack (no meep/selenocyte/claude/playwright package or binary).
#   2. docker/research/entrypoint.sh is the tiny exec wrapper: executable,
#      bash -n clean, shebang + set -euo pipefail, execs "$@".
#   3. The CUT_RELEASE_IMAGES default in tools/cut-release.sh includes
#      `research`.
#   4. .woodpecker/publish-images.yml has a research step that builds
#      docker/research/Dockerfile into ghcr.io/disinto/research.
#   5. When docker is available (the live box), builds disinto/research:local
#      and verifies the image has ssh/rsync/jq and no claude/meep binaries.
#
# Read-only: steps 1-4 are pure file inspection; step 5 only builds and runs
# ephemeral containers (no repo, forge, or Nomad state is mutated).
#
# Run via: tools/run-acceptance.sh 1305
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck disable=SC1091
source "$REPO_ROOT/tests/lib/acceptance-helpers.sh"

ac_require_cmd grep sed

DOCKERFILE="$REPO_ROOT/docker/research/Dockerfile"
ENTRYPOINT="$REPO_ROOT/docker/research/entrypoint.sh"
ac_assert_file "$DOCKERFILE" "docker/research/Dockerfile is missing"
ac_assert_file "$ENTRYPOINT" "docker/research/entrypoint.sh is missing"

# ── 1. The Dockerfile installs the thin toolset, nothing else ────────────────
ac_log "checking the Dockerfile installs the thin transport toolset"
# The apt-get install line (with its continuation) is the only place packages
# can enter the image.
INSTALL_LINE="$(grep -A1 'apt-get install' "$DOCKERFILE" | tr '\n' ' ' | tr -d '\\')"
[ -n "$INSTALL_LINE" ] || ac_fail "docker/research/Dockerfile has no apt-get install line"
for pkg in bash openssh-client rsync jq ca-certificates; do
  printf '%s' "$INSTALL_LINE" | grep -qw "$pkg" \
    || ac_fail "docker/research/Dockerfile does not install $pkg"
done
for bad in meep selenocyte claude playwright; do
  if printf '%s' "$INSTALL_LINE" | grep -qi "$bad"; then
    ac_fail "docker/research/Dockerfile installs a '$bad' package (the science stack stays on the worker)"
  fi
done
ac_log "Dockerfile toolset OK (bash, openssh-client, rsync, jq, ca-certificates; no meep/claude/playwright)"

# ── 2. The entrypoint is a tiny exec wrapper ─────────────────────────────────
ac_log "checking docker/research/entrypoint.sh"
[ -x "$ENTRYPOINT" ] || ac_fail "docker/research/entrypoint.sh is not executable"
head -n 1 "$ENTRYPOINT" | grep -q '^#!/usr/bin/env bash$' \
  || ac_fail "entrypoint does not start with #!/usr/bin/env bash"
grep -q 'set -euo pipefail' "$ENTRYPOINT" \
  || ac_fail "entrypoint is missing set -euo pipefail"
grep -q 'exec "\$@"' "$ENTRYPOINT" \
  || ac_fail "entrypoint does not exec its arguments (the real dispatch lands in run-experiment.sh)"
bash -n "$ENTRYPOINT" || ac_fail "entrypoint does not parse (bash -n)"
ac_log "entrypoint OK (exec wrapper, parses clean)"

# ── 3. The release image list includes research ─────────────────────────────
ac_log "checking the CUT_RELEASE_IMAGES default includes research"
DEFAULT_IMAGES="$(grep -E '^CUT_RELEASE_IMAGES=' "$REPO_ROOT/tools/cut-release.sh" \
  | sed -E 's/.*:-([^}]+)\}.*/\1/')"
[ -n "$DEFAULT_IMAGES" ] || ac_fail "could not extract the CUT_RELEASE_IMAGES default from tools/cut-release.sh"
printf '%s' "$DEFAULT_IMAGES" | grep -qw research \
  || ac_fail "CUT_RELEASE_IMAGES default '$DEFAULT_IMAGES' does not include research"
ac_log "CUT_RELEASE_IMAGES default OK: $DEFAULT_IMAGES"

# ── 4. The publish pipeline builds the research image ───────────────────────
ac_log "checking .woodpecker/publish-images.yml publishes the research image"
PUBLISH_YML="$REPO_ROOT/.woodpecker/publish-images.yml"
ac_assert_file "$PUBLISH_YML" ".woodpecker/publish-images.yml is missing"
grep -q 'repo: ghcr.io/disinto/research' "$PUBLISH_YML" \
  || ac_fail "publish-images.yml has no step for ghcr.io/disinto/research"
grep -q 'dockerfile: docker/research/Dockerfile' "$PUBLISH_YML" \
  || ac_fail "publish-images.yml does not build docker/research/Dockerfile"
ac_log "publish-images.yml OK (ghcr.io/disinto/research from docker/research/Dockerfile)"

# ── 5. When docker is available: build and inspect the image ────────────────
if command -v docker >/dev/null 2>&1; then
  ac_log "docker available — building disinto/research:local"
  docker build -q -t disinto/research:local \
    -f "$REPO_ROOT/docker/research/Dockerfile" "$REPO_ROOT" \
    >/dev/null || ac_fail "docker build of docker/research failed"
  for b in ssh rsync jq; do
    docker run --rm --entrypoint "$b" disinto/research:local --version >/dev/null 2>&1 \
      || ac_fail "disinto/research:local is missing the '$b' binary"
  done
  if docker run --rm --entrypoint bash disinto/research:local \
    -c 'command -v claude >/dev/null || command -v meep >/dev/null'; then
    ac_fail "disinto/research:local contains a claude or meep binary"
  fi
  ac_log "image OK (ssh/rsync/jq present; no claude or meep)"
else
  ac_log "docker not available — skipping the image build (steps 1-4 verified statically)"
fi

ac_pass
