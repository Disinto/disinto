#!/usr/bin/env bash
# =============================================================================
# lib/init/nomad/lib-vault-mlock.sh — CAP_IPC_LOCK probe + mlock-aware vault.hcl
#
# Sourced by lib/init/nomad/systemd-vault.sh (issue #1285). Unprivileged
# containers (the fresh ubuntu:24.04 LXC of v0.5.0 Stage B) do not carry
# CAP_IPC_LOCK in their bounding set, so the vault.service unit's
# AmbientCapabilities=CAP_IPC_LOCK grant can never be applied and mlock()
# would fail — with the repo config's disable_mlock=false the real server
# exits at startup and cluster-up aborts at step 7/9 ("vault.service never
# starts"). The probe below lets systemd-vault.sh persist disable_mlock=true
# on such hosts (with an explicit WARN naming the tradeoff) while keeping
# disable_mlock=false on capable hosts.
#
# Deliberately out of scope (per #1285's decision): the temporary bootstrap
# server in vault-init.sh (already mlock-disabled by #1274) and the unit
# file (its CAP_IPC_LOCK grant is harmless to keep; it simply cannot apply
# where the bounding set forbids it).
#
# Public API (sourced into caller scope):
#
#   vault_ipc_lock_in_bounding_set [STATUS_FILE]
#     True (0) iff CAP_IPC_LOCK (bit 14) is in the capability bounding set.
#     Parses CapBnd (16-hex-digit 64-bit mask) from STATUS_FILE, defaulting
#     to /proc/self/status. A missing or malformed CapBnd returns 1 —
#     "no capability" is the safe direction (the service still starts; only
#     the mlock guarantee is dropped).
#
#   vault_hcl_with_mlock_disabled SRC DST
#     Render SRC to DST with disable_mlock=true: rewrites the existing
#     `disable_mlock` line in place, or appends one when absent (same
#     semantics as vault-init.sh's ephemeral temp-server config, #1274).
#     Everything else stays byte-identical, so a host that regains the
#     capability heals back to the repo copy on the next install.
#
# Pure function library — no top-level side effects, no dependency on the
# caller's log()/die(), so it can be loaded directly from bats tests.
# =============================================================================

# vault_ipc_lock_in_bounding_set [STATUS_FILE]
#   CAP_IPC_LOCK is bit 14 of the kernel capability mask (capabilities(7)).
#   CapBnd can exceed 2^63 (bash arithmetic is signed 64-bit), but bit 14
#   sits far below the sign bit, so `$(( (value >> 14) & 1 ))` isolates it
#   correctly for both positive and high-bit-set (negative) masks.
vault_ipc_lock_in_bounding_set() {
  local status_file="${1:-/proc/self/status}"
  local capbnd
  capbnd="$(awk '$1 == "CapBnd:" { print $2; exit }' "$status_file" 2>/dev/null || true)"
  [[ "$capbnd" =~ ^[0-9a-fA-F]{16}$ ]] || return 1
  local value=$((16#$capbnd))
  [ $(( (value >> 14) & 1 )) -eq 1 ]
}

# vault_hcl_with_mlock_disabled SRC DST
vault_hcl_with_mlock_disabled() {
  local src="$1" dst="$2"
  if grep -q '^disable_mlock' "$src"; then
    sed 's/^disable_mlock.*/disable_mlock = true/' "$src" > "$dst"
  else
    cat "$src" > "$dst"
    printf '\ndisable_mlock = true\n' >> "$dst"
  fi
}
