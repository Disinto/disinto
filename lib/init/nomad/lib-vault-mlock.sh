#!/usr/bin/env bash
# =============================================================================
# lib/init/nomad/lib-vault-mlock.sh — functional mlock probe + mlock-aware
# vault.hcl renderer
#
# Sourced by lib/init/nomad/systemd-vault.sh (issues #1285, #1287). In the
# fresh ubuntu:24.04 LXC of v0.5.0 Stage B, mlock() is denied even though
# CAP_IPC_LOCK sits in the bounding set — apparmor/seccomp or LXC policy
# below the capability layer still blocks it — so the original CapBnd-bit
# probe (#1285) reported "capable" while the real server exited at startup
# with the repo config's disable_mlock=false and cluster-up aborted at step
# 7/9 ("vault.service never starts"). Bounding-set presence does not imply
# mlock works; #1287 replaces the bit check with a FUNCTIONAL probe: attempt
# to actually lock one page and report success/failure.
#
# The probe tries perl first (perl-base is essential on Ubuntu —
# POSIX::mlock on a scratch scalar); when perl is absent it falls back to
# python3 via ctypes; when neither interpreter exists it reports "absent"
# (rc 2) — the safe direction (the service still starts; only the mlock
# guarantee is dropped) — and the caller WARNs.
#
# Deliberately out of scope (per #1285's decision): the temporary bootstrap
# server in vault-init.sh (already mlock-disabled by #1274) and the unit
# file (its CAP_IPC_LOCK grant is harmless to keep; it simply cannot help
# where a policy below the capability layer denies mlock).
#
# Public API (sourced into caller scope):
#
#   vault_mlock_probe
#     True (0) iff a real one-page mlock attempt succeeds in the current
#     environment. Returns 1 when the attempt was made and denied; 2 when
#     no interpreter (perl/python3) is available to attempt it. The actual
#     attempt lives in vault_mlock_probe_attempt — the single seam tests
#     stub in both directions without any privileged environment.
#
#   vault_hcl_with_mlock_disabled SRC DST
#     Render SRC to DST with disable_mlock=true: rewrites the existing
#     `disable_mlock` line in place, or appends one when absent (same
#     semantics as vault-init.sh's ephemeral temp-server config, #1274).
#     Everything else stays byte-identical, so a host where mlock works
#     again heals back to the repo copy on the next install.
#
# Pure function library — no top-level side effects, no dependency on the
# caller's log()/die(), so it can be loaded directly from bats tests.
# =============================================================================

# vault_mlock_probe
#   Functional probe: attempt to actually lock one page and report the
#   result. Interpreter order: perl (POSIX::mlock on a scratch scalar),
#   then python3 (ctypes). The attempt answers 0 (locked) / 1 (denied) /
#   2 (no interpreter can perform the attempt); an unexpected rc > 2 is
#   normalised to 2 — "no mlock" is the safe direction either way.
vault_mlock_probe() {
  local rc=0
  vault_mlock_probe_attempt || rc=$?
  [ "$rc" -le 2 ] || rc=2
  return "$rc"
}

# vault_mlock_probe_attempt
#   The actual one-page mlock attempt — the seam tests stub in both
#   directions. perl is preferred (perl-base is essential on Ubuntu;
#   POSIX::mlock on a scratch scalar); python3 (ctypes) is the fallback.
#   Each interpreter answers 0 (locked) / 1 (denied) / 2 (cannot probe —
#   e.g. a perl built without POSIX::mlock) / >2 (crash). A non-definitive
#   answer hands over to the next interpreter; when nothing is left it
#   returns 2 ("absent"). Interpreter diagnostics go to /dev/null: the
#   probe is silent either way, only the exit code carries the answer.
vault_mlock_probe_attempt() {
  local rc=0
  if command -v perl >/dev/null 2>&1; then
    perl -MPOSIX -e 'exit 2 unless defined &POSIX::mlock; my $page = "x" x 4096; exit(POSIX::mlock($page) ? 0 : 1)' 2>/dev/null
    rc=$?
    [ "$rc" -le 1 ] && return "$rc"
  fi
  if command -v python3 >/dev/null 2>&1; then
    python3 -c '
import ctypes
import sys
libc = ctypes.CDLL(None)
buf = (ctypes.c_char * 4096)()
sys.exit(0 if libc.mlock(buf, len(buf)) == 0 else 1)
' 2>/dev/null
    rc=$?
    [ "$rc" -le 1 ] && return "$rc"
  fi
  return 2
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
