#!/usr/bin/env bash
# guard.sh — Active-state guard for cron entry points
#
# Each agent checks for a state file before running. If the file
# doesn't exist, the agent logs a skip and exits cleanly.
#
# State files live in $FACTORY_ROOT/state/:
#   .dev-active, .reviewer-active, .planner-active, etc.
#
# Presence = permission to run. Absence = skip (factory off by default).

# check_active <agent_name>
#   Exit 0 (skip) if the state file is absent.
check_active() {
  local agent_name="$1"
  local state_file="${FACTORY_ROOT}/state/.${agent_name}-active"
  if [ ! -f "$state_file" ]; then
    echo "[check_active] SKIP: state file state/.${agent_name}-active not found — agent disabled" >&2
    log "${agent_name} not active — skipping"
    exit 0
  fi
}
