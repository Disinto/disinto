#!/usr/bin/env bash
# =============================================================================
# lib/init/nomad/lib-vault-mlock.sh — functional mlockall probe + mlock-aware
# vault.hcl renderer
#
# Sourced by lib/init/nomad/systemd-vault.sh (issues #1285, #1287, follow-up).
# Vault does mlockall(MCL_CURRENT|MCL_FUTURE), not a one-page mlock(). In
# the v0.5.0 Stage B unprivileged ubuntu:24.04 LXC:
#   CapBnd has CAP_IPC_LOCK, mlock(4k) succeeds, mlockall() returns ENOMEM
#   (ulimit -l is 8192, systemd LimitMEMLOCK=infinity cannot raise it).
# #1287's one-page probe therefore kept disable_mlock=false and
# vault.service still died at cluster-up 7/9. This probe attempts mlockall.
#
# Interpreter order:
#   1. perl, only when POSIX::mlockall is defined (perl-base usually is not)
#   2. python3 ctypes libc.mlockall
#   3. neither → rc 2 (absent-means-absent); caller WARNs
#
# Deliberately out of scope: vault-init.sh temp server (#1274, already
# mlock-disabled) and the unit file (CAP_IPC_LOCK grant stays).
#
# Public API (sourced into caller scope):
#
#   vault_mlock_probe
#     True (0) iff mlockall() succeeds here. 1 = attempted and denied;
#     2 = no capable interpreter. Unexpected rc > 2 → 2 (safe direction).
#     vault_mlock_probe_attempt is the seam tests stub.
#
#   vault_hcl_with_mlock_disabled SRC DST
#     Render SRC to DST with disable_mlock=true (rewrite or append).
#
# Pure function library — no top-level side effects, no log()/die().
# =============================================================================

vault_mlock_probe() {
  local rc=0
  vault_mlock_probe_attempt || rc=$?
  [ "$rc" -le 2 ] || rc=2
  return "$rc"
}

# vault_mlock_probe_attempt — real mlockall. Tests stub this in both
# directions. perl if POSIX::mlockall exists; else python3; else rc 2.
# A non-definitive perl answer (rc > 1) hands over to python3.
vault_mlock_probe_attempt() {
  local rc=0
  if command -v perl >/dev/null 2>&1; then
    # MCL_CURRENT|MCL_FUTURE == 3. perl-base has no POSIX::mlockall → rc 2.
    perl -MPOSIX -e 'exit 2 unless defined &POSIX::mlockall; exit(POSIX::mlockall(3) ? 0 : 1)' 2>/dev/null
    rc=$?
    [ "$rc" -le 1 ] && return "$rc"
  fi
  if command -v python3 >/dev/null 2>&1; then
    python3 -c '
import ctypes, sys
libc = ctypes.CDLL(None)
MCL_CURRENT, MCL_FUTURE = 1, 2
sys.exit(0 if libc.mlockall(MCL_CURRENT | MCL_FUTURE) == 0 else 1)
' 2>/dev/null
    rc=$?
    [ "$rc" -le 1 ] && return "$rc"
  fi
  return 2
}

vault_hcl_with_mlock_disabled() {
  local src="$1" dst="$2"
  if grep -q '^disable_mlock' "$src"; then
    sed 's/^disable_mlock.*/disable_mlock = true/' "$src" > "$dst"
  else
    cat "$src" > "$dst"
    printf '\ndisable_mlock = true\n' >> "$dst"
  fi
}
