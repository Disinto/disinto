#!/usr/bin/env bash
set -euo pipefail
echo starting
run_planner_iteration
run_predictor_iteration
run_gardener_iteration
run_supervisor_iteration
