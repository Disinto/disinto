#!/usr/bin/env bash
# tests/release-smoke-nomad.sh — Nomad+Vault backend release verification (#1227)
#
# release-smoke.sh only exercises the docker-compose backend. The production
# factory runs the Nomad+Vault backend (`disinto init --backend=nomad`), so a
# tagged release is only actually tested when this script passes too.
#
# Stages (same [N/M] PASS/FAIL/SKIP convention as release-smoke.sh):
#
#   1. Prepare the tree under test — clone the tag into a scratch dir, or
#      validate an existing checkout in place via SRC_DIR (CI).
#   2. Run `disinto init placeholder/repo --backend=nomad --with forgejo
#      --import-env <scratch> --dry-run` and assert exit 0.
#   3. Assert the plan contains all five sections: Cluster-up, Vault
#      policies, Vault auth, Vault import, Deploy services.
#   4. Assert every repo path the plan references (.sh/.hcl under the tree)
#      exists in the tree, the two Vault provisioning entry points are
#      present and executable, and vault/policies/ holds policy files.
#   5. Stage B — fresh-LXC init. Runs only when SCRATCH_LXC_NAME is set on an
#      LXD host: lxc launch, clone the tag, `sudo ./bin/disinto init
#      --backend=nomad --with forgejo`, assert `nomad job status forgejo`
#      reports running and Forgejo answers on 127.0.0.1:3000. Teardown:
#      `lxc delete <name> --force`. Without SCRATCH_LXC_NAME the stage
#      SKIPs (exit 0) — CI has no LXD, so CI coverage is Stages 1-4.
#
# Stage A never mutates host state: the dry-run plan is computed, never
# executed.
#
# Usage:
#   VERSION=v0.3.0 bash tests/release-smoke-nomad.sh
#   SRC_DIR="$PWD" bash tests/release-smoke-nomad.sh          # CI: test the checkout
#   SCRATCH_LXC_NAME=disinto-smoke VERSION=v0.3.0 bash tests/release-smoke-nomad.sh
#
# Env:
#   VERSION             tag or branch to test (default: main)
#   REPO_URL            clone source (default: public Codeberg mirror)
#   SRC_DIR             validate this existing checkout in place (no clone)
#   SCRATCH_LXC_NAME    LXD container name for Stage B (empty = SKIP)
#   SCRATCH_LXC_IMAGE   LXD image for Stage B (default: images:ubuntu/24.04)
#   SCRATCH_LXC_MEMORY  RAM cap (default: 6GiB). Swap is always off.
#   SCRATCH_LXC_CPU     CPU cap (default: 2).
#   SCRATCH_LXC_DISK    Dedicated btrfs loop size (default: 15GiB). The dir
#                       storage driver does NOT enforce quotas — without this
#                       a scratch box can fill the host pool. Empty = refuse
#                       to launch (fail closed). Set to "none" to opt out
#                       (RAM/CPU still capped).
#   NOMAD_INIT_EXTRA_ARGS  extra flags for the Stage B init (word-split),
#                         e.g. "--import-env /root/.env --age-key /root/keys.txt"
#
# Exit 0 = all stages passed or SKIPped; exit 1 = one or more failed.

set -euo pipefail

# ── Defaults ────────────────────────────────────────────────────────────────
VERSION="${VERSION:-main}"
REPO_URL="${REPO_URL:-https://codeberg.org/johba/disinto}"
SRC_DIR="${SRC_DIR:-}"
SCRATCH_LXC_NAME="${SCRATCH_LXC_NAME:-}"
SCRATCH_LXC_IMAGE="${SCRATCH_LXC_IMAGE:-images:ubuntu/24.04}"
SCRATCH_LXC_MEMORY="${SCRATCH_LXC_MEMORY:-6GiB}"
SCRATCH_LXC_CPU="${SCRATCH_LXC_CPU:-2}"
SCRATCH_LXC_DISK="${SCRATCH_LXC_DISK:-15GiB}"
SCRATCH_LXC_STORAGE_SOURCE="${SCRATCH_LXC_STORAGE_SOURCE:-}"
NOMAD_INIT_EXTRA_ARGS="${NOMAD_INIT_EXTRA_ARGS:-}"
CLONE_DIR=""
SCRATCH_ENV_FILE=""
PLAN_FILE=""
LXC_CREATED=false
LXC_POOL_CREATED=""
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
  # If-form (not &&-chains) so set -e cannot abort the trap early and skip
  # the LXC delete below.
  if [ -n "$SCRATCH_ENV_FILE" ] && [ -f "$SCRATCH_ENV_FILE" ]; then
    rm -f "$SCRATCH_ENV_FILE"
  fi
  if [ -n "$PLAN_FILE" ] && [ -f "$PLAN_FILE" ]; then
    rm -f "$PLAN_FILE"
  fi
  # Only delete the container WE created, then the scratch pool if we made it.
  if [ "$LXC_CREATED" = true ] && [ -n "$SCRATCH_LXC_NAME" ]; then
    lxc delete "$SCRATCH_LXC_NAME" --force 2>/dev/null || true
  fi
  if [ -n "$LXC_POOL_CREATED" ]; then
    lxc storage delete "$LXC_POOL_CREATED" 2>/dev/null || true
  fi
  # Only remove the clone WE created; SRC_DIR is the caller's tree.
  if [ -n "$CLONE_DIR" ] && [ -d "$CLONE_DIR" ]; then
    rm -rf "$CLONE_DIR" || true
  fi
}
trap cleanup EXIT

# ── [1/5] Prepare the tree under test ──────────────────────────────────────
STAGE=1
echo "=== Stage 1/5: Prepare tree for ${VERSION} ==="

SAFE_REF="${VERSION//[^A-Za-z0-9._-]/-}"
if [ -n "$SRC_DIR" ]; then
  # CI path: validate the checkout in place. Stage A is read-only with
  # respect to the tree (dry-run only), so no clone is needed.
  if [ -f "${SRC_DIR}/bin/disinto" ]; then
    TREE_DIR="$SRC_DIR"
    pass "Using in-place tree (SRC_DIR=${SRC_DIR})"
  else
    fail "SRC_DIR=${SRC_DIR} has no bin/disinto"
    exit 1
  fi
else
  CLONE_DIR="/tmp/disinto-smoke-nomad-${SAFE_REF}"
  rm -rf "$CLONE_DIR"
  if git clone --branch "$VERSION" --depth 1 "$REPO_URL" "$CLONE_DIR" 2>/dev/null; then
    TREE_DIR="$CLONE_DIR"
    pass "Cloned ${VERSION} to ${CLONE_DIR}"
  else
    fail "Failed to clone ${VERSION} from ${REPO_URL}"
    exit 1
  fi
fi

# ── [2/5] Run the init dry-run plan ────────────────────────────────────────
STAGE=2
echo "=== Stage 2/5: disinto init --backend=nomad --dry-run ==="

# A throwaway env file so the plan exercises the import section.
SCRATCH_ENV_FILE="$(mktemp)"
printf 'SMOKE=placeholder\n' > "$SCRATCH_ENV_FILE"

PLAN_FILE="$(mktemp)"
PLAN_RC=0
(
  cd "$TREE_DIR"
  ./bin/disinto init placeholder/repo \
    --backend=nomad --with forgejo --import-env "$SCRATCH_ENV_FILE" --dry-run
) > "$PLAN_FILE" 2>&1 || PLAN_RC=$?

if [ "$PLAN_RC" -eq 0 ]; then
  pass "init --backend=nomad --with forgejo --dry-run exited 0"
else
  fail "init --backend=nomad --with forgejo --dry-run exited ${PLAN_RC}"
  cat "$PLAN_FILE" >&2
fi

# ── [3/5] Assert the plan contains all five sections ───────────────────────
STAGE=3
echo "=== Stage 3/5: Plan sections ==="

for section in \
  "Cluster-up dry-run" \
  "Vault policies dry-run" \
  "Vault auth dry-run" \
  "Vault import dry-run" \
  "Deploy services dry-run"
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

# The dry-run plan interleaves tree-prefixed repo paths with /etc/ and /srv/
# install targets, so anchor the extraction on the tree prefix.
TREE_ESC="$(printf '%s' "$TREE_DIR" | sed 's/\./\\./g')"
REF_PATHS="$(grep -oE "${TREE_ESC}/[A-Za-z0-9_./-]+\.(sh|hcl)" "$PLAN_FILE" | sort -u || true)"
REF_COUNT=0
MISSING=0
if [ -n "$REF_PATHS" ]; then
  while IFS= read -r p; do
    REF_COUNT=$((REF_COUNT + 1))
    if [ ! -f "$p" ]; then
      fail "plan references a file that does not exist in the tree: ${p#"$TREE_DIR"/}"
      MISSING=1
    fi
  done <<< "$REF_PATHS"
fi

if [ "$MISSING" -ne 0 ]; then
  : # each missing path was already reported via fail above
elif [ "$REF_COUNT" -ge 5 ]; then
  pass "All ${REF_COUNT} referenced repo paths (.sh/.hcl) exist in the tree"
else
  fail "Only ${REF_COUNT} referenced repo paths found in the plan (expected at least 5) — plan output may be broken"
fi

# The policies step syncs every vault/policies/*.hcl from the tree; the plan
# references the step, not the individual files, so check the directory
# holds policies directly. Same for the two provisioning entry points.
for tool in "tools/vault-apply-policies.sh" "tools/vault-import.sh"; do
  if [ -x "${TREE_DIR}/${tool}" ]; then
    pass "${tool} present and executable"
  else
    fail "${tool} missing or not executable in the tree"
  fi
done

if compgen -G "${TREE_DIR}/vault/policies/*.hcl" > /dev/null; then
  pass "vault/policies/ holds policy .hcl files"
else
  fail "no policy .hcl files found under vault/policies/"
fi

# ── [5/5] Stage B — fresh-LXC init (SCRATCH_LXC_NAME-gated) ────────────────
STAGE=5
echo "=== Stage 5/5: Fresh-LXC init (Stage B) ==="

if [ -z "$SCRATCH_LXC_NAME" ]; then
  skip "Stage B: SCRATCH_LXC_NAME not set — no LXD init (set it, plus a working LXD host, to run the real Nomad+Vault deploy)"
else
  command -v lxc > /dev/null 2>&1 || fail "Stage B: lxc CLI not on PATH"

  if [ "$FAILED" -eq 0 ]; then
    if lxc info "$SCRATCH_LXC_NAME" > /dev/null 2>&1; then
      fail "Stage B: container ${SCRATCH_LXC_NAME} already exists — refusing to clobber it"
    else
      launch_args=("$SCRATCH_LXC_IMAGE" "$SCRATCH_LXC_NAME"
        -c "limits.memory=${SCRATCH_LXC_MEMORY}"
        -c limits.memory.swap=false
        -c "limits.cpu=${SCRATCH_LXC_CPU}"
        -c security.nesting=true)
      if [ "$SCRATCH_LXC_DISK" = "none" ]; then
        warn "Stage B: SCRATCH_LXC_DISK=none — no disk quota (dir pool can fill the host)"
      else
        pool_name="${SCRATCH_LXC_NAME}-pool"
        # `source=` on btrfs must be an existing btrfs filesystem, not a
        # directory to place a loop file. Pre-created pools (this host:
        # loop+mount on /opt/ai/lxd) are used as-is. Otherwise create a
        # sized loop in LXD's default disks dir — never pass source=dir.
        if lxc storage show "$pool_name" >/dev/null 2>&1; then
          launch_args+=(-s "$pool_name")
        elif lxc storage create "$pool_name" btrfs "size=${SCRATCH_LXC_DISK}" 2>/dev/null; then
          LXC_POOL_CREATED="$pool_name"
          launch_args+=(-s "$pool_name")
        else
          fail "Stage B: failed to create btrfs pool ${pool_name} size=${SCRATCH_LXC_DISK} (dir pools have no quota — refusing to launch uncapped). Pre-create the pool on the data LV or set SCRATCH_LXC_DISK=none."
        fi
      fi
      if [ "$FAILED" -eq 0 ] && lxc launch "${launch_args[@]}" 2>/dev/null; then
        LXC_CREATED=true
        pass "LXD container ${SCRATCH_LXC_NAME} launched from ${SCRATCH_LXC_IMAGE} (memory=${SCRATCH_LXC_MEMORY} cpu=${SCRATCH_LXC_CPU} disk=${SCRATCH_LXC_DISK})"
      elif [ "$FAILED" -eq 0 ]; then
        fail "Stage B: lxc launch ${SCRATCH_LXC_IMAGE} ${SCRATCH_LXC_NAME} failed"
      fi
    fi
  fi

  if [ "$FAILED" -eq 0 ]; then
    if lxc exec "$SCRATCH_LXC_NAME" -- bash -c \
      'apt-get update -qq && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq git curl sudo ca-certificates' 2> /dev/null; then
      pass "Installed git/curl/sudo inside the container"
    else
      fail "Stage B: failed to install git/curl inside the container"
    fi
  fi

  if [ "$FAILED" -eq 0 ]; then
    if lxc exec "$SCRATCH_LXC_NAME" -- git clone --branch "$VERSION" --depth 1 "$REPO_URL" /root/disinto 2> /dev/null; then
      pass "Cloned ${VERSION} inside the container"
    else
      fail "Stage B: git clone ${VERSION} failed inside the container"
    fi
  fi

  if [ "$FAILED" -eq 0 ]; then
    INIT_LOG="/tmp/disinto-smoke-nomad-init-${SAFE_REF}.log"
    echo "Stage B: running disinto init --backend=nomad --with forgejo (log: ${INIT_LOG})"
    # Random admin pass generated INSIDE the scratch box so forgejo-bootstrap
    # can run unattended. Never printed; dies with the container at EXIT.
    INIT_REMOTE="$(mktemp)"
    {
      cat <<'EOS'
#!/bin/bash
set -euo pipefail
cd /root/disinto
set +o pipefail
pass=$(dd if=/dev/urandom bs=24 count=1 2>/dev/null | base64 | tr -d '\n/=+' | cut -c1-24)
set -o pipefail
[ "${#pass}" -ge 8 ]
printf 'FORGE_ADMIN_PASS=%s\n' "$pass" >> /root/disinto/.env
export FORGE_ADMIN_PASS="$pass"
EOS
      printf 'sudo -n --preserve-env=FORGE_ADMIN_PASS ./bin/disinto init placeholder/repo --backend=nomad --with forgejo %s\n' "${NOMAD_INIT_EXTRA_ARGS}"
    } > "$INIT_REMOTE"
    lxc file push "$INIT_REMOTE" "${SCRATCH_LXC_NAME}/root/stageb-init.sh" >/dev/null
    rm -f "$INIT_REMOTE"
    if lxc exec "$SCRATCH_LXC_NAME" -- bash /root/stageb-init.sh > "$INIT_LOG" 2>&1; then
      pass "disinto init --backend=nomad --with forgejo completed"
    else
      fail "Stage B: disinto init failed — see ${INIT_LOG}"
      tail -n 40 "$INIT_LOG" >&2 || true
    fi
  fi

  if [ "$FAILED" -eq 0 ]; then
    # Host :3000 is not bound (Nomad check is in-alloc). Probe Forgejo
    # the same way bootstrap does. nomad job status -json has no Allocations
    # and may need an ACL token this smoke does not have.
    healthy=false
    for _i in $(seq 1 12); do
      if lxc exec "$SCRATCH_LXC_NAME" -- bash -lc \
        'nomad alloc exec -i=false -job -task forgejo forgejo wget -qO- http://127.0.0.1:3000/api/v1/version' \
        2>/dev/null | grep -q .; then
        healthy=true
        break
      fi
      sleep 5
    done
    if [ "$healthy" = true ]; then
      pass "Forgejo answers /api/v1/version (in-alloc)"
    else
      fail "Stage B: Forgejo not answering /api/v1/version in-alloc"
    fi
  fi

  # Extra probes: the mlockall fix + resource caps. Fail closed if any lie.
  if [ "$FAILED" -eq 0 ]; then
    mlock_line="$(lxc exec "$SCRATCH_LXC_NAME" -- grep -E '^disable_mlock' /etc/vault.d/vault.hcl 2>/dev/null || true)"
    if [ "$mlock_line" = "disable_mlock = true" ]; then
      pass "persisted vault.hcl has disable_mlock=true (mlockall probe denied)"
    else
      fail "Stage B: expected disable_mlock=true in /etc/vault.d/vault.hcl, got: ${mlock_line:-<missing>}"
    fi
  fi
  if [ "$FAILED" -eq 0 ]; then
    if lxc exec "$SCRATCH_LXC_NAME" -- env VAULT_ADDR=http://127.0.0.1:8200 \
         vault status 2>/dev/null | grep -qE 'Sealed[[:space:]]+false'; then
      pass "vault status: unsealed"
    else
      fail "Stage B: vault is not unsealed"
    fi
  fi
  if [ "$FAILED" -eq 0 ]; then
    mem="$(lxc config get "$SCRATCH_LXC_NAME" limits.memory)"
    if [ "$mem" = "$SCRATCH_LXC_MEMORY" ]; then
      pass "LXC limits.memory=${mem}"
    else
      fail "Stage B: limits.memory is '${mem}', expected ${SCRATCH_LXC_MEMORY}"
    fi
  fi
  if [ "$FAILED" -eq 0 ]; then
    root_g="$(lxc exec "$SCRATCH_LXC_NAME" -- df -BG / | awk 'NR==2 { gsub(/G/,"",$2); print $2 }')"
    # Dir pool would show the whole data LV (~300G+). Capped btrfs is ~15.
    if [ -n "$root_g" ] && [ "$root_g" -le 20 ]; then
      pass "container root is ${root_g}G (disk cap held)"
    else
      fail "Stage B: container root is ${root_g:-?}G — disk quota missing?"
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
  echo "=== NOMAD RELEASE SMOKE: PASSED (${SKIPPED} stage(s) skipped) ==="
else
  echo "=== NOMAD RELEASE SMOKE: PASSED ==="
fi
echo "============================================"
