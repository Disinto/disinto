#!/usr/bin/env bash
# =============================================================================
# planner/after-gardener.sh — the planner waits for a running gardener (#2163)
#
# Since #2151 the gardener's job runs two roles, gardener,planner.
# docker/agents/entrypoint.sh paces each slow organ by iteration * POLL_INTERVAL
# modulo its interval (#1388), and 43200 is a multiple of 21600: every 12 hours
# the gardener and the planner start in the same iteration, the gardener first.
# Both runs call ensure_ops_repo (lib/formula-session.sh) on the one ops clone
# and pull it at the same moment — on 2026-11-07 the two overlapped ("Cannot
# fast-forward to multiple branches"), leaving the gardener on an un-updated
# clone and the planner reading the previous run's tape grades and
# catalog/claims.md.
#
# The wait keys on the running process, not a fixed schedule offset: it holds
# whatever the intervals are and however long the gardener actually takes.
#
# Function (sourced; called by planner/planner-run.sh):
#   planner_wait_for_gardener
#     -> returns 0 always. While pgrep finds gardener-run.sh, sleeps
#        PLANNER_GARDENER_POLL_S (default 60) and checks again, counting the
#        wait by adding the poll interval per sleep — never the clock, so a
#        test can stub sleep. Gives up after PLANNER_GARDENER_WAIT_S (default
#        10800 = 3 h; gardener runs take about 45 to 75 minutes) and logs that
#        the planner runs anyway. A non-integer value in either variable falls
#        back to its default. Waiting never stops a planner run.
# =============================================================================
set -euo pipefail

# planner_wait_for_gardener — see the file header.
planner_wait_for_gardener() {
  local poll="${PLANNER_GARDENER_POLL_S:-60}"
  local cap="${PLANNER_GARDENER_WAIT_S:-10800}"
  # A non-integer value falls back to the default.
  case "$poll" in
    '' | *[!0-9]*) poll=60 ;;
  esac
  case "$cap" in
    '' | *[!0-9]*) cap=10800 ;;
  esac

  local waited=0
  while pgrep -f "gardener-run.sh" >/dev/null; do
    if [ "$waited" -eq 0 ]; then
      log "gardener is running; the planner waits for it"
    fi
    if [ "$waited" -ge "$cap" ]; then
      log "gardener still running after ${waited}s; the planner runs anyway"
      return 0
    fi
    sleep "$poll"
    waited=$((waited + poll))
  done
  if [ "$waited" -gt 0 ]; then
    log "gardener finished; the planner waited ${waited}s"
  fi
  return 0
}
