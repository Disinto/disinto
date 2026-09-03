#!/usr/bin/env bash
# tests/release-smoke-nomad.sh — Nomad+Vault backend release verification (#1227)
#
# release-smoke.sh only exercises the docker-compose backend. This script
# exercises the nomad backend so a tagged release's init path
# (cluster-up, vault policies/auth/import, forgejo deploy) is actually
# tested, not just compiled into the tree.
#
# Stages:
#   A (always, read-only) — plan validation:
#       Clone the tag (or use SRC_DIR in place, e.g. in CI), then run
#       `./bin/disinto init --backend=nomad --with forgejo --import-env <tmp>
#       --dry-run` and assert:
#         - exit 0
#         - the five plan sections are present (cluster-up, policies,
#           auth, import, deploy)
#         - every repo path the plan references (files under the clone
#           with .sh/.hcl extension) exists in the clone
#       No host state is touched: the plan is computed, never executed.
#   B (only when SCRATCH_LXC_NAME is set) — fresh-LXC init:
#       lxc launch, clone the tag, `disinto init --backend=nomad
#       --with forgejo`, assert `nomad job status forgejo` is
#       running/healthy and Forgejo answers on 127.0.0.1:3000.
#       Teardown: `lxc delete <name> --force`.
#       Without SCRATCH_LXC_NAME the stage SKIPs (exit 0) — CI has no
#       LXD, so CI coverage is Stage A.
#
# Usage:
#   VERSION=v0.3.0 bash tests/release-smoke-nomad.sh
#   SRC_DIR="$PWD" bash tests/release-smoke-nomad.sh        # CI: test the checkout
#   SCRATCH_LXC_NAME=disinto-smoke VERSION=v0.3.0 bash tests/release-smoke-nomad.sh
#
# Exit 0 = all stages passed or SKIPped; exit 1 = one or more failed.

set -euo pipefail

# ── Defaults ────────────────────────────────────────────────────────────────
VERSION="${VERSION:-main}"
REPO_URL="${REPO_URL:-https://codeberg.org/johba/disinto}"
SRC_DIR="${SRC_DIR:-}"
SCRATCH_LXC_NAME="${SCRATCH_LXC_NAME:-}"
SCRATCH_LXC_IMAGE="${SCRATCH_LXC_IMAGE:-images:ubuntu/24.04}"
CLONE_DIR=""
SCRATCH_ENV_FILE=""
PLAN_FILE=""
LXC_CREATED=false
FAILED=0
SKIPPED=0
STAGE=0
TOTAL_STAGES=5

# ── Helpers ─────────────────────────────────────────────────────────────────
pass() { printf '[%d/%d] PASS: %s\n' "$STAGE" "$TOTAL_STAGES" "$*"; }
fail() { printf '[%d/%d] FAIL: %s\n' "$STAGE" "$TOTAL_STAGES" "$*" >&2; FAILED=1; }
warn() { printf '[%d/%d] WARN: %s\n' "$STAGE" "$TOTAL_STAGES" "$*" >&2; }
skip() { printf '[%d/%d] SKIP: %s\n' "$STAGE" "$TOTAL_STAGES" "$*" >&2; SKIPPED=$((SKIPPED + 1)); }

cleanup() {
  [ -n "$SCRATCH_ENV_FILE" ] && [ -f "$SCRATCH_ENV_FILE" ] && rm -f "$SCRATCH_ENV_FILE"
  [ -n "$PLAN_FILE" ] && [ -f "$PLAN_FILE" ] && rm -f "$PLAN_FILE"
  # Only remove the LXC container WE created.
  if [ "$LXC_CREATED" = true ] && [ -n "$SCRATCH_LXC_NAME" ]; then
    lxc delete "$SCRATCH_LXC_NAME" --force 2>/dev/null || \
      warn "Failed to delete LXD container ${SCRATCH_LXC_NAME}"
  fi
  # Only remove the clone WE created; SRC_DIR is the caller's tree.
  if [ -n "$CLONE_DIR" ] && [ -d "$CLONE_DIR" ]; then
    rm -rf "$CLONE_DIR"
  fi
}
trap cleanup EXIT

# ── [1/5] Prepare the tree under test ──────────────────────────────────────
STAGE=1
echo "=== Stage 1/5: Prepare tree for $VERSION ==="

SAFE_REF="${VERSION//[^A-Za-z0-9._-]/-}"
if [ -n "$SRC_DIR" ]; then
  # CI path: validate the checkout in place. Stage A is read-only with
  # respect to the tree (dry-run only), so no clone is needed.
  [ -f "${SRC_DIR}/bin/disinto" ] || { fail "SRC_DIR=$SRC_DIR has no bin/disinto"; exit 1; }
  TREE_DIR="$SRC_DIR"
  pass "Using in-place tree (SRC_DIR=$SRC_DIR)"
else
  CLONE_DIR="/tmp/disinto-smoke-nomad-${SAFE_REF}"
  rm -rf "$CLONE_DIR"
  git clone --branch "$VERSION" --depth 1 "$REPO_URL" "$CLONE_DIR" 2>/dev/null || {
    fail "Failed to clone ${VERSION} from ${REPO_URL}"
    exit 1
  }
  TREE_DIR="$CLONE_DIR"
  pass "Cloned ${VERSION} to ${CLONE_DIR}"
fi

# ── [2/5] Run the init dry-run plan ────────────────────────────────────────
STAGE=2
echo "=== Stage 2/5: disinto init --backend=nomad --dry-run ==="

# A throwaway env file so the --import-env plan section is exercised.
SCRATCH_ENV_FILE="$(mktemp)"
printf 'SMOKE=placeholder\n' >"$SCRATCH_ENV_FILE"

PLAN_FILE="$(mktemp)"
PLAN_RC=0
(
  cd "$TREE_DIR"
  # FACTORY_ROOT is exported for parity with release-smoke.sh; bin/disinto
  # recomputes it from its own location either way.
  FACTORY_ROOT="$TREE_DIR" ./bin/disinto init placeholder/repo \
    --backend=nomad --with forgejo --import-env "$SCRATCH_ENV_FILE" --dry-run
) >"$PLAN_FILE" 2>&1 || PLAN_RC=$?

if [ "$PLAN_RC" -eq 0 ]; then
  pass "init --backend=nomad --with forgejo --dry-run exited 0"
else
  fail "init --backend=nomad --with forgejo --dry-run exited $PLAN_RC"
  cat "$PLAN_FILE" >&2
fi

# ── [3/5] Assert the plan contains all five sections ───────────────────────
STAGE=3
echo "=== Stage 3/5: Plan sections ==="

for section in \
  'Cluster-up dry-run' \
  'Vault policies dry-run' \
  'Vault auth dry-run' \
  'Vault import dry-run' \
  'Deploy services dry-run'
do
  if grep -q "$section" "$PLAN_FILE"; then
    pass "plan contains the ${section} section"
  else
    fail "plan is missing the ${section} section"
  fi
done

# ── [4/5] Every repo path referenced in the plan exists in the tree ────────
STAGE=4
echo "=== Stage 4/5: Plan references resolve to files in the tree ==="

# The dry-run plan interleaves clone-prefixed repo paths with /etc/... and
# /srv/... install targets, so anchor extraction on the tree prefix.
TREE_ESC="$(printf '%s' "$TREE_DIR" | sed 's/\./\\./g')"
REF_PATHS="$(grep -oE "${TREE_ESC}/[A-Za-z0-9_./-]+\.(sh|hcl)" "$PLAN_FILE" | sort -u || true)"
REF_COUNT=0
if [ -n "$REF_PATHS" ]; then
  while IFS= read -r p; do
    REF_COUNT=$((REF_COUNT + 1))
    if [ ! -f "$p" ]; then
      fail "plan references a file that does not exist in the tree: ${p#"$TREE_DIR"/}"
    fi
  done <<<"$REF_PATHS"
fi

if [ "$REF_COUNT" -ge 5 ]; then
  pass "All ${REF_COUNT} referenced repo paths (.sh/.hcl) exist in the tree"
else
  fail "Only ${REF_COUNT} referenced repo paths found in the plan (expected at least 5) — plan output may be broken"
fi

# The policies and import steps are echoed as commands (not executed) in the
# dry-run plan, so their .hcl inputs never appear in the path extraction.
# Check the two entry points explicitly.
for tool in "tools/vault-apply-policies.sh" "tools/vault-import.sh"; do
  if [ -x "${TREE_DIR}/${tool}" ]; then
    pass "${tool} present and executable"
  else
    fail "${tool} missing or not executable in the tree"
  fi
done

# ── [5/5] Stage B — fresh-LXC init (SCRATCH_LXC_NAME-gated) ────────────────
STAGE=5
echo "=== Stage 5/5: Fresh-LXC init (Stage B) ==="

if [ -z "$SCRATCH_LXC_NAME" ]; then
  skip "Stage B: SCRATCH_LXC_NAME not set — no LXD init; set it (plus a working LXD host) to run the real Nomad+Vault deploy"
else
  command -v lxc >/dev/null 2>&1 || {
    fail "Stage B: lxc CLI not on PATH"
  }

  if lxc info "$SCRATCH_LXC_NAME" >/dev/null 2>&1; then
    fail "Stage B: container ${SCRATCH_LXC_NAME} already exists — refusing to clobber it"
  else
    if lxc launch "$SCRATCH_LXC_IMAGE" "$SCRATCH_LXC_NAME" 2>/dev/null; then
      LXC_CREATED=true
      pass "LXC container ${SCRATCH_LXC_NAME} launched from ${SCRATCH_LXC_IMAGE}"
    else
      fail "Stage B: lxc launch ${SCRATCH_LXC_IMAGE} ${SCRATCH_LXC_NAME} failed"
    fi
  fi

  if [ "$FAILED" -eq 0 ]; then
    lxc exec "$SCRATCH_LXC_NAME" -- bash -c \
      'apt-get update -qq && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq git curl sudo ca-certificates' 2>/dev/null \
      || fail "Stage B: failed to install git/curl inside the LXC container"

    if [ "$FAILED" -eq 0 ]; then
      if lxc exec "$SCRATCH_LXC_NAME" -- git clone --branch "$VERSION" --depth 1 "$REPO_URL" /root/disinto 2>/dev/null; then
        pass "Cloned ${VERSION} inside the container"
      else
        fail "Stage B: git clone failed inside the container"
      fi
    fi

    if [ "$FAILED" -eq 0 ]; then
      INIT_LOG="/tmp/disinto-smoke-nomad-init-${SAFE_REF}.log"
      echo "Stage B: running disinto init --backend=nomad --with forgejo (log: ${INIT_LOG})"
      lxc exec "$SCRATCH_LXC_NAME" -- bash -c \
        "cd /root/disinto && sudo ./bin/disinto init placeholder/repo --backend=nomad --with forgejo" \
        >"$INIT_LOG" 2>&1 \
        || {
          fail "Stage B: disinto init failed — see ${INIT_LOG}"
          tail -n 40 "$INIT_LOG" >&2
        }
    fi

    if [ "$FAILED" -eq 0 ]; then
      healthy=false
      for _i in $(seq 1 40); do
        sleep 15
        if lxc exec "$SCRATCH_LXC_NAME" -- nomad job status forgejo 2>/dev/null \
          | grep -q '"running"' && lxc exec "$SCRATCH_LXC_NAME" -- nomad job status forgejo 2>/dev/null \
          | grep -qi healthy; then
          healthy=true
          break
        fi
      done
      if [ "$healthy" = true ]; then
        pass "nomad job status forgejo reports running/healthy"
      else
        fail "Stage B: forgejo job not running/healthy after 10 min"
      fi
    fi

    if [ "$FAILED" -eq 0 ]; then
      if lxc exec "$SCRATCH_LXC_NAME" -- curl -fsS http://127.0.0.1:3000/api/v1/version >/dev/null 2>&1; then
        pass "Forgejo answers on http://127.0.0.1:3000/api/v1/version"
      else
        fail "Stage B: Forgejo not answering on 127.0.0.1:3000"
      fi
    fi
  fi
fi

# ── Summary ─────────────────────────────────────────────────────────────────
echo ""
echo "============================================"
if [ "$FAILED" -ne 0 ]; then
  echo "=== NOMAD RELEASE SMOKE: FAILED ==="
  exit 1
fi
if [ "$SKIPPED" -gt 0 ]; then
  echo "=== NOMAD RELEASE SMOKE: PASSED (${SKIPPED} skipped) ==="
else
  echo "=== NOMAD RELEASE SMOKE: PASSED ==="
fi
echo "============================================"
