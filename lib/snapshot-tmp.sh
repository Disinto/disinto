#!/usr/bin/env bash
# snapshot-tmp.sh — shared temp-file tracking for the snapshot collectors
#
# Sourced by the five snapshot collectors (snapshot-agents.sh,
# snapshot-daemon.sh, snapshot-forge.sh, snapshot-inbox.sh,
# snapshot-nomad.sh). Provides the TMPFILES array, mktemp_safe() and
# cleanup(). Each caller installs its own `trap cleanup EXIT` at top
# level, so every process keeps its own array and trap.
#
# ── Temp file tracking ───────────────────────────────────────────────────────
#
# Two kinds of scratch files, two kinds of tracking:
#
# 1. Files that must live next to their final destination — the
#    ${SNAPSHOT_PATH}.<name>.XXXXXX scratch files that are atomically mv'd
#    into SNAPSHOT_PATH. They must be on the same filesystem as SNAPSHOT_PATH,
#    so they are created at that path and removed one by one from TMPFILES
#    (rm -f in cleanup).
#
# 2. Everything else. mktemp_safe is called from inside command
#    substitutions (e.g. issues_json="$(fetch_issues)"). A subshell cannot grow
#    the parent's TMPFILES array — TMPFILES+=() inside it is lost when the
#    subshell exits — so a per-file cleanup trap could never see these files.
#    They all leak into /tmp (this is issue #1948). The fix: a private per-run
#    directory (SNAPSHOT_RUN_DIR) created at source time by the parent shell
#    that owns the EXIT trap. Every mktemp_safe call with no argument, or a
#    template under /tmp/, is redirected into this one directory, and
#    cleanup() removes the whole directory at once (rm -rf) instead of relying
#    on the per-file TMPFILES list. The directory is created and destroyed by
#    the parent shell, so files a subshell creates go with it.
#
TMPFILES=()

# Private per-run directory, created at source time (top level of the collector
# that sourced this file). All mktemp_safe calls with no argument, or a /tmp/
# template, land here; cleanup() nukes it with rm -rf. Created by the parent
# shell (which owns `trap cleanup EXIT`), so subshell-created files are reaped
# with it.
SNAPSHOT_RUN_DIR="$(mktemp -d "${TMPDIR:-/tmp}/snapshot-run.XXXXXX")"

# Assigns through the global `_TMPFILE` rather than printing to stdout.
# Reason: command substitution forks a subshell, so any TMPFILES+=() inside it
# is discarded when the subshell exits — the parent's array stays empty and
# a per-file cleanup trap could never see those files. Files created under
# SNAPSHOT_RUN_DIR are therefore reaped by cleanup()'s rm -rf (not by the
# TMPFILES list), which is what lets mktemp_safe be called from inside $(…).
mktemp_safe() {
  local template="${1:-}"
  if [ -z "$template" ]; then
    template="${SNAPSHOT_RUN_DIR}/tmp.XXXXXX"
  elif [[ "$template" == /tmp/* ]]; then
    template="${SNAPSHOT_RUN_DIR}/$(basename "$template")"
  fi
  _TMPFILE="$(mktemp "$template")"
  TMPFILES+=("$_TMPFILE")
}

cleanup() {
  rm -f "${TMPFILES[@]}" 2>/dev/null || true
  rm -rf "$SNAPSHOT_RUN_DIR" 2>/dev/null || true
}
