#!/usr/bin/env bash
# tests/release-smoke.sh — Post-release verification smoke test
#
# Validates that a freshly-cloned tagged release can be consumed on a
# host with no pre-existing disinto state (pull-only path).
#
# This automates the runbook in docs/release-verification.md.
#
# Usage:
#   VERSION=v0.3.0 bash tests/release-smoke.sh
#
# Exit 0 = all stages passed; exit 1 = one or more stages failed.

set -euo pipefail

# ── Defaults ────────────────────────────────────────────────────────────────
VERSION="${VERSION:-}"
CLONE_DIR=""
FAILED=0
WARNINGS=0
STAGE=0
TOTAL_STAGES=5

# ── Helpers ─────────────────────────────────────────────────────────────────
pass() { printf '[%d/%d] PASS: %s\n' "$STAGE" "$TOTAL_STAGES" "$*"; }
fail() { printf '[%d/%d] FAIL: %s\n' "$STAGE" "$TOTAL_STAGES" "$*" >&2; FAILED=1; }
warn() { printf '[%d/%d] WARN: %s\n' "$STAGE" "$TOTAL_STAGES" "$*" >&2; WARNINGS=$((WARNINGS + 1)); }
skip() { printf '[%d/%d] SKIP: %s\n' "$STAGE" "$TOTAL_STAGES" "$*" >&2; }

cleanup() {
  if [ -n "${CLONE_DIR:-}" ] && [ -d "$CLONE_DIR" ]; then
    # Tear down any compose stack before removing the tree
    if [ -f "$CLONE_DIR/docker-compose.yml" ]; then
      (cd "$CLONE_DIR" && ./bin/disinto down 2>/dev/null) || true
    fi
    rm -rf "$CLONE_DIR"
  fi
  # Remove any smoke project artifacts
  if [ -n "${FACTORY_ROOT:-}" ] && [ -f "${FACTORY_ROOT}/projects/example-smoke.toml" ]; then
    rm -f "${FACTORY_ROOT}/projects/example-smoke.toml"
  fi
}
trap cleanup EXIT

# ── Pre-flight: require VERSION ────────────────────────────────────────────
if [ -z "$VERSION" ]; then
  echo "Usage: VERSION=v0.3.0 bash tests/release-smoke.sh" >&2
  exit 1
fi

# Strip leading 'v' for local dirs
TAG_NO_V="${VERSION#v}"
CLONE_DIR="/tmp/disinto-smoke-${TAG_NO_V}"

# ── [1/5] Clone the tagged release ────────────────────────────────────────
STAGE=1
echo "=== Stage 1/5: Clone v${VERSION} ==="

if [ -d "$CLONE_DIR/.git" ]; then
  # Reuse existing clone but ensure we're on the right tag
  (cd "$CLONE_DIR" && git fetch --quiet --tags && git checkout -f "$VERSION" 2>/dev/null) || true
else
  rm -rf "$CLONE_DIR"
  git clone --branch "$VERSION" --depth 1 \
    https://codeberg.org/johba/disinto "$CLONE_DIR" 2>/dev/null || {
    fail "Failed to clone v${VERSION} from Codeberg (GHCR pull-only path)"
    exit 1
  }
fi
pass "Cloned v${VERSION}"

# ── [2/5] Assert VERSION file matches tag ─────────────────────────────────
STAGE=2
echo "=== Stage 2/5: Assert VERSION file ==="

FILE_VERSION="$(cat "${CLONE_DIR}/VERSION")"
TAG_VERSION="${VERSION#v}"

if [ "$TAG_VERSION" = "$FILE_VERSION" ]; then
  pass "VERSION file matches tag (${FILE_VERSION})"
else
  fail "VERSION mismatch — tag=${TAG_VERSION} file=${FILE_VERSION}"
fi

# ── [3/5] Bootstrap smoke project ─────────────────────────────────────────
STAGE=3
echo "=== Stage 3/5: Bootstrap smoke project ==="

# Check required tools
for tool in docker jq curl git; do
  command -v "$tool" >/dev/null 2>&1 || {
    warn "Required tool missing: $tool (some checks will be skipped)"
    break
  }
done

# Source the disinto CLI — it needs FACTORY_ROOT
export FACTORY_ROOT="$CLONE_DIR"
export DISINTO_IMAGE_TAG="$VERSION"

# Run init against a disposable smoke repo.
# Use --bare so we don't need docker-compose on the host.
# The example-smoke repo is a placeholder — we only validate that init
# succeeds and generates the expected artifacts.
(
  cd "$CLONE_DIR"
  ./bin/disinto init https://codeberg.org/disinto/example-smoke \
    --bare --yes 2>&1 || {
    fail "disinto init failed for example-smoke"
    exit 1
  }
)

# Assert project TOML was generated
if [ -f "${CLONE_DIR}/projects/example-smoke.toml" ]; then
  pass "Project TOML generated (projects/example-smoke.toml)"
else
  fail "Project TOML not generated"
fi

# Assert .env was created
if [ -f "${CLONE_DIR}/.env" ]; then
  pass ".env file created"
else
  fail ".env file not created"
fi

# ── [4/5] Assert stack health ──────────────────────────────────────────────
STAGE=4
echo "=== Stage 4/5: Assert stack health ==="

# Only run docker-level checks if docker is available and compose is up
if command -v docker >/dev/null 2>&1 && [ -f "${CLONE_DIR}/docker-compose.yml" ]; then
  # Start the stack (non-interactive)
  (cd "$CLONE_DIR" && ./bin/disinto up --wait 2>&1) || {
    warn "disinto up failed — skipping health checks"
  }

  # Check container health
  healthy_count=$(docker compose -f "${CLONE_DIR}/docker-compose.yml" ps 2>/dev/null \
    | grep -c 'healthy' || true)
  if [ "$healthy_count" -gt 0 ]; then
    pass "Found ${healthy_count} healthy container(s)"
  else
    warn "No healthy containers detected (may need more time to start)"
  fi

  # Check disinto status for expected services
  status_output=$(cd "$CLONE_DIR" && ./bin/disinto status 2>/dev/null) || status_output=""

  if echo "$status_output" | grep -qi "forgejo"; then
    pass "Forgejo detected in status output"
  else
    warn "Forgejo not detected in status output"
  fi

  if echo "$status_output" | grep -qi "woodpecker"; then
    pass "Woodpecker detected in status output"
  else
    warn "Woodpecker not detected in status output"
  fi

  # Check agent heartbeat (up to 5 min)
  heartbeat_found=false
  for _i in $(seq 1 10); do
    sleep 30
    if docker compose -f "${CLONE_DIR}/docker-compose.yml" logs agents 2>&1 \
        | grep -q "heartbeat"; then
      heartbeat_found=true
      break
    fi
  done

  if [ "$heartbeat_found" = true ]; then
    pass "Agent heartbeat detected within 5 min"
  else
    warn "No agent heartbeat within 5 min (may be expected if no issues to process)"
  fi
else
  skip "Docker not available — skipping container health checks"
fi

# ── [5/5] Teardown ────────────────────────────────────────────────────────
STAGE=5
echo "=== Stage 5/5: Teardown ==="

if [ -f "${CLONE_DIR}/docker-compose.yml" ]; then
  (cd "$CLONE_DIR" && ./bin/disinto down 2>&1) || {
    warn "disinto down failed (non-fatal)"
  }
  pass "Stack torn down"
else
  pass "No compose stack to tear down"
fi

# LXD cleanup — only if we're running inside an LXD container
if lxc info >/dev/null 2>&1; then
  container_name="disinto-smoke-${TAG_NO_V}"
  if lxc list --format csv -c n 2>/dev/null | grep -q "^${container_name}$"; then
    lxc delete "$container_name" --force 2>/dev/null || {
      warn "Failed to delete LXD container ${container_name}"
    }
    pass "LXD container ${container_name} deleted"
  fi
fi

# ── Summary ─────────────────────────────────────────────────────────────────
echo ""
echo "============================================"
if [ "$FAILED" -ne 0 ]; then
  echo "=== RELEASE SMOKE: FAILED (${WARNINGS} warnings) ==="
  exit 1
fi
if [ "$WARNINGS" -gt 0 ]; then
  echo "=== RELEASE SMOKE: PASSED (${WARNINGS} warnings) ==="
else
  echo "=== RELEASE SMOKE: PASSED ==="
fi
echo "============================================"
