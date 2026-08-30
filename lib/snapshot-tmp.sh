#!/usr/bin/env bash
# snapshot-tmp.sh — shared temp-file tracking for the snapshot collectors
#
# Sourced by the five snapshot collectors (snapshot-agents.sh,
# snapshot-daemon.sh, snapshot-forge.sh, snapshot-inbox.sh,
# snapshot-nomad.sh). Provides the TMPFILES array, mktemp_safe() and
# cleanup(). Each caller installs its own `trap cleanup EXIT` at top
# level, so every process keeps its own array and trap.

# ── Temp file tracking ───────────────────────────────────────────────────────

TMPFILES=()

# Assigns through a global `_TMPFILE` rather than printing to stdout. Reason:
# command substitution forks a subshell, so any TMPFILES+=() inside it is
# discarded when the subshell exits — the parent's array stays empty and
# the cleanup trap rm -fs nothing. Calling mktemp_safe directly (no $(…))
# keeps the array updates in the parent shell where the trap can see them.
mktemp_safe() {
  _TMPFILE="$(mktemp "$@")"
  TMPFILES+=("$_TMPFILE")
}

cleanup() {
  rm -f "${TMPFILES[@]}" 2>/dev/null || true
}
