#!/usr/bin/env bash
# =============================================================================
# docker/research/entrypoint.sh — thin entrypoint for disinto/research (#1305)
#
# The research image is a transport (bash, ssh, rsync, jq, ca-certificates —
# no Meep, no Claude, no Playwright). It execs whatever command the runner
# hands it; the real dispatch logic lands in formulas/run-experiment.sh
# (#1308). With no args it drops to a shell for interactive debugging.
# =============================================================================
set -euo pipefail

if [ "$#" -gt 0 ]; then
  exec "$@"
fi
exec /bin/bash
