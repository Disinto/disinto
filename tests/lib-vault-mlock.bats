#!/usr/bin/env bats
# =============================================================================
# tests/lib-vault-mlock.bats — Tests for lib/init/nomad/lib-vault-mlock.sh
#
# Issue #1285 + #1287: in the fresh ubuntu:24.04 LXC of v0.5.0 Stage B
# mlock() is denied even though CAP_IPC_LOCK sits in the bounding set
# (apparmor/seccomp or LXC policy below the capability layer) — with the
# repo config's disable_mlock=false the real server exits at startup and
# cluster-up aborts at step 7/9 ("vault.service never starts"). systemd-
# vault.sh must probe mlock FUNCTIONALLY (mlockall, not one page) BEFORE
# writing the persisted vault.hcl and persist
# disable_mlock=true when the attempt does not succeed, while keeping
# disable_mlock=false on hosts where mlock actually works. Bounding-set
# presence does not imply mlock works — the original CapBnd-bit fixture
# tests are gone.
#
# The lock attempt is isolated in vault_mlock_probe_attempt, so both
# directions (lock succeeds / lock denied / nothing can attempt the lock)
# are pinned hermetically against the real repo source file — no container
# privileges, no vault, no systemd.
# =============================================================================

load '../lib/init/nomad/lib-vault-mlock.sh'

setup() {
  REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
  SRC_HCL="${REPO_ROOT}/nomad/vault.hcl"
  STATUS_FILE="${BATS_TEST_TMPDIR}/status"
  [ -f "$SRC_HCL" ] || { echo "missing repo source: $SRC_HCL" >&2; return 1; }
}

# _write_status CAPBND [CAPEFF] — write a /proc/self/status-shaped file with
# the given CapBnd. The probe no longer reads it; these fixtures only prove
# the probe ignores the bounding set (the #1285/#1287 regression itself).
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

# _sandbox_path DIR — restrict PATH to a fresh dir containing only the
# minimal utilities (printf/mkdir/chmod/rm, symlinked from the real PATH)
# the test body AND bats's own tmpdir cleanup need. The probe's
# interpreter selection then resolves against exactly the fake interpreters
# the test installs in DIR.
_sandbox_path() {
  local dir="$1"
  rm -rf "$dir"; mkdir -p "$dir"
  local tool
  for tool in printf mkdir chmod rm; do
    ln -s "$(command -v "$tool")" "${dir}/$tool" 2>/dev/null || true
  done
  PATH="$dir"
}

# _fake_bin DIR NAME EXIT_CODE [STDERR_TEXT] — write a fake interpreter
# script that (optionally) emits noise on stderr and exits with EXIT_CODE.
_fake_bin() {
  local dir="$1" name="$2" rc="$3" noise="${4:-}"
  {
    printf '#!/bin/sh\n'
    [ -n "$noise" ] && printf 'echo %s >&2\n' "$noise"
    printf 'exit %s\n' "$rc"
  } > "${dir}/${name}"
  chmod +x "${dir}/${name}"
}

# ── vault_mlock_probe — the functional probe ────────────────────────────────

@test "probe: lock attempt succeeds → mlock available (stub rc 0)" {
  vault_mlock_probe_attempt() { return 0; }
  run vault_mlock_probe
  [ "$status" -eq 0 ]
}

@test "probe: lock attempt denied → mlock unavailable (stub rc 1)" {
  vault_mlock_probe_attempt() { return 1; }
  run vault_mlock_probe
  [ "$status" -ne 0 ]
}

@test "probe: nothing can attempt the lock → mlock unavailable (stub rc 2, safe direction)" {
  vault_mlock_probe_attempt() { return 2; }
  run vault_mlock_probe
  [ "$status" -ne 0 ]
}

@test "probe: crashed attempt (unexpected rc > 2) → mlock unavailable (safe direction)" {
  vault_mlock_probe_attempt() { return 3; }
  run vault_mlock_probe
  [ "$status" -ne 0 ]
}

@test "probe: CapBnd bit 14 present but the lock attempt denied → unavailable (the #1287 Stage B regression)" {
  _write_status 0000000000004000     # CAP_IPC_LOCK in the bounding set…
  vault_mlock_probe_attempt() { return 1; }   # …yet mlock() is still denied
  run vault_mlock_probe
  [ "$status" -ne 0 ]
}

@test "probe: CapBnd bit 14 absent but the lock attempt succeeded → available (probe ignores the bounding set)" {
  _write_status 00000000a80425fb     # unprivileged-container-style mask…
  vault_mlock_probe_attempt() { return 0; }   # …but the real lock succeeds
  run vault_mlock_probe
  [ "$status" -eq 0 ]
}

@test "probe: real (unstubbed) probe answers 0, 1, or 2 — never a crash" {
  run vault_mlock_probe
  [ "$status" -le 2 ]
}

@test "probe: real (unstubbed) probe is stable across two runs" {
  run vault_mlock_probe
  local first="$status"
  run vault_mlock_probe
  [ "$status" -eq "$first" ]
}

@test "probe: perl is preferred when both interpreters exist (PATH sandbox)" {
  local bin="${BATS_TEST_TMPDIR}/bin"
  _sandbox_path "$bin"
  _fake_bin "$bin" perl 0
  _fake_bin "$bin" python3 1
  run vault_mlock_probe
  [ "$status" -eq 0 ]
}

@test "probe: python3 is used when perl is absent (PATH sandbox)" {
  local bin="${BATS_TEST_TMPDIR}/bin"
  _sandbox_path "$bin"
  _fake_bin "$bin" python3 1
  run vault_mlock_probe
  [ "$status" -eq 1 ]
}

@test "probe: neither perl nor python3 exists → rc 2 (PATH sandbox)" {
  local bin="${BATS_TEST_TMPDIR}/bin"
  _sandbox_path "$bin"
  run vault_mlock_probe
  [ "$status" -eq 2 ]
}

@test "probe: interpreter diagnostics are suppressed (silent probe)" {
  local bin="${BATS_TEST_TMPDIR}/bin"
  _sandbox_path "$bin"
  _fake_bin "$bin" perl 0 "perl diagnostic noise"
  run vault_mlock_probe
  [ "$status" -eq 0 ]
  [ -z "$output" ]
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
  # Exactly one line differs from the source: same line count, and
  # byte-identical once the disable_mlock line is stripped from both.
  # (Not "count normal-diff < / > marker lines": alpine CI's busybox diff
  # emits unified output only, where changed lines carry - / + prefixes.)
  [ "$(wc -l < "$src")" -eq "$(wc -l < "$out")" ]
  diff <(grep -v '^disable_mlock' "$src") <(grep -v '^disable_mlock' "$out")
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
# source: functional probe → (repo copy | mlock-disabled variant) → persist.
# The "unavailable" case is the Stage B unprivileged-LXC path; the
# "available" case is the capable-host path that must keep
# disable_mlock=false byte-for-byte.

_persist_config() {
  # $1 = output path
  local out="$1"
  local desired="$SRC_HCL"
  if ! vault_mlock_probe; then
    desired="${BATS_TEST_TMPDIR}/desired.hcl"
    vault_hcl_with_mlock_disabled "$SRC_HCL" "$desired"
  fi
  install -m 0644 "$desired" "$out"
}

@test "decision: mlock unavailable → persisted config has disable_mlock=true, all else identical" {
  vault_mlock_probe_attempt() { return 1; }   # Stage B: bit present, mlock denied
  local out="${BATS_TEST_TMPDIR}/vault.hcl"
  _persist_config "$out"
  grep -q '^disable_mlock = true$' "$out"
  [ "$(grep -c '^disable_mlock' "$out")" -eq 1 ]
  # Exactly one line flipped vs the repo source; storage/listener/ui intact.
  # (Same portability rationale as the render test above.)
  [ "$(wc -l < "$SRC_HCL")" -eq "$(wc -l < "$out")" ]
  diff <(grep -v '^disable_mlock' "$SRC_HCL") <(grep -v '^disable_mlock' "$out")
  grep -q 'path = "/var/lib/vault/data"' "$out"
  grep -q 'tls_disable = true' "$out"
}

@test "decision: mlock available → persisted config is the repo copy, byte-for-byte" {
  vault_mlock_probe_attempt() { return 0; }
  local out="${BATS_TEST_TMPDIR}/vault.hcl"
  _persist_config "$out"
  cmp -s "$SRC_HCL" "$out"
  grep -q '^disable_mlock = false$' "$out"
}

# ── Regression guards on the scripts themselves ──────────────────────────────
#
# The fix's point is ORDER: probe mlock, then write vault.hcl. If a refactor
# reorders (or reverts to copying the repo copy unconditionally) the Stage B
# container breaks again. Line-order guards, same style as the `sudo -n --
# env` guard in tests/disinto-init-nomad.bats.

@test "systemd-vault.sh probes mlock functionally before installing the persisted config" {
  local script="${REPO_ROOT}/lib/init/nomad/systemd-vault.sh"
  local probe_line install_line
  probe_line="$(grep -nF 'vault_mlock_probe' "$script" | head -1 | cut -d: -f1)"
  install_line="$(grep -nF 'install -m 0644 -o root -g root "$VAULT_HCL_DESIRED"' "$script" | head -1 | cut -d: -f1)"
  [ -n "$probe_line" ]
  [ -n "$install_line" ]
  [ "$probe_line" -lt "$install_line" ]
  # The CapBnd-bit probe (#1285) must be gone — bounding-set presence does
  # not imply mlock works (#1287).
  [ -z "$(grep -nF 'vault_ipc_lock_in_bounding_set' "$script")" ]
}

@test "systemd-vault.sh logs an explicit WARN naming the tradeoff when mlock is unavailable" {
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

@test "probe attempt is mlockall, not a one-page mlock" {
  local lib="${REPO_ROOT}/lib/init/nomad/lib-vault-mlock.sh"
  grep -q 'mlockall' "$lib"
  ! grep -q '4096' "$lib"
  local script="${REPO_ROOT}/lib/init/nomad/systemd-vault.sh"
  grep -q 'mlockall' "$script"
  ! grep -q 'one page locked' "$script"
}
