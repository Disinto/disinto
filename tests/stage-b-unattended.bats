#!/usr/bin/env bats
# Guards for unattended Stage B (empty-box Forgejo + parameterized jobs).

setup() {
  ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
}

@test "deploy.sh does not wait on parameterized batch jobs" {
  grep -q 'parameterized batch job' "$ROOT/lib/init/nomad/deploy.sh"
  grep -q 'no deployment to wait for' "$ROOT/lib/init/nomad/deploy.sh"
}

@test "forgejo-bootstrap empty-box path uses su-exec git, not root" {
  grep -q 'su-exec git' "$ROOT/lib/init/nomad/forgejo-bootstrap.sh"
  grep -q 'CREATE_VIA_CLI' "$ROOT/lib/init/nomad/forgejo-bootstrap.sh"
  ! grep -q 'nomad alloc exec -t=false' "$ROOT/lib/init/nomad/forgejo-bootstrap.sh"
}

@test "smoke Stage B mints FORGE_ADMIN_PASS inside the scratch box" {
  grep -q 'FORGE_ADMIN_PASS' "$ROOT/tests/release-smoke-nomad.sh"
  grep -q 'stageb-init.sh' "$ROOT/tests/release-smoke-nomad.sh"
}

@test "smoke Stage B does not overlay product files from the host tree" {
  ! grep -q 'forgejo-bootstrap.sh' "$ROOT/tests/release-smoke-nomad.sh" || \
    grep -q 'stageb-init' "$ROOT/tests/release-smoke-nomad.sh"
  ! grep 'lxc file push' "$ROOT/tests/release-smoke-nomad.sh" | grep -q bootstrap
  ! grep 'lxc file push' "$ROOT/tests/release-smoke-nomad.sh" | grep -q deploy.sh
}

@test "smoke Stage B probes Forgejo in-alloc, not host :3000 only" {
  grep -q 'in-alloc' "$ROOT/tests/release-smoke-nomad.sh"
}
