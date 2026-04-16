#!/usr/bin/env bash
# =============================================================================
# lib/init/nomad/lib-systemd.sh — Shared idempotent systemd-unit installer
#
# Sourced by lib/init/nomad/systemd-nomad.sh and lib/init/nomad/systemd-vault.sh
# (and any future sibling) to collapse the "write unit if content differs,
# daemon-reload, enable (never start)" boilerplate.
#
# Install-but-don't-start is the invariant this helper enforces — mid-migration
# installers land files and enable units; the orchestrator (S0.4) starts them.
#
# Public API (sourced into caller scope):
#
#   systemd_require_preconditions UNIT_PATH
#     Asserts the caller is uid 0 and `systemctl` is on $PATH. Calls the
#     caller's die() with a UNIT_PATH-scoped message on failure.
#
#   systemd_install_unit UNIT_PATH UNIT_NAME UNIT_CONTENT
#     Writes UNIT_CONTENT to UNIT_PATH (0644 root:root) only if on-disk
#     content differs. If written, runs `systemctl daemon-reload`. Then
#     enables UNIT_NAME (no-op if already enabled). Never starts the unit.
#
# Caller contract:
#   - Callers MUST define `log()` and `die()` before sourcing this file (we
#     call log() for status chatter and rely on the caller's error-handling
#     stance; `set -e` propagates install/cmp/systemctl failures).
# =============================================================================

# systemd_require_preconditions UNIT_PATH
systemd_require_preconditions() {
  local unit_path="$1"
  if [ "$(id -u)" -ne 0 ]; then
    die "must run as root (needs write access to ${unit_path})"
  fi
  command -v systemctl >/dev/null 2>&1 \
    || die "systemctl not found (systemd is required)"
}

# systemd_install_unit UNIT_PATH UNIT_NAME UNIT_CONTENT
systemd_install_unit() {
  local unit_path="$1"
  local unit_name="$2"
  local unit_content="$3"

  local needs_reload=0
  if [ ! -f "$unit_path" ] \
     || ! printf '%s\n' "$unit_content" | cmp -s - "$unit_path"; then
    log "writing unit → ${unit_path}"
    # Subshell-scoped EXIT trap guarantees the temp file is removed on
    # both success AND set-e-induced failure of `install`. A function-
    # scoped RETURN trap does NOT fire on errexit-abort (bash only runs
    # RETURN on normal function exit), so the subshell is the reliable
    # cleanup boundary. It's also isolated from the caller's EXIT trap.
    (
      local tmp
      tmp="$(mktemp)"
      trap 'rm -f "$tmp"' EXIT
      printf '%s\n' "$unit_content" > "$tmp"
      install -m 0644 -o root -g root "$tmp" "$unit_path"
    )
    needs_reload=1
  else
    log "unit file already up to date"
  fi

  if [ "$needs_reload" -eq 1 ]; then
    log "systemctl daemon-reload"
    systemctl daemon-reload
  fi

  if systemctl is-enabled --quiet "$unit_name" 2>/dev/null; then
    log "${unit_name} already enabled"
  else
    log "systemctl enable ${unit_name}"
    systemctl enable "$unit_name" >/dev/null
  fi
}
