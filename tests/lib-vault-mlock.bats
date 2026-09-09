#!/usr/bin/env bats
# =============================================================================
# tests/lib-vault-mlock.bats — Tests for lib/init/nomad/lib-vault-mlock.sh
#
# Issue #1285: in an unprivileged container (the fresh ubuntu:24.04 LXC of
# v0.5.0 Stage B) CAP_IPC_LOCK is not in the bounding set, so the
# vault.service unit's AmbientCapabilities grant cannot apply and the
# persisted config's disable_mlock=false makes the real server exit at
# startup — init aborts at cluster-up step 7/9 ("vault.service never
# starts"). systemd-vault.sh must probe CapBnd (bit 14) BEFORE writing the
# persisted vault.hcl and persist disable_mlock=true when the capability is
# absent, while keeping disable_mlock=false on capable hosts.
#
# The probe takes the /proc/self/status analogue as an argument, so both
# directions (capability present / absent) are pinned hermetically against
# the real repo source file — no container privileges, no vault, no systemd.
# =============================================================================

load '../lib/init/nomad/lib-vault-mlock.sh'

setup() {
  REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
  SRC_HCL="${REPO_ROOT}/nomad/vault.hcl"
  STATUS_FILE="${BATS_TEST_TMPDIR}/status"
  [ -f "$SRC_HCL" ] || { echo "missing repo source: $SRC_HCL" >&2; return 1; }
}

# _write_status CAPBND [CAPEFF] — write a /proc/self/status-shaped file with
# the given CapBnd. CapPrm/CapEff default to 00000000a80425fb (bit 14 CLEARED)
# on purpose: the decoy differs from the CapBnd under test, so a probe that
# reads the wrong field (e.g. CapEff) fails the "available" tests below.
_write_status() {
  local capbnd="$1"
  local capprm="${2:-00000000a80425fb}"
  cat > "$STATUS_FILE" <<EOF
Name:   probe-test
Umask:  0022
State:  R (running)
Pid:    4242
PPid:   1
CapPrm: ${capprm}
CapEff: ${capprm}
CapBnd: ${capbnd}
CapInh: 0000000000000000
CapAmb: 0000000000000000
EOF
}

# ── vault_ipc_lock_in_bounding_set — the probe ───────────────────────────────

@test "probe: CapBnd with bit 14 set → available (even when CapEff lacks it)" {
  _write_status 0000000000004000
  run vault_ipc_lock_in_bounding_set "$STATUS_FILE"
  [ "$status" -eq 0 ]
}

@test "probe: unprivileged-container mask (bit 14 cleared) → not available" {
  _write_status 00000000a80425fb
  run vault_ipc_lock_in_bounding_set "$STATUS_FILE"
  [ "$status" -ne 0 ]
}

@test "probe: full 64-bit mask (high bit set, signed-arithmetic path) → available" {
  _write_status ffffffffffffffff
  run vault_ipc_lock_in_bounding_set "$STATUS_FILE"
  [ "$status" -eq 0 ]
}

@test "probe: all bits except bit 14 → not available" {
  _write_status ffffffffffffbfff
  run vault_ipc_lock_in_bounding_set "$STATUS_FILE"
  [ "$status" -ne 0 ]
}

@test "probe: only adjacent bit 13 → not available" {
  _write_status 0000000000002000
  run vault_ipc_lock_in_bounding_set "$STATUS_FILE"
  [ "$status" -ne 0 ]
}

@test "probe: only adjacent bit 15 → not available" {
  _write_status 0000000000008000
  run vault_ipc_lock_in_bounding_set "$STATUS_FILE"
  [ "$status" -ne 0 ]
}

@test "probe: zero mask → not available" {
  _write_status 0000000000000000
  run vault_ipc_lock_in_bounding_set "$STATUS_FILE"
  [ "$status" -ne 0 ]
}

@test "probe: status file without a CapBnd line → not available (safe direction)" {
  printf 'Name:   probe-test\nCapEff: 0000000000004000\n' > "$STATUS_FILE"
  run vault_ipc_lock_in_bounding_set "$STATUS_FILE"
  [ "$status" -ne 0 ]
}

@test "probe: missing status file → not available (safe direction)" {
  run vault_ipc_lock_in_bounding_set "${BATS_TEST_TMPDIR}/no-such-file"
  [ "$status" -ne 0 ]
}

@test "probe: malformed CapBnd (too short) → not available" {
  _write_status 00000000004000
  run vault_ipc_lock_in_bounding_set "$STATUS_FILE"
  [ "$status" -ne 0 ]
}

@test "probe: malformed CapBnd (non-hex) → not available" {
  _write_status 00000000zzzz4000
  run vault_ipc_lock_in_bounding_set "$STATUS_FILE"
  [ "$status" -ne 0 ]
}

@test "probe: default argument reads /proc/self/status consistently" {
  run vault_ipc_lock_in_bounding_set
  local default_rc="$status"
  # Either answer is valid on any host; a crash (rc > 1) is not.
  [ "$default_rc" -le 1 ]
  run vault_ipc_lock_in_bounding_set /proc/self/status
  [ "$status" -eq "$default_rc" ]
}

# ── vault_hcl_with_mlock_disabled — the renderer ─────────────────────────────

@test "render: rewrites the disable_mlock=false line in place, all else byte-identical" {
  local src="${BATS_TEST_TMPDIR}/in.hcl" out="${BATS_TEST_TMPDIR}/out.hcl"
  cat > "$src" <<'EOF'
storage "file" {
  path = "/var/lib/vault/data"
}
disable_mlock = false
api_addr = "http://127.0.0.1:8200"
EOF
  vault_hcl_with_mlock_disabled "$src" "$out"
  [ "$(grep -c '^disable_mlock' "$out")" -eq 1 ]
  grep -q '^disable_mlock = true$' "$out"
  # Exactly one line differs from the source.
  [ "$(diff "$src" "$out" | grep -c '^[<>]')" -eq 2 ]
}

@test "render: appends a disable_mlock line when the file has none" {
  local src="${BATS_TEST_TMPDIR}/in.hcl" out="${BATS_TEST_TMPDIR}/out.hcl"
  printf 'ui = true\n' > "$src"
  vault_hcl_with_mlock_disabled "$src" "$out"
  [ "$(grep -c '^disable_mlock' "$out")" -eq 1 ]
  [ "$(tail -1 "$out")" = "disable_mlock = true" ]
}

@test "render: idempotent on an already-mlock-disabled config" {
  local src="${BATS_TEST_TMPDIR}/in.hcl" out="${BATS_TEST_TMPDIR}/out.hcl"
  printf 'disable_mlock = true\n' > "$src"
  vault_hcl_with_mlock_disabled "$src" "$out"
  [ "$(cat "$out")" = "disable_mlock = true" ]
}

# ── Persisted-config decision flow (what systemd-vault.sh installs) ──────────
#
# Replicates systemd-vault.sh's config-install decision against the real repo
# source: probe → (repo copy | mlock-disabled variant) → persist. The "absent"
# case is the Stage B unprivileged-LXC path; the "present" case is the
# capable-host path that must keep disable_mlock=false byte-for-byte.

_persist_config() {
  # $1 = status file (probe input), $2 = output path
  local status_file="$1" out="$2"
  local desired="$SRC_HCL"
  if ! vault_ipc_lock_in_bounding_set "$status_file"; then
    desired="${BATS_TEST_TMPDIR}/desired.hcl"
    vault_hcl_with_mlock_disabled "$SRC_HCL" "$desired"
  fi
  install -m 0644 "$desired" "$out"
}

@test "decision: capability absent → persisted config has disable_mlock=true, all else identical" {
  _write_status 00000000a80425fb   # Stage B unprivileged-LXC-style mask
  local out="${BATS_TEST_TMPDIR}/vault.hcl"
  _persist_config "$STATUS_FILE" "$out"
  grep -q '^disable_mlock = true$' "$out"
  [ "$(grep -c '^disable_mlock' "$out")" -eq 1 ]
  # Exactly one line flipped vs the repo source; storage/listener/ui intact.
  [ "$(diff "$SRC_HCL" "$out" | grep -c '^[<>]')" -eq 2 ]
  grep -q 'path = "/var/lib/vault/data"' "$out"
  grep -q 'tls_disable = true' "$out"
}

@test "decision: capability present → persisted config is the repo copy, byte-for-byte" {
  _write_status 0000000000004000
  local out="${BATS_TEST_TMPDIR}/vault.hcl"
  _persist_config "$STATUS_FILE" "$out"
  cmp -s "$SRC_HCL" "$out"
  grep -q '^disable_mlock = false$' "$out"
}

# ── Regression guards on the scripts themselves ──────────────────────────────
#
# The fix's point is ORDER: probe CapBnd, then write vault.hcl. If a refactor
# reorders (or reverts to copying the repo copy unconditionally) the Stage B
# container breaks again. Line-order guards, same style as the `sudo -n --
# env` guard in tests/disinto-init-nomad.bats.

@test "systemd-vault.sh probes CAP_IPC_LOCK before installing the persisted config" {
  local script="${REPO_ROOT}/lib/init/nomad/systemd-vault.sh"
  local probe_line install_line
  probe_line="$(grep -nF 'vault_ipc_lock_in_bounding_set' "$script" | head -1 | cut -d: -f1)"
  install_line="$(grep -nF 'install -m 0644 -o root -g root "$VAULT_HCL_DESIRED"' "$script" | head -1 | cut -d: -f1)"
  [ -n "$probe_line" ]
  [ -n "$install_line" ]
  [ "$probe_line" -lt "$install_line" ]
}

@test "systemd-vault.sh logs an explicit WARN naming the tradeoff when the capability is absent" {
  local script="${REPO_ROOT}/lib/init/nomad/systemd-vault.sh"
  local warn
  warn="$(grep -F 'log "WARN' "$script" | grep -F 'disable_mlock=true')"
  [ -n "$warn" ]
  [[ "$warn" == *"tradeoff"* ]]
  [[ "$warn" == *"dev-persisted-seal"* ]]
}

@test "systemd-vault.sh unit template still grants CAP_IPC_LOCK (unit file untouched)" {
  local script="${REPO_ROOT}/lib/init/nomad/systemd-vault.sh"
  grep -q 'CapabilityBoundingSet=CAP_IPC_LOCK' "$script"
  grep -q 'AmbientCapabilities=CAP_IPC_LOCK' "$script"
}
