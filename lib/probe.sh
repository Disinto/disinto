#!/usr/bin/env bash
# =============================================================================
# lib/probe.sh — run a probe and read its number (#1673)
#
# Sprint effects and claim checks both run a probe from the ops repo and read
# one number from it. This is the shared runner: the path rule, the timeout
# and the number check live here, not in each caller. No callers yet —
# tools/sprint-outcomes.sh and tools/claim-checks.sh will source it.
#
# Sourced from the caller:
#   source "$(dirname "$0")/../lib/probe.sh"
#
# Storage (env, the test seam):
#   $OPS_REPO_ROOT    — ops repo clone; the probe runs as
#                       bash "${OPS_REPO_ROOT}/PATH"
#   $PROBE_TIMEOUT_S  — wall-clock seconds for `timeout` (default 300)
#
# Function:
#   probe_value PATH
#     PATH must start with `probes/` and hold no `..`. Otherwise print one
#     reason line on stderr and return 2, without running anything.
#     Otherwise run:
#       timeout "${PROBE_TIMEOUT_S:-300}" bash "${OPS_REPO_ROOT}/PATH"
#     (probes need not be executable). Exit 0 and a last stdout line that is
#     a number — integer or decimal, may be negative, the same shape
#     sprint_expect_met accepts (`^-?([0-9]+(\.[0-9]+)?|\.[0-9]+)$`): print
#     that number and return 0. Anything else: print nothing on stdout, one
#     reason line on stderr, return 1.
#
# Hermetic aside from the probe itself: bash + timeout. No network, no forge,
# no agent, no secrets (AD-006).
# =============================================================================
set -euo pipefail

# probe_value PATH — see the file header. The probe's own stdout/stderr is
# captured; on failure only the one reason line reaches the caller, so a
# noisy probe cannot leak past this function.
probe_value() {
  local path="${1:-}"
  # Path rule first, before OPS_REPO_ROOT is even read: a bad path must not
  # run, and must not depend on the ops clone existing.
  if [[ "$path" != probes/* || "$path" == *..* ]]; then
    printf 'bad path\n' >&2
    return 2
  fi
  if [ -z "${OPS_REPO_ROOT:-}" ]; then
    printf 'OPS_REPO_ROOT is unset\n' >&2
    return 1
  fi

  local tmp rc limit start_ts last line
  tmp="$(mktemp -d)"
  rc=0
  limit="${PROBE_TIMEOUT_S:-300}"
  # date -u +%s is the portable epoch (busybox date cannot parse @epoch).
  start_ts="$(date -u +%s)"
  # The issue's command, exactly: probes need not be executable, so bash
  # runs the file. Probe stdout/stderr stay in the temp dir.
  timeout "$limit" bash "${OPS_REPO_ROOT}/${path}" >"$tmp/out" 2>"$tmp/err" || rc=$?
  # busybox timeout (alpine CI) reports the child's signal-death status
  # (143=TERM, 137=KILL) where GNU coreutils reports 124. A signal death
  # at/after the limit is a timeout either way; a 143/137 before the limit
  # (for example an OOM kill) stays a probe exit.
  if [[ "$limit" =~ ^[0-9]+$ ]] \
    && { [ "$rc" -eq 143 ] || [ "$rc" -eq 137 ]; } \
    && [ "$(( $(date -u +%s) - start_ts ))" -ge "$limit" ]; then
    rc=124
  fi
  if [ "$rc" -eq 124 ]; then
    rm -rf "$tmp"
    printf 'probe timed out\n' >&2
    return 1
  fi
  if [ "$rc" -ne 0 ]; then
    rm -rf "$tmp"
    printf 'probe exited %s\n' "$rc" >&2
    return 1
  fi

  last=""
  while IFS= read -r line || [ -n "${line:-}" ]; do
    last="$line"
  done <"$tmp/out"
  rm -rf "$tmp"
  # A CRLF probe would otherwise fail the number check on the trailing CR.
  last="${last%$'\r'}"
  if [[ ! "$last" =~ ^-?([0-9]+(\.[0-9]+)?|\.[0-9]+)$ ]]; then
    printf 'last line is not a number\n' >&2
    return 1
  fi
  printf '%s\n' "$last"
}
