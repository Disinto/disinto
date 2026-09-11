#!/usr/bin/env bats
# Stage B must not launch an uncapped LXC (host RAM/disk).

setup() {
  SCRIPT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)/tests/release-smoke-nomad.sh"
}

@test "Stage B defaults cap memory, cpu, and disk" {
  grep -q 'SCRATCH_LXC_MEMORY:-6GiB' "$SCRIPT"
  grep -q 'SCRATCH_LXC_CPU:-2' "$SCRIPT"
  grep -q 'SCRATCH_LXC_DISK:-15GiB' "$SCRIPT"
}

@test "Stage B launch always sets limits.memory and disables swap" {
  grep -q 'limits.memory=${SCRATCH_LXC_MEMORY}' "$SCRIPT"
  grep -q 'limits.memory.swap=false' "$SCRIPT"
}

@test "Stage B refuses to launch when the btrfs pool cannot be created" {
  grep -q 'refusing to launch uncapped' "$SCRIPT"
}

@test "Stage B cleanup deletes the scratch pool it created" {
  grep -q 'lxc storage delete' "$SCRIPT"
  # Container delete must come before pool delete (pool busy otherwise).
  local del_ct del_pool
  del_ct="$(grep -n 'lxc delete \"$SCRATCH_LXC_NAME\"' "$SCRIPT" | head -1 | cut -d: -f1)"
  del_pool="$(grep -n 'lxc storage delete' "$SCRIPT" | head -1 | cut -d: -f1)"
  [ "$del_ct" -lt "$del_pool" ]
}

@test "bare uncapped lxc launch IMAGE NAME is gone" {
  ! grep -E 'lxc launch "\$SCRATCH_LXC_IMAGE" "\$SCRATCH_LXC_NAME"' "$SCRIPT"
}
